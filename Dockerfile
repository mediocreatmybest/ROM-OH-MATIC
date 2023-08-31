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
LABEL Francois Lacroix <xbgmsharp@gmail.com>

# Setup system and install tools
#RUN echo "initscripts hold" | dpkg --set-selections
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
RUN echo 'alias ll="ls -lah --color=auto"' >> /etc/bash.bashrc

# Make sure the package repository is up to date
RUN apt-get update && apt-get -yq upgrade

# Set locale
RUN apt-get -qqy install locales
#RUN locale-gen --purge en_US en_US.UTF-8
#RUN dpkg-reconfigure locales
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8
ENV LC_ALL en_US.UTF-8

# Set ENV
ENV HOME /root
ENV DEBIAN_FRONTEND noninteractive

# Install SSH
RUN apt-get install -y openssh-server
RUN sed -ri 's/UsePAM yes/#UsePAM yes/g' /etc/ssh/sshd_config
RUN sed -ri 's/#UsePAM no/UsePAM no/g' /etc/ssh/sshd_config
RUN sed 's/#PermitRootLogin yes/PermitRootLogin yes/' -i /etc/ssh/sshd_config
RUN sed 's/PermitRootLogin without-password/PermitRootLogin yes/' -i /etc/ssh/sshd_config
RUN mkdir /var/run/sshd
RUN echo 'root:admin' | chpasswd

# Add the install script in the directory.
ADD install.sh /tmp/install.sh
RUN chmod +x /tmp/install.sh
#ADD . /app

# Install it all
RUN \
  bash /tmp/install.sh

# Define environment variables
ENV PORT 80

# Define working directory.
WORKDIR /var/www/ipxe-buildweb

# Define default command.
# Start ssh and other services.
#CMD ["/bin/bash", "/tmp/install.sh"]

# Expose ports.
EXPOSE 22 80

# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Make sure the package repository is up to date
ONBUILD apt-get update && apt-get -yq upgrade
ONBUILD apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Allow to execute
RUN chmod +x /opt/rom-o-matic/start.sh
RUN chmod +x /opt/rom-o-matic/update.sh

#RUN /etc/init.d/apache2 start
#ENTRYPOINT ["/usr/bin/tail","-f","/var/log/apache2/access.log"]
ENTRYPOINT ["/opt/rom-o-matic/start.sh"]
