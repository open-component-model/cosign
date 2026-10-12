#!/usr/bin/env bash
# Smoke-tests a cosign image: reported version, and `initialize`, which needs CA
# certs, FIPS-mode TLS to the sigstore TUF CDN and a writable $HOME.
set -euo pipefail

image="${1:?usage: smoke-image.sh <image-ref> <expected-version>}"
version="${2:?usage: smoke-image.sh <image-ref> <expected-version>}"

docker run --rm "$image" version | grep -E "GitVersion:\s+${version}$"
docker run --rm "$image" initialize
