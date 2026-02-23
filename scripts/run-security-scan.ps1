# Security Scan Runner - one repo per execution (for n8n loop integration)
# Reads input from: env SECURITY_SCAN_REPO_PATH, workflow/input.json, or first argument.
# Writes: reports/security_scan_<repoName>_<date>.md and workflow/output.json for n8n.

param(
    [Parameter(Position = 0)]
    [string] $RepoPath,
    [string] $RepoName,
    [switch] $ScanContainers = $true,
    [string] $SecurityScanRoot = $PSScriptRoot + "\.."
)

$ErrorActionPreference = "Stop"
$SecurityScanRoot = (Resolve-Path $SecurityScanRoot).Path
$WorkflowDir = Join-Path $SecurityScanRoot "workflow"
$ReportsDir = Join-Path $SecurityScanRoot "reports"
$ScriptsDir = Join-Path $SecurityScanRoot "scripts"

# --- Resolve input (n8n loop item) ---
if (-not $RepoPath -and $env:SECURITY_SCAN_REPO_PATH) {
    $RepoPath = $env:SECURITY_SCAN_REPO_PATH
}
if (-not $RepoPath) {
    $inputFile = Join-Path $WorkflowDir "input.json"
    if (Test-Path $inputFile) {
        $input = Get-Content $inputFile -Raw | ConvertFrom-Json
        $RepoPath = $input.repoPath
        if (-not $RepoName -and $input.repoName) { $RepoName = $input.repoName }
        if ($null -ne $input.scanContainers) { $ScanContainers = [bool]$input.scanContainers }
    }
}
if (-not $RepoPath) {
    Write-Error "Repo path required. Set SECURITY_SCAN_REPO_PATH, pass -RepoPath, or set workflow/input.json repoPath."
    exit 1
}

$RepoPath = $RepoPath.Trim()
if (-not (Test-Path $RepoPath -PathType Container)) {
    Write-Error "Repo path does not exist or is not a directory: $RepoPath"
    exit 1
}
$RepoPath = (Resolve-Path $RepoPath).Path
if (-not $RepoName) { $RepoName = [System.IO.Path]::GetFileName($RepoPath) }

$Date = Get-Date -Format "yyyy-MM-dd"
$ReportName = "security_scan_${RepoName}_${Date}.md"
$ReportPath = Join-Path $ReportsDir $ReportName
$GrypeConfig = Join-Path $ScriptsDir "grype-config.yaml"

# Ensure output dirs
if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null }
if (-not (Test-Path $WorkflowDir)) { New-Item -ItemType Directory -Path $WorkflowDir -Force | Out-Null }

# --- Discovery ---
$Manifests = @()
$ContainerFiles = @()
$Images = @()

if (Test-Path (Join-Path $RepoPath "package.json")) { $Manifests += "node" }
if (Test-Path (Join-Path $RepoPath "go.mod")) { $Manifests += "go" }
if (Test-Path (Join-Path $RepoPath "requirements.txt")) { $Manifests += "python" }
if (Test-Path (Join-Path $RepoPath "Pipfile")) { $Manifests += "python" }
if (Test-Path (Join-Path $RepoPath "pyproject.toml")) { $Manifests += "python" }
if (Test-Path (Join-Path $RepoPath "pom.xml")) { $Manifests += "maven" }
if (Test-Path (Join-Path $RepoPath "Cargo.toml")) { $Manifests += "rust" }

Get-ChildItem -Path $RepoPath -Recurse -Include "Dockerfile","docker-compose*.yml","*.yaml","*.yml" -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($RepoPath.Length).TrimStart("\")
    if ($rel -match "Dockerfile|docker-compose|k8s|helm|charts|deploy|Chart\.yaml|values\.yaml") {
        $ContainerFiles += $rel
    }
}

# --- Build report and run scans ---
$CommandsRun = @()
$Findings = [System.Collections.ArrayList]::new()
$CriticalHigh = 0

$Sb = [System.Text.StringBuilder]::new()
[void]$Sb.AppendLine("# Security Scan Report: $RepoName")
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("**Date:** $Date")
[void]$Sb.AppendLine("**Repository:** $RepoPath")
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("## 1) Discovered stack")
[void]$Sb.AppendLine("- **Manifests:** " + ($Manifests -join ", "))
[void]$Sb.AppendLine("- **Container-related files:** " + ($ContainerFiles -join ", "))
[void]$Sb.AppendLine("")

