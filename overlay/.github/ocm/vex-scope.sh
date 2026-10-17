#!/usr/bin/env bash
# Scopes a govulncheck OpenVEX document to the product it describes.
# govulncheck names the product "Unknown Product" and path-escapes module purls
# (pkg:golang/golang.org%2Fx%2Fcrypto), so scanners matching statements by purl
# (e.g. trivy --vex) apply none of them. This sets every product to <product purl>, restores
# the module paths of the subcomponents and, with <file>, pins the product to that file's
# SHA-256 (OpenVEX product hashes). Previous product hashes are dropped.
#
#   binary:      vex-scope.sh cosign-linux-amd64.openvex.json pkg:golang/<module> dist/cosign-linux-amd64
#   image:       vex-scope.sh govulncheck.openvex.json "pkg:oci/cosign@sha256%3A<hex>"
set -euo pipefail

usage="usage: vex-scope.sh <govulncheck.openvex.json> <product purl> [<file>]"
vex="${1:?$usage}"
product="${2:?$usage}"
if ! [[ "$product" =~ ^pkg:[a-z]+/ ]]; then
  echo "::error::${product} is not a purl" >&2
  exit 1
fi
hash=""
if [ -n "${3:-}" ]; then
  hash="$(sha256sum "$3" | cut -d' ' -f1)"
fi

jq --arg product "$product" --arg hash "$hash" '
  .statements[]?.products[]? |= (
    ."@id" = $product
    | del(.hashes)
    | if $hash != "" then .hashes = {"sha-256": $hash} else . end
    | .subcomponents[]?."@id" |= gsub("%2F"; "/"))
' "$vex"
