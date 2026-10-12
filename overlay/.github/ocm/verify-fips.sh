#!/usr/bin/env bash
# Fails unless <binary> was built with the CMVP-certified Go Cryptographic Module
# of the active toolchain, FIPS mode on by default, and CGO disabled.
set -euo pipefail

bin="${1:?usage: verify-fips.sh <binary>}"
# Compare against the toolchain's certified.txt so a Go bump that ships a newer
# certified module is picked up without editing this script.
want="$(cat "$(go env GOROOT)/lib/fips140/certified.txt")"
info="$(go version -m "$bin")"

tab=$'\t'
ok=true
grep -qxF "${tab}build${tab}GOFIPS140=${want}" <<<"$info" || ok=false
grep -qxF "${tab}build${tab}CGO_ENABLED=0" <<<"$info" || ok=false
godebug="$(grep -E "^${tab}build${tab}DefaultGODEBUG=" <<<"$info" | cut -d= -f2- || true)"
tr ',' '\n' <<<"$godebug" | grep -qxF 'fips140=on' || ok=false

if [ "$ok" != true ]; then
  echo "::error::${bin} is not a certified FIPS build (expected GOFIPS140=${want})"
  exit 1
fi
echo "${bin}: GOFIPS140=${want}, fips140=on, CGO_ENABLED=0"
