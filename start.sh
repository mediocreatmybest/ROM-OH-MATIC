#!/bin/bash
# Start sshd for remote access, but only if explicitly enabled -- there is
# no default password and no default root access. Prefer `docker exec` for
# routine debugging; SSH is for cases that genuinely need it.
if [ "$ENABLE_SSH" = "true" ]; then
	if [ -n "$SSH_AUTHORIZED_KEY" ]; then
		mkdir -p /root/.ssh
		chmod 700 /root/.ssh
		echo "$SSH_AUTHORIZED_KEY" > /root/.ssh/authorized_keys
		chmod 600 /root/.ssh/authorized_keys
		{
			echo "PermitRootLogin prohibit-password"
			echo "PasswordAuthentication no"
		} > /etc/ssh/sshd_config.d/01-ipxe-web-ssh.conf
		echo "ENABLE_SSH is 'true': starting sshd with key-based root login only."
		/usr/sbin/sshd
	elif [ -n "$SSH_ROOT_PASSWORD" ]; then
		echo "root:$SSH_ROOT_PASSWORD" | chpasswd
		{
			echo "PermitRootLogin yes"
			echo "PasswordAuthentication yes"
		} > /etc/ssh/sshd_config.d/01-ipxe-web-ssh.conf
		echo "ENABLE_SSH is 'true': starting sshd with password-based root login. Prefer SSH_AUTHORIZED_KEY instead where possible."
		/usr/sbin/sshd
	else
		echo "ENABLE_SSH is 'true' but neither SSH_AUTHORIZED_KEY nor SSH_ROOT_PASSWORD is set; refusing to start sshd without credentials. Set one of them, or use 'docker exec' for a debugging shell instead."
	fi
else
	echo "ENABLE_SSH is not 'true', skipping sshd (use 'docker exec' for a debugging shell)."
fi
# Pull the latest git version on startup, but only if explicitly asked to --
# a frozen image should run exactly the revision baked in at build time.
if [ "$UPDATE_ON_START" = "true" ]; then
	/opt/rom-o-matic/update.sh
else
	echo "UPDATE_ON_START is not 'true', running the baked-in baseline (frozen mode)."
fi
# Add ServerName to apache2.conf to avoid warning about fully qualified domain name.
# Guarded so restarting an existing container doesn't keep appending it.
if ! grep -q '^ServerName' /etc/apache2/apache2.conf; then
	echo "ServerName localhost" >> /etc/apache2/apache2.conf
fi

# Send Apache's logs to the container's stdout/stderr instead of files
# nothing is watching, so `docker logs` shows what's actually happening.
ln -sf /dev/stdout /var/log/apache2/access.log
ln -sf /dev/stderr /var/log/apache2/error.log

# Run Apache as the actual foreground process the container monitors --
# a crashed Apache now stops the container instead of it staying alive via
# `tail`. No more suppressing startup errors, either.
echo "Starting apache2 in the foreground..."
exec apachectl -D FOREGROUND