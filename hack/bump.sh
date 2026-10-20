#!/usr/bin/env bash
# One dependency-update PR, end to end. Called by .github/workflows/bump.yml; lifecycle in
# docs/maintenance.md#update-prs.
#
#   bump.sh open <target> <slug>   run the updater on <target>, push bump/<target>/<slug>, open or refresh its PR
#   bump.sh wait                   wait for the PR's CI run (env TARGET, SHA)
#   bump.sh merge                  fast-forward TARGET to SHA; GitHub records the PR as merged (env TARGET, BRANCH, SHA, PR;
#                                  if TARGET moved, dispatches a rebuild with DISPATCH_TOKEN unless REBUILT=true)
#
# <target>/<slug>: ocm/vX.Y.Z go-modules, or main with a hack/bump-pins.sh group.
# open/merge push with GH_APP_TOKEN (only ocmbot may push to main and ocm/v*); gh uses GH_TOKEN.
# REPO_URL overrides the push/fetch remote (local tests). Results go to $GITHUB_OUTPUT (stdout
# when unset), one line per step to $GITHUB_STEP_SUMMARY (stderr when unset).
set -euo pipefail

BOT_NAME='ocmbot[bot]'
BOT_EMAIL='125909804+ocmbot[bot]@users.noreply.github.com'
LABEL=dependencies
PIN_GROUPS='go-toolchain test-tooling sigstore-e2e-services github-actions base-images'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GITHUB_REPOSITORY:?}"

