#!/bin/bash
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------

# Selects the package manager and every OS-specific path/user/package name
# below. Set by the Dockerfile (ENV TARGET_OS, from ARG TARGET_OS) so it's
# also available at container runtime, e.g. to start.sh. Defaults to ubuntu
# so a plain `bash install.sh` outside the Dockerfile behaves as before.
TARGET_OS="${TARGET_OS:-ubuntu}"

case "$TARGET_OS" in
    ubuntu)
	WWW_USER=www-data
	WWW_GROUP=www-data
	DOCROOT_LINK=/var/www/html
	;;
    alpine)
	WWW_USER=apache
	WWW_GROUP=apache
	DOCROOT_LINK=/var/www/localhost/htdocs
	;;
    *)
	echo "install.sh: unknown TARGET_OS '$TARGET_OS' (expected 'ubuntu' or 'alpine')" >&2
	exit 1
	;;
esac

# Every package installed below, before anything touches the filesystem
# with $WWW_USER/$WWW_GROUP. On Ubuntu www-data already exists in the base
# image, but on Alpine the apache user is created by the apache2 package
# itself -- chowning to it earlier (as this script briefly did) fails with
# "unknown user/group" because that package hasn't been installed yet.
if [ "$TARGET_OS" = "ubuntu" ]; then
    # Fix "Error debconf: unable to initialize frontend: Dialog"
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

    # Upgrade system
    apt-get update && apt-get -yq dist-upgrade

    # install git client
    apt-get -yq install git

    # Install basic compilation tools and dev libraries
    apt-get -yq install \
	build-essential \
	iasl mtools perl python3 \
	subversion uuid-dev liblzma-dev xz-utils

    # Install CGI Perl dependencies
    apt-get -yq install \
	liburi-perl \
	libfcgi-perl \
	libconfig-inifiles-perl \
	libipc-system-simple-perl \
	libsub-override-perl \
	libcgi-pm-perl

    # Install Apache with fast CGI and PHP module
    apt-get -yq install \
	libapache2-mod-fcgid \
	libapache2-mod-php
    a2enmod fcgid php8.5

    # Install JSON library Perl
    apt-get -yq install \
	libjson-perl \
	libjson-any-perl \
	libjson-xs-perl

    # Install extra packages to allow to build ISO and EFI binary
    apt-get -yq install \
	binutils-dev \
	genisoimage \
	syslinux \
	isolinux

    # sbsigntool: sbsign/sbverify, for optionally signing a built EFI binary
    # for Secure Boot with an admin-supplied key, and for verifying an
    # arbitrary EFI binary against a public certificate. Neither feature
    # generates or stores any key -- see public/build.fcgi's sign_binary()
    # and public/verify.fcgi.
    apt-get -yq install \
	sbsigntool

    # configure fast-cgi
    cat << EOF > /etc/apache2/mods-enabled/fcgid.conf
<IfModule mod_fcgid.c>
    FcgidConnectTimeout 120
    FcgidIdleTimeout 3600
    FcgidBusyTimeout 300
    FcgidIOTimeout 360
    # Raised from the previous 15 MiB to comfortably clear verify.fcgi's own
    # 34 MB request cap (32 MiB binary + certificate + multipart overhead) --
    # otherwise mod_fcgid rejects an oversized-but-under-the-app-limit
    # upload itself, as a generic 500 page, before verify.fcgi's own check
    # ever runs to explain why. This is a ceiling, not a target: build.fcgi's
    # own per-field limits (TRUST_MAX_BYTES etc.) are unchanged and are what
    # actually bounds a normal build request.
    FcgidMaxRequestLen 40000000
    <IfModule mod_mime.c>
        AddHandler fcgid-script .fcgi
    </IfModule>
    <Files ~ (\.fcgi)>
        SetHandler fcgid-script
        Options +FollowSymLinks +ExecCGI
    </Files>
