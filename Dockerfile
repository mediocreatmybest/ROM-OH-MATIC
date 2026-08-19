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

# Selects the FROM stage below and, via the ENV re-declared after it, the
# apt/apk branches in install.sh and start.sh.
ARG TARGET_OS=ubuntu

# ----------------------------------------------------------------------
# Ubuntu base
# ----------------------------------------------------------------------
# Pinned to an LTS release: ubuntu:latest can resolve to a non-LTS interim
# release with an incomplete package set.
FROM ubuntu:25.10 AS base-ubuntu

# Package lists are removed in the same RUN that creates them. A later RUN
# only whiteouts them -- the bytes still ship in this layer.
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections \
 && echo 'alias ll="ls -lah --color=auto"' >> /etc/bash.bashrc \
 && apt-get update \
 && apt-get -yq upgrade \
 && apt-get -yq install --no-install-recommends locales openssh-server \
 && locale-gen en_US.UTF-8 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# After the RUN above: locale-gen is passed the locale explicitly and never
# reads these.
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DISTRIBUTION_VERSION=24.04

# ----------------------------------------------------------------------
# Alpine base
# ----------------------------------------------------------------------
FROM alpine:3.24 AS base-alpine

# --no-cache fetches the index per operation and discards it, so nothing
# persists in /var/cache/apk. bash: the scripts use bash-specific syntax and
# Alpine ships busybox ash only.
RUN apk upgrade --no-cache \
 && apk add --no-cache bash openssh-server

# musl has no glibc-style locales; C.UTF-8 is the practical equivalent.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISTRIBUTION_VERSION=3.20

# ----------------------------------------------------------------------
# Selected base -- everything from here down is OS-agnostic application
# setup, shared between both variants.
# ----------------------------------------------------------------------
FROM base-${TARGET_OS}
LABEL maintainer="Francois Lacroix <xbgmsharp@gmail.com>"

# Re-declared: an ARG's value doesn't survive the FROM that consumes it.
ARG TARGET_OS=ubuntu
ENV TARGET_OS=${TARGET_OS}

# UPDATE_ON_START: frozen by default, so a tagged image runs the revision
# baked in at build time. ENABLE_SSH / UI_ENABLE_CERT_FEATURE: off by
# default; see start.sh and README.md.
ENV HOME=/root \
    DEBIAN_FRONTEND=noninteractive \
    GIT_SSL_VERIFY=true \
    UPDATE_ON_START=false \
    ENABLE_SSH=false \
    UI_ENABLE_CERT_FEATURE=false

RUN mkdir -p /run/sshd

# Revision to check out inside the image. CI overrides this with the commit
# under test, so a PR build tests the PR (see install.sh).
ARG GIT_REF=master

# os-env.sh is copied alongside install.sh because /opt/rom-o-matic does not
# exist yet; start.sh later sources it from the cloned repo instead.
COPY install.sh scripts/os-env.sh /tmp/

# No chmod first -- install.sh is passed to bash, which ignores the execute
# bit. The /tmp sweep rides along here so it costs no extra layer; install.sh
# cleans its own package caches internally for the same reason.
RUN bash /tmp/install.sh \
 && rm -rf /tmp/* /var/tmp/*

ENV PORT=80

WORKDIR /var/www/ipxe-buildweb

EXPOSE 22 80

# Keep the package repository current if this image is used as a base build
# https://docs.docker.com/engine/reference/builder/#onbuild
#
# One ONBUILD, not two: each becomes its own layer in the descendant image,
# so upgrading in one and cleaning in the next left the caches shipping in
# the descendant regardless -- the same trap as the build stages above.
# Alpine needs no cache removal at all once `apk upgrade` is --no-cache.
ONBUILD RUN if [ "$TARGET_OS" = "ubuntu" ]; then \
      apt-get update && apt-get -yq upgrade \
      && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    else \
      apk upgrade --no-cache && rm -rf /tmp/* /var/tmp/*; \
    fi

# Set explicitly rather than trusting the checkout: a Windows clone with
# core.fileMode=false drops the bit, and mod_fcgid exec's the .fcgi scripts
# directly -- a missing bit there fails every request as a bare Apache 500,
# with nothing in any log. (This happened, with verify.fcgi.) options.php
# exec's parseheaders.py directly for the same reason. Globbed so a future
# .fcgi is covered automatically.
RUN chmod +x \
      /opt/rom-o-matic/start.sh \
      /opt/rom-o-matic/update.sh \
      /opt/rom-o-matic/scripts/parseheaders.py \
      /opt/rom-o-matic/public/*.fcgi

# Reflects whether the web service responds, not just whether the process is
# alive. wget: busybox supplies it on Alpine, and install.sh installs it on
# Ubuntu, whose base image ships neither wget nor curl. Keep that install --
# without it this probe fails every time and the container never goes healthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:80/ || exit 1

# Project-specific metadata; the standard OCI labels are added by
# docker/metadata-action in the workflow. Defaults keep a plain local
# `docker build .` working.
ARG IPXE_REVISION=unknown
LABEL org.rom-oh-matic.ipxe.revision="${IPXE_REVISION}" \
      org.rom-oh-matic.distribution="${TARGET_OS}" \
      org.rom-oh-matic.distribution.version="${DISTRIBUTION_VERSION}"

# Entry point to start the container and the additional services.
ENTRYPOINT ["/opt/rom-o-matic/start.sh"]