# Node
if ($Manifests -contains "node") {
    $pkgPath = Join-Path $RepoPath "package.json"
    try {
        Push-Location $RepoPath
        $auditOut = & npm audit --json 2>&1
        $CommandsRun += "npm audit --json"
        $auditObj = $auditOut | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($auditObj.vulnerabilities) {
            foreach ($p in $auditObj.vulnerabilities.PSObject.Properties) {
                $v = $p.Value
                $sev = $v.severity
                if ($sev -eq "critical" -or $sev -eq "high") { $CriticalHigh++ }
                [void]$Findings.Add([PSCustomObject]@{
                    Finding = $v.id
                    Severity = $sev
                    Location = "package.json"
                    Affected = $p.Name
                    Fix = ($v.fixAvailable -eq $true ? "npm update $($p.Name)" : "Review manually")
                })
            }
        }
        [void]$Sb.AppendLine("### npm audit")
        [void]$Sb.AppendLine("```")
        [void]$Sb.AppendLine(($auditOut | Out-String))
        [void]$Sb.AppendLine("```")
        [void]$Sb.AppendLine("")
    } catch {
        [void]$Sb.AppendLine("### npm audit")
        [void]$Sb.AppendLine("Error: $_")
        [void]$Sb.AppendLine("")
    } finally {
        Pop-Location
    }
}

# Grype (filesystem / SBOM)
$grypeExe = Get-Command grype -ErrorAction SilentlyContinue
if ($grypeExe -and (Test-Path $GrypeConfig)) {
    try {
        $grypeOut = & grype --config $GrypeConfig $RepoPath -o json 2>&1
        $CommandsRun += "grype --config scripts/grype-config.yaml <repo> -o json"
        $grypeObj = $grypeOut | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($grypeObj.matches) {
            foreach ($m in $grypeObj.matches) {
                $sev = $m.vulnerability.severity
                if ($sev -eq "Critical" -or $sev -eq "High") { $CriticalHigh++ }
                [void]$Findings.Add([PSCustomObject]@{
                    Finding = $m.vulnerability.id
                    Severity = $sev
                    Location = "filesystem / SBOM"
                    Affected = $m.artifact.name
                    Fix = $m.vulnerability.fix.versions -join ", "
                })
            }
        }
        [void]$Sb.AppendLine("### Grype (filesystem)")
        [void]$Sb.AppendLine("```")
        [void]$Sb.AppendLine(($grypeOut | Out-String))
        [void]$Sb.AppendLine("```")
        [void]$Sb.AppendLine("")
    } catch {
        [void]$Sb.AppendLine("### Grype")
        [void]$Sb.AppendLine("Error: $_")
        [void]$Sb.AppendLine("")
    }
} else {
    [void]$Sb.AppendLine("Grype not run (grype not in PATH or config missing).")
    [void]$Sb.AppendLine("")
}

# Summary table
[void]$Sb.AppendLine("## 2) Summary table")
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("| Finding | Severity | Location | Affected Package/Image | Fix Suggestion |")
[void]$Sb.AppendLine("|---------|----------|----------|-------------------------|----------------|")
foreach ($f in $Findings) {
    [void]$Sb.AppendLine("| $($f.Finding) | $($f.Severity) | $($f.Location) | $($f.Affected) | $($f.Fix) |")
}
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("## 3) Prioritized fixes (top critical/high)")
$top = $Findings | Where-Object { $_.Severity -match "critical|Critical|high|High" } | Select-Object -First 5
foreach ($f in $top) {
    [void]$Sb.AppendLine("- **$($f.Severity)** $($f.Finding) in $($f.Affected): $($f.Fix)")
}
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("## 4) Commands run")
foreach ($c in $CommandsRun) {
    [void]$Sb.AppendLine("- $c")
}
[void]$Sb.AppendLine("")
[void]$Sb.AppendLine("## 5) Next steps")
[void]$Sb.AppendLine("- Review high/critical findings and apply fixes or accept risk.")
[void]$Sb.AppendLine("- Re-run this workflow after dependency or image updates.")

Set-Content -Path $ReportPath -Value $Sb.ToString() -Encoding UTF8

# --- Workflow output for n8n ---
$output = @{
    repoPath   = $RepoPath
    repoName   = $RepoName
    reportPath = $ReportPath
    reportName = $ReportName
    date       = $Date
    totalFindings = $Findings.Count
    criticalHigh  = $CriticalHigh
    commandsRun   = $CommandsRun
}
$outputPath = Join-Path $WorkflowDir "output.json"
$output | ConvertTo-Json -Depth 5 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host "Report: $ReportPath"
Write-Host "Findings: $($Findings.Count) (critical+high: $CriticalHigh)"
Write-Host "Output: $outputPath"
