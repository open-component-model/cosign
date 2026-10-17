# Verifying OCM cosign builds

Every release `vX.Y.Z+ocm.N` is built by OCM Release on `ocm/vX.Y.Z` and signed through
GitHub artifact attestations (Sigstore, GitHub's OIDC identity of the workflow run).

| Subject | Attestation | Predicate type |
|---|---|---|
| each release binary `cosign-*` | SLSA build provenance | `https://slsa.dev/provenance/v1` |
| image index `ghcr.io/open-component-model/cosign@sha256:…` | SLSA build provenance | `https://slsa.dev/provenance/v1` |
| image index | govulncheck vulnerability report (OpenVEX) | `https://openvex.dev/ns` |

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

## Vulnerability report (OpenVEX)

**What is scanned**: `govulncheck -mode binary -format openvex` on the release's
`cosign-linux-amd64`, in the `build` job of OCM CI, against the
[Go vulnerability database](https://vuln.go.dev) at build time. Every target builds the same
packages, so the report holds for all platforms. The govulncheck version is
`GOVULNCHECK_VERSION` in `overlay/.github/ocm/.env`.

**Where it shows up**:
- the `build` job summary of OCM CI (on every update PR, too) and a warning annotation when
  anything is affected;
- the release notes ("Known vulnerabilities");
- the release asset `govulncheck.openvex.json`;
- the attestation on the image index.

**How to read it**: one OpenVEX statement per vulnerability in a module compiled into the
binary.
- `affected`: govulncheck found vulnerable symbols of that module in the binary.
- `not_affected` (justification `vulnerable_code_not_present`): the module is present, but
  the vulnerable symbols are not.

Each statement names the vulnerability (`GO-YYYY-NNNN`, linked to pkg.go.dev) and the module
version as a `pkg:golang/` purl. govulncheck itself names no product; in the image attestation
every statement's product is the image index, `pkg:oci/cosign@sha256%3A…`, with the modules
as subcomponents (`.github/ocm/vex-image.sh`), so scanners can match the statements to the
image. The release asset is the unmodified govulncheck output.

**Why it never blocks a release**: some findings have no fix on a maintenance branch.
`github.com/sigstore/**` modules are frozen at the upstream tag's versions
([Go module policy](maintenance.md#go-module-policy)), and some upstream dependencies are
unmaintained. Fixable ones disappear through the daily Go module updates. Blocking would only
stop the FIPS builds without changing the code that ships.

**It is a snapshot**: the report reflects the vulnerability database when the release was
built. For a current view of a downloaded binary, re-scan it:

```bash
go run golang.org/x/vuln/cmd/govulncheck@latest -mode binary -format openvex cosign-linux-amd64
```

Verify the attestation and extract the report:

```bash
gh attestation verify oci://ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N \
  --repo open-component-model/cosign \
  --predicate-type https://openvex.dev/ns \
  --format json --jq '.[0].verificationResult.statement.predicate' > vex.json

# affected vulnerabilities and modules
jq -r '.statements[] | select(.status == "affected")
  | "\(.vulnerability.name)\t\([.products[].subcomponents[]."@id"] | join(","))"' vex.json
```

The attested report is standard OpenVEX scoped to the image index, so scanners that accept VEX
apply it to that image. Trivy discovers the attestation itself:

```bash
trivy image --vex oci ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N
# or with the extracted report
trivy image --vex vex.json ghcr.io/open-component-model/cosign:vX.Y.Z-ocm.N
```

Scan the tag or the index digest: the statements and the attestation refer to the image index,
not to the per-platform manifests.

## Images that predate the report

Releases built before the OpenVEX attestation was introduced carry only build provenance.
For those, `gh attestation verify --predicate-type https://openvex.dev/ns` fails with
`HTTP 404`. Use the re-scan command above on their binaries instead.

Releases attested before the report was scoped to the image carry the raw govulncheck product
(`Unknown Product`): scanners find the attestation but apply none of its statements.
