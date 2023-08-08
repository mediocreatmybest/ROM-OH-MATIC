#!/usr/bin/env perl
#
# Generates list of options from header file
#
# Initial version by Francois Lacroix <xbgmsharp@gmail.com>
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2019 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE.txt
# Website:  http://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------
### Dependencies
# apt-get install libjson-perl
# or
# perl -MCPAN -e 'install JSON'
### Install
# Link the script into the ipxe source eg: /opt/ipxe/src/util/
### Run
# The script is run by options.php

use strict;
use warnings;
use autodie;
use v5.10;
use JSON;

my $bool; # list of define value

my $directory = '/opt/rom-o-matic/ipxe/src/config';
opendir my $dir, $directory or die $!;
while (my $file = readdir($dir))
{
	next unless ($file =~ m/.h$/);
	next if($file =~ m/(defaults|colour|named).h$/);

	open my $fh, "$directory/$file" or die $!;
	while(my $line = <$fh>) {
		
		chomp($line);
		next unless($line =~ m|/*#(un)?def|);

		if (
			# match line with value and description
			$line =~ m/^(?<Disabled>\/*)#(?<Type>\w+)\s+(?<Name>\w+)(?!\s+\/\*)\s+(?<Value>"[^"]*"|[A-Za-z0-9_-]+|\d+)\s+\/\*\s+(?<Description>(?:.(?!\*\/))+)/ ||
			# match line with value only
			$line =~ m/^(?<Disabled>\/*)#(?<Type>\w+)\s+(?<Name>\w+)(?!\s+\/\*)\s+(?<Value>"[^"]*"|[A-Za-z0-9_-]+|\d+)(?<Description>)/ ||
			# match line with description only
			$line =~ m/^(?<Disabled>\/*)#(?<Type>\w+)\s+(?<Name>\w+)\s+\/\*\s+(?<Description>(?:.(?!\*\/))+)(?<Value>)/ ||
			# match line without value or description
			$line =~ m/^(?<Disabled>\/*)#(?<Type>\w+)\s+(?<Name>\w+)(?<Value>)(?<Description>)/
		)
		{
			if ($+{Value} ne "")
			{
				my $value = $+{Value};
				$value =~ s/^"|"$//g;
				push(@$bool, {
					file		=> $file,
					type		=> "input",
					name		=> $+{Name},
					value		=> $value,
					description 	=> $+{Description}
				});
			}
			elsif ($+{Disabled} eq "\\")
			{
				my $type = $+{Type} == "define" ? "undef" : "define";
				push(@$bool, {
					file		=> $file,
					type		=> $type,
					name		=> $+{Name},
					description 	=> $+{Description}
				});
			}
			else
			{
				push(@$bool, {
					file		=> $file,
					type		=> $+{Type},
					name		=> $+{Name},
					description	=> $+{Description}
				});
			}	
		}

	}
	close $fh;
}
closedir $dir;

print JSON->new->pretty->utf8->encode(\@$bool);

exit;
