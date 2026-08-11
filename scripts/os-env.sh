#!/bin/bash
# shellcheck disable=SC2034 # every var here is consumed by whichever
# script sources this file (install.sh, start.sh), not by this file itself.
#
# TARGET_OS -> user/group/path mapping, sourced by both install.sh (at
# build time, from a copy alongside it at /tmp/os-env.sh) and start.sh (at
# container runtime, from its normal location in the cloned repo) so the
# two never drift apart on what "ubuntu" or "alpine" actually means.
#
# `exit 1` in the unknown-OS case below terminates whichever script
# sourced this file too -- both install.sh and start.sh should fail hard
# on an unrecognised TARGET_OS rather than silently guessing.
TARGET_OS="${TARGET_OS:-ubuntu}"

case "$TARGET_OS" in
    ubuntu)
	WWW_OWNER=www-data:www-data
	DOCROOT_LINK=/var/www/html
	APACHE_MAIN_CONF=/etc/apache2/apache2.conf
	APACHE_FOREGROUND_CMD=(apachectl -D FOREGROUND)
	# There's no Ubuntu equivalent of Alpine's conf.d auto-include (see
	# below) -- fcgid.conf here both loads the module (a2enmod's job on
	# a real install) and carries this app's own <Files ~ (\.fcgi)>
	# handler block.
	FCGID_CONF_PATH=/etc/apache2/mods-enabled/fcgid.conf
	;;
    alpine)
	WWW_OWNER=apache:apache
	DOCROOT_LINK=/var/www/localhost/htdocs
	APACHE_MAIN_CONF=/etc/apache2/httpd.conf
	# Alpine's apache2 package ships no apachectl wrapper, just httpd
	# itself; -D FOREGROUND is the same flag either way.
	APACHE_FOREGROUND_CMD=(httpd -D FOREGROUND)
	# apache-mod-fcgid already drops its own conf.d snippet that loads
	# the module and an unrelated /fcgi-bin/ alias -- this app's own
	# <Files ~ (\.fcgi)> handler block still needs to be added, just as
	# its own file rather than overwriting the package's.
	FCGID_CONF_PATH=/etc/apache2/conf.d/rom-o-matic-fcgid.conf
	;;
    *)
	echo "os-env.sh: unknown TARGET_OS '$TARGET_OS' (expected 'ubuntu' or 'alpine')" >&2
	exit 1
	;;
esac
