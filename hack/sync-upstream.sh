#!/usr/bin/env bash
# Mirrors upstream stable tags, creates ocm/<tag> maintenance branches, and
# refreshes the overlay on existing maintenance branches.
#
# Required env: GH_APP_TOKEN, MIN_TAG, CONTROL_DIR, CONTROL_SHA. Optional: EXTRA_TAG.
# Pushes must use the app token: GITHUB_TOKEN may not touch .github/workflows, and only ocmbot may push to ocm/v*.
set -euo pipefail

: "${GH_APP_TOKEN:?}" "${MIN_TAG:?}" "${CONTROL_DIR:?}" "${CONTROL_SHA:?}"
EXTRA_TAG="${EXTRA_TAG:-}"

FORK=open-component-model/cosign
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
APPLY="${CONTROL_DIR}/hack/apply-overlay.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git remote add origin "https://x-access-token:${GH_APP_TOKEN}@github.com/${FORK}.git"
git remote add upstream https://github.com/sigstore/cosign.git
git config user.name 'ocmbot[bot]'
git config user.email '125909804+ocmbot[bot]@users.noreply.github.com'

git fetch -q --no-tags upstream '+refs/tags/*:refs/upstream-tags/*'
git fetch -q --no-tags origin '+refs/tags/*:refs/tags/*' '+refs/heads/ocm/*:refs/remotes/origin/ocm/*'

# 1. Mirror upstream stable tags; never overwrite a tag that already exists.
while read -r t; do
  [[ "$t" =~ $TAG_RE ]] || continue
  up="$(git rev-parse "refs/upstream-tags/$t")"
  if ! have="$(git rev-parse -q --verify "refs/tags/$t")"; then
    echo "mirroring tag $t"
    git push -q origin "refs/upstream-tags/$t:refs/tags/$t"
    git update-ref "refs/tags/$t" "$up"
  elif [ "$have" != "$up" ]; then
    echo "::warning::tag $t differs from upstream, left untouched"
  fi
done < <(git for-each-ref --format='%(refname:lstrip=2)' refs/upstream-tags/)

# Existing maintenance branches, captured before step 2 creates new ones.
mapfile -t existing < <(git for-each-ref --format='%(refname:lstrip=4)' refs/remotes/origin/ocm/)

at_or_above_min() {
  [ "$(printf '%s\n%s\n' "$MIN_TAG" "$1" | sort -V | head -1)" = "$MIN_TAG" ]
}

# 2. Create maintenance branches for new tags.
candidates=()
while read -r t; do
  if [[ "$t" =~ $TAG_RE ]] && at_or_above_min "$t"; then candidates+=("$t"); fi
done < <(git for-each-ref --format='%(refname:lstrip=2)' refs/tags/)
if [ -n "$EXTRA_TAG" ]; then
  if ! [[ "$EXTRA_TAG" =~ $TAG_RE ]] || ! git rev-parse -q --verify "refs/tags/$EXTRA_TAG" >/dev/null; then
    echo "::error::EXTRA_TAG $EXTRA_TAG is not a mirrored stable tag"
    exit 1
  fi
  candidates+=("$EXTRA_TAG")
fi

for t in "${candidates[@]}"; do
  if git rev-parse -q --verify "refs/remotes/origin/ocm/$t" >/dev/null; then continue; fi
  echo "creating branch ocm/$t"
  git checkout -q -B "ocm/$t" "refs/tags/$t^{commit}"
  "$APPLY" "$CONTROL_DIR"
  git commit -q -s -m "chore: apply OCM overlay (ocm-main@${CONTROL_SHA::12})"
  git push -q origin "HEAD:refs/heads/ocm/$t"
  git update-ref "refs/remotes/origin/ocm/$t" HEAD
done

# 3. Refresh the overlay on branches that already existed. Runs in an `if`, where
# errexit is off, so every step propagates its failure explicitly.
refresh() {
  local name="$1"
  git checkout -q -f -B "ocm/$name" "refs/remotes/origin/ocm/$name" || return 1
  git clean -q -fdx || return 1
  "$APPLY" "$CONTROL_DIR" || return 1
  if git diff --cached --quiet; then
    echo "ocm/$name: overlay up to date"
    return 0
  fi
  git commit -q -s -m "chore: update OCM overlay (ocm-main@${CONTROL_SHA::12})" || return 1
  git push -q origin "HEAD:refs/heads/ocm/$name"
}

failed=()
for name in "${existing[@]}"; do
  [ -n "$name" ] || continue
  echo "refreshing overlay on ocm/$name"
  if refresh "$name"; then continue; fi
  # Most likely a race with a Renovate fast-forward: re-fetch and retry once.
  echo "::warning::push to ocm/$name rejected, retrying on fresh branch head"
  if git fetch -q --no-tags origin "+refs/heads/ocm/$name:refs/remotes/origin/ocm/$name" && refresh "$name"; then
    continue
  fi
  echo "::error::failed to refresh overlay on ocm/$name"
  failed+=("$name")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "::error::overlay refresh failed for: ${failed[*]}"
  exit 1
fi
