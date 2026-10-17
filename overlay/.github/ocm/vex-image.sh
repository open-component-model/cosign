#!/usr/bin/env bash
# Scopes a govulncheck OpenVEX document to the image index it is attested on.
# govulncheck names the product "Unknown Product" and path-escapes module purls
# (pkg:golang/golang.org%2Fx%2Fcrypto), so scanners matching statements by purl
# (e.g. trivy --vex oci) apply none of them. This sets every product to the purl of
# the image index and restores the module paths of the subcomponents.
set -euo pipefail

usage="usage: vex-image.sh <govulncheck.openvex.json> <image> <index digest>"
vex="${1:?$usage}"
image="${2:?$usage}"
digest="${3:?$usage}"
if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::${digest} is not a sha256 digest" >&2
  exit 1
fi

# No repository_url qualifier: the digest identifies the image, so mirrors match too.
jq --arg product "pkg:oci/${image##*/}@${digest/:/%3A}" '
  .statements[]?.products[]? |= (
    ."@id" = $product
    | .subcomponents[]?."@id" |= gsub("%2F"; "/"))
' "$vex"
