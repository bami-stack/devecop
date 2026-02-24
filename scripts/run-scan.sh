#!/usr/bin/env bash
# Security Scan Runner - one repo per execution (for n8n loop integration)
# Reads input from: env SECURITY_SCAN_REPO_PATH, workflow/input.json, or --repo-path argument.
# Writes: reports/security_scan_<repoName>_<date>.md and workflow/output.json for n8n.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SCAN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="$SECURITY_SCAN_ROOT/workflow"
REPORTS_DIR="$SECURITY_SCAN_ROOT/reports"
SCRIPTS_DIR="$SECURITY_SCAN_ROOT/scripts"

REPO_PATH=""
REPO_NAME=""
SCAN_CONTAINERS=true

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path)   REPO_PATH="$2";   shift 2 ;;
    --repo-name)   REPO_NAME="$2";   shift 2 ;;
    --no-containers) SCAN_CONTAINERS=false; shift ;;
    *) REPO_PATH="$1"; shift ;;
  esac
done

# --- Resolve input ---
if [[ -z "$REPO_PATH" && -n "${SECURITY_SCAN_REPO_PATH:-}" ]]; then
  REPO_PATH="$SECURITY_SCAN_REPO_PATH"
fi

if [[ -z "$REPO_PATH" ]]; then
  INPUT_FILE="$WORKFLOW_DIR/input.json"
  if [[ -f "$INPUT_FILE" ]]; then
    REPO_PATH=$(jq -r '.repoPath // empty' "$INPUT_FILE")
    [[ -z "$REPO_NAME" ]] && REPO_NAME=$(jq -r '.repoName // empty' "$INPUT_FILE")
    SCAN_CONTAINERS=$(jq -r '.scanContainers // true' "$INPUT_FILE")
  fi
fi

if [[ -z "$REPO_PATH" ]]; then
  echo "ERROR: Repo path required. Set SECURITY_SCAN_REPO_PATH, pass --repo-path, or set workflow/input.json repoPath." >&2
  exit 1
fi

REPO_PATH="${REPO_PATH%/}"
if [[ ! -d "$REPO_PATH" ]]; then
  echo "ERROR: Repo path does not exist or is not a directory: $REPO_PATH" >&2
  exit 1
fi

REPO_PATH="$(realpath "$REPO_PATH")"
[[ -z "$REPO_NAME" ]] && REPO_NAME="$(basename "$REPO_PATH")"

DATE="$(date +%Y-%m-%d)"
REPORT_NAME="security_scan_${REPO_NAME//\//_}_${DATE}.md"
REPORT_PATH="$REPORTS_DIR/$REPORT_NAME"
GRYPE_CONFIG="$SCRIPTS_DIR/grype-config.yaml"

mkdir -p "$REPORTS_DIR" "$WORKFLOW_DIR"

# --- Discovery ---
MANIFESTS=()
CONTAINER_FILES=()

[[ -f "$REPO_PATH/package.json"    ]] && MANIFESTS+=(node)
[[ -f "$REPO_PATH/go.mod"          ]] && MANIFESTS+=(go)
[[ -f "$REPO_PATH/requirements.txt"]] && MANIFESTS+=(python)
[[ -f "$REPO_PATH/Pipfile"         ]] && MANIFESTS+=(python)
[[ -f "$REPO_PATH/pyproject.toml"  ]] && MANIFESTS+=(python)
[[ -f "$REPO_PATH/pom.xml"         ]] && MANIFESTS+=(maven)
[[ -f "$REPO_PATH/Cargo.toml"      ]] && MANIFESTS+=(rust)

while IFS= read -r -d '' file; do
  rel="${file#$REPO_PATH/}"
  if echo "$rel" | grep -qE 'Dockerfile|docker-compose|k8s|helm|charts|deploy|Chart\.yaml|values\.yaml'; then
    CONTAINER_FILES+=("$rel")
  fi
