#!/usr/bin/env bash
# CI: prove the built image's distribution labels describe the base it was
# actually built on.
#
# DISTRIBUTION_VERSION is a hand-maintained duplicate of the Dockerfile's
# FROM tag (kept literal so Dependabot can still parse and bump it -- see
# the note in the base-ubuntu stage). The Dockerfile asserts at build time
# that the ENV matches the base's own os-release, which catches a bump that
# rewrites the FROM line and leaves the ENV behind. This catches the other
# half: the ENV -> LABEL plumbing at the bottom of the Dockerfile, where the
# final stage inherits the value from base-${TARGET_OS}. A break there --
# a shadowing ARG, a re-declared ENV, a stage rename -- would ship an image
# labelled with the wrong base, or with no version at all, while every
# build-time assert still passed. The label is what consumers of the
# published image read, so it is the thing worth checking directly.
set -euo pipefail

image="${1:-${IMAGE_NAME:-mediocreatmybest/ipxe-buildweb}:test}"

# Same guard, and for the same reason, as smoke-cert-disabled.sh: `docker
# run` on a missing local image tries to pull it, and a wrong tag then
# surfaces as a registry "manifest unknown" error naming a tag that was
# never meant to exist remotely.
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Image '$image' is not present locally."
  echo "Pass the image to test as the first argument, e.g.:"
  echo "  bash $0 mediocreatmybest/ipxe-buildweb:test-ubuntu"
  exit 1
fi

label() {
  docker image inspect --format "{{ index .Config.Labels \"$1\" }}" "$image"
}

echo "== Reading distribution labels from $image =="
labelled_os=$(label org.rom-oh-matic.distribution)
labelled_version=$(label org.rom-oh-matic.distribution.version)
echo "  org.rom-oh-matic.distribution:         ${labelled_os:-<empty>}"
echo "  org.rom-oh-matic.distribution.version: ${labelled_version:-<empty>}"

# Checked before the comparisons below: an unset label reads back as the
# empty string, and comparing that against anything would report a
# mismatch that names no value and points at no cause.
missing=0
[ -n "$labelled_os" ] || { echo "  org.rom-oh-matic.distribution is missing or empty."; missing=1; }
[ -n "$labelled_version" ] || { echo "  org.rom-oh-matic.distribution.version is missing or empty."; missing=1; }
if [ "$missing" -ne 0 ]; then
  echo "The ENV -> LABEL plumbing at the bottom of the Dockerfile is broken."
  exit 1
fi

# Read from inside the image rather than from the ENV the label came from,
# which would make this check circular.
echo "== Reading os-release from inside the image =="
os_release=$(docker run --rm --entrypoint sh "$image" -c '. /etc/os-release && echo "$ID $VERSION_ID"')
actual_os=${os_release%% *}
actual_version=${os_release##* }
echo "  ID=$actual_os VERSION_ID=$actual_version"

problem=0

if [ "$labelled_os" != "$actual_os" ]; then
  echo "  distribution label is '$labelled_os' but the base image is '$actual_os'."
  problem=1
else
  echo "  distribution: '$labelled_os' matches the base image, OK"
fi

# Alpine reports a patch-level VERSION_ID (3.24.1) where the FROM tag names
# only the series (3.24), so the series itself and any patch release under
# it both count as a match. Ubuntu's VERSION_ID is the full release (26.04)
# and matches exactly; the series form is simply never hit there.
case "$actual_version" in
  "$labelled_version"|"$labelled_version".*)
    echo "  distribution.version: '$labelled_version' matches base '$actual_version', OK"
    ;;
  *)
    echo "  distribution.version label is '$labelled_version' but the base image is '$actual_version'."
    echo "  Update DISTRIBUTION_VERSION in the Dockerfile stage to match its FROM tag."
    problem=1
    ;;
esac

exit "$problem"
