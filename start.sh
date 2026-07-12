#!/bin/bash
# Start sshd for remote access.
/usr/sbin/sshd
# Pull the latest git version on startup.
/opt/rom-o-matic/update.sh
# Add ServerName to apache2.conf to avoid warning about fully qualified domain name.
echo "ServerName localhost" >> /etc/apache2/apache2.conf
# Start apache2 in the background.
echo "Starting apache2..."
apachectl start > /dev/null 2>&1
# Touch the apache log file to avoid error about missing file, and tail the log file to keep the container running.
touch /var/log/apache2/access.log
echo "Tailing apache2 access log..."
exec /usr/bin/tail -f /var/log/apache2/access.log