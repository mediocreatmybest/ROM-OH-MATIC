#!/usr/bin/env bash
# CI: exercise build.fcgi's actual iPXE-building job end to end, including
# the certificate-trust path, against the container started by the workflow.
set -euo pipefail

url=http://localhost:8080/build.fcgi

# Prove the published image can actually do its one job, not just serve a
# web page. This is the same request the wizard's JS constructs (see
# public/js/ui.js's buildcfg()) -- build.fcgi clones and compiles from the
# iPXE submodule already baked into the image (build.ini's
# repository=/opt/rom-o-matic/ipxe/.git, cloned --local/--bare/--shared),
# so this never touches the network.
echo "== Submitting a representative iPXE build =="
curl -sf --max-time 120 \
  -D /tmp/build-headers.txt \
  -o /tmp/undionly.kpxe \
  "${url}?BINARY=undionly.kpxe&BINDIR=bin&REVISION=master&DEBUG=&EMBED.00script.ipxe=" || {
  echo "Build request failed"
  exit 1
}
grep -qi '^Content-Disposition: attachment' /tmp/build-headers.txt || {
  echo "Response did not look like a file download"
  cat /tmp/build-headers.txt
  exit 1
}
size=$(stat -c%s /tmp/undionly.kpxe)
echo "Build artefact size: ${size} bytes"
if [ "$size" -lt 10000 ]; then
  echo "Build artefact is suspiciously small (${size} bytes) -- likely an error page, not a real binary"
  exit 1
fi

# Cover the certificate-trust path: build.fcgi's trust_cert() wires a
# POSTed TRUST_CERT into both CERT= and TRUST= for the same file (see
# public/build.fcgi), and the frontend now submits builds via multipart
# POST (see public/js/ui.js's buildcfg()/buildcfgParams()), not the GET
# query string the plain smoke test above still uses for simplicity.
# Neither case was previously exercised anywhere in CI.
echo "== Submitting a certificate-trust EFI build =="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/ci-root-key.pem -out /tmp/ci-root-cert.pem \
  -subj '/CN=CI Test Root/O=CI'
status=$(curl -s --max-time 180 \
  -D /tmp/trust-build-headers.txt \
  -o /tmp/snponly.efi \
  -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F "TRUST_CERT=</tmp/ci-root-cert.pem" \
  "$url")
echo "Response status: ${status}"
if [ "$status" != "200" ]; then
  echo "Certificate-trust build request failed"
  echo "--- response headers ---"
  cat /tmp/trust-build-headers.txt
  echo "--- response body ---"
  cat /tmp/snponly.efi
  exit 1
fi
grep -qi '^Content-Disposition: attachment' /tmp/trust-build-headers.txt || {
  echo "Response did not look like a file download"
  cat /tmp/trust-build-headers.txt
  exit 1
}
size=$(stat -c%s /tmp/snponly.efi)
echo "Certificate-trust build artefact size: ${size} bytes"
if [ "$size" -lt 10000 ]; then
  echo "Build artefact is suspiciously small (${size} bytes) -- likely an error page, not a real binary"
  exit 1
fi

# Negative case: trust_cert()'s `openssl x509 -noout` validation must
# actually reject bad input end-to-end (not just when unit-tested in
# isolation) -- a bogus PEM block must fail the build, not silently
# produce a binary that trusts nothing.
echo "== Submitting an invalid certificate and confirming rejection =="
status=$(curl -s --max-time 120 \
  -o /tmp/invalid-cert-response.txt \
  -w '%{http_code}' \
  -F 'BINARY=snponly.efi' \
  -F 'BINDIR=bin-x86_64-efi' \
  -F 'REVISION=master' \
  -F 'DEBUG=' \
  -F 'EMBED.00script.ipxe=' \
  -F $'TRUST_CERT=-----BEGIN CERTIFICATE-----\nnotbase64\n-----END CERTIFICATE-----' \
  "$url")
echo "Response status: ${status}"
if [ "$status" = "200" ]; then
  echo "Invalid certificate was accepted -- trust_cert() should have rejected it"
  cat /tmp/invalid-cert-response.txt
  exit 1
fi

# The positive case above proves TRUST_CERT works via POST; this proves
# build.fcgi's own request-method check actually rejects it over GET too,
# rather than relying solely on the frontend never constructing such a URL
# (see trust_cert() in public/build.fcgi) -- a GET query string still lands
# in browser history and front-end access logs regardless of what the
# frontend intends.
echo "== Submitting TRUST_CERT via GET and confirming rejection =="
status=$(curl -s --max-time 30 \
  -o /tmp/get-trust-response.txt \
  -w '%{http_code}' \
  --get \
  --data-urlencode 'BINARY=snponly.efi' \
  --data-urlencode 'BINDIR=bin-x86_64-efi' \
  --data-urlencode 'REVISION=master' \
  --data-urlencode 'DEBUG=' \
  --data-urlencode 'EMBED.00script.ipxe=' \
  --data-urlencode 'TRUST_CERT@/tmp/ci-root-cert.pem' \
  "$url")
echo "Response status: ${status}"
if [ "$status" = "200" ]; then
  echo "TRUST_CERT over GET was accepted -- build.fcgi should reject it"
  cat /tmp/get-trust-response.txt
  exit 1
fi
grep -qi 'POST' /tmp/get-trust-response.txt || {
  echo "Rejected, but not with the expected POST-required error"
  cat /tmp/get-trust-response.txt
  exit 1
}
