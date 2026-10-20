#!/usr/bin/env bash
# Updates one group of main pins (run from the root of a main checkout) and writes
# the commit message to $BUMP_MSG; leaves it empty when nothing changed.
#
#   bump-pins.sh go-toolchain|test-tooling|sigstore-e2e-services   pins in overlay/.github/ocm/.env
#   bump-pins.sh github-actions                                    action SHAs (pinact)
#   bump-pins.sh base-images                                       FROM digests in the Containerfile
#
# Needs GH_TOKEN (gh release lookups, pinact). Pin format: docs/maintenance.md#pin-format.
set -euo pipefail

group="${1:-}"
: "${BUMP_MSG:?BUMP_MSG must name the file that receives the commit message}"
: "${GH_TOKEN:?GH_TOKEN is required for GitHub API lookups}"
ENV_FILE=overlay/.github/ocm/.env
TOOLS_FILE=hack/tools.env
CONTAINERFILE=overlay/.github/ocm/Containerfile
changes=()

latest() { # <source> [<name>]
  case "$1" in
    go) curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//' ;;
    github-release) gh release view -R "$2" --json tagName -q .tagName ;;
    go-module) curl -fsSL "https://proxy.golang.org/$2/@latest" | jq -r .Version ;;
    *) echo "::error::unknown pin source '$1'" >&2; return 1 ;;
  esac
}

# Bumps every pin of <group> in <file>: the NAME=value line after "# bump: <group> <source> [<name>]".
bump_env() { # <file> <group>
  local file="$1" want="$2" out line marker=() name old new
  out="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#marker[@]}" -gt 0 ] && [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}" old="${BASH_REMATCH[2]}"
      if ! new="$(latest "${marker[@]:2}")" || [ -z "$new" ] || [ "$new" = null ]; then
        echo "::error::lookup failed for ${name} (${marker[*]:2})" >&2
        rm -f "$out"
        return 1
      fi
      if [ "$new" != "$old" ]; then
        changes+=("${name} ${old} -> ${new}")
        line="${name}=${new}"
      fi
      marker=()
    elif [[ "$line" =~ ^#\ bump:\ (.*)$ ]]; then
      read -r -a marker <<< "x ${BASH_REMATCH[1]}"
      if [ "${marker[1]}" != "$want" ]; then marker=(); fi
    else
      marker=()
    fi
    printf '%s\n' "$line" >> "$out"
  done < "$file"
  cat "$out" > "$file" && rm -f "$out"
}

pin() { grep -E "^$2=" "$1" | cut -d= -f2-; }

case "$group" in
  go-toolchain) subject="chore(deps): update go toolchain"; bump_env "$ENV_FILE" "$group" ;;
  test-tooling) subject="chore(deps): update test tooling"; bump_env "$ENV_FILE" "$group" ;;
  sigstore-e2e-services) subject="chore(deps): update sigstore e2e services"; bump_env "$ENV_FILE" "$group" ;;
  github-actions)
    subject="chore(deps): update github actions"
    bump_env "$TOOLS_FILE" "$group"
    GITHUB_TOKEN="$GH_TOKEN" go run "github.com/suzuki-shunsuke/pinact/v5/cmd/pinact@$(pin "$TOOLS_FILE" PINACT_VERSION)" \
      run --update .github/workflows/*.yml overlay/.github/workflows/*.yml
    while IFS= read -r l; do changes+=("${l#+}"); done < <(git diff -U0 -- '*.yml' | grep -E '^\+.*uses:' | sed -E 's/^\+[[:space:]]*(- )?//' | sort -u)
    ;;
  base-images)
    subject="chore(deps): update container base images"
    re='^(FROM .*[[:space:]])([^[:space:]@]+:[^[:space:]@]+)@(sha256:[0-9a-f]{64})(.*)$'
    out="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ $re ]]; then
        ref="${BASH_REMATCH[2]}" old="${BASH_REMATCH[3]}"
        new="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' | jq -r .digest)"
        if [[ ! "$new" =~ ^sha256:[0-9a-f]{64}$ ]]; then
          echo "::error::digest lookup failed for ${ref}" >&2
          exit 1
        fi
        if [ "$new" != "$old" ]; then
          changes+=("${ref} ${old} -> ${new}")
          line="${BASH_REMATCH[1]}${ref}@${new}${BASH_REMATCH[4]}"
        fi
      fi
      printf '%s\n' "$line" >> "$out"
    done < "$CONTAINERFILE"
    cat "$out" > "$CONTAINERFILE" && rm -f "$out"
    ;;
  *) echo "usage: bump-pins.sh go-toolchain|test-tooling|sigstore-e2e-services|github-actions|base-images" >&2; exit 2 ;;
esac

: > "$BUMP_MSG"
if [ -z "$(git status --porcelain)" ]; then
  echo "nothing to update"
  exit 0
fi
{
  echo "$subject"
  echo
  if [ "${#changes[@]}" -gt 0 ]; then printf -- '- %s\n' "${changes[@]}"; fi
} > "$BUMP_MSG"
cat "$BUMP_MSG"
