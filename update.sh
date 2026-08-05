#!/bin/bash
# Check for git pull / updates.
#
# Never let a failed or slow pull take the container down -- the baseline
# baked into the image at build time is still there and still works, so a
# broken network or an interrupted pull should just mean "stayed on the old
# revision", not "container won't start".

REPO_DIR=/opt/rom-o-matic
LOCK_FILE=/var/run/ipxe-build/rom-o-matic-update.lock
TIMEOUT_SECONDS=120

# check ssl state of git from ENV due to systems with proxy MITM / SSL Inspection.
# Only disable SSL verify if GIT_SSL_VERIFY is set to false. Re-applied here
# (not just at build time in install.sh) so a runtime override of the ENV
# actually takes effect for this pull.
if [ "$GIT_SSL_VERIFY" = "false" ]; then
	echo "git ssl verify is flagged to be disabled"
	git config --global http.sslVerify false
else
	git config --global http.sslVerify true
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	echo "update.sh: another update is already in progress, skipping this run"
	exit 0
fi

echo "ROM-OH-MATIC revision before update: $(git -C "$REPO_DIR" rev-parse HEAD)"
echo "iPXE revision before update: $(git -C "$REPO_DIR/ipxe" rev-parse HEAD 2>/dev/null || echo unknown)"

if timeout "$TIMEOUT_SECONDS" git -C "$REPO_DIR" pull --recurse-submodules; then
	echo "ROM-OH-MATIC revision after update: $(git -C "$REPO_DIR" rev-parse HEAD)"
	echo "iPXE revision after update: $(git -C "$REPO_DIR/ipxe" rev-parse HEAD 2>/dev/null || echo unknown)"
else
	echo "update.sh: git pull failed or timed out after ${TIMEOUT_SECONDS}s, continuing with the existing baseline"
fi
