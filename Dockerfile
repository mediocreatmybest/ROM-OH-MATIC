#------------------------------------------------------------------------
# Dynamic iPXE image generator
#
# Copyright (C) 2012-2021 Francois Lacroix. All Rights Reserved.
# License:  GNU General Public License version 3 or later; see LICENSE
# Website:  https://ipxe.org, https://github.com/xbgmsharp/ipxe-buildweb
#------------------------------------------------------------------------
#
# Ubuntu LTS or Alpine + Apache2 + module + my app
#
# Base from ultimate-seed Dockerfile
# https://github.com/pilwon/ultimate-seed
#
# AUTHOR: xbgmsharp@gmail.com
# WEBSITE: https://github.com/xbgmsharp/ipxe-buildweb
#
# DOCKER-VERSION 1.0.0
# VERSION 0.0.1

# Which OS family to build on. Selects the FROM stage below and, via the
# ENV TARGET_OS re-declared after it, every OS-specific branch in
# install.sh and start.sh. "ubuntu" is the long-standing default; "alpine"
# is a smaller, musl-based alternative -- same application and scripts,
# different package manager and a handful of Apache/path differences.
ARG TARGET_OS=ubuntu

# ----------------------------------------------------------------------
# Ubuntu base
# ----------------------------------------------------------------------
# Pinned to a specific LTS release / 
# Lets clean some of this up, simplifying these into single layers.
FROM ubuntu:24.04 AS base-ubuntu

ENV LANG=en_US.utf8 \
    LC_ALL=en_US.UTF-8 \
    DISTRIBUTION_VERSION=24.04

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections \
    && echo 'alias ll="ls -lah --color=auto"' >> /etc/bash.bashrc \
    && apt-get update \
    && apt-get -yq upgrade \
    && apt-get install -y --no-install-recommends \
        locales \
        openssh-server \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------
# Alpine base
# ----------------------------------------------------------------------
FROM alpine:3.20 AS base-alpine

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISTRIBUTION_VERSION=3.20

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        bash \
        openssh-server

# ----------------------------------------------------------------------
# Selected base -- everything from here down is OS-agnostic application
# setup, shared between both variants.
# ----------------------------------------------------------------------
FROM base-${TARGET_OS}
LABEL maintainer="Francois Lacroix <xbgmsharp@gmail.com>"

# Re-declared: an ARG's value doesn't survive past the FROM that consumes
# it unless declared again in the new stage. Turned into an ENV right away
# so install.sh (run later via `bash /tmp/install.sh`) and start.sh (at
# container runtime, long after any ARG has gone) can both just read
# $TARGET_OS directly.
ARG TARGET_OS=ubuntu
ENV TARGET_OS=${TARGET_OS}

# Set ENV
ENV HOME=/root \
    DEBIAN_FRONTEND=noninteractive \
    GIT_SSL_VERIFY=true \
    UPDATE_ON_START=false \
    ENABLE_SSH=false \
    UI_ENABLE_CERT_FEATURE=false

RUN mkdir -p /run/sshd

# Revision to check out inside the image. Defaults to master; CI overrides
# this with the actual commit/PR being built so the image reflects the code
# under test rather than always cloning master (see install.sh).
ARG GIT_REF=master

# Add the install script and its shared TARGET_OS mapping (scripts/os-env.sh
# is also sourced by start.sh later, from its normal place in the cloned
# repo -- copied here too since /opt/rom-o-matic doesn't exist yet at this
# point in the build).
COPY install.sh scripts/os-env.sh /tmp/
RUN chmod +x /tmp/install.sh \
    && bash /tmp/install.sh

# Define environment variables
ENV PORT=80

# Define working directory.
WORKDIR /var/www/ipxe-buildweb

# Expose ports.
EXPOSE 22 80

# Clean up package manager caches when done.
RUN if [ "$TARGET_OS" = "ubuntu" ]; then \
      apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    else \
      rm -rf /var/cache/apk/* /tmp/* /var/tmp/*; \
    fi

# Make sure the package repository is up to date if used as a base build
# https://docs.docker.com/engine/reference/builder/#onbuild
ONBUILD RUN if [ "$TARGET_OS" = "ubuntu" ]; then apt-get update && apt-get -yq upgrade; else apk update && apk upgrade; fi
ONBUILD RUN if [ "$TARGET_OS" = "ubuntu" ]; then apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; else rm -rf /var/cache/apk/* /tmp/* /var/tmp/*; fi


RUN chmod +x /opt/rom-o-matic/start.sh \
    && chmod +x /opt/rom-o-matic/update.sh \
    && chmod +x /opt/rom-o-matic/scripts/parseheaders.py \
    && chmod +x /opt/rom-o-matic/public/*.fcgi

# Allow iPXE submodule to be updated due to change in ownership with submodules
RUN git config --global --add safe.directory /opt/rom-o-matic/ipxe

# Reflect whether the web service is actually responding, not just whether
# the container process is alive. wget is present by default on both bases
# (Ubuntu ships it standalone; Alpine's busybox includes a wget applet);
# curl is not present on either.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:80/ || exit 1

# Project-specific build metadata (standard OCI labels -- title, revision,
# created, etc. -- are added by docker/metadata-action in the workflow
# instead of hard-coded here). Populated by CI; a plain local `docker build .`
# gets a sensible fallback rather than a hard failure. distribution.version
# comes from the per-OS base stage above (24.04 for Ubuntu, 3.20 for Alpine).
ARG IPXE_REVISION=unknown
LABEL org.rom-oh-matic.ipxe.revision="${IPXE_REVISION}" \
      org.rom-oh-matic.distribution="${TARGET_OS}" \
      org.rom-oh-matic.distribution.version="${DISTRIBUTION_VERSION}"

# Entry point to start the container and the additional services.
ENTRYPOINT ["/opt/rom-o-matic/start.sh"]
