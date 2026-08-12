#!/bin/bash
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------

# WWW_OWNER, DOCROOT_LINK and FCGID_CONF_PATH below all come from this --
# copied to /tmp alongside install.sh by the Dockerfile, since /opt/rom-o-
# matic (where the repo's own copy lives) doesn't exist yet at this point.
# shellcheck source=scripts/os-env.sh disable=SC1091
. /tmp/os-env.sh

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

    # Cleaned here, in the same shell and therefore the same Docker layer as
    # the installs above -- a later RUN would only whiteout the bytes, not
    # remove them from the image. Nothing after this installs packages.
    apt-get clean
    rm -rf /var/lib/apt/lists/*
else
    # --no-cache fetches the index per operation and discards it, so no
    # `apk update` is wanted here -- that would leave one behind for nothing.
    apk add --no-cache git
    # The scripts use bash-specific syntax; Alpine ships busybox ash only.
    apk add --no-cache bash

    # coreutils: iPXE's rootcert rule splits a PEM bundle with csplit, which
    # busybox lacks -- without it, only certificate-trust builds fail, and
    # obscurely. Ubuntu has it in the base image.
    apk add --no-cache \
	build-base coreutils \
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
    apk add --no-cache \
	sbsigntool

    # build.fcgi and verify.fcgi shell out to the openssl CLI. Ubuntu ships
    # it; Alpine's base image has only busybox applets, none of which is it.
    apk add --no-cache \
	openssl
fi

# configure fast-cgi. Identical on both OSes -- only where it's written
# differs (FCGID_CONF_PATH, from os-env.sh), so this runs once rather than
# being duplicated inside the branch above where it can drift.
cat << EOF > "$FCGID_CONF_PATH"
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
chown -R "$WWW_OWNER" /opt/rom-o-matic

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
chown -R "$WWW_OWNER" \
    /var/run/ipxe-build/ipxe-build-cache.lock \
    /var/cache/ipxe-build \
    /var/run/ipxe-build \
    /opt/rom-o-matic/ipxe

# Move symlink creation to the end of build/install process
rm -rf "$DOCROOT_LINK"
ln -s /opt/rom-o-matic/public "$DOCROOT_LINK"
