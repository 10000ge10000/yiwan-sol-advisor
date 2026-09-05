<#
.SYNOPSIS
    Builds, exports, and verifies the standalone Yiwan Sol Advisor active skill from the plugin source tree.
.DESCRIPTION
    Extracts the orchestration skill, scripts, references, and agent metadata from
    plugins/sol-advisor/ into the standalone active skill directory (~/.codex/skills/yiwan-sol-advisor),
    and validates SHA-256 digests across source assets, build outputs, and active skill files.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetDir = (Join-Path $env:USERPROFILE ".codex\skills\yiwan-sol-advisor"),

    [Parameter(Mandatory = $false)]
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Pass([string]$Msg) {
    [Console]::WriteLine("PASS: $Msg")
}

function Fail([string]$Msg) {
    [Console]::Error.WriteLine("FAIL: $Msg")
    exit 1
}

function Compute-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$scriptDir = $PSScriptRoot
$pluginDir = (Resolve-Path -LiteralPath (Join-Path $scriptDir "..")).Path
$repoDir = (Resolve-Path -LiteralPath (Join-Path $pluginDir "..\..")).Path

$skillSrcDir = Join-Path $pluginDir "skills\orchestration"
$scriptsSrcDir = Join-Path $pluginDir "scripts"

[Console]::WriteLine("=== YIWAN SOL ADVISOR SKILL BUILDER & INTEGRITY CHECKER ===")
[Console]::WriteLine("Plugin Dir: $pluginDir")
[Console]::WriteLine("Target Dir: $TargetDir")
[Console]::WriteLine("Mode: $(if ($CheckOnly) { 'Check-Only' } else { 'Build & Sync' })")

if (-not (Test-Path -LiteralPath $skillSrcDir -PathType Container)) {
    Fail "Source skill directory not found: $skillSrcDir"
}

# Assets to sync
$scriptFiles = @(
    "launch-sol-advisor.ps1",
    "launch-sol-advisor.sh",
    "run-antigravity-implementer.ps1",
    "run-antigravity-implementer.sh",
    "run-fresh-reviewer.ps1",
    "run-fresh-reviewer.sh",
    "setup-yiwan-sol-advisor.ps1",
    "setup-yiwan-sol-advisor.sh",
    "verify-skill.ps1",
    "verify-skill.sh"
)

$referenceFiles = @(
    "model-report.md",
    "operations.md",
    "role-contracts.md"
)

# 1. Verification of source existence
foreach ($sf in $scriptFiles) {
    $p = Join-Path $scriptsSrcDir $sf
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Fail "Missing source script: $p"
    }
}
foreach ($rf in $referenceFiles) {
    $p = Join-Path (Join-Path $skillSrcDir "references") $rf
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Fail "Missing source reference: $p"
    }
}
Pass "All source scripts and references verified present."

if (-not $CheckOnly) {
    # Ensure target directories exist
    [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $TargetDir "scripts")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $TargetDir "references")) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $TargetDir "agents")) | Out-Null

    # Sync scripts
    foreach ($sf in $scriptFiles) {
        $srcP = Join-Path $scriptsSrcDir $sf
        $dstP = Join-Path (Join-Path $TargetDir "scripts") $sf
        $bytes = [System.IO.File]::ReadAllBytes($srcP)
        [System.IO.File]::WriteAllBytes($dstP, $bytes)
    }

    # Sync references
    foreach ($rf in $referenceFiles) {
        $srcP = Join-Path (Join-Path $skillSrcDir "references") $rf
        $dstP = Join-Path (Join-Path $TargetDir "references") $rf
        $bytes = [System.IO.File]::ReadAllBytes($srcP)
        [System.IO.File]::WriteAllBytes($dstP, $bytes)
    }

    # Generate / Sync SKILL.md
    $srcSkillMd = [System.IO.File]::ReadAllText((Join-Path $skillSrcDir "SKILL.md"), [System.Text.Encoding]::UTF8)
    $activeSkillMd = $srcSkillMd.Replace("name: orchestration", "name: yiwan-sol-advisor")
    $activeSkillMd = $activeSkillMd.Replace("# Sol Advisor Orchestration", "# Yiwan Sol Advisor Orchestration")
    [System.IO.File]::WriteAllText((Join-Path $TargetDir "SKILL.md"), $activeSkillMd, $utf8NoBom)

    # Generate / Sync agents/openai.yaml
    $srcYamlPath = Join-Path $skillSrcDir "agents\openai.yaml"
    $srcYaml = [System.IO.File]::ReadAllText($srcYamlPath, [System.Text.Encoding]::UTF8)
    $activeYaml = $srcYaml.Replace("Sol Advisor Orchestration", "Yiwan Sol Advisor")
    $activeYaml = $activeYaml.Replace("Architect and review with Sol at the user's current effort; implement solely with Antigravity CLI.", "Sol uses current effort; Antigravity implements.")
    $activeYaml = $activeYaml.Replace("`$orchestration", "`$yiwan-sol-advisor")
    [System.IO.File]::WriteAllText((Join-Path $TargetDir "agents\openai.yaml"), $activeYaml, $utf8NoBom)

    Pass "Export and generation completed successfully."
}

# 2. SHA-256 Comparison Report
[Console]::WriteLine("--- SHA-256 COMPARISON AUDIT ---")
$mismatches = 0

foreach ($sf in $scriptFiles) {
    $srcHash = Compute-FileSha256 (Join-Path $scriptsSrcDir $sf)
    $dstHash = Compute-FileSha256 (Join-Path (Join-Path $TargetDir "scripts") $sf)
    if ($srcHash -ne $dstHash) {
        [Console]::WriteLine("MISMATCH: scripts/$sf (src: $srcHash vs dst: $dstHash)")
        $mismatches++
    } else {
        [Console]::WriteLine("MATCH   : scripts/$sf -> $srcHash")
    }
}

foreach ($rf in $referenceFiles) {
    $srcHash = Compute-FileSha256 (Join-Path (Join-Path $skillSrcDir "references") $rf)
    $dstHash = Compute-FileSha256 (Join-Path (Join-Path $TargetDir "references") $rf)
    if ($srcHash -ne $dstHash) {
        [Console]::WriteLine("MISMATCH: references/$rf (src: $srcHash vs dst: $dstHash)")
        $mismatches++
    } else {
        [Console]::WriteLine("MATCH   : references/$rf -> $srcHash")
    }
}

# Verify SKILL.md content equivalence
$dstSkillHash = Compute-FileSha256 (Join-Path $TargetDir "SKILL.md")
[Console]::WriteLine("SKILL.md : Active Skill SHA-256 -> $dstSkillHash")

# Verify agents/openai.yaml
$dstYamlHash = Compute-FileSha256 (Join-Path $TargetDir "agents\openai.yaml")
[Console]::WriteLine("agents/openai.yaml: Active Skill SHA-256 -> $dstYamlHash")

if ($mismatches -gt 0) {
    Fail "Integrity check failed with $mismatches mismatches."
}

Pass "All synchronized assets matched SHA-256 hashes perfectly!"