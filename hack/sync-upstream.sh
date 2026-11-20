#!/usr/bin/env bash
# Mirrors upstream stable tags, creates ocm/<tag> maintenance branches, and
# refreshes the overlay on the highest maintenance branch only; older ones are frozen.
#
# Required env: GH_APP_TOKEN, BOT_SLUG, MIN_TAG, CONTROL_DIR, CONTROL_SHA. Optional: EXTRA_TAG.
# GH_APP_TOKEN is a token of the cosign release bot (BOT_SLUG), which mirrors the tags and
# writes ocm/v*; GITHUB_TOKEN may not touch .github/workflows. Branch commits are created
# through the REST API, so GitHub signs them: every commit on this repository is signed.
set -euo pipefail

: "${GH_APP_TOKEN:?}" "${BOT_SLUG:?}" "${MIN_TAG:?}" "${CONTROL_DIR:?}" "${CONTROL_SHA:?}"
EXTRA_TAG="${EXTRA_TAG:-}"
export GH_TOKEN="$GH_APP_TOKEN"

FORK=open-component-model/cosign
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
APPLY="${CONTROL_DIR}/hack/apply-overlay.sh"

bot_id="$(gh api "users/${BOT_SLUG}%5Bbot%5D" --jq .id)"
SIGNOFF="Signed-off-by: ${BOT_SLUG}[bot] <${bot_id}+${BOT_SLUG}[bot]@users.noreply.github.com>"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git remote add origin "https://x-access-token:${GH_APP_TOKEN}@github.com/${FORK}.git"
git remote add upstream https://github.com/sigstore/cosign.git

git fetch -q --no-tags upstream '+refs/tags/*:refs/upstream-tags/*'
git fetch -q --no-tags origin '+refs/tags/*:refs/tags/*' '+refs/heads/ocm/*:refs/remotes/origin/ocm/*'

# Prints the API tree entries (JSON array) for the changes staged on top of commit $1,
# uploading a blob for every added or changed file. Used inside `if`, so every step
# propagates its failure explicitly.
staged_entries() {
  local parent="$1" meta path old_mode new_mode new_sha status blob entries='[]'
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r old_mode new_mode _ new_sha status <<<"${meta#:}"
    if [ "$status" = D ]; then
      entries="$(jq -c --arg p "$path" --arg m "$old_mode" \
        '. + [{path: $p, mode: $m, type: "blob", sha: null}]' <<<"$entries")" || return 1
      continue
    fi
    blob="$(git cat-file blob "$new_sha" | base64 -w0 | jq -Rs '{content: ., encoding: "base64"}' \
      | gh api "repos/${FORK}/git/blobs" --input - --jq .sha)" || return 1
    if [ "$blob" != "$new_sha" ]; then
      echo "::error::blob for ${path} is ${blob}, expected ${new_sha}"
      return 1
    fi
    entries="$(jq -c --arg p "$path" --arg m "$new_mode" --arg s "$new_sha" \
      '. + [{path: $p, mode: $m, type: "blob", sha: $s}]' <<<"$entries")" || return 1
  done < <(git diff-index --cached --no-renames -z "$parent")
  printf '%s\n' "$entries"
}

# Creates a commit of the staged tree on top of commit $1 with message $2 through the
# REST API (GitHub signs it) and prints its SHA. Nothing references it yet.
api_commit() {
  local parent="$1" message="$2" want base entries tree sha verified
  want="$(git write-tree)" || return 1
  base="$(git rev-parse "${parent}^{tree}")" || return 1
  entries="$(staged_entries "$parent")" || return 1
  tree="$(jq -n --arg base "$base" --argjson tree "$entries" '{base_tree: $base, tree: $tree}' \
    | gh api "repos/${FORK}/git/trees" --input - --jq .sha)" || return 1
  if [ "$tree" != "$want" ]; then
    echo "::error::tree ${tree} created through the API differs from the staged tree ${want}"
    return 1
  fi
  sha="$(jq -n --arg msg "$message" --arg tree "$tree" --arg parent "$parent" \
    '{message: $msg, tree: $tree, parents: [$parent]}' \
    | gh api "repos/${FORK}/git/commits" --input - --jq .sha)" || return 1
  verified="$(gh api "repos/${FORK}/git/commits/${sha}" --jq .verification.verified)" || return 1
  if [ "$verified" != true ]; then
    echo "::error::commit ${sha} is not signed; not moving the branch"
    return 1
  fi
  printf '%s\n' "$sha"
}

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

at_or_above_min() {
  [ "$(printf '%s\n%s\n' "$MIN_TAG" "$1" | sort -V | head -1)" = "$MIN_TAG" ]
}

# 2. Create maintenance branches for new tags: the upstream tag plus one overlay commit.
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
  git checkout -q -f -B "ocm/$t" "refs/tags/$t^{commit}"
  git clean -q -fdx
  "$APPLY" "$CONTROL_DIR"
  sha="$(api_commit "$(git rev-parse HEAD)" "$(printf 'chore: apply OCM overlay (main@%s)\n\n%s' "${CONTROL_SHA::12}" "$SIGNOFF")")"
  gh api "repos/${FORK}/git/refs" -f ref="refs/heads/ocm/$t" -f sha="$sha" --silent
  git fetch -q --no-tags origin "+refs/heads/ocm/$t:refs/remotes/origin/ocm/$t"
done

# 3. Refresh the overlay on the highest maintenance branch, computed after step 2 created
# new ones. refresh runs in an `if`, where errexit is off, so every step propagates its
# failure explicitly.
refresh() {
  local name="$1" head sha
  git checkout -q -f -B "ocm/$name" "refs/remotes/origin/ocm/$name" || return 1
  git clean -q -fdx || return 1
  "$APPLY" "$CONTROL_DIR" || return 1
  if git diff --cached --quiet; then
    echo "ocm/$name: overlay up to date"
    return 0
  fi
  head="$(git rev-parse HEAD)" || return 1
  sha="$(api_commit "$head" "$(printf 'chore: update OCM overlay (main@%s)\n\n%s' "${CONTROL_SHA::12}" "$SIGNOFF")")" || return 1
  # force=false: only a fast-forward from the fetched head; a Renovate merge in between rejects it.
  gh api -X PATCH "repos/${FORK}/git/refs/heads/ocm/$name" -f sha="$sha" -F force=false --silent
}

highest="$(git for-each-ref --format='%(refname:lstrip=4)' refs/remotes/origin/ocm/ | sort -V | tail -1)"
[ -n "$highest" ] || exit 0

echo "refreshing overlay on ocm/$highest"
if refresh "$highest"; then exit 0; fi
# Most likely a race with a Renovate fast-forward: re-fetch and retry once.
echo "::warning::update of ocm/$highest rejected, retrying on fresh branch head"
if git fetch -q --no-tags origin "+refs/heads/ocm/$highest:refs/remotes/origin/ocm/$highest" && refresh "$highest"; then
  exit 0
fi
echo "::error::failed to refresh overlay on ocm/$highest"
exit 1
