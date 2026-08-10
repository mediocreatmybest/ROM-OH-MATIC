#!/usr/bin/perl
#
# Verify an arbitrary EFI/PE binary against a public certificate.
#
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------
#
# Standalone from build.fcgi on purpose: this checks a binary the caller
# already has -- built here, built elsewhere, or received from a third
# party -- not one this request builds. It shares build.fcgi's process
# model (FastCGI via the same mod_fcgid handler, no separate Apache
# config needed) and its subprocess-safety conventions (list-form exec,
# app-generated temp paths, per-request cleanup), but none of its git/
# cache machinery, which this has no use for.
#
# Takes only a PUBLIC certificate. There is no key material anywhere in
# this file -- see build.fcgi's sign_binary() for the signing side, which
# is deliberately kept separate for exactly that reason: this endpoint's
# whole safety story is "nothing secret ever arrives here", and mixing it
# into the same code path as key handling would put that one keystroke
# away from being wrong.
#
### Dependencies
# apt-get install sbsigntool
#
### Apache
# Handled by the same "AddHandler fcgid-script .fcgi" rule build.fcgi
# uses -- see install.sh's fcgid.conf. No separate registration needed.

use CGI qw ( :cgi );
use FCGI;
use File::Temp;
use File::Spec::Functions qw ( tmpdir catdir catfile );
use IO::File;
use IO::Handle;
use IPC::Open3;
use JSON::PP qw ( encode_json );
use Symbol qw ( gensym );
use Sub::Override;
use strict;
use warnings;

my $tmpdir = tmpdir();

# Bounds checked independently at the field level below; this is the
# outer limit on the whole request body, checked by CGI.pm itself before
# any of this script's own code runs. Without it, an upload with no
# Content-Length ceiling at all would be fully buffered to disk before
# the per-field size check ever gets a chance to reject it.
use constant REQUEST_MAX_BYTES => 34_000_000; # binary + cert + multipart overhead
$CGI::POST_MAX = REQUEST_MAX_BYTES;

use constant CERT_MAX_BYTES   => 65536;      # 64 KiB -- one certificate
use constant BINARY_MAX_BYTES => 33_554_432; # 32 MiB -- generous for any real iPXE EFI binary
use constant VERIFY_TIMEOUT_SECS => 10;

# Duplicate original STDOUT and STDERR before the main loop starts
# redirecting them per-request (see build.fcgi's identical pattern).
open my $origstdout, ">&", \*STDOUT or die "Could not dup STDOUT: $!\n";
open my $origstderr, ">&", \*STDERR or die "Could not dup STDERR: $!\n";

###############################################################################
#
# Run a command with a wall-clock timeout, capturing stdout and stderr
# separately without ever going through a shell.
#
# Sequential blocking reads on the two pipes are safe here specifically
# because the only command this is used for (sbverify) has an output
# vocabulary consisting entirely of single short lines -- confirmed
# empirically across every failure mode this script guards against
# (unsigned, wrong certificate, truncated file, garbage input, missing
# file). That is far below a pipe's buffer size, so the child can never
# block waiting for this process to drain the other stream first. This
# is not a generally-safe pattern for an arbitrary command; it is safe
# for this one, known, bounded-output command.
#
sub run_capturing {
  my @cmd = ( "timeout", VERIFY_TIMEOUT_SECS, @_ );
  my ( $childout, $childerr ) = ( gensym(), gensym() );
  my $pid = open3 ( my $childin, $childout, $childerr, @cmd );
  close $childin;
  local $/ = undef;
  my $stdout = <$childout>;
  my $stderr = <$childerr>;
  waitpid ( $pid, 0 );
  my $rc = $? >> 8;
  return ( $rc, ( defined $stdout ? $stdout : "" ), ( defined $stderr ? $stderr : "" ) );
}

###############################################################################
#
# Respond with a JSON body and exit this request (not the process -- the
# main loop's per-request fork means "exit" below only ends this child).
#

sub respond {
  my $fcgiout = shift;
  my $cgi = shift;
  my $status = shift;
  my $data = shift;
  print $fcgiout $cgi->header ( -status => $status, -type => "application/json; charset=utf-8" );
  print $fcgiout encode_json ( $data );
}

###############################################################################
#
# Verify. Returns a hashref for respond() -- never dies past this point,
# so every path through here produces a clean JSON response rather than
# the plain-text 500 build.fcgi uses (this is a checking tool, not a
# build; "the file doesn't verify" is an ordinary result, not a fault).
#

