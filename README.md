# OCM FIPS builds of sigstore/cosign

This fork of [sigstore/cosign](https://github.com/sigstore/cosign) publishes
FIPS 140-3 builds of cosign: built with `GOFIPS140=certified` (the CMVP-certified
Go Cryptographic Module of the pinned Go toolchain, `fips140=on` by default) and
`CGO_ENABLED=0`, for `linux/amd64` and `linux/arm64` only. Upstream sources are
never modified.

## Branch model

| Ref | Content |
|---|---|
| `ocm-main` (default) | Automation only: this README, Renovate, the sync job, and `overlay/` |
| tags `vX.Y.Z` | Mirrors of every upstream stable tag (hourly, never overwritten) |
| `ocm/vX.Y.Z` | Maintenance branch = upstream tag `vX.Y.Z` + one overlay commit + dependency updates |
| tags `vX.Y.Z+ocm.N` | Releases cut from `ocm/vX.Y.Z` |

`overlay/` is copied onto every maintenance branch: it replaces upstream's
workflows and Dependabot config with `OCM CI` and `OCM Release`, and adds
`.github/ocm/` (Go version pin, FIPS verification, image Containerfile).
Never edit overlay files on a maintenance branch; change `overlay/` on `ocm-main`
and the `Sync upstream` workflow propagates it to every maintenance branch.

## Automation

- **Sync upstream** (`.github/workflows/sync-upstream.yml`, hourly and on
  `overlay/`/`hack/` changes): mirrors new upstream stable tags, creates
  `ocm/vX.Y.Z` for every tag at or above `v3.1.3`, and refreshes the overlay on
  existing maintenance branches.
- **OCM Release** (on every push to `ocm/v*`): runs `OCM CI`, builds and
  verifies the FIPS binaries, pushes a multi-arch image, and creates the GitHub
  release `vX.Y.Z+ocm.N` with provenance attestations. Release notes are generated
  by git-cliff (`.github/ocm/cliff.toml`) and always list every change since the
  upstream tag `vX.Y.Z` the branch forked from.
- **Renovate** (`.github/renovate.json5`): branch automerge without review, no
  release-age gate, one update branch at a time (security fixes excepted).
  Maintenance branches get non-major Go module updates, direct and indirect, one
  library (source repository) per branch; `ocm-main` gets action, base-image, Go
  toolchain, kind and Sigstore e2e service updates, which reach every maintenance
  branch through Sync upstream.

## Versioning

`vX.Y.Z+ocm.N`: `vX.Y.Z` is the upstream release, `N` increments on every push
to `ocm/vX.Y.Z`. `+ocm.N` is semver build metadata: an OCM build of upstream
`vX.Y.Z`, with the same precedence as `vX.Y.Z`.

## Artifacts

- Release assets: `cosign-linux-amd64`, `cosign-linux-arm64`, `cosign_checksums.txt`
  (same names and format as upstream).
- Image: `ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N` (OCI tags cannot contain
  `+`, so it becomes `-`), moving tags `vX.Y.Z` (newest build of that release) and
  `latest` (highest maintenance branch). Scratch-based: the
  binary, a CA bundle, `/tmp` and `$HOME=/home/nonroot`; runs as `65532:65532`.

Verify a download:

```bash
sha256sum -c --ignore-missing cosign_checksums.txt
gh attestation verify cosign-linux-amd64 --repo open-component-model/cosign
go version -m cosign-linux-amd64 | grep -E 'GOFIPS140=|fips140=on|CGO_ENABLED=0'
```

## Adding a maintenance branch for an older tag

Tags below `v3.1.3` get no branch automatically. To create one for any mirrored
stable tag:

```bash
gh workflow run sync-upstream.yml --repo open-component-model/cosign --ref ocm-main -f tag=v2.6.5
```

## FIPS-only unit test failures

If a unit test fails under `GOFIPS140=certified` but passes with
`GOFIPS140=off` on the same commit, add it to `FIPS_SKIP_TESTS` (a `go test -skip`
regex) in `overlay/.github/ocm/.env`. Never skip e2e failures: they mean the
shipped binary is broken for that feature.
