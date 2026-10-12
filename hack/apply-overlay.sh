#!/usr/bin/env bash
# Replaces upstream workflows/dependabot with the OCM overlay and stages the result.
# Run from the root of a maintenance-branch worktree. Recopying the whole overlay
# makes the staged diff empty when nothing changed.
set -euo pipefail

control_dir="${1:?usage: apply-overlay.sh <control_dir>}"

# Only workflow definitions go; .github/workflows/cosign-test.{key,pub} are used by test/ci.mk.
git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | xargs -0 -r git rm -q --
git rm -q --ignore-unmatch -- .github/dependabot.yml
cp -R "${control_dir}/overlay/." .
git add -A -- .github