done < <(find "$REPO_PATH" -type f \( -name "Dockerfile" -o -name "docker-compose*.yml" -o -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)

# --- Report helpers ---
COMMANDS_RUN=()
FINDINGS_JSON="[]"
CRITICAL_HIGH=0

append_finding() {
  local finding="$1" severity="$2" location="$3" affected="$4" fix="$5"
  FINDINGS_JSON=$(echo "$FINDINGS_JSON" | jq \
    --arg f "$finding" --arg s "$severity" --arg l "$location" \
    --arg a "$affected" --arg x "$fix" \
    '. + [{finding: $f, severity: $s, location: $l, affected: $a, fix: $x}]')
  if echo "$severity" | grep -qi "critical\|high"; then
    (( CRITICAL_HIGH++ )) || true
  fi
}

# --- Start report ---
{
cat <<EOF
# Security Scan Report: $REPO_NAME

**Date:** $DATE
**Repository:** $REPO_PATH

## 1) Discovered stack
- **Manifests:** ${MANIFESTS[*]:-none}
- **Container-related files:** ${CONTAINER_FILES[*]:-none}

EOF
} > "$REPORT_PATH"

# --- npm audit ---
if [[ " ${MANIFESTS[*]} " == *" node "* ]]; then
  {
    echo "### npm audit"
    echo '```'
  } >> "$REPORT_PATH"

  pushd "$REPO_PATH" > /dev/null
  AUDIT_OUT=$(npm audit --json 2>&1 || true)
  COMMANDS_RUN+=("npm audit --json")

  echo "$AUDIT_OUT" >> "$REPORT_PATH"
  echo '```' >> "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"

  # Parse vulnerabilities
  if echo "$AUDIT_OUT" | jq -e '.vulnerabilities' > /dev/null 2>&1; then
    while IFS= read -r pkg; do
      sev=$(echo "$AUDIT_OUT" | jq -r --arg p "$pkg" '.vulnerabilities[$p].severity')
      vid=$(echo "$AUDIT_OUT" | jq -r --arg p "$pkg" '.vulnerabilities[$p].via[0].source // .vulnerabilities[$p].via[0] // "unknown"')
      fix_available=$(echo "$AUDIT_OUT" | jq -r --arg p "$pkg" '.vulnerabilities[$p].fixAvailable')
      fix="Review manually"
      [[ "$fix_available" == "true" ]] && fix="npm update $pkg"
      append_finding "$vid" "$sev" "package.json" "$pkg" "$fix"
    done < <(echo "$AUDIT_OUT" | jq -r '.vulnerabilities | keys[]')
  fi
  popd > /dev/null
fi

# --- Grype ---
if command -v grype > /dev/null 2>&1 && [[ -f "$GRYPE_CONFIG" ]]; then
  {
    echo "### Grype (filesystem)"
    echo '```'
  } >> "$REPORT_PATH"

  GRYPE_OUT=$(grype --config "$GRYPE_CONFIG" "$REPO_PATH" -o json 2>&1 || true)
  COMMANDS_RUN+=("grype --config scripts/grype-config.yaml <repo> -o json")

  echo "$GRYPE_OUT" >> "$REPORT_PATH"
  echo '```' >> "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"

  if echo "$GRYPE_OUT" | jq -e '.matches' > /dev/null 2>&1; then
    while IFS=$'\t' read -r vid sev name fix_versions; do
      append_finding "$vid" "$sev" "filesystem / SBOM" "$name" "$fix_versions"
    done < <(echo "$GRYPE_OUT" | jq -r '.matches[] | [.vulnerability.id, .vulnerability.severity, .artifact.name, (.vulnerability.fix.versions | join(","))] | @tsv')
  fi
else
  echo "Grype not run (grype not in PATH or config missing)." >> "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"
fi

# --- Summary table ---
{
echo "## 2) Summary table"
echo ""
echo "| Finding | Severity | Location | Affected Package/Image | Fix Suggestion |"
echo "|---------|----------|----------|------------------------|----------------|"
echo "$FINDINGS_JSON" | jq -r '.[] | "| \(.finding) | \(.severity) | \(.location) | \(.affected) | \(.fix) |"'
echo ""

echo "## 3) Prioritized fixes (top critical/high)"
echo "$FINDINGS_JSON" | jq -r '.[] | select(.severity | test("critical|high"; "i")) | "- **\(.severity)** \(.finding) in \(.affected): \(.fix)"' | head -5
echo ""

echo "## 4) Commands run"
for cmd in "${COMMANDS_RUN[@]}"; do echo "- $cmd"; done
echo ""

echo "## 5) Next steps"
echo "- Review high/critical findings and apply fixes or accept risk."
echo "- Re-run this workflow after dependency or image updates."
} >> "$REPORT_PATH"

# --- Workflow output for n8n ---
COMMANDS_JSON=$(printf '%s\n' "${COMMANDS_RUN[@]}" | jq -R . | jq -s .)
TOTAL_FINDINGS=$(echo "$FINDINGS_JSON" | jq 'length')

jq -n \
  --arg repoPath "$REPO_PATH" \
  --arg repoName "$REPO_NAME" \
  --arg reportPath "$REPORT_PATH" \
  --arg reportName "$REPORT_NAME" \
  --arg date "$DATE" \
  --argjson totalFindings "$TOTAL_FINDINGS" \
  --argjson criticalHigh "$CRITICAL_HIGH" \
  --argjson commandsRun "$COMMANDS_JSON" \
  '{repoPath: $repoPath, repoName: $repoName, reportPath: $reportPath, reportName: $reportName,
    date: $date, totalFindings: $totalFindings, criticalHigh: $criticalHigh, commandsRun: $commandsRun}' \
  > "$WORKFLOW_DIR/output.json"

echo "Report:   $REPORT_PATH"
echo "Findings: $TOTAL_FINDINGS (critical+high: $CRITICAL_HIGH)"
echo "Output:   $WORKFLOW_DIR/output.json"