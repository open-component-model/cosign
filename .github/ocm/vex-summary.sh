#!/usr/bin/env bash
# Renders per-target govulncheck OpenVEX documents (cosign-<os>-<arch>.openvex.json) as
# markdown (job summary, release notes): one row per affected vulnerability, with the
# platforms whose code reaches it.
set -euo pipefail

usage="usage: vex-summary.sh <cosign-<os>-<arch>.openvex.json>..."
if [ "$#" -eq 0 ]; then
  echo "$usage" >&2
  exit 1
fi
for vex in "$@"; do
  if ! [[ "$(basename "$vex")" =~ ^cosign-[a-z0-9]+-[a-z0-9]+\.openvex\.json$ ]]; then
    echo "::error::${vex}: ${usage}" >&2
    exit 1
  fi
  if ! jq -e '."@context" | startswith("https://openvex.dev/ns")' "$vex" >/dev/null 2>&1; then
    echo "::error::${vex} is not an OpenVEX document" >&2
    exit 1
  fi
done

jq -rn '
  def modules: [.[].products[]?.subcomponents[]?."@id"
    | sub("^pkg:golang/"; "") | gsub("%2F"; "/")] | unique | join(", ");
  [inputs | {doc: ., platform: (input_filename
    | capture("cosign-(?<os>[a-z0-9]+)-(?<arch>[a-z0-9]+)\\.openvex\\.json$") | "\(.os)/\(.arch)")}]
  | . as $docs
  | [$docs[] | .platform as $p | .doc.statements[]? | . + {platform: $p}]
  | group_by(.vulnerability.name) as $vulns
  | ($vulns | map(map(select(.status == "affected")) | select(length > 0))) as $affected
  | "### Known vulnerabilities (govulncheck)",
    "",
    "\($affected | length) affected, \(($vulns | length) - ($affected | length)) not affected on any of the \($docs | length) platforms (scanned \($docs[0].doc.timestamp // "at an unknown time")). The OpenVEX reports are attested on the image and the binaries: [verify them](https://github.com/open-component-model/cosign/blob/ocm-main/docs/verification.md#vulnerability-report-openvex).",
    (if ($affected | length) > 0 then
      "",
      "| vulnerability | module | platforms | summary |",
      "| --- | --- | --- | --- |",
      ($affected[] | "| [\(.[0].vulnerability.name)](\(.[0].vulnerability."@id")) | \(modules) | \(map(.platform) | sort | join(", ")) | \(.[0].vulnerability.description // "" | gsub("\\|"; "\\|")) |")
    else empty end)
' "$@"
