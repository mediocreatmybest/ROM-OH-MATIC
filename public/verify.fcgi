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
# Checks a binary the caller already has -- built here, built elsewhere,
# or received from a third party -- rather than one this request builds.
# Shares build.fcgi's process model (FastCGI under the same mod_fcgid
# handler) and its subprocess conventions, but none of its git/cache
# machinery.
#
# Takes only a PUBLIC certificate; no key material exists anywhere in
# this file. That is the whole reason it is a separate file from
# build.fcgi's sign_binary() rather than another branch inside it.
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
use File::Spec::Functions qw ( tmpdir catfile );
use IO::Handle;
use IPC::Open3;
use JSON::PP qw ( encode_json );
use Symbol qw ( gensym );
use Sub::Override;
use strict;
use warnings;

my $tmpdir = tmpdir();

# Outer limit on the whole request body, applied by CGI.pm before any of
# this script's own field-level checks run -- otherwise an oversized
# upload is buffered to disk in full before anything rejects it. Must
# stay under install.sh's FcgidMaxRequestLen, or mod_fcgid rejects the
# request with its own generic 500 first and the JSON error below never
# gets sent.
use constant REQUEST_MAX_BYTES => 34_000_000; # binary + cert + multipart overhead
$CGI::POST_MAX = REQUEST_MAX_BYTES;

use constant CERT_MAX_BYTES   => 65536;      # 64 KiB -- one certificate
use constant BINARY_MAX_BYTES => 33_554_432; # 32 MiB -- generous for any real iPXE EFI binary
use constant VERIFY_TIMEOUT_SECS => 10;

# Written by start.sh, once, when UI_ENABLE_CERT_FEATURE=true -- see the
# identical constant and comment in build.fcgi, which this endpoint's
# feature toggle must always agree with. Marks enabled, not disabled, so
# the absence of the file leaves this endpoint off.
use constant CERT_FEATURE_FLAG => "/opt/rom-o-matic/.cert-feature-enabled";

# Duplicate original STDOUT and STDERR before the main loop starts
# redirecting them per-request (see build.fcgi's identical pattern).
open my $origstdout, ">&", \*STDOUT or die "Could not dup STDOUT: $!\n";
open my $origstderr, ">&", \*STDERR or die "Could not dup STDERR: $!\n";

###############################################################################
#
# Run a command with a wall-clock timeout, capturing stdout and stderr
# separately, never through a shell.
#
# Reading the two pipes sequentially would deadlock a command that fills
# one while this waits on the other. Safe here only because the commands
# used (sbverify, openssl x509 -noout) emit a single short line in every
# case -- checked against each one this script handles. Not a pattern to
# copy for an arbitrary command.
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

  return { error => "Certificate verification is not enabled on this deployment." }
      unless -e CERT_FEATURE_FLAG;

  return { error => "This endpoint accepts POST only." }
      unless uc ( $cgi->request_method() // "" ) eq "POST";

  if ( $cgi->cgi_error() ) {
    return { error => "Request too large or malformed: ".$cgi->cgi_error() };
  }

  # Re-validated here even though certificate.php already checked it
  # client-side -- this endpoint is reachable on its own, so it cannot
  # assume that ran. (build.fcgi's trust_cert() takes the same position.)
  my $certPem = $cgi->param ( "VERIFY_CERT" );
  return { error => "No certificate supplied." }
      unless defined $certPem && length $certPem;
  return { error => "Certificate data exceeds the ".CERT_MAX_BYTES()."-byte limit." }
      if length ( $certPem ) > CERT_MAX_BYTES;

  # Nothing here ever needs a key, so refuse one rather than quietly
  # accepting and ignoring it.
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

  # The uploaded binary. Only ever passed to sbverify as a path to parse;
  # never executed, and never used to derive a path of our own.
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

  # CGI->new() parses the whole request -- including the uploaded binary --
  # eagerly, before verify() ever runs, so it is just as able to die on
  # malformed or adversarial input as anything inside verify() itself. Not
  # wrapping it left a real gap in this file's own stated guarantee ("never
  # dies past this point"): an exception here would propagate straight out
  # of this forked child with no FCGI response ever sent, which mod_fcgid
  # can only see as the process dying and answers with its own generic
  # error page -- exactly the kind of opaque failure this endpoint exists
  # to avoid for the caller.
  my $cgi;
  eval {
    local *STDIN = $fcgiin;
    $cgi = CGI->new();
  };
  if ( $@ ) {
    warn "verify.fcgi: could not parse the request: $@";
    # CGI->new() failed, so $cgi never got assigned -- respond() still
    # needs a working CGI object to build response headers with, which an
    # empty one (no input to parse, so nothing left to fail on) provides.
    respond ( $fcgiout, CGI->new ( "" ), "400 Bad Request",
	      { verified => JSON::PP::false, reason => "error",
		message => "Could not read the request." } );
    exit ( 0 );
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
