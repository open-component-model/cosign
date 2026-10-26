# OCM FIPS builds of sigstore/cosign

[![Renovate](https://github.com/open-component-model/cosign/actions/workflows/renovate.yml/badge.svg)](https://github.com/open-component-model/cosign/actions/workflows/renovate.yml)
[![Sync upstream](https://github.com/open-component-model/cosign/actions/workflows/sync-upstream.yml/badge.svg)](https://github.com/open-component-model/cosign/actions/workflows/sync-upstream.yml)
[![Release schedule](https://github.com/open-component-model/cosign/actions/workflows/release-schedule.yml/badge.svg)](https://github.com/open-component-model/cosign/actions/workflows/release-schedule.yml)
[![Control CI](https://github.com/open-component-model/cosign/actions/workflows/control-ci.yml/badge.svg)](https://github.com/open-component-model/cosign/actions/workflows/control-ci.yml)
[![Security PRs](https://img.shields.io/github/issues-pr/open-component-model/cosign/security?label=open%20security%20PRs)](https://github.com/open-component-model/cosign/pulls?q=is%3Apr+is%3Aopen+label%3Asecurity)

This fork of [sigstore/cosign](https://github.com/sigstore/cosign) publishes
FIPS 140-3 builds of cosign: built with `GOFIPS140=certified` (the CMVP-certified
Go Cryptographic Module of the pinned Go toolchain, `fips140=on` by default) and
`CGO_ENABLED=0`. Only the highest maintenance branch is maintained, and only with Go module
security fixes and Go toolchain updates; upstream sources are modified only for security fixes
upstream has not released yet ([security patches](docs/maintenance.md#security-patches)).

## Branch model

| Ref | Content |
|---|---|
| `main` (default) | Automation only: this README, `docs/`, `hack/`, workflows and `overlay/` |
| tags `vX.Y.Z` | Mirrors of every upstream stable tag (hourly, never overwritten) |
| `ocm/vX.Y.Z` | Maintenance branch = upstream tag `vX.Y.Z` + overlay commits + security updates. Only the highest one is maintained; older ones are frozen |
| `renovate/…` | Short-lived Renovate update branch, fast-forwarded once CI passes; a PR only when CI fails |
| tags `vX.Y.Z+ocm.N` | Releases cut from `ocm/vX.Y.Z` |

`overlay/` is copied onto every new maintenance branch and kept current on the highest one: it
replaces upstream's workflows and Dependabot config with `OCM CI` and `OCM Release`, and adds
`.github/ocm/` (version pins, FIPS verification, image Containerfile). Never edit overlay files
on a maintenance branch; change `overlay/` on `main` and Sync upstream propagates it.

## Automation

- **Sync upstream** (hourly) mirrors upstream tags, creates `ocm/vX.Y.Z` for every tag at or
  above `v3.1.3`, and refreshes the overlay on the highest maintenance branch.
- **Renovate** (02:00 and 14:00 UTC) opens Go module security updates (OSV and GitHub
  vulnerability alerts) on the highest maintenance branch and Go toolchain updates on `main`.
  It fast-forwards each update once CI passes; failing updates become PRs (security ones
  labelled `security`).
- **Release schedule** (daily 06:00 UTC) runs **OCM Release** on the highest maintenance branch
  if its tree changed since its last release: tests, FIPS binaries, multi-arch image, GitHub
  release `vX.Y.Z+ocm.N` with provenance and a govulncheck OpenVEX report.

Details, update policy and runbooks: [docs/maintenance.md](docs/maintenance.md).

## Versioning

`vX.Y.Z+ocm.N`: `vX.Y.Z` is the upstream release, `N` increments on every release
of `ocm/vX.Y.Z`. `+ocm.N` is semver build metadata: an OCM build of upstream
`vX.Y.Z`, with the same precedence as `vX.Y.Z`.

## Artifacts

- Release assets: `cosign-linux-{amd64,arm64,arm,ppc64le,s390x,riscv64}`,
  `cosign-darwin-{amd64,arm64}`, `cosign-windows-amd64.exe`, `cosign_checksums.txt`
  (same names and format as upstream, without the CGO `pivkey-pkcs11key` variants),
  all cross-compiled with `CGO_ENABLED=0`, plus per binary a CycloneDX SBOM
  (`cosign-<os>-<arch>.cdx.json`) and a govulncheck OpenVEX report
  (`cosign-<os>-<arch>.openvex.json`), and the merged `govulncheck.openvex.json`.
- Image: `ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N` (OCI tags cannot contain
  `+`, so it becomes `-`), moving tags `vX.Y.Z` (newest build of that release) and
  `latest` (highest maintenance branch), for `linux/amd64`, `linux/arm64`,
  `linux/arm/v7`, `linux/ppc64le`, `linux/s390x` and `linux/riscv64` (as upstream).
  Scratch-based: the binary, a CA bundle, `/tmp` and `$HOME=/home/nonroot`; runs as
  `65532:65532`. Attested: SLSA build provenance and the merged govulncheck OpenVEX report
  on the index; provenance, SBOM and the platform's OpenVEX report on each platform
  manifest. Each binary carries its provenance, SBOM and OpenVEX report.
- Release notes list every change since the upstream tag and the known vulnerabilities
  govulncheck found reachable in the shipped code.

Verify a download:

```bash
sha256sum -c --ignore-missing cosign_checksums.txt
gh attestation verify cosign-linux-amd64 --repo open-component-model/cosign
go version -m cosign-linux-amd64 | grep -E 'GOFIPS140=|fips140=on|CGO_ENABLED=0'
```

Image provenance, the vulnerability report and how to read it:
[docs/verification.md](docs/verification.md).
