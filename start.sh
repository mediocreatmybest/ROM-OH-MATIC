#!/bin/bash
# WWW_OWNER, APACHE_MAIN_CONF and APACHE_FOREGROUND_CMD below all come from
# this shared file (also sourced by install.sh at build time), so the two
# scripts can't drift apart on what "ubuntu" or "alpine" actually means.
# shellcheck source=scripts/os-env.sh disable=SC1091
. /opt/rom-o-matic/scripts/os-env.sh

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
# Certificate handling is opt-in. UI_ENABLE_CERT_FEATURE=true keeps the
# HTTPS certificate trust and Secure Boot signing/verification sections
# (marked CERT_FEATURE:BEGIN/END in the template) in the page; anything
# else strips them out entirely. The same choice writes a flag file
# build.fcgi and verify.fcgi both check on every request, so this is a
# real "this feature does not exist on this deployment" toggle rather
# than a hidden UI section still reachable by posting to those scripts
# directly.
#
# The flag marks *enabled*, not disabled, so the off state is the absence
# of a file: if this script somehow never runs, the features stay off
# rather than silently coming on.
CERT_FEATURE_FLAG=/opt/rom-o-matic/.cert-feature-enabled
TEMPLATE=/opt/rom-o-matic/public/index.html.template
INDEX=/opt/rom-o-matic/public/index.html
if [ "$UI_ENABLE_CERT_FEATURE" = "true" ]; then
	echo "UI_ENABLE_CERT_FEATURE is 'true': certificate trust and Secure Boot sections are available."
	cp "$TEMPLATE" "$INDEX"
	touch "$CERT_FEATURE_FLAG"
else
	echo "UI_ENABLE_CERT_FEATURE is not 'true': certificate trust and Secure Boot signing/verification are disabled. Set UI_ENABLE_CERT_FEATURE=true to offer them."
	sed '/<!-- CERT_FEATURE:BEGIN/,/<!-- CERT_FEATURE:END -->/d' "$TEMPLATE" > "$INDEX"
	rm -f "$CERT_FEATURE_FLAG"
fi
chown "$WWW_OWNER" "$INDEX"

# Add ServerName to the main Apache config to avoid warning about fully
# qualified domain name. Guarded so restarting an existing container
# doesn't keep appending it.
if ! grep -q '^ServerName' "$APACHE_MAIN_CONF"; then
	echo "ServerName localhost" >> "$APACHE_MAIN_CONF"
fi

# Send Apache's logs to the container's stdout/stderr instead of files
# nothing is watching, so `docker logs` shows what's actually happening.
ln -sf /dev/stdout /var/log/apache2/access.log
ln -sf /dev/stderr /var/log/apache2/error.log

# Run Apache as the actual foreground process the container monitors --
# a crashed Apache now stops the container instead of it staying alive via
# `tail`. No more suppressing startup errors, either.
echo "Starting apache2 in the foreground..."
exec "${APACHE_FOREGROUND_CMD[@]}"