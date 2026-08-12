#!/usr/bin/env bash
# CI: syntax and unit-test validation, run before the Docker image is built.
set -euo pipefail

echo "== Shell syntax check =="
for f in install.sh start.sh update.sh scripts/os-env.sh scripts/ci/*.sh; do
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

# mod_fcgid execs these directly, so one committed without the executable
# bit fails every request it serves -- and does it invisibly: the forked
# child dies before exec'ing perl, so nothing from Apache or Perl explains
# it and Apache returns its own generic 500. Checked against git's own
# recorded mode, not the working tree's: on a core.fileMode=false checkout
# (any Windows clone) the two disagree, and git's is the one that ends up
# in the image. The Dockerfile also chmods these defensively, but catching
# it here names the real problem instead of quietly masking it.
echo "== FastCGI script executable-bit check =="
# Listed into a variable first, and required to be non-empty: reading the
# loop straight from a pipeline would let a git failure (or a glob that
# matches nothing, if these ever move) produce zero iterations and pass
# silently -- a check that cannot fail is worse than no check, since it
# reads as proof.
fcgi_modes=$(git ls-files -s 'public/*.fcgi')
if [ -z "$fcgi_modes" ]; then
  echo "  No public/*.fcgi files found in git -- expected at least build.fcgi."
  echo "  Refusing to report success on an empty check."
  exit 1
fi
fcgi_mode_problem=0
while read -r mode _ _ path; do
  if [ "$mode" != "100755" ]; then
    echo "  $path is $mode in git; mod_fcgid needs it executable (100755)."
    echo "  Fix with: git update-index --chmod=+x $path"
    fcgi_mode_problem=1
  else
    echo "  $path: 100755, OK"
  fi
done <<< "$fcgi_modes"
if [ "$fcgi_mode_problem" -ne 0 ]; then
  exit 1
fi
