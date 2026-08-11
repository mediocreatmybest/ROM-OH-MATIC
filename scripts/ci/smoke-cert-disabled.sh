#!/usr/bin/env bash
# CI: prove the shipped default. Certificate trust and Secure Boot
# signing/verification are opt-in (UI_ENABLE_CERT_FEATURE), so a plain
# `docker run` of the published image must not offer them -- in the page,
# or through the endpoints behind it.
#
# Runs its own container on a second port rather than reusing the one the
# other smoke scripts share, which is deliberately started with the
# feature switched on so it can exercise those paths at all.
set -euo pipefail

image="${1:-${IMAGE_NAME:-mediocreatmybest/ipxe-buildweb}:test}"
container=rom-o-matic-smoke-default
port=8090
url="http://localhost:${port}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== Starting a container with no certificate ENV set =="
docker rm --force "$container" >/dev/null 2>&1 || true
docker run --detach --publish "${port}:80" --name "$container" "$image" >/dev/null

ready=false
for i in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "Container exited before becoming ready"
    docker logs "$container"
    exit 1
  fi
  if curl -sf "$url/" -o /dev/null; then
    echo "HTTP ready after ${i}s"
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != "true" ]; then
  echo "Timed out waiting for HTTP readiness"
  docker logs "$container"
  exit 1
fi

# The markup must be absent, not merely hidden -- a display:none section
# would still ship every id and input to the browser.
echo "== Confirming the certificate sections are not in the served page =="
page=$(curl -sf "$url/")
for marker in 'id="trust"' 'id="secureboot"' 'id="sign_consent"' 'id="verify_button"' 'trust_cert_file' 'sign_key_file'; do
  if printf '%s' "$page" | grep -q "$marker"; then
    echo "Found \"$marker\" in the default page; the certificate sections should not be served"
    exit 1
  fi
done
echo "None of the certificate markup is present"

# The page is only half of it: both endpoints are reachable on their own,
# so they have to refuse regardless of what the page does or doesn't show.
echo "== Confirming build.fcgi refuses TRUST_CERT =="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/default-off.key -out /tmp/default-off.pem \
  -subj '/CN=CI Default Off/O=CI' 2>/dev/null
status=$(curl -s -o /tmp/default-trust.txt -w '%{http_code}' --max-time 60 \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F 'TRUST_CERT=</tmp/default-off.pem' \
  "$url/build.fcgi")
if [ "$status" = "200" ]; then
  echo "TRUST_CERT was accepted with the feature off"
  exit 1
fi
grep -qi 'not enabled' /tmp/default-trust.txt || {
  echo "Rejected, but not with the expected not-enabled error"
  cat /tmp/default-trust.txt
  exit 1
}

echo "== Confirming build.fcgi refuses SIGN_KEY/SIGN_CERT =="
status=$(curl -s -o /tmp/default-sign.txt -w '%{http_code}' --max-time 60 \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F 'SIGN_KEY=@/tmp/default-off.key' \
  -F 'SIGN_CERT=</tmp/default-off.pem' \
  "$url/build.fcgi")
if [ "$status" = "200" ]; then
  echo "SIGN_KEY/SIGN_CERT was accepted with the feature off"
  exit 1
fi
grep -qi 'not enabled' /tmp/default-sign.txt || {
  echo "Rejected, but not with the expected not-enabled error"
  cat /tmp/default-sign.txt
  exit 1
}

echo "== Confirming verify.fcgi refuses a well-formed request =="
response=$(curl -s --max-time 60 \
  -F 'VERIFY_CERT=</tmp/default-off.pem' \
  -F 'VERIFY_BINARY=@/tmp/default-off.pem' \
  "$url/verify.fcgi")
echo "Response: ${response}"
printf '%s' "$response" | grep -qi 'not enabled' || {
  echo "verify.fcgi did not refuse with the expected not-enabled error"
  exit 1
}

# Turning the feature off must not cost anything else. A normal build is
# the whole point of the application.
echo "== Confirming a normal build still works with the feature off =="
status=$(curl -s -o /tmp/default-build.kpxe -w '%{http_code}' --max-time 180 \
  -F 'BINARY=undionly.kpxe' \
  -F 'BINDIR=bin' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  "$url/build.fcgi")
if [ "$status" != "200" ]; then
  echo "A plain build failed with the certificate features off"
  cat /tmp/default-build.kpxe
  exit 1
fi
size=$(stat -c%s /tmp/default-build.kpxe)
echo "Build artefact size: ${size} bytes"
if [ "$size" -lt 10000 ]; then
  echo "Build artefact is suspiciously small (${size} bytes) -- likely an error page, not a real binary"
  exit 1
fi
