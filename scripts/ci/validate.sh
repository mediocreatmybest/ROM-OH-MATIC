#!/usr/bin/env bash
# CI: syntax and unit-test validation, run before the Docker image is built.
set -euo pipefail

echo "== Shell syntax check =="
for f in install.sh start.sh update.sh scripts/ci/*.sh; do
  bash -n "$f"
done

echo "== PHP syntax check =="
for f in public/*.php; do
  php -l "$f"
done

echo "== Python syntax check =="
python3 -m py_compile scripts/parseheaders.py

echo "== Python unit tests =="
python3 -m unittest discover -s tests -v

echo "== JavaScript syntax check =="
node --check public/js/ui.js
