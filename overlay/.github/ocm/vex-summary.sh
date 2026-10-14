#!/usr/bin/env bash
# Renders a govulncheck OpenVEX document as markdown (job summary, release notes).
set -euo pipefail

vex="${1:?usage: vex-summary.sh <govulncheck.openvex.json>}"
if ! jq -e '."@context" | startswith("https://openvex.dev/ns")' "$vex" >/dev/null 2>&1; then
  echo "::error::${vex} is not an OpenVEX document" >&2
  exit 1
fi

jq -r '
  def modules: [.products[]?.subcomponents[]?."@id"
    | sub("^pkg:golang/"; "") | gsub("%2F"; "/")] | unique | join(", ");
  (.statements // []) as $s
  | ($s | map(select(.status == "affected"))) as $affected
  | "### Known vulnerabilities (govulncheck)",
    "",
    "\($affected | length) affected, \($s | map(select(.status == "not_affected")) | length) present but not reachable (scanned \(.timestamp // "at an unknown time")). The OpenVEX report is attested on the image: [verify it](https://github.com/open-component-model/cosign/blob/ocm-main/docs/verification.md#vulnerability-report-openvex).",
    (if ($affected | length) > 0 then
      "",
      "| vulnerability | module | summary |",
      "| --- | --- | --- |",
      ($affected[] | "| [\(.vulnerability.name)](\(.vulnerability."@id")) | \(modules) | \(.vulnerability.description // "" | gsub("\\|"; "\\|")) |")
    else empty end)
' "$vex"
