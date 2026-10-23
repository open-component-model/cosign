#!/usr/bin/env bash
# Updates the Go modules of a maintenance branch (run from its root) to their newest
# allowed versions and writes the commit message to $BUMP_MSG. Leaves the tree untouched
# and $BUMP_MSG empty when nothing can be updated. Policy: docs/maintenance.md#go-module-policy.
set -euo pipefail

: "${BUMP_MSG:?BUMP_MSG must name the file that receives the commit message}"
export GOTOOLCHAIN=local GOFLAGS=-mod=mod
: > "$BUMP_MSG"

before="$(mktemp)"
trap 'rm -f "$before"' EXIT
go mod edit -json > "$before"

# Every module listed in go.mod (direct and // indirect) with an available update.
# `go list -m -u` stays within one module path, so Go majors (new paths) never show up.
# shellcheck disable=SC2046 # one argument per module path
mapfile -t updates < <(
  go list -m -u -json $(jq -r '.Require[].Path' "$before") | jq -r '
    select(.Update)
    # The cosign ecosystem moves in lockstep with cosign source: rekor v1.5.4 added
    # CreateLogEntryContext to its generated client (the cosign mock no longer compiles),
    # timestamp-authority v2.1.3 broke the TSA e2e tests. Newer versions arrive with new
    # upstream cosign tags, i.e. new maintenance branches.
    | select(.Path | startswith("github.com/sigstore/") | not)
    # Renamed to github.com/ThalesGroup/crypto11 at v1.5.0; bumps past v1.4.x on the old
    # path fail go.sum with a module-path mismatch (OCM #2966, #3379).
    | select(.Path != "github.com/ThalesIgnite/crypto11")
    # v2.27.0 pulls google.golang.org/genproto past the removal of googleapis/cloud/kms/v1,
    # which tink-go-gcpkms v2.4.0 tests (via timestamp-authority) still import: tidy fails.
    | select(.Path != "github.com/googleapis/gax-go/v2")
    # Indirect modules without releases follow their importers via MVS instead of jumping
    # to their default-branch tip, which breaks version sets: e.g. k8s.io/kube-openapi tip
    # needs structured-merge-diff/v7 while apimachinery still passes v6 types.
    | select((.Indirect and (.Update.Version | test("[0-9]{14}-[0-9a-f]{12}$"))) | not)
    # No v0 -> v1 either (same module path, but a major in semver terms).
    | select((.Version | split(".")[0]) == (.Update.Version | split(".")[0]))
    | "\(.Path)@\(.Update.Version)"'
)

if [ "${#updates[@]}" -eq 0 ]; then
  echo "nothing to update"
  exit 0
fi
printf 'updating %s\n' "${updates[@]}"
# A module that needs a newer Go than GO_VERSION fails here (GOTOOLCHAIN=local); it waits
# for the go-toolchain bump on main.
go get "${updates[@]}"
go mod tidy

{
  echo "fix(deps): update go modules"
  echo
  echo "| module | from | to |"
  echo "| --- | --- | --- |"
  go mod edit -json | jq -r --slurpfile old "$before" '
    ($old[0].Require | map({(.Path): .Version}) | add) as $was
    | .Require[] | select($was[.Path] != null and $was[.Path] != .Version)
    | "| \(.Path) | \($was[.Path]) | \(.Version) |"'
} > "$BUMP_MSG"