usage() {
  echo "usage: bump.sh open ocm/vX.Y.Z go-modules | open main <${PIN_GROUPS// /|}> | wait | merge" >&2
  exit 2
}
output() { echo "$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }
summary() { echo "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"; }
ci_workflow() { if [ "$1" = main ]; then echo "Control CI"; else echo "OCM CI"; fi; }

# Fresh temp repo with the given branches under refs/remotes/origin/ (missing ones are skipped).
work=""
trap '[ -z "$work" ] || rm -rf "$work"' EXIT
clone() {
  work="$(mktemp -d)"
  cd "$work"
  git init -q
  git remote add origin "${REPO_URL:-https://x-access-token:${GH_APP_TOKEN:?}@github.com/${GITHUB_REPOSITORY}.git}"
  git config user.name "$BOT_NAME"
  git config user.email "$BOT_EMAIL"
  local b
  for b in "$@"; do
    git fetch -q --no-tags origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
  done
}

cmd_open() {
  local target="${1:-}" slug="${2:-}" updater branch base existing msg sha title body pr
  if [ "$target" = main ] && [[ " $PIN_GROUPS " == *" $slug "* ]]; then
    updater=("$here/bump-pins.sh" "$slug")
  elif [[ "$target" =~ ^ocm/v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$slug" = go-modules ]; then
    updater=("$here/bump-go-modules.sh")
  else
    usage
  fi
  branch="bump/${target}/${slug}"
  output "target=${target}"
  output "branch=${branch}"

  clone "$target" "$branch"
  base="$(git rev-parse -q --verify "refs/remotes/origin/${target}")" || { echo "::error::branch ${target} not found" >&2; exit 1; }
  existing="$(git rev-parse -q --verify "refs/remotes/origin/${branch}" || true)"
  if [ -n "$existing" ] && [ "$(git log -1 --format=%ae "$existing")" != "$BOT_EMAIL" ]; then
    summary "- \`${branch}\`: has commits by others, left to its PR"
    output "state=skipped"
    return
  fi

  git checkout -q -B work "$base"
  msg="$(mktemp)"
  BUMP_MSG="$msg" "${updater[@]}"
  if [ -z "$(git status --porcelain)" ]; then
    # Deleting the branch closes a PR whose updates have landed some other way.
    if [ -n "$existing" ]; then git push -q origin --delete "$branch"; fi
    summary "- \`${target}\` ${slug}: up to date"
    output "state=none"
    return
  fi
  git add -A
  git commit -q -s -F "$msg"
  sha="$(git rev-parse HEAD)"
  if [ -n "$existing" ] && [ "$(git rev-parse "${existing}^")" = "$base" ] && git diff --quiet "$existing" HEAD; then
    # Same update as the previous run: keep its commit, and so its CI run (wait retries it).
    sha="$existing"
  else
    git push -q --force origin "${sha}:refs/heads/${branch}"
  fi

  title="$(git log -1 --format=%s "$sha")"
  body="$(mktemp)"
  {
    git log -1 --format=%b "$sha" | grep -v '^Signed-off-by:' || true
    echo
    echo "---"
    echo "Opened by [Maintain](https://github.com/${GITHUB_REPOSITORY}/actions/workflows/maintain.yml)."
    echo "ocmbot fast-forwards \`${target}\` to this branch once $(ci_workflow "$target") passes; a failing PR"
    echo "stays open and is rebuilt on every run. Pushing to this branch takes it over:"
    echo "see [update PRs](https://github.com/${GITHUB_REPOSITORY}/blob/main/docs/maintenance.md#update-prs)."
  } > "$body"
  gh label create "$LABEL" --repo "$GITHUB_REPOSITORY" --color 0366d6 \
    --description "Dependency updates opened by Maintain" --force >/dev/null
  pr="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --base "$target" --state open --json url -q '.[0].url')"
  if [ -z "$pr" ]; then
    pr="$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$target" --head "$branch" \
      --title "$title" --body-file "$body" --label "$LABEL")"
  else
    gh pr edit "$pr" --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$body" >/dev/null
  fi
  summary "- \`${target}\` ${slug}: ${pr}"
  output "state=open"
  output "sha=${sha}"
  output "pr=${pr}"
}

cmd_wait() {
  : "${TARGET:?}" "${SHA:?}"
  local wf run="" id status conclusion url result
  wf="$(ci_workflow "$TARGET")"
  for _ in $(seq 60); do
    run="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$wf" --commit "$SHA" --event pull_request \
      --limit 1 --json databaseId,status,conclusion -q '.[0] // empty | "\(.databaseId) \(.status) \(.conclusion)"')"
    if [ -n "$run" ]; then break; fi
    sleep 10
  done
  if [ -z "$run" ]; then
    echo "::error::no ${wf} run for ${SHA} after 10 minutes"
    summary "  - ${wf}: no run found"
    output "result=failure"
    exit 1
  fi
  read -r id status conclusion <<< "$run"
  if [ "$status" = completed ] && [ "$conclusion" != success ]; then
    # Unchanged update whose CI failed on an earlier run: retry the failed jobs once per run.
    echo "re-running failed jobs of ${wf} run ${id}"
    gh run rerun "$id" --repo "$GITHUB_REPOSITORY" --failed
    for _ in $(seq 24); do
      [ "$(gh run view "$id" --repo "$GITHUB_REPOSITORY" --json status -q .status)" = completed ] || break
      sleep 5
    done
  fi
  url="$(gh run view "$id" --repo "$GITHUB_REPOSITORY" --json url -q .url)"
  echo "waiting for ${url}"
  if gh run watch "$id" --repo "$GITHUB_REPOSITORY" --exit-status -i 30 >/dev/null; then
    result=success
  else
    result=failure
  fi
  output "result=${result}"
  output "run-url=${url}"
  summary "  - ${wf}: [${result}](${url})"
  if [ "$result" != success ]; then
    echo "::error::${wf} failed: ${url}"
    exit 1
  fi
}

cmd_merge() {
  : "${TARGET:?}" "${BRANCH:?}" "${SHA:?}" "${PR:?}"
  local state=""
  clone "$TARGET" "$BRANCH"
  if [ "$(git rev-parse -q --verify "refs/remotes/origin/${BRANCH}" || true)" != "$SHA" ]; then
    summary "  - not merged: \`${BRANCH}\` changed while CI ran"
    return
  fi
  # A plain push is accepted only as a fast-forward.
  if ! git merge-base --is-ancestor "refs/remotes/origin/${TARGET}" "$SHA" ||
    ! git push -q origin "${SHA}:refs/heads/${TARGET}"; then
    # Typically Sync upstream propagating a main overlay change. Rebuild on the new head
    # right away, once: a rebuilt run that loses the race again waits for the next Maintain run.
    if [ "${REBUILT:-false}" = true ]; then
      echo "::warning::${TARGET} moved again while CI ran; ${PR} stays open and is rebuilt on the next run"
      summary "  - not merged: \`${TARGET}\` moved again while CI ran, rebuilt on the next run"
      return
    fi
    GH_TOKEN="${DISPATCH_TOKEN:-$GH_TOKEN}" gh workflow run bump.yml --repo "$GITHUB_REPOSITORY" --ref main \
      -f target="$TARGET" -f slug="${BRANCH#"bump/${TARGET}/"}" -f rebuilt=true
    echo "::notice::${TARGET} moved while CI ran; started a Bump run to rebuild ${PR} on the new head"
    summary "  - not merged: \`${TARGET}\` moved while CI ran, [rebuilding now](https://github.com/${GITHUB_REPOSITORY}/actions/workflows/bump.yml)"
    return
  fi
  for _ in $(seq 12); do
    state="$(gh pr view "$PR" --repo "$GITHUB_REPOSITORY" --json state -q .state)"
    if [ "$state" = MERGED ]; then break; fi
    sleep 5
  done
  if [ "$state" = MERGED ]; then
    # delete_branch_on_merge may have removed it already.
    if git ls-remote --exit-code -q --heads origin "$BRANCH" >/dev/null; then
      git push -q origin --delete "$BRANCH"
    fi
  else
    echo "::warning::${PR} is ${state} after the fast-forward; branch ${BRANCH} kept"
  fi
  summary "  - merged into \`${TARGET}\`"
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  wait) cmd_wait ;;
  merge) cmd_merge ;;
  *) usage ;;
esac
