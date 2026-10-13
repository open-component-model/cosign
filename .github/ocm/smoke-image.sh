#!/usr/bin/env bash
# Smoke-tests a cosign image: reported version, and `initialize`, which needs CA
# certs, FIPS-mode TLS to the sigstore TUF CDN and a writable $HOME.
set -euo pipefail

image="${1:?usage: smoke-image.sh <image-ref> <expected-version>}"
version="${2:?usage: smoke-image.sh <image-ref> <expected-version>}"

# Literal comparison: versions contain '+' (vX.Y.Z+ocm.N), a regex metacharacter.
got="$(docker run --rm "$image" version | awk '$1 == "GitVersion:" {print $2}')"
if [ "$got" != "$version" ]; then
  echo "::error::${image} reports GitVersion '${got}', expected '${version}'"
  exit 1
fi
echo "GitVersion: ${got}"
docker run --rm "$image" initialize
