#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE.txt
# Website:  http://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------
#
# Ubuntu LTS + Apache2 + module + my app
#
# Base from ultimate-seed Dockerfile
# https://github.com/pilwon/ultimate-seed
#
# AUTHOR: xbgmsharp@gmail.com
# WEBSITE: https://github.com/xbgmsharp/ipxe-buildweb
#
# DOCKER-VERSION 1.0.0
# VERSION 0.0.1

# Pull base image.
FROM ubuntu:latest
LABEL maintainer="Francois Lacroix <xbgmsharp@gmail.com>"

# Setup system and install tools
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
RUN echo 'alias ll="ls -lah --color=auto"' >> /etc/bash.bashrc

# Make sure the package repository is up to date
RUN apt-get update && apt-get -yq upgrade

# Set locale
RUN apt-get -qqy install locales
ENV LANG=en_US.utf8
ENV LC_ALL=en_US.UTF-8
RUN locale-gen en_US.UTF-8

# Set ENV
ENV HOME=/root
ENV DEBIAN_FRONTEND=noninteractive
ENV GIT_SSL_VERIFY=true

# Install SSH
RUN apt-get install -y openssh-server
# Enable SSHD
RUN mkdir -p /run/sshd
# Alow root login and password authentication
RUN echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/01-ipxe-web-ssh.conf
RUN echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/01-ipxe-web-ssh.conf
RUN echo 'root:admin' | chpasswd

# Add the install script in the directory.
COPY install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh

# Install it all
RUN \
  bash /tmp/install.sh

# Define environment variables
ENV PORT=80

# Define working directory.
WORKDIR /var/www/ipxe-buildweb

# Expose ports.
EXPOSE 22 80

# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Make sure the package repository is up to date if used as a base build
# https://docs.docker.com/engine/reference/builder/#onbuild
ONBUILD RUN apt-get update && apt-get -yq upgrade
ONBUILD RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set as execute with +x
RUN chmod +x /opt/rom-o-matic/start.sh
RUN chmod +x /opt/rom-o-matic/update.sh

# Allow iPXE submodule to be updated due to change in ownership with submodules
RUN git config --global --add safe.directory /opt/rom-o-matic/ipxe

# Entry point to start the container and the additional services.
ENTRYPOINT ["/opt/rom-o-matic/start.sh"]
