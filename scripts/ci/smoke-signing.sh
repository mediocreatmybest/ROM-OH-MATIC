#!/usr/bin/env bash
# CI: exercise the Secure Boot signing (build.fcgi's sign_binary()) and
# verification (verify.fcgi) paths end to end against the container started
# by the workflow, with disposable, CI-generated key/certificate material.
# Both scripts independently re-validate everything they're given, so this
# proves the real request/response contract, not just the unit-level logic.
set -euo pipefail

build_url=http://localhost:8080/build.fcgi
verify_url=http://localhost:8080/verify.fcgi
container=rom-o-matic-smoke

# Snapshots container and host memory/process state. Named for when it is
# called, not what it found -- a step failing here must never abort the
# script (the diagnostics matter most exactly when something is already
# wrong), so every command is best-effort.
diagnostic_snapshot() {
  local label="$1"
  echo "-- resource snapshot: ${label} --"
  docker stats --no-stream "$container" 2>&1 || true
  free -h 2>&1 || true
  # --sort is a GNU procps flag; Alpine's container only has busybox ps,
  # which doesn't understand it (or report RSS at all) -- fall back to a
  # plain listing there rather than let the whole diagnostic step error out.
  docker exec "$container" sh -c 'ps aux --sort=-rss 2>/dev/null | head -15 || ps aux | head -15' 2>&1 || true
}

# Two distinct, disposable key/cert pairs: "a" signs; "b" exists purely to
# be the wrong certificate for the mismatch case below.
echo "== Generating disposable Secure Boot key/certificate pairs =="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/sign-a.key -out /tmp/sign-a.pem \
  -subj '/CN=CI Signing Test A/O=CI'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/sign-b.key -out /tmp/sign-b.pem \
  -subj '/CN=CI Signing Test B/O=CI'
# An encrypted key, for build.fcgi's clean-rejection check below --
# PKCS#1 style ("Proc-Type: 4,ENCRYPTED"), the format sbsign has no way
# to be given a passphrase for.
openssl rsa -in /tmp/sign-a.key -aes256 -traditional \
  -passout pass:citest -out /tmp/sign-a-encrypted.key

# --- Positive case: sign a real build, then verify the result two ways ---
echo "== Building and signing an EFI binary =="
status=$(curl -s --max-time 180 \
  -D /tmp/sign-headers.txt \
  -o /tmp/signed.efi \
  -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F 'SIGN_KEY=@/tmp/sign-a.key' \
  -F 'SIGN_CERT=</tmp/sign-a.pem' \
  "$build_url")
echo "Response status: ${status}"
if [ "$status" != "200" ]; then
  echo "Signed build request failed"
  cat /tmp/sign-headers.txt
  cat /tmp/signed.efi
  exit 1
fi
grep -qi '^Content-Disposition: attachment' /tmp/sign-headers.txt || {
  echo "Response did not look like a file download"
  cat /tmp/sign-headers.txt
  exit 1
}
size=$(stat -c%s /tmp/signed.efi)
echo "Signed artefact size: ${size} bytes"
if [ "$size" -lt 10000 ]; then
  echo "Signed artefact is suspiciously small (${size} bytes) -- likely an error page, not a real binary"
  exit 1
fi

# Independent check: build.fcgi already sbverifies its own output before
# returning it (see sign_binary()'s comment on why that alone isn't
# evidence enough), so re-verify here too, on the runner, entirely outside
# the container that produced it.
echo "== Independently verifying the signed binary with sbverify =="
sbverify --cert /tmp/sign-a.pem /tmp/signed.efi

diagnostic_snapshot "right before verify.fcgi's first-ever request in this container"

echo "== Verifying the signed binary through verify.fcgi (matching cert) =="
response=$(curl -s --max-time 30 \
  -F 'VERIFY_CERT=</tmp/sign-a.pem' \
  -F 'VERIFY_BINARY=@/tmp/signed.efi' \
  "$verify_url")
echo "Response: ${response}"
echo "$response" | grep -q '"verified":true' || {
  echo "verify.fcgi did not report a match for the correct certificate"
  diagnostic_snapshot "immediately after the failed request above"
  # Untruncated -- a tail here previously let the periodic health-check
  # GETs (one every 30s) push a real error line for this exact failure
  # out of the captured window.
  echo "-- container logs (untruncated) --"
  docker logs "$container" 2>&1 || true
  echo "-- host kernel log: OOM/kill activity --"
  # `matches=$(pipeline)` still trips `set -e` when the pipeline's last
  # command exits non-zero even though it is only reporting "grep found
  # nothing" -- a bare assignment isn't one of set -e's documented
  # exemptions (unlike an if-condition). Previously lost this entire
  # section's output silently: the script exited right here, with no
  # error message, the moment dmesg legitimately found nothing to report.
  if dmesg_text=$(sudo dmesg 2>&1); then
    oom_lines=$(printf '%s\n' "$dmesg_text" | grep -iE 'killed process|out of memory|oom' || true)
    if [ -n "$oom_lines" ]; then
      printf '%s\n' "$oom_lines" | tail -20
    else
      echo "dmesg ran cleanly -- no OOM/kill lines found"
    fi
  else
    echo "dmesg itself failed or is unavailable on this runner"
  fi

  # A zombie found here means some child under the container's process
  # tree exited around the failure and has not yet been reaped by its
  # parent -- worth knowing whether that parent is Apache itself (a
  # worker crash, upstream of anything build.fcgi/verify.fcgi could ever
  # log) rather than the FastCGI child process.
  #
  # Relies on procps-style `ps aux` having a STAT column at field 8;
  # Alpine's busybox `ps` reports no STAT column at all, so this always
  # comes back empty there rather than a genuine "no zombies" finding.
  echo "-- zombie/defunct processes in the container --"
  zombies=$(docker exec "$container" sh -c 'ps aux' 2>&1 | awk '$8 ~ /^Z/' || true)
  if [ -n "$zombies" ]; then
    echo "$zombies"
    zpid=$(printf '%s\n' "$zombies" | awk '{print $2}' | head -1)
    if [ -n "$zpid" ]; then
      echo "-- /proc/${zpid}/status for that PID (parent PID, while still readable) --"
      docker exec "$container" sh -c "cat /proc/${zpid}/status" 2>&1 || true
    fi
  else
    echo "no zombie/defunct processes found"
  fi

  echo "-- Apache's own child-death log lines --"
  docker logs "$container" 2>&1 | grep -iE 'AH0005[0-9]|exit signal|core dumped|segfault' \
    || echo "none found"

  exit 1
}
echo "$response" | grep -q '"reason":"match"' || {
  echo "verify.fcgi reported verified:true but not reason:match"
  exit 1
}