sub verify {
  my $cgi = shift;

  return { error => "This endpoint accepts POST only." }
      unless uc ( $cgi->request_method() // "" ) eq "POST";

  if ( $cgi->cgi_error() ) {
    return { error => "Request too large or malformed: ".$cgi->cgi_error() };
  }

  # --- Certificate: PEM text only, already validated client-side by
  # certificate.php -- independently re-validated here, same principle
  # as build.fcgi's trust_cert(): never trust that validation already
  # ran, since this endpoint is directly reachable on its own. ---
  my $certPem = $cgi->param ( "VERIFY_CERT" );
  return { error => "No certificate supplied." }
      unless defined $certPem && length $certPem;
  return { error => "Certificate data exceeds the ".CERT_MAX_BYTES()."-byte limit." }
      if length ( $certPem ) > CERT_MAX_BYTES;

  foreach my $marker ( "-----BEGIN PRIVATE KEY-----",
			"-----BEGIN RSA PRIVATE KEY-----",
			"-----BEGIN EC PRIVATE KEY-----",
			"-----BEGIN ENCRYPTED PRIVATE KEY-----",
			"-----BEGIN DSA PRIVATE KEY-----" ) {
    return { error => "Private key material was detected and is not accepted. This tool only ever needs a public certificate." }
	if index ( $certPem, $marker ) >= 0;
  }

  my @certBlocks = ( $certPem =~
		      /(-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----)/sg );
  return { error => "No PEM certificate block found." } unless @certBlocks;
  return { error => "Only a single certificate is supported for verification; ".scalar ( @certBlocks )." were supplied." }
      if @certBlocks > 1;

  # --- Binary: an arbitrary upload, the whole reason this file exists.
  # Never executed or interpreted as anything but bytes for sbverify to
  # parse -- see run_capturing() above and the module comment. ---
  my $upload = $cgi->param ( "VERIFY_BINARY" );
  return { error => "No file was uploaded to verify." } unless $upload;
  my $uploadPath = $cgi->tmpFileName ( $upload );
  return { error => "Could not read the uploaded file." }
      unless $uploadPath && -f $uploadPath;
  my $size = -s $uploadPath;
  return { error => "Uploaded file exceeds the ".BINARY_MAX_BYTES()."-byte limit." }
      if $size > BINARY_MAX_BYTES;
  return { error => "Uploaded file is empty." } if $size == 0;

  # Dedicated, per-request temporary directory with app-generated
  # filenames -- never derived from the uploaded filename or content.
  my $dirfh = File::Temp->newdir ( "ipxe-verify-XXXXXX", DIR => $tmpdir, CLEANUP => 1 );
  my $dir = $dirfh->dirname;

  my $certFile = catfile ( $dir, "cert.pem" );
  open my $certFh, ">", $certFile or return { error => "Internal error preparing certificate." };
  print $certFh $certBlocks[0];
  close $certFh;

  my ( $checkRc ) = run_capturing ( "openssl", "x509", "-in", $certFile, "-noout" );
  return { error => "The supplied certificate could not be parsed as X.509." }
      if $checkRc != 0;

  my ( $rc, $stdout, $stderr ) = run_capturing ( "sbverify", "--cert", $certFile, $uploadPath );

  if ( $rc == 0 ) {
    return {
      verified => JSON::PP::true,
      reason   => "match",
      message  => "This file's Secure Boot signature matches the supplied certificate.",
    };
  }

  if ( $rc == 1 ) {
    # sbverify's entire failure vocabulary, confirmed empirically (see the
    # module comment above) rather than assumed. Anything not matched
    # falls through to the generic "mismatch" case, which is also what a
    # binary signed by a different key produces.
    if ( $stderr =~ /No signature table present/ ) {
      return { verified => JSON::PP::false, reason => "unsigned",
	       message => "This file has no Secure Boot signature at all." };
    }
    if ( $stderr =~ /DOS header|a\.out header|too small|Can't open image|Error reading file/ ) {
      return { verified => JSON::PP::false, reason => "invalid",
	       message => "This does not look like a valid PE/COFF (EFI) binary." };
    }
    return { verified => JSON::PP::false, reason => "mismatch",
	     message => "This file has a Secure Boot signature, but it does not match the supplied certificate." };
  }

  # Anything else (the "timeout" wrapper's 124, a signal death, sbverify
  # itself crashing) is treated as our failure to get a clean answer, not
  # a verification result -- reported distinctly rather than folded into
  # "mismatch", and logged with detail server-side only.
  warn "verify.fcgi: sbverify exited ".$rc." (stderr: ".$stderr.")\n";
  return { verified => JSON::PP::false, reason => "error",
	   message => "Could not check this file. Try again, or with a smaller file." };
}

###############################################################################
#
# Main loop -- same skeleton as build.fcgi's, minus everything specific
# to building (niceness, cache locking, the git/make pipeline).
#

$SIG{CHLD} = "IGNORE";
my $fcgi_destroy_override = Sub::Override->new ( "FCGI::DESTROY", sub {} );

while ( 1 ) {
  my $fcgiin = IO::Handle->new();
  my $fcgiout = IO::Handle->new();
  my $request = FCGI::Request ( $fcgiin, $fcgiout, $fcgiout );
  last if $request->Accept() < 0;

  if ( ! $request->IsFastCGI() ) {
    open $fcgiin, "<&", \*STDIN or die "Could not dup STDIN: $!\n";
    open $fcgiout, ">&", \*STDOUT or die "Could not dup STDOUT: $!\n";
  }

  $request->Detach();
  my $child = fork();
  if ( ! defined $child ) {
    die "Could not fork: $!\n";
  } elsif ( $child ) {
    next;
  }
  $fcgi_destroy_override->restore();
  $request->Attach();
  $request->LastCall();

  my $cgi;
  {
    local *STDIN = $fcgiin;
    $cgi = CGI->new();
  }

  undef $SIG{CHLD};

  my $logfh = ( -t STDERR ? undef : File::Temp->new() );
  if ( $logfh ) {
    $logfh->autoflush();
    close STDOUT;
    open STDOUT, ">&", $logfh or die "Could not dup logfh for STDOUT: $!\n";
    close STDERR;
    open STDERR, ">&", $logfh or die "Could not dup logfh for STDERR: $!\n";
  }

  my $result = eval { verify ( $cgi ) };
  if ( $@ ) {
    warn $@;
    $result = { verified => JSON::PP::false, reason => "error",
		message => "Could not check this file." };
  }

  close STDOUT;
  open STDOUT, ">&", $origstdout or die "Could not restore STDOUT: $!\n";
  close STDERR;
  open STDERR, ">&", $origstderr or die "Could not restore STDERR: $!\n";

  my $status = $result->{error} ? "400 Bad Request" : "200 OK";
  respond ( $fcgiout, $cgi, $status, $result );

  exit ( 0 );
}