</IfModule>
EOF
else
    # Alpine's index needs refreshing the same way apt's does; --no-cache
    # skips the local package index cache entirely instead of needing a
    # separate `rm -rf /var/cache/apk/*` cleanup step later.
    apk update
    apk add --no-cache git
    # Alpine ships no shell but busybox ash by default. install.sh,
    # start.sh and update.sh all use bash-specific syntax, so bash is
    # installed here rather than rewritten to plain POSIX sh.
    apk add --no-cache bash

    apk add --no-cache \
	build-base \
	iasl mtools perl python3 \
	subversion util-linux-dev xz-dev

    apk add --no-cache \
	perl-uri \
	perl-fcgi \
	perl-config-inifiles \
	perl-ipc-system-simple \
	perl-sub-override \
	perl-cgi

    # apache-mod-fcgid and php83-apache2 each drop their own pre-activated
    # snippet into /etc/apache2/conf.d/ on install and httpd.conf
    # IncludeOptional-s the whole directory -- there's no Ubuntu-style
    # a2enmod/mods-enabled step on Alpine, installing the package is enough.
    # The fcgid package's own conf.d snippet only wires up a /fcgi-bin/
    # alias though, not the .fcgi extension handler this app actually
    # needs, so that part still has to be added here, just as its own
    # conf.d file rather than overwriting the package's.
    apk add --no-cache \
	apache-mod-fcgid \
	php83 php83-apache2 php83-openssl

    # Install JSON library Perl
    apk add --no-cache \
	perl-json \
	perl-json-any \
	perl-json-xs

    # Install extra packages to allow to build ISO and EFI binary.
    # genisoimage is bundled inside cdrkit on Alpine, not its own package;
    # isolinux.bin ships inside the syslinux package itself (found by
    # iPXE's own util/genfsimg under /usr/share/syslinux), so there's no
    # separate isolinux package to install either.
    apk add --no-cache \
	binutils-dev \
	cdrkit \
	syslinux

    # sbsigntool: sbsign/sbverify, for optionally signing a built EFI binary
    # for Secure Boot with an admin-supplied key, and for verifying an
    # arbitrary EFI binary against a public certificate. Neither feature
    # generates or stores any key -- see public/build.fcgi's sign_binary()
    # and public/verify.fcgi.
    apk add --no-cache \
	sbsigntool

    # build.fcgi and verify.fcgi both shell out to the openssl CLI directly
    # (certificate parsing/validation ahead of sbsign) -- present by default
    # on Ubuntu, but Alpine's base image has no openssl binary at all, only
    # busybox applets, none of which is it. Confirmed missing (and this
    # line added) after an actual signed-build request 500'd with
    # `"openssl" failed to start: "No such file or directory"`.
    apk add --no-cache \
	openssl

    # configure fast-cgi
    cat << EOF > /etc/apache2/conf.d/rom-o-matic-fcgid.conf
<IfModule mod_fcgid.c>
    FcgidConnectTimeout 120
    FcgidIdleTimeout 3600
    FcgidBusyTimeout 300
    FcgidIOTimeout 360
    # Raised from the previous 15 MiB to comfortably clear verify.fcgi's own
    # 34 MB request cap (32 MiB binary + certificate + multipart overhead) --
    # otherwise mod_fcgid rejects an oversized-but-under-the-app-limit
    # upload itself, as a generic 500 page, before verify.fcgi's own check
    # ever runs to explain why. This is a ceiling, not a target: build.fcgi's
    # own per-field limits (TRUST_MAX_BYTES etc.) are unchanged and are what
    # actually bounds a normal build request.
    FcgidMaxRequestLen 40000000
    <IfModule mod_mime.c>
        AddHandler fcgid-script .fcgi
    </IfModule>
    <Files ~ (\.fcgi)>
        SetHandler fcgid-script
        Options +FollowSymLinks +ExecCGI
    </Files>
</IfModule>
EOF
fi

# check ssl state of git from ENV due to systems with proxy MITM / SSL Inspection.
# Only disable SSL verify if GIT_SSL_VERIFY is set to false
if [ "$GIT_SSL_VERIFY" = "false" ]; then
    echo "git ssl verify is flagged to be disabled"
    git config --global http.sslVerify false
fi

# clone this repository at the revision under test. Defaults to master so a
# plain `docker build .` behaves as before; CI passes --build-arg
# GIT_REF=<commit-or-branch> so a pull-request build actually tests the PR's
# content instead of silently testing whatever is currently on master.
GIT_REF="${GIT_REF:-master}"
git clone https://github.com/mediocreatmybest/ROM-OH-MATIC.git /opt/rom-o-matic
git -C /opt/rom-o-matic checkout "$GIT_REF"
git -C /opt/rom-o-matic submodule update --init --recursive
chown -R "$WWW_USER:$WWW_GROUP" /opt/rom-o-matic

# Allow iPXE submodule to be updated due to change in ownership with submodules
git config --global --add safe.directory /opt/rom-o-matic/ipxe
git config --global --add safe.directory /opt/rom-o-matic

#  Prepare iPXE directory
# Note: build.fcgi's cache root and lockfile (see build.ini) live under
# /var/cache/ipxe-build and /var/run/ipxe-build; its own scratch/worktree
# directories use the system tmpdir (plain /tmp), not /var/tmp. An earlier
# /var/tmp/ipxe-build here was dead weight -- created, then immediately
# wiped by the later `rm -rf /tmp/* /var/tmp/*` cleanup step anyway, and
# nothing ever read from it.
mkdir -p \
    /var/cache/ipxe-build \
    /var/run/ipxe-build
rm -rf \
    /var/cache/ipxe-build/* \
    /var/run/ipxe-build/*

# Prepare the git iPXE repository
touch /var/run/ipxe-build/ipxe-build-cache.lock
chown -R "$WWW_USER:$WWW_GROUP" \
    /var/run/ipxe-build/ipxe-build-cache.lock \
    /var/cache/ipxe-build \
    /var/run/ipxe-build \
    /opt/rom-o-matic/ipxe

# Move symlink creation to the end of build/install process
rm -rf "$DOCROOT_LINK"
ln -s /opt/rom-o-matic/public "$DOCROOT_LINK"