echo "== Verifying the signed binary through verify.fcgi (wrong cert) =="
response=$(curl -s --max-time 30 \
  -F 'VERIFY_CERT=</tmp/sign-b.pem' \
  -F 'VERIFY_BINARY=@/tmp/signed.efi' \
  "$verify_url")
echo "Response: ${response}"
echo "$response" | grep -q '"verified":false' || {
  echo "verify.fcgi did not report a mismatch for the wrong certificate"
  exit 1
}
echo "$response" | grep -q '"reason":"mismatch"' || {
  echo "verify.fcgi reported verified:false but not reason:mismatch"
  exit 1
}

# --- Negative case: an unsigned EFI binary reads as "unsigned", not "invalid" ---
echo "== Building an unsigned EFI binary for the unsigned-verify case =="
status=$(curl -s --max-time 180 \
  -o /tmp/unsigned.efi \
  -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  "$build_url")
if [ "$status" != "200" ]; then
  echo "Unsigned build request failed"
  cat /tmp/unsigned.efi
  exit 1
fi

echo "== Verifying an unsigned binary through verify.fcgi =="
response=$(curl -s --max-time 30 \
  -F 'VERIFY_CERT=</tmp/sign-a.pem' \
  -F 'VERIFY_BINARY=@/tmp/unsigned.efi' \
  "$verify_url")
echo "Response: ${response}"
echo "$response" | grep -q '"reason":"unsigned"' || {
  echo "verify.fcgi did not classify an unsigned binary as reason:unsigned"
  exit 1
}

# --- Negative case: not a PE/COFF binary at all ---
echo "== Verifying a non-binary file through verify.fcgi =="
echo "this is not an EFI binary" > /tmp/garbage.bin
response=$(curl -s --max-time 30 \
  -F 'VERIFY_CERT=</tmp/sign-a.pem' \
  -F 'VERIFY_BINARY=@/tmp/garbage.bin' \
  "$verify_url")
echo "Response: ${response}"
echo "$response" | grep -q '"reason":"invalid"' || {
  echo "verify.fcgi did not classify garbage input as reason:invalid"
  exit 1
}

# --- Negative case: verify.fcgi over GET must be rejected, same reasoning
# as smoke-builds.sh's TRUST_CERT-over-GET case -- reachable on its own,
# so the POST-only check has to hold regardless of what the frontend does. ---
echo "== Submitting to verify.fcgi via GET and confirming rejection =="
status=$(curl -s --max-time 30 -o /tmp/get-verify-response.txt -w '%{http_code}' "$verify_url")
echo "Response status: ${status}"
if [ "$status" = "200" ]; then
  echo "GET to verify.fcgi was accepted -- it should reject non-POST requests"
  cat /tmp/get-verify-response.txt
  exit 1
fi
grep -qi 'POST' /tmp/get-verify-response.txt || {
  echo "Rejected, but not with the expected POST-required error"
  cat /tmp/get-verify-response.txt
  exit 1
}

# --- Negative case: build.fcgi with only one of SIGN_KEY/SIGN_CERT ---
echo "== Submitting an incomplete signing request (key, no certificate) =="
status=$(curl -s --max-time 60 -o /tmp/incomplete-sign-response.txt -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F 'SIGN_KEY=@/tmp/sign-a.key' \
  "$build_url")
echo "Response status: ${status}"
if [ "$status" = "200" ]; then
  echo "Incomplete signing request was accepted -- both SIGN_KEY and SIGN_CERT should be required together"
  exit 1
fi
grep -qi 'SIGN_KEY and SIGN_CERT must both be supplied' /tmp/incomplete-sign-response.txt || {
  echo "Rejected, but not with the expected incomplete-signing error"
  cat /tmp/incomplete-sign-response.txt
  exit 1
}

# --- Negative case: an encrypted private key must be rejected cleanly,
# not handed to sbsign to fail on (or hang against) with no passphrase. ---
echo "== Submitting an encrypted private key and confirming clean rejection =="
status=$(curl -s --max-time 60 -o /tmp/encrypted-key-response.txt -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F 'SIGN_KEY=@/tmp/sign-a-encrypted.key' \
  -F 'SIGN_CERT=</tmp/sign-a.pem' \
  "$build_url")
echo "Response status: ${status}"
if [ "$status" = "200" ]; then
  echo "An encrypted private key was accepted -- sign_binary() should reject it before ever calling sbsign"
  exit 1
fi
grep -qi 'passphrase-protected' /tmp/encrypted-key-response.txt || {
  echo "Rejected, but not with the expected encrypted-key error"
  cat /tmp/encrypted-key-response.txt
  exit 1
}
