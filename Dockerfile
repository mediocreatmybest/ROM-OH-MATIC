#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
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
# Pinned to a specific LTS release rather than :latest -- ubuntu:latest can
# resolve to a non-LTS interim release with an incomplete/broken package set,
# which isn't something a Docker build should be at the mercy of.
FROM ubuntu:24.04
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
# Frozen by default: a SHA/version-tagged image should run the exact
# revision baked in at build time. Set to "true" to pull updates on every
# container start instead.
ENV UPDATE_ON_START=false
# SSH is off by default -- no hard-coded password, no default root access.
# Set to "true" plus SSH_AUTHORIZED_KEY (preferred) or SSH_ROOT_PASSWORD to
# enable it at runtime; see start.sh. Normal debugging should use
# `docker exec` instead.
ENV ENABLE_SSH=false
# Certificate trust and Secure Boot signing/verification are available by
# default. Set to "true" to remove both from the interface and have
# build.fcgi/verify.fcgi refuse them outright; see start.sh.
ENV UI_REMOVE_CERT_FEATURE=false

# Install SSH. The server is always present (keeps this a single image
# rather than a separate SSH-enabled variant), but start.sh only launches
# and configures it when ENABLE_SSH is explicitly turned on.
RUN apt-get install -y openssh-server
RUN mkdir -p /run/sshd

# Revision to check out inside the image. Defaults to master; CI overrides
# this with the actual commit/PR being built so the image reflects the code
# under test rather than always cloning master (see install.sh).
ARG GIT_REF=master

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

# Set as execute with +x. options.php execs parseheaders.py directly, so it
# needs the bit too -- don't rely on the mode surviving a checkout, since a
# Windows clone with core.fileMode=false won't carry it.
RUN chmod +x /opt/rom-o-matic/start.sh
RUN chmod +x /opt/rom-o-matic/update.sh
RUN chmod +x /opt/rom-o-matic/scripts/parseheaders.py

# Allow iPXE submodule to be updated due to change in ownership with submodules
RUN git config --global --add safe.directory /opt/rom-o-matic/ipxe

# Reflect whether the web service is actually responding, not just whether
# the container process is alive. wget is already present in the base
# image; curl is not.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:80/ || exit 1

# Project-specific build metadata (standard OCI labels -- title, revision,
# created, etc. -- are added by docker/metadata-action in the workflow
# instead of hard-coded here). Populated by CI; a plain local `docker build .`
# gets a sensible fallback rather than a hard failure.
ARG IPXE_REVISION=unknown
LABEL org.rom-oh-matic.ipxe.revision="${IPXE_REVISION}" \
      org.rom-oh-matic.distribution="ubuntu" \
      org.rom-oh-matic.distribution.version="24.04"

# Entry point to start the container and the additional services.
ENTRYPOINT ["/opt/rom-o-matic/start.sh"]
