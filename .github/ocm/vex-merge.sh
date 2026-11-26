#!/usr/bin/env bash
# Merges per-target govulncheck OpenVEX documents into the report for the image index and
# the release as a whole: a vulnerability is affected if any target reaches it, and
# not_affected only if none does. Document fields come from the first input; statements are
# one per vulnerability, sorted by ID.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: vex-merge.sh <cosign-<os>-<arch>.openvex.json>..." >&2
  exit 1
fi

jq -s '
  .[0] + {statements: ([.[].statements[]?]
    | group_by(.vulnerability.name)
    | map((map(select(.status == "affected")) | first) // first))}
' "$@"
