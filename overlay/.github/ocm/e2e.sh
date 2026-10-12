#!/usr/bin/env bash
# Runs upstream test/e2e_test.sh against pinned, cacheable sigstore services.
#
# e2e_test.sh sources sigstore/scaffolding's run-containers.sh, which clones fulcio, rekor,
# timestamp-authority and rekor-tiles into $CLONE_DIR at HEAD and builds them from source
# (~10 min). An existing clone is only `git pull`ed, and compose skips building images that
# already exist. So we pre-clone the release tags pinned in .env on a branch that tracks
# itself (the pull is a no-op) and load the service images cached under those pins.
#
#   e2e.sh key                cache key of the service images
#   e2e.sh run [images.tar]   start kind, pre-clone services, load images, run test/e2e_test.sh
#   e2e.sh save-images <tar>  write the built service images to <tar>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin() { grep -E "^$1=" "$here/.env" | cut -d= -f2-; }
services=(
  "fulcio=$(pin FULCIO_VERSION)"
  "rekor=$(pin REKOR_VERSION)"
  "timestamp-authority=$(pin TIMESTAMP_AUTHORITY_VERSION)"
  "rekor-tiles=$(pin REKOR_TILES_VERSION)"
)
image_re='^(docker\.io/library/)?(fulcio|rekor|timestamp-authority|rekor-tiles)-'

case "${1:-}" in
  key)
    # The witness image is derived from the rekor-tiles pin (see run), so the pins
    # fully determine the image set. Bump v1 to force a rebuild.
    key="sigstore-images-v1"
    for s in "${services[@]}"; do key+="-${s%%=*}-${s#*=}"; done
    echo "$key"
    ;;
  run)
    : "${CLONE_DIR:?CLONE_DIR must be set: run-containers.sh clones the services there}"
    images="${2:-}"

    # kind backs `cosign generate-key-pair k8s://...`; create it while the services load.
    go install "sigs.k8s.io/kind@$(pin KIND_VERSION)"
    kind_log="$(mktemp)"
    kind create cluster >"$kind_log" 2>&1 &
    kind_pid=$!

    mkdir -p "$CLONE_DIR"
    for s in "${services[@]}"; do
      repo="${s%%=*}" tag="${s#*=}"
      rm -rf "${CLONE_DIR:?}/$repo"
      git clone -q --depth 1 --branch "$tag" "https://github.com/sigstore/${repo}.git" "$CLONE_DIR/$repo"
      git -C "$CLONE_DIR/$repo" checkout -q -B pinned
      git -C "$CLONE_DIR/$repo" config branch.pinned.remote .
      git -C "$CLONE_DIR/$repo" config branch.pinned.merge refs/heads/pinned
    done

    # rekor-tiles builds its witness from transparency-dev/witness#main, whose CLI drifts
    # away from older compose files (e.g. --poll_interval was removed). Build the witness
    # as of the pinned rekor-tiles release; compose merges compose.override.yml itself.
    released="$(git -C "$CLONE_DIR/rekor-tiles" log -1 --format=%cI)"
    witness_git="$(mktemp -d)"
    git clone -q --bare --filter=blob:none https://github.com/transparency-dev/witness.git "$witness_git"
    witness_ref="$(git -C "$witness_git" rev-list -1 --before="$released" HEAD)"
    echo "witness: transparency-dev/witness@${witness_ref} (as of rekor-tiles ${released})"
    cat >"$CLONE_DIR/rekor-tiles/compose.override.yml" <<EOF
services:
  witness:
    build:
      context: https://github.com/transparency-dev/witness.git#${witness_ref}
EOF
    if [ -n "$images" ] && [ -f "$images" ]; then
      docker load -q -i "$images"
    else
      echo "no cached service images; run-containers.sh builds them from source"
    fi

    if ! wait "$kind_pid"; then
      cat "$kind_log"
      exit 1
    fi
    CGO_ENABLED=1 ./test/e2e_test.sh
    ;;
  save-images)
    out="${2:?usage: e2e.sh save-images <tar>}"
    mapfile -t imgs < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "$image_re" || true)
    if [ "${#imgs[@]}" -eq 0 ]; then
      echo "::error::no sigstore service images found"
      exit 1
    fi
    printf 'saving %s\n' "${imgs[@]}"
    docker save -o "$out" "${imgs[@]}"
    ;;
  *)
    echo "usage: e2e.sh key | run [images.tar] | save-images <tar>" >&2
    exit 2
    ;;
esac
