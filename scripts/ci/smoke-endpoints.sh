#!/usr/bin/env bash
# CI: confirm the built image's container actually starts and serves HTTP.
set -euo pipefail

container=rom-o-matic-smoke
url=http://localhost:8080/

echo "== Waiting for HTTP readiness =="
# Bounded readiness loop: fail fast if the container exits, otherwise
# poll HTTP until it responds or the timeout is reached.
ready=false
for i in $(seq 1 30); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "Container exited before becoming ready"
    exit 1
  fi
  if curl -sf "$url" -o /dev/null; then
    echo "HTTP ready after ${i}s"
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != "true" ]; then
  echo "Timed out waiting for HTTP readiness"
  exit 1
fi

echo "== Verifying expected page content =="
curl -sf "$url" | grep -q 'ROM-o-matic' || {
  echo "Root page did not contain the expected ROM-o-matic identifier"
  exit 1
}
