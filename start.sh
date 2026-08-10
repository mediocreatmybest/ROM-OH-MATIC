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
# Generate index.html from its template on every start (not just once at
# image build), so this also takes effect after UPDATE_ON_START pulls a new
# template and after a plain container restart with a changed ENV. Regular
# index.html is gitignored precisely because it's this script's output, not
# a source file -- UPDATE_ON_START's git pull above only ever touches the
# template.
#
# UI_REMOVE_CERT_FEATURE=true strips the HTTPS certificate trust and Secure
# Boot signing/verification sections (marked CERT_FEATURE:BEGIN/END in the
# template) out of the page entirely, and writes a flag file build.fcgi and
# verify.fcgi both check on every request -- so this is a real "this feature
# does not exist on this deployment" toggle, not just a hidden UI section
# still reachable by posting to those scripts directly.
CERT_FEATURE_FLAG=/opt/rom-o-matic/.cert-feature-disabled
TEMPLATE=/opt/rom-o-matic/public/index.html.template
INDEX=/opt/rom-o-matic/public/index.html
if [ "$UI_REMOVE_CERT_FEATURE" = "true" ]; then
	echo "UI_REMOVE_CERT_FEATURE is 'true': removing certificate trust and Secure Boot sections from the interface."
	sed '/<!-- CERT_FEATURE:BEGIN/,/<!-- CERT_FEATURE:END -->/d' "$TEMPLATE" > "$INDEX"
	touch "$CERT_FEATURE_FLAG"
else
	echo "UI_REMOVE_CERT_FEATURE is not 'true', certificate trust and Secure Boot sections are available."
	cp "$TEMPLATE" "$INDEX"
	rm -f "$CERT_FEATURE_FLAG"
fi
chown www-data:www-data "$INDEX"

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