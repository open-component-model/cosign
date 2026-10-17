# Verifying OCM cosign builds

Every release `vX.Y.Z+ocm.N` is built by OCM Release on `ocm/vX.Y.Z` and signed through
GitHub artifact attestations (Sigstore, GitHub's OIDC identity of the workflow run).

| Subject | Attestation | Predicate type |
|---|---|---|
| each release binary `cosign-*` | SLSA build provenance | `https://slsa.dev/provenance/v1` |
| each release binary `cosign-*` | SBOM of its platform (CycloneDX) | `https://cyclonedx.org/bom` |
| each release binary `cosign-*` | govulncheck report of its platform (OpenVEX) | `https://openvex.dev/ns` |
| image index `ghcr.io/open-component-model/cosign@sha256:…` | SLSA build provenance | `https://slsa.dev/provenance/v1` |
| image index | govulncheck report of all platforms, merged (OpenVEX) | `https://openvex.dev/ns` |
| each platform manifest of the image | SLSA build provenance | `https://slsa.dev/provenance/v1` |
| each platform manifest of the image | SBOM of its platform (CycloneDX) | `https://cyclonedx.org/bom` |
| each platform manifest of the image | govulncheck report of its platform (OpenVEX) | `https://openvex.dev/ns` |

Image attestations are also pushed to the registry next to the image.

## Release assets

```bash
gh release download vX.Y.Z+ocm.N --repo open-component-model/cosign -p 'cosign-linux-amd64' -p cosign_checksums.txt
sha256sum -c --ignore-missing cosign_checksums.txt
gh attestation verify cosign-linux-amd64 --repo open-component-model/cosign
```

## FIPS build settings

```bash
go version -m cosign-linux-amd64 | grep -E 'GOFIPS140=|fips140=on|CGO_ENABLED=0'
```

All three must appear. `GOFIPS140=certified` selects the CMVP-certified Go Cryptographic
Module of the pinned toolchain (named in the release notes), and `fips140=on` makes it the
default at run time.

## Image provenance

```bash
gh attestation verify oci://ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N \
  --repo open-component-model/cosign
```

The tag resolves to the image index. A platform's manifest carries its own provenance; verify
it by digest (`docker buildx imagetools inspect ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N`
lists them): `gh attestation verify oci://ghcr.io/open-component-model/cosign@sha256:… --repo open-component-model/cosign`.

## SBOM (CycloneDX)

**What it lists**: the Go modules and standard library compiled into one target, generated
from source by [cyclonedx-gomod](https://github.com/CycloneDX/cyclonedx-gomod) (`app -std
-licenses`, version `CYCLONEDX_GOMOD_VERSION` in `overlay/.github/ocm/.env`) with the build
settings of that binary, in the `build` job of OCM CI. The main component is
`pkg:golang/github.com/sigstore/cosign/vN@vX.Y.Z%2Bocm.N` with `goos`/`goarch` qualifiers.
The image adds no packages: besides the binary it holds only a CA bundle, `/tmp` and
`$HOME`, so a platform's SBOM is its binary's SBOM.

**Where it shows up**: release assets `cosign-<os>-<arch>.cdx.json` and attestations on each
release binary and each image platform manifest (not on the index: one SBOM per platform).

```bash
gh attestation verify cosign-linux-amd64 --repo open-component-model/cosign \
  --predicate-type https://cyclonedx.org/bom \
  --format json --jq '.[0].verificationResult.statement.predicate' > sbom.cdx.json
```

## Vulnerability report (OpenVEX)

**What is scanned**: `govulncheck -format openvex ./cmd/cosign` (source mode), once per release
target (`GOOS`/`GOARCH`, `linux/arm` as `GOARM=7`) with the build settings of the binaries
(`CGO_ENABLED=0`, `GOFIPS140`), in the `build` job of OCM CI, against the
[Go vulnerability database](https://vuln.go.dev) at build time. Reachability depends on the
platform, so each target has its own report, `cosign-<os>-<arch>.openvex.json`. The image
index report merges them (`.github/ocm/vex-merge.sh`): `affected` if any platform reaches
the vulnerability. The govulncheck version is `GOVULNCHECK_VERSION` in
`overlay/.github/ocm/.env`.

**Where it shows up**:
- the `build` job summary of OCM CI (on every update PR, too) and a warning annotation when
  anything is affected;
- the release notes ("Known vulnerabilities", with the affected platforms);
- the release assets `cosign-<os>-<arch>.openvex.json` (per binary) and
  `govulncheck.openvex.json` (merged);
- attestations on each release binary, each image platform manifest and the image index.

**How to read it**: one OpenVEX statement per vulnerability in a module that cosign depends on.
- `affected`: cosign's call graph reaches a vulnerable symbol (in the merged report: on at
  least one platform).
- `not_affected`: it does not. Justification `vulnerable_code_not_present`: no vulnerable
  package is used; `vulnerable_code_not_in_execute_path`: a vulnerable package is used, but
  no call path reaches its vulnerable symbols. The call graph does not follow reflection,
  `unsafe` or `go:linkname`.

Each statement names the vulnerability (`GO-YYYY-NNNN`, linked to pkg.go.dev) and the module
version as a `pkg:golang/` purl. govulncheck itself names no product; every published report
is scoped (`.github/ocm/vex-scope.sh`) so scanners can match its statements:
- per-binary reports (release assets, binary attestations): product
  `pkg:golang/github.com/sigstore/cosign/vN` with the binary's SHA-256 as product hash;
- merged release asset `govulncheck.openvex.json`: the same product without a hash;
- image attestations: product `pkg:oci/cosign@sha256%3A…`, the attested index or platform
  manifest digest.

The affected modules are the subcomponents.

**Why it never blocks a release**: some findings have no fix on a maintenance branch.
`github.com/sigstore/**` modules are frozen at the upstream tag's versions
([Go module policy](maintenance.md#go-module-policy)), and some upstream dependencies are
unmaintained. Fixable ones disappear through the daily Go module updates. Blocking would only
stop the FIPS builds without changing the code that ships.

**It is a snapshot**: the report reflects the vulnerability database when the release was
built. For a current view, re-scan the release's source with the settings of a target:

```bash
git checkout vX.Y.Z+ocm.N
CGO_ENABLED=0 GOFIPS140=certified GOOS=linux GOARCH=amd64 \
  go run golang.org/x/vuln/cmd/govulncheck@latest -format openvex ./cmd/cosign
```

Verify the attestation and extract the report (image index; for a binary, verify the file,
e.g. `gh attestation verify cosign-linux-amd64 …`, with the same flags):

```bash
gh attestation verify oci://ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N \
  --repo open-component-model/cosign \
  --predicate-type https://openvex.dev/ns \
  --format json --jq '.[0].verificationResult.statement.predicate' > vex.json

# affected vulnerabilities and modules
jq -r '.statements[] | select(.status == "affected")
  | "\(.vulnerability.name)\t\([.products[].subcomponents[]."@id"] | join(","))"' vex.json
```

The attested reports are standard OpenVEX scoped to the attested digest, so scanners that
accept VEX apply them to that image. Trivy discovers the attestation itself:

```bash
trivy image --vex oci ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N
# or with the extracted report
trivy image --vex vex.json ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N
```

Trivy only finds attestations on the reference it scans: the tag or index digest uses the
merged report, a platform manifest digest (`docker buildx imagetools inspect`) uses that
platform's report.

## Images that predate the report

Releases built before the OpenVEX attestation was introduced carry only build provenance.
For those, `gh attestation verify --predicate-type https://openvex.dev/ns` fails with
`HTTP 404`; the same holds for binaries and platform manifests of releases built before the
per-platform reports. Use the re-scan command above instead.

Releases attested before the report was scoped to the image carry the raw govulncheck product
(`Unknown Product`): scanners find the attestation but apply none of its statements.
