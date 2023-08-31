#!/bin/bash
#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE.txt
# Website:  http://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------

# Fix "Error debconf: unable to initialize frontend: Dialog"
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

# Upgrade system
apt-get update && apt-get -yq dist-upgrade

# install git if needed
apt -yq install git

# clone this repository
# git clone https://github.com/realslacker/rom-o-matic.git /opt/rom-o-matic
# Test git clone of brach
git clone --branch 2204 https://github.com/mediocreatmybest/ROM-OH-MATIC.git /opt/rom-o-matic
git -C /opt/rom-o-matic submodule init
git -C /opt/rom-o-matic submodule update
rm -rf /var/www/html
ln -s /opt/rom-o-matic/public /var/www/html
#ln -s /opt/rom-o-matic/scripts/parseheaders.pl /opt/rom-o-matic/ipxe/src/util/
chown -R www-data:www-data /opt/rom-o-matic
git config --global --add safe.directory /opt/rom-o-matic

# Install basic compilation tools and dev libraries
apt -yq install \
    build-essential \
    iasl lzma-dev mtools perl python3 \
    subversion uuid-dev liblzma-dev mtools

# Install CGI Perl dependencies
apt-get -yq install \
    liburi-perl \
    libfcgi-perl \
    libconfig-inifiles-perl \
    libipc-system-simple-perl \
    libsub-override-perl \
    libcgi-pm-perl

#  Prepare iPXE directory
mkdir -p \
    /var/cache/ipxe-build \
    /var/run/ipxe-build \
    /var/tmp/ipxe-build
rm -rf \
    /var/cache/ipxe-build/* \
    /var/run/ipxe-build/* \
    /var/tmp/ipxe-build/*

# Prepare the git iPXE repository
touch /var/run/ipxe-build/ipxe-build-cache.lock
chown -R www-data:www-data \
    /var/run/ipxe-build/ipxe-build-cache.lock \
    /var/cache/ipxe-build \
    /var/run/ipxe-build \
    /var/tmp/ipxe-build \
    /opt/ipxe

# Install Apache with fast CGI and PHP module
apt-get -yq install \
    libapache2-mod-fcgid \
    libapache2-mod-php
a2enmod fcgid php8.1

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

# configure fast-cgi
cat << EOF > /etc/apache2/mods-enabled/fcgid.conf
<IfModule mod_fcgid.c>
    FcgidConnectTimeout 120
    FcgidIdleTimeout 3600
    FcgidBusyTimeout 300
    FcgidIOTimeout 360
    FcgidMaxRequestLen 15728640
    <IfModule mod_mime.c>
        AddHandler fcgid-script .fcgi
    </IfModule>
    <Files ~ (\.fcgi)>
        SetHandler fcgid-script
        Options +FollowSymLinks +ExecCGI
    </Files>
</IfModule>
EOF

service apache2 start
