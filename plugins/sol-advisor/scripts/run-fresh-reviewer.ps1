<#
.SYNOPSIS
    Deterministic fresh-review mechanism for yiwan-sol-advisor on Windows PowerShell 7.
.DESCRIPTION
    Starts a separate ephemeral read-only gpt-5.6-sol Codex process using the user's configured reasoning effort,
    supplies staged diff (git diff --cached --binary) and unstaged diff (git diff --binary) separately,
    untracked file contents (with streaming SHA-256 and binary detection), implementer evidence,
    and parent verification evidence within fail-closed presentation limits.
    Validates that the reviewed repository remains unmodified via comprehensive content fingerprinting,
    enforces mandatory closed-set 9 cryptographic evidence bindings (SHA-256), strictly validates schemas,
    and returns only SHIP, FIX-FIRST, or RETHINK in a structured JSON envelope.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$GoalFile,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceFile,

    [Parameter(Mandatory = $true)]
    [string]$ParentVerificationFile,

    [Parameter(Mandatory = $true)]
    [string]$ReviewOutputFile,

    [Parameter(Mandatory = $false)]
    [string]$Timeout = "15m",

    [Parameter(Mandatory = $false)]
    [switch]$TestMode,

    [Parameter(Mandatory = $false)]
    [string]$TestCodexBin = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    [Parameter(Mandatory = $false)]
    [string]$ReasoningEffort = ""
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine("ERROR: PowerShell 7+ (pwsh) is required; detected PowerShell version $($PSVersionTable.PSVersion)")
    exit 1
}

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Msg) {
    [Console]::Error.WriteLine("ERROR: $Msg")
    exit 1
}

function Get-CurrentCodexConfig {
    $result = @{
        Model = $null
        ReasoningEffort = $null
    }
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE ".codex" } else { $env:CODEX_HOME }
    $configPath = Join-Path $codexHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $result }
    try {
        $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.UTF8Encoding]::new($false, $true))
        $matchModel = [regex]::Match($configText, '(?m)^\s*model\s*=\s*"([^"]+)"')
        if ($matchModel.Success) {
            $result.Model = $matchModel.Groups[1].Value.Trim()
        }
        $matchEffort = [regex]::Match($configText, '(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"')
        if ($matchEffort.Success) {
            $result.ReasoningEffort = $matchEffort.Groups[1].Value.Trim()
        }
    } catch {
        # ignore read errors, return whatever was found
    }
    return $result
}

$inheritedCodexConfig = Get-CurrentCodexConfig
$effectiveModel = if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $Model.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($env:SOL_ADVISOR_MODEL)) {
    $env:SOL_ADVISOR_MODEL.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_MODEL)) {
    $env:CODEX_MODEL.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($inheritedCodexConfig.Model)) {
    $inheritedCodexConfig.Model
} else {
    $null
}

$effectiveReasoningEffort = if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    $ReasoningEffort.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($inheritedCodexConfig.ReasoningEffort)) {
    $inheritedCodexConfig.ReasoningEffort
} else {
    $null
}
$inheritedReasoningEffort = $effectiveReasoningEffort

function Parse-Duration([string]$d) {
    if ([string]::IsNullOrWhiteSpace($d)) {
        Fail "Duration string cannot be empty."
    }
    $trimmed = $d.Trim()
    $totalSec = 0
    if ($trimmed -match '^(\d+)h(?:(\d+)m)?$') {
        $hours = [int]$Matches[1]
        $mins = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $totalSec = ($hours * 3600) + ($mins * 60)
    } elseif ($trimmed -match '^(\d+)m(?:(\d+)s)?$') {
        $mins = [int]$Matches[1]
        $secs = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        $totalSec = ($mins * 60) + $secs
    } elseif ($trimmed -match '^(\d+)s$') {
        $totalSec = [int]$Matches[1]
    } elseif ($trimmed -match '^(\d+)$') {
        $totalSec = [int]$Matches[1]
    } else {
        Fail "Invalid duration format '$d'. Supported formats: '15m', '600s', '1h', '1h30m'."
    }
    if ($totalSec -le 0) { Fail "Duration must be greater than zero: $d" }
    return $totalSec
}

$timeoutSec = Parse-Duration $Timeout
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-RemainingTimeoutMs([int]$MaxStepMs = -1) {
    $remSec = $timeoutSec - $sw.Elapsed.TotalSeconds
    if ($remSec -le 0) {
        Fail "Fresh reviewer execution exceeded timeout of $Timeout ($timeoutSec seconds)."
    }
    $remMs = [int]($remSec * 1000)
    if ($MaxStepMs -gt 0) {
        return [Math]::Min($MaxStepMs, $remMs)
    }
    return $remMs
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
                try { & taskkill.exe /F /T /PID $Process.Id 2>$null | Out-Null } catch {}
            }
            try {
                $Process.Kill($true)
                [void]$Process.WaitForExit(3000)
            } catch {}
        }
    } catch {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            try { & taskkill.exe /F /T /PID $Process.Id 2>$null | Out-Null } catch {}
        }
        try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# 1. P/Invoke for Win32 path normalization and handle inspection
if (-not ([System.Management.Automation.PSTypeName]'SolAdvisorReviewer.Win32Path').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SolAdvisorReviewer {
    public static class Win32Path {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern uint GetFinalPathNameByHandle(
            SafeFileHandle hFile,
            [Out] StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            FileShare dwShareMode,
            IntPtr lpSecurityAttributes,
            FileMode dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile
        );

        public const uint FILE_READ_ATTRIBUTES = 0x0080;
        public const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        public const uint OPEN_EXISTING = 3;
    }
}
"@
}

function Get-PhysicalDirectoryPath([string]$Path) {
    if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    $h = [SolAdvisorReviewer.Win32Path]::CreateFile(
        $Path,
        [SolAdvisorReviewer.Win32Path]::FILE_READ_ATTRIBUTES,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete,
        [System.IntPtr]::Zero,
        [System.IO.FileMode]::Open,
        [SolAdvisorReviewer.Win32Path]::FILE_FLAG_BACKUP_SEMANTICS,
        [System.IntPtr]::Zero
    )
    if ($h.IsInvalid) {
        Fail "Cannot open handle for directory path resolution: $Path"
    }
    try {
        $sb = [System.Text.StringBuilder]::new(1024)
        $res = [SolAdvisorReviewer.Win32Path]::GetFinalPathNameByHandle($h, $sb, 1024, 0)
        if ($res -eq 0) {
            Fail "GetFinalPathNameByHandle failed for: $Path"
        }
        $resPath = $sb.ToString()
        if ($resPath.StartsWith("\\?\UNC\")) {
            return "\\" + $resPath.Substring(8)
        } elseif ($resPath.StartsWith("\\?\")) {
            return $resPath.Substring(4)
        }
        return $resPath
    } finally {
        $h.Dispose()
    }
}

function Assert-NoReparseInAncestors([string]$Path, [string]$Label) {
    $curr = $Path
    while (-not [string]::IsNullOrWhiteSpace($curr)) {
        if (Test-Path -LiteralPath $curr) {
            $item = Get-Item -LiteralPath $curr -Force -ErrorAction SilentlyContinue
            if ($null -ne $item) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Fail "$Label contains symbolic link, junction, or reparse point: $curr"
                }
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($curr)
        if ($parent -eq $curr -or [string]::IsNullOrEmpty($parent)) { break }
        $curr = $parent
    }
}

# 2. Validate Workspace
if ([string]::IsNullOrWhiteSpace($Workspace)) { Fail "Workspace path is empty." }
if (-not [System.IO.Path]::IsPathRooted($Workspace)) { Fail "Workspace must be an absolute path: $Workspace" }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    Fail "Target workspace does not exist or is not a directory: $Workspace"
}
Assert-NoReparseInAncestors $Workspace "Workspace directory"
$resolvedWs = (Resolve-Path -LiteralPath $Workspace).Path
$physicalWs = Get-PhysicalDirectoryPath $resolvedWs

# Git command helper with strict exit code checking and bounded remaining timeout
function Invoke-GitCmd([string]$Ws, [string[]]$GitArgs) {
    $waitMs = Get-RemainingTimeoutMs 30000
    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = "git"
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.CreateNoWindow = $true
    $pinfo.WorkingDirectory = $Ws
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $pinfo.StandardOutputEncoding = $strictUtf8
    $pinfo.StandardErrorEncoding = $strictUtf8
    $pinfo.ArgumentList.Add("-C")
    $pinfo.ArgumentList.Add($Ws)
    foreach ($a in $GitArgs) { $pinfo.ArgumentList.Add($a) }

    $p = [System.Diagnostics.Process]::Start($pinfo)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($waitMs)) {
        try { $p.Kill($true) } catch {}
        Fail "Git command timed out: git $($GitArgs -join ' ')"
    }
    [System.Threading.Tasks.Task]::WaitAll($stdoutTask, $stderrTask)
    if ($p.ExitCode -ne 0) {
        Fail "Git command failed (exit code $($p.ExitCode)): git $($GitArgs -join ' ')`n$($stderrTask.Result)"
    }
    return $stdoutTask.Result
}

function Get-GitBinaryDiffBytes([string]$Ws, [string[]]$DiffArgs) {
    $waitMs = Get-RemainingTimeoutMs 60000
    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = "git"
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.CreateNoWindow = $true
    $pinfo.WorkingDirectory = $Ws
    $pinfo.ArgumentList.Add("-C")
    $pinfo.ArgumentList.Add($Ws)
    $pinfo.ArgumentList.Add("diff")
    foreach ($a in $DiffArgs) { $pinfo.ArgumentList.Add($a) }

    $p = [System.Diagnostics.Process]::Start($pinfo)
    $ms = [System.IO.MemoryStream]::new()
    $copyTask = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($waitMs)) {
        try { $p.Kill($true) } catch {}
        Fail "Git diff timed out."
    }
    [System.Threading.Tasks.Task]::WaitAll($copyTask, $errTask)
    if ($p.ExitCode -ne 0) {
        Fail "Git diff failed (exit code $($p.ExitCode)): $($errTask.Result)"
    }
    return ,$ms.ToArray()
}

$gitTopLevelRaw = Invoke-GitCmd $physicalWs @("rev-parse", "--show-toplevel")
if ([string]::IsNullOrWhiteSpace($gitTopLevelRaw)) {
    Fail "Target workspace is not a Git repository root: $Workspace"
}
$gitTopLevel = (Resolve-Path -LiteralPath $gitTopLevelRaw.Trim()).Path
$physicalGitTop = Get-PhysicalDirectoryPath $gitTopLevel
if (-not $physicalWs.Equals($physicalGitTop, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Target workspace is not the top-level root of the Git repository ($physicalWs vs $physicalGitTop)."
}

$wsPrefix = $physicalWs.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

# 3. Validate GoalFile, EvidenceFile & ParentVerificationFile
function Validate-InputFile([string]$FilePath, [string]$Label, [int]$MaxSize = 1048576) {
    if ([string]::IsNullOrWhiteSpace($FilePath)) { Fail "$Label path is empty." }
    if (-not [System.IO.Path]::IsPathRooted($FilePath)) { Fail "$Label must be an absolute path: $FilePath" }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Fail "$Label does not exist or is not a file: $FilePath"
    }
    $fItem = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    if ($fItem.Length -gt $MaxSize) {
        Fail "$Label exceeds maximum allowed size of $MaxSize bytes ($($fItem.Length) bytes)."
    }
    $parentDir = [System.IO.Path]::GetDirectoryName($FilePath)
    Assert-NoReparseInAncestors $parentDir "$Label parent directory"
    Assert-NoReparseInAncestors $FilePath $Label
    $resolved = (Resolve-Path -LiteralPath $FilePath).Path
    $physDir = Get-PhysicalDirectoryPath $parentDir
    $physFile = [System.IO.Path]::Combine($physDir, [System.IO.Path]::GetFileName($resolved))
    if ($physDir.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physDir.Equals($physicalWs, [System.StringComparison]::OrdinalIgnoreCase) -or $physFile.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label is inside target workspace ($physFile is inside $physicalWs)."
    }
    return $resolved
}

function Compute-Sha256Hex([byte[]]$Data) {
    if ($null -eq $Data) {
        $Data = [byte[]]@()
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([byte[]]$Data)
        return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Compute-Sha256String([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return Compute-Sha256Hex $bytes
}

function Get-FileSha256AndLength([string]$FilePath) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return @{ Length = 0; Sha256 = "MISSING" }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $hashBytes = $sha.ComputeHash($stream)
        $hex = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
        return @{ Length = $stream.Length; Sha256 = $hex }
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$resolvedGoalFile = Validate-InputFile $GoalFile "GoalFile"
$resolvedEvidenceFile = Validate-InputFile $EvidenceFile "EvidenceFile"
$resolvedParentVerFile = Validate-InputFile $ParentVerificationFile "ParentVerificationFile"

# 4. Validate ReviewOutputFile
if ([string]::IsNullOrWhiteSpace($ReviewOutputFile)) { Fail "ReviewOutputFile path is empty." }
if (-not [System.IO.Path]::IsPathRooted($ReviewOutputFile)) {
    Fail "ReviewOutputFile must be an absolute path: $ReviewOutputFile"
}
if ($ReviewOutputFile.StartsWith("\\.\") -or $ReviewOutputFile.StartsWith("\\?\")) {
    Fail "ReviewOutputFile contains unsupported device path syntax: $ReviewOutputFile"
}
$fileNameOnly = [System.IO.Path]::GetFileName($ReviewOutputFile)
if ($fileNameOnly.Contains(":")) {
    Fail "ReviewOutputFile contains Alternate Data Stream (ADS) syntax: $ReviewOutputFile"
}
$reservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")
$baseNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($ReviewOutputFile)
if ($baseNameNoExt.ToUpperInvariant() -in $reservedNames) {
    Fail "ReviewOutputFile uses reserved DOS device name: $ReviewOutputFile"
}

if (Test-Path -LiteralPath $ReviewOutputFile) {
    Fail "Review output destination already exists (no-clobber): $ReviewOutputFile"
}

$outputParentDir = [System.IO.Path]::GetDirectoryName($ReviewOutputFile)
if (-not (Test-Path -LiteralPath $outputParentDir -PathType Container)) {
    Fail "Review output parent directory does not exist: $outputParentDir"
}
Assert-NoReparseInAncestors $outputParentDir "Review output parent directory"
$resolvedOutputParent = (Resolve-Path -LiteralPath $outputParentDir).Path
$physicalOutputParent = Get-PhysicalDirectoryPath $resolvedOutputParent

if ($physicalOutputParent.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalOutputParent.Equals($physicalWs, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Review output destination is inside target workspace: $physicalOutputParent"
}

# 5. Read and Strictly Validate Parent Verification Artifact Schema
$rawParentVerBytes = [System.IO.File]::ReadAllBytes($resolvedParentVerFile)
$parentVerHash = Compute-Sha256Hex $rawParentVerBytes

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$parentVerText = $utf8NoBom.GetString($rawParentVerBytes)

$pvDoc = $null
try {
    $pvDoc = [System.Text.Json.JsonDocument]::Parse($parentVerText)
} catch {
    Fail "ParentVerificationFile is not valid JSON: $_"
}

if ($pvDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
    Fail "ParentVerificationFile must be a JSON object."
}

$parentVerObj = $parentVerText | ConvertFrom-Json

# Strict allowed keys in parent-verification.json
$allowedPvKeys = @("schema_version", "iteration", "verified_at_utc", "ownership_check", "integrity_check", "implementer_evidence_assessment", "suggested_commands_unexecuted", "trusted_verification", "all_checks_passed", "bindings")
foreach ($prop in $parentVerObj.PSObject.Properties) {
    if ($prop.Name -notin $allowedPvKeys) {
        Fail "Unknown key '$($prop.Name)' in parent-verification.json (strict schema validation)."
    }
}

if ($null -eq $parentVerObj.schema_version -or $pvDoc.RootElement.GetProperty("schema_version").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or [int]$parentVerObj.schema_version -ne 1) {
    Fail "ParentVerificationFile schema_version must be integer 1."
}
if ($null -eq $parentVerObj.all_checks_passed -or $pvDoc.RootElement.GetProperty("all_checks_passed").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
    Fail "ParentVerificationFile does not report all_checks_passed = true."
}
if ($pvDoc.RootElement.GetProperty("iteration").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or [int]$parentVerObj.iteration -lt 1) { Fail "ParentVerificationFile iteration must be a positive integer." }
if ($pvDoc.RootElement.GetProperty("verified_at_utc").ValueKind -ne [System.Text.Json.JsonValueKind]::String -or [string]::IsNullOrWhiteSpace([string]$parentVerObj.verified_at_utc)) { Fail "ParentVerificationFile verified_at_utc must be a non-empty string." }
$suggestedElem = $pvDoc.RootElement.GetProperty("suggested_commands_unexecuted")
if ($suggestedElem.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { Fail "ParentVerificationFile suggested_commands_unexecuted must be an array." }
foreach ($item in $suggestedElem.EnumerateArray()) { if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "ParentVerificationFile suggested_commands_unexecuted elements must be strings." } }

# Caller-authored trusted verification validation. The field is required even
# when no verifier was supplied so the reviewer can distinguish "not run" from
# a malformed or omitted evidence record.
if ($null -eq $parentVerObj.trusted_verification -or -not ($parentVerObj.trusted_verification -is [System.Management.Automation.PSCustomObject])) {
    Fail "ParentVerificationFile trusted_verification is missing or not an object."
}
$allowedTvKeys = @("supplied", "script_sha256", "command", "exit_code_observed", "passed", "stdout", "stderr")
foreach ($prop in $parentVerObj.trusted_verification.PSObject.Properties) {
    if ($prop.Name -notin $allowedTvKeys) {
        Fail "Unknown key '$($prop.Name)' in parent-verification trusted_verification (strict schema validation)."
    }
}
foreach ($requiredKey in $allowedTvKeys) {
    if ($null -eq $parentVerObj.trusted_verification.PSObject.Properties[$requiredKey]) {
        Fail "ParentVerificationFile trusted_verification is missing required key '$requiredKey'."
    }
}
$tvElem = $pvDoc.RootElement.GetProperty("trusted_verification")
$tvSuppliedKind = $tvElem.GetProperty("supplied").ValueKind
if ($tvSuppliedKind -ne [System.Text.Json.JsonValueKind]::True -and $tvSuppliedKind -ne [System.Text.Json.JsonValueKind]::False) {
    Fail "ParentVerificationFile trusted_verification.supplied must be boolean."
}
foreach ($stringKey in @("script_sha256", "command", "stdout", "stderr")) {
    if ($tvElem.GetProperty($stringKey).ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
        Fail "ParentVerificationFile trusted_verification.$stringKey must be string."
    }
}
if ($tvSuppliedKind -eq [System.Text.Json.JsonValueKind]::False) {
    if ($tvElem.GetProperty("exit_code_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::Null -or
        $tvElem.GetProperty("passed").ValueKind -ne [System.Text.Json.JsonValueKind]::Null) {
        Fail "Unsupplied trusted verification must use null exit_code_observed and passed values."
    }
} else {
    if ([string]$parentVerObj.trusted_verification.script_sha256 -notmatch '^[0-9a-f]{64}$') {
        Fail "Supplied trusted verification script_sha256 must be 64 lowercase hex characters."
    }
    if ([string]::IsNullOrWhiteSpace([string]$parentVerObj.trusted_verification.command)) {
        Fail "Supplied trusted verification command must be a non-empty string."
    }
    if ($tvElem.GetProperty("exit_code_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
        [int]$parentVerObj.trusted_verification.exit_code_observed -ne 0) {
        Fail "Supplied trusted verification exit_code_observed must be integer 0."
    }
    if ($tvElem.GetProperty("passed").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
        Fail "Supplied trusted verification passed must be boolean true."
    }
}

# Ownership check validation
if ($null -eq $parentVerObj.ownership_check -or -not ($parentVerObj.ownership_check -is [System.Management.Automation.PSCustomObject])) {
    Fail "ParentVerificationFile ownership_check is missing or not an object."
}
$allowedOcKeys = @("passed", "declared_owned_files", "window_modified_files", "unowned_modifications")
foreach ($prop in $parentVerObj.ownership_check.PSObject.Properties) {
    if ($prop.Name -notin $allowedOcKeys) {
        Fail "Unknown key '$($prop.Name)' in parent-verification ownership_check (strict schema validation)."
    }
}
$ocElem = $pvDoc.RootElement.GetProperty("ownership_check")
if ($ocElem.GetProperty("passed").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
    Fail "ParentVerificationFile ownership_check.passed must be boolean true."
}
if ($ocElem.GetProperty("declared_owned_files").ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
    $ocElem.GetProperty("window_modified_files").ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
    $ocElem.GetProperty("unowned_modifications").ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
    Fail "ParentVerificationFile ownership_check arrays must be JSON arrays."
}
if ($parentVerObj.ownership_check.unowned_modifications.Count -ne 0) {
    Fail "ParentVerificationFile reports unowned modifications."
}
foreach ($arrayName in @("declared_owned_files", "window_modified_files", "unowned_modifications")) { foreach ($item in $ocElem.GetProperty($arrayName).EnumerateArray()) { if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "ParentVerificationFile ownership_check.$arrayName elements must be strings." } } }

# Integrity check validation
if ($null -eq $parentVerObj.integrity_check -or -not ($parentVerObj.integrity_check -is [System.Management.Automation.PSCustomObject])) {
    Fail "ParentVerificationFile integrity_check is missing or not an object."
}
$allowedIcKeys = @("passed", "head_unchanged", "baseline_head_sha", "current_head_sha", "scoped_git_metadata_unchanged", "in_progress_git_operations")
foreach ($prop in $parentVerObj.integrity_check.PSObject.Properties) {
    if ($prop.Name -notin $allowedIcKeys) {
        Fail "Unknown key '$($prop.Name)' in parent-verification integrity_check (strict schema validation)."
    }
}
$icElem = $pvDoc.RootElement.GetProperty("integrity_check")
if ($icElem.GetProperty("passed").ValueKind -ne [System.Text.Json.JsonValueKind]::True -or
    $icElem.GetProperty("head_unchanged").ValueKind -ne [System.Text.Json.JsonValueKind]::True -or
    $icElem.GetProperty("scoped_git_metadata_unchanged").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
    Fail "ParentVerificationFile integrity_check booleans must be true."
}
$bHead = [string]$parentVerObj.integrity_check.baseline_head_sha
$cHead = [string]$parentVerObj.integrity_check.current_head_sha
if ($bHead -notmatch '^[0-9a-f]{40}$' -or $cHead -notmatch '^[0-9a-f]{40}$' -or $bHead -ne $cHead) {
    Fail "ParentVerificationFile integrity_check HEAD SHAs invalid or mismatched."
}
if ($icElem.GetProperty("in_progress_git_operations").ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or $parentVerObj.integrity_check.in_progress_git_operations.Count -ne 0) {
    Fail "ParentVerificationFile integrity_check in_progress_git_operations must be empty array."
}

# Implementer evidence assessment validation
if ($null -eq $parentVerObj.implementer_evidence_assessment -or -not ($parentVerObj.implementer_evidence_assessment -is [System.Management.Automation.PSCustomObject])) {
    Fail "ParentVerificationFile implementer_evidence_assessment missing or not an object."
}
$allowedIeaKeys = @("passed", "implementer_status", "implementer_reported_tests_untrusted", "implementer_reported_test_summary")
foreach ($prop in $parentVerObj.implementer_evidence_assessment.PSObject.Properties) {
    if ($prop.Name -notin $allowedIeaKeys) {
        Fail "Unknown key '$($prop.Name)' in implementer_evidence_assessment (strict schema validation)."
    }
}
$ieaElem = $pvDoc.RootElement.GetProperty("implementer_evidence_assessment")
if ($ieaElem.GetProperty("passed").ValueKind -ne [System.Text.Json.JsonValueKind]::True -or $ieaElem.GetProperty("implementer_reported_tests_untrusted").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
    Fail "ParentVerificationFile implementer_evidence_assessment booleans must be true."
}
foreach ($name in @("implementer_status", "implementer_reported_test_summary")) { if ($ieaElem.GetProperty($name).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "ParentVerificationFile implementer_evidence_assessment.$name must be string." } }

if ($null -eq $parentVerObj.bindings) {
    Fail "ParentVerificationFile missing required 'bindings' object."
}
$requiredPvBindingKeys = @(
    "task_sha256",
    "plan_sha256",
    "spec_sha256",
    "implementer_evidence_sha256",
    "pre_window_manifest_sha256",
    "post_window_manifest_sha256",
    "repository_manifest_sha256",
    "aggregate_delta_manifest_sha256"
)
foreach ($prop in $parentVerObj.bindings.PSObject.Properties) {
    if ($prop.Name -notin $requiredPvBindingKeys) {
        Fail "Unknown key '$($prop.Name)' in parent-verification bindings (strict schema validation)."
    }
}
foreach ($bk in $requiredPvBindingKeys) {
    if ($pvDoc.RootElement.GetProperty("bindings").GetProperty($bk).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "ParentVerificationFile binding '$bk' must be string." }
    if ($null -eq $parentVerObj.bindings.PSObject.Properties[$bk] -or [string]::IsNullOrWhiteSpace([string]$parentVerObj.bindings.$bk)) {
        Fail "ParentVerificationFile bindings missing required key '$bk'."
    }
    $val = [string]$parentVerObj.bindings.$bk
    if ($val -notmatch '^[0-9a-f]{64}$') {
        Fail "ParentVerificationFile binding '$bk' value '$val' is not a 64-lowercase-hex string."
    }
}

# 6. Read Raw Goal and Implementer Evidence
$rawGoalBytes = [System.IO.File]::ReadAllBytes($resolvedGoalFile)
$taskHash = Compute-Sha256Hex $rawGoalBytes
$goalContent = $utf8NoBom.GetString($rawGoalBytes)

$rawEvidenceBytes = [System.IO.File]::ReadAllBytes($resolvedEvidenceFile)
$implEvHash = Compute-Sha256Hex $rawEvidenceBytes
$evidenceContent = $utf8NoBom.GetString($rawEvidenceBytes)

$implDoc = $null
try {
    $implDoc = [System.Text.Json.JsonDocument]::Parse($evidenceContent)
} catch {
    Fail "EvidenceFile is not valid JSON: $_"
}
if ($implDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
    Fail "EvidenceFile must be a JSON object."
}

$implEvidenceObj = $evidenceContent | ConvertFrom-Json

$allowedImplKeys = @("schema_version", "invocation", "runtime_observability", "agy_result")
foreach ($prop in $implEvidenceObj.PSObject.Properties) {
    if ($prop.Name -notin $allowedImplKeys) {
        Fail "Unknown key '$($prop.Name)' in EvidenceFile (strict schema validation)."
    }
}

if ($null -eq $implEvidenceObj.schema_version -or $implDoc.RootElement.GetProperty("schema_version").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or [int]$implEvidenceObj.schema_version -ne 1) {
    Fail "EvidenceFile schema_version must be integer 1."
}

# Validate invocation object
if ($null -eq $implEvidenceObj.invocation -or -not ($implEvidenceObj.invocation -is [System.Management.Automation.PSCustomObject])) {
    Fail "EvidenceFile invocation missing or not an object."
}
$allowedInvKeys = @("provider", "cli_version_observed", "model_requested", "model_catalog_exact_match_observed", "effort_requested", "mode_requested", "output_format_requested", "cwd_observed", "permission_mode_requested", "started_at_utc", "ended_at_utc", "duration_ms_observed", "exit_code_observed")
foreach ($prop in $implEvidenceObj.invocation.PSObject.Properties) {
    if ($prop.Name -notin $allowedInvKeys) {
        Fail "Unknown key '$($prop.Name)' in EvidenceFile invocation (strict schema validation)."
    }
}
if ($implEvidenceObj.invocation.provider -ne "google-antigravity-cli") {
    Fail "EvidenceFile invocation.provider must be 'google-antigravity-cli'."
}
if ([string]::IsNullOrWhiteSpace($implEvidenceObj.invocation.model_requested)) {
    Fail "EvidenceFile invocation.model_requested must not be empty."
}
if ($implEvidenceObj.invocation.effort_requested -ne "high" -or $implEvidenceObj.invocation.mode_requested -ne "accept-edits" -or $implEvidenceObj.invocation.output_format_requested -ne "json") {
    Fail "EvidenceFile invocation pins mismatch."
}
$invElem = $implDoc.RootElement.GetProperty("invocation")
foreach ($name in @("provider", "cli_version_observed", "model_requested", "effort_requested", "mode_requested", "output_format_requested", "cwd_observed", "permission_mode_requested", "started_at_utc", "ended_at_utc")) { if ($invElem.GetProperty($name).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "EvidenceFile invocation.$name must be string." } }
if ($invElem.GetProperty("model_catalog_exact_match_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
    Fail "EvidenceFile model_catalog_exact_match_observed must be boolean true."
}
if ($invElem.GetProperty("duration_ms_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $invElem.GetProperty("exit_code_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::Number) {
    Fail "EvidenceFile duration and exit code must be numeric."
}

# Validate runtime_observability
if ($null -eq $implEvidenceObj.runtime_observability -or -not ($implEvidenceObj.runtime_observability -is [System.Management.Automation.PSCustomObject])) {
    Fail "EvidenceFile runtime_observability missing or not an object."
}
$allowedRoKeys = @("model_field_observed", "effort_field_observed", "mode_field_observed", "cwd_field_observed", "note")
foreach ($prop in $implEvidenceObj.runtime_observability.PSObject.Properties) {
    if ($prop.Name -notin $allowedRoKeys) {
        Fail "Unknown key '$($prop.Name)' in EvidenceFile runtime_observability (strict schema validation)."
    }
}
$roElem = $implDoc.RootElement.GetProperty("runtime_observability")
foreach ($name in @("model_field_observed", "effort_field_observed", "mode_field_observed", "cwd_field_observed")) {
    if ($roElem.GetProperty($name).ValueKind -notin @([System.Text.Json.JsonValueKind]::True, [System.Text.Json.JsonValueKind]::False)) {
        Fail "EvidenceFile runtime_observability.$name must be boolean."
    }
}
if ($roElem.GetProperty("note").ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "EvidenceFile runtime_observability.note must be string." }

$requiredAgyKeys = @("status", "objective", "changes", "verified", "judgment_calls", "gaps", "response")
$allowedAgyKeys = @("status", "objective", "changes", "verified", "judgment_calls", "gaps", "response", "conversation_id")
if ($null -eq $implEvidenceObj.agy_result -or -not ($implEvidenceObj.agy_result -is [System.Management.Automation.PSCustomObject])) { Fail "EvidenceFile agy_result missing or not an object." }
foreach ($name in $requiredAgyKeys) {
    if ($null -eq $implEvidenceObj.agy_result.PSObject.Properties[$name] -or -not ($implEvidenceObj.agy_result.$name -is [string])) { Fail "EvidenceFile agy_result.$name must be string." }
}
foreach ($prop in $implEvidenceObj.agy_result.PSObject.Properties) {
    if ($prop.Name -notin $allowedAgyKeys) { Fail "Unknown key '$($prop.Name)' in EvidenceFile agy_result." }
    if (-not ($prop.Value -is [string])) { Fail "EvidenceFile agy_result.$($prop.Name) must be string." }
}

# Verify bindings match between parent verification and independent hashes
if ([string]$parentVerObj.bindings.task_sha256 -ne $taskHash) {
    Fail "ParentVerificationFile task_sha256 '$($parentVerObj.bindings.task_sha256)' does not match actual task hash '$taskHash'."
}
if ([string]$parentVerObj.bindings.implementer_evidence_sha256 -ne $implEvHash) {
    Fail "ParentVerificationFile implementer_evidence_sha256 '$($parentVerObj.bindings.implementer_evidence_sha256)' does not match actual evidence hash '$implEvHash'."
}

# 7. Scoped Git Metadata Digest Function
function Get-ScopedGitMetadataDigest([string]$WsPath, [bool]$IncludeIndex = $true) {
    $ms = [System.IO.MemoryStream]::new()
    $writer = [System.IO.StreamWriter]::new($ms, [System.Text.UTF8Encoding]::new($false))

    $gitDirRel = (Invoke-GitCmd $WsPath @("rev-parse", "--git-dir")).Trim()
    $gitDirFull = [System.IO.Path]::GetFullPath((Join-Path $WsPath $gitDirRel))

    # 1. HEAD file & rev-parse
    $headFile = Join-Path $gitDirFull "HEAD"
    if (Test-Path -LiteralPath $headFile -PathType Leaf) {
        $headInfo = Get-FileSha256AndLength $headFile
        $writer.WriteLine("HEAD_FILE:" + $headInfo.Sha256)
    } else {
        $writer.WriteLine("HEAD_FILE:MISSING")
    }
    $headSha = (Invoke-GitCmd $WsPath @("rev-parse", "HEAD")).Trim()
    $writer.WriteLine("HEAD_SHA:$headSha")

    try {
        $headRef = (Invoke-GitCmd $WsPath @("symbolic-ref", "-q", "HEAD")).Trim()
    } catch {
        $headRef = "DETACHED"
    }
    $writer.WriteLine("HEAD_REF:$headRef")

    # 2. Config file
    $configFile = Join-Path $gitDirFull "config"
    if (Test-Path -LiteralPath $configFile -PathType Leaf) {
        $cfgInfo = Get-FileSha256AndLength $configFile
        $writer.WriteLine("CONFIG:" + $cfgInfo.Sha256)
    } else {
        $writer.WriteLine("CONFIG:MISSING")
    }

    # 3. Packed refs
    $packedRefsFile = Join-Path $gitDirFull "packed-refs"
    if (Test-Path -LiteralPath $packedRefsFile -PathType Leaf) {
        $prInfo = Get-FileSha256AndLength $packedRefsFile
        $writer.WriteLine("PACKED_REFS:" + $prInfo.Sha256)
    } else {
        $writer.WriteLine("PACKED_REFS:MISSING")
    }

    # 4. Refs directory
    $refsDir = Join-Path $gitDirFull "refs"
    $writer.WriteLine("REFS_ENTRIES:")
    if (Test-Path -LiteralPath $refsDir -PathType Container) {
        $refFiles = Get-ChildItem -LiteralPath $refsDir -Recurse -File | Sort-Object FullName
        foreach ($rf in $refFiles) {
            $rel = $rf.FullName.Substring($refsDir.Length).Replace("\", "/").TrimStart('/')
            $rInfo = Get-FileSha256AndLength $rf.FullName
            $writer.WriteLine("REF:${rel}:" + $rInfo.Sha256)
        }
    }

    # 5. Hooks directory
    $hooksDir = Join-Path $gitDirFull "hooks"
    $writer.WriteLine("HOOKS_ENTRIES:")
    if (Test-Path -LiteralPath $hooksDir -PathType Container) {
        $hookFiles = Get-ChildItem -LiteralPath $hooksDir -Recurse -File | Sort-Object FullName
        foreach ($hf in $hookFiles) {
            $rel = $hf.FullName.Substring($hooksDir.Length).Replace("\", "/").TrimStart('/')
            $hInfo = Get-FileSha256AndLength $hf.FullName
            $writer.WriteLine("HOOK:${rel}:" + $hInfo.Sha256)
        }
    }

    # 6. Info directory (exclude, attributes, grafts)
    $infoDir = Join-Path $gitDirFull "info"
    $writer.WriteLine("INFO_ENTRIES:")
    if (Test-Path -LiteralPath $infoDir -PathType Container) {
        $infoFiles = Get-ChildItem -LiteralPath $infoDir -Recurse -File | Sort-Object FullName
        foreach ($inf in $infoFiles) {
            $rel = $inf.FullName.Substring($infoDir.Length).Replace("\", "/").TrimStart('/')
            $iInfo = Get-FileSha256AndLength $inf.FullName
            $writer.WriteLine("INFO:${rel}:" + $iInfo.Sha256)
        }
    }

    # 7. Shallow / Grafts / Replace markers
    $shallowFile = Join-Path $gitDirFull "shallow"
    if (Test-Path -LiteralPath $shallowFile -PathType Leaf) {
        $shInfo = Get-FileSha256AndLength $shallowFile
        $writer.WriteLine("SHALLOW:" + $shInfo.Sha256)
    } else {
        $writer.WriteLine("SHALLOW:MISSING")
    }

    # 8. In-progress operation markers
    $writer.WriteLine("IN_PROGRESS_MARKERS:")
    $opMarkers = @("MERGE_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE", "ORIG_HEAD", "FETCH_HEAD")
    foreach ($marker in $opMarkers) {
        $mPath = Join-Path $gitDirFull $marker
        if (Test-Path -LiteralPath $mPath) {
            $writer.WriteLine("OP_MARKER:${marker}:PRESENT")
        }
    }

    # 9. Index file
    if ($IncludeIndex) {
        $indexFile = Join-Path $gitDirFull "index"
        if (Test-Path -LiteralPath $indexFile -PathType Leaf) {
            $idxInfo = Get-FileSha256AndLength $indexFile
            $writer.WriteLine("INDEX:" + $idxInfo.Sha256)
        } else {
            $writer.WriteLine("INDEX:MISSING")
        }
    }

    $writer.Flush()
    $metaBytes = $ms.ToArray()
    $metaHash = Compute-Sha256Hex $metaBytes
    $writer.Dispose()
    $ms.Dispose()
    return $metaHash
}

# Universal runtime cache and compilation artifact filter
function Test-IsIgnoredRuntimeCachePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $norm = $Path.Replace("\", "/").Trim('/')
    # Python runtime bytecode & cache directories
    if ($norm -match '(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.coverage|\.tox|\.nox)(/|$)') { return $true }
    if ($norm -match '\.(pyc|pyo|pyd)$') { return $true }
    # Node.js / packaging caches
    if ($norm -match '(^|/)(node_modules/\.cache|\.npm|\.yarn/cache)(/|$)') { return $true }
    # Editor & OS temporary artifacts
    if ($norm -match '(^|/)(\.DS_Store|Thumbs\.db|\.directory)$') { return $true }
    if ($norm -match '\.(tmp|swp|bak)$' -or $norm -match '(^|/)\.~') { return $true }
    return $false
}

# 8. Compute Deterministic Repository Manifest
function Get-DeterministicRepoManifest([string]$WsPath) {
    $ms = [System.IO.MemoryStream]::new()
    $writer = [System.IO.StreamWriter]::new($ms, [System.Text.UTF8Encoding]::new($false))

    $headSha = (Invoke-GitCmd $WsPath @("rev-parse", "HEAD")).Trim()
    $writer.WriteLine("HEAD:$headSha")

    try {
        $headRef = (Invoke-GitCmd $WsPath @("symbolic-ref", "-q", "HEAD")).Trim()
    } catch {
        $headRef = "DETACHED"
    }
    $writer.WriteLine("REF:$headRef")

    $scopedMetaHash = Get-ScopedGitMetadataDigest $WsPath $true
    $writer.WriteLine("SCOPED_GIT_METADATA:$scopedMetaHash")

    $statusRaw = Invoke-GitCmd $WsPath @("status", "--porcelain=v1", "-z")
    $writer.WriteLine("STATUS_Z:$statusRaw")

    $diffCachedBytes = Get-GitBinaryDiffBytes $WsPath @("--cached", "--binary")
    $diffCachedHash = Compute-Sha256Hex $diffCachedBytes
    $writer.WriteLine("DIFF_CACHED_BYTES:$($diffCachedBytes.Length):$diffCachedHash")

    $diffUnstagedBytes = Get-GitBinaryDiffBytes $WsPath @("--binary")
    $diffUnstagedHash = Compute-Sha256Hex $diffUnstagedBytes
    $writer.WriteLine("DIFF_UNSTAGED_BYTES:$($diffUnstagedBytes.Length):$diffUnstagedHash")

    $diffHeadBytes = Get-GitBinaryDiffBytes $WsPath @("HEAD", "--binary")
    $diffHeadHash = Compute-Sha256Hex $diffHeadBytes
    $writer.WriteLine("DIFF_HEAD_BYTES:$($diffHeadBytes.Length):$diffHeadHash")

    $untrackedRaw = Invoke-GitCmd $WsPath @("ls-files", "--others", "--exclude-standard", "-z")
    $writer.WriteLine("UNTRACKED_FILES:")
    if (-not [string]::IsNullOrEmpty($untrackedRaw)) {
        $uList = $untrackedRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
        [System.Array]::Sort($uList, [System.StringComparer]::Ordinal)
        foreach ($uf in $uList) {
            $normUf = $uf.Replace("\", "/").TrimStart('/')
            if (Test-IsIgnoredRuntimeCachePath $normUf) { continue }
            $fullPath = [System.IO.Path]::Combine($WsPath, $uf)
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $fInfo = Get-FileSha256AndLength $fullPath
                $writer.WriteLine("${uf}:$($fInfo.Length):$($fInfo.Sha256)")
            }
        }
    }

    $dirtyRaw = Invoke-GitCmd $WsPath @("diff", "--name-only", "HEAD", "-z")
    $writer.WriteLine("DIRTY_TRACKED_FILES:")
    if (-not [string]::IsNullOrEmpty($dirtyRaw)) {
        $dList = $dirtyRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
        [System.Array]::Sort($dList, [System.StringComparer]::Ordinal)
        foreach ($df in $dList) {
            $fullPath = [System.IO.Path]::Combine($WsPath, $df)
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $fInfo = Get-FileSha256AndLength $fullPath
                $writer.WriteLine("${df}:$($fInfo.Length):$($fInfo.Sha256)")
            } else {
                $writer.WriteLine("${df}:DELETED")
            }
        }
    }

    $writer.Flush()
    $manifestBytes = $ms.ToArray()
    $manifestHash = Compute-Sha256Hex $manifestBytes
    $writer.Dispose()
    $ms.Dispose()

    return @{
        HeadSha = $headSha
        HeadRef = $headRef
        ManifestHash = $manifestHash
        ManifestString = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
    }
}

$preReviewManifest = Get-DeterministicRepoManifest $physicalWs
$preReviewFingerprint = $preReviewManifest.ManifestHash

# Verify repository manifest matches parent verification binding
if ([string]$parentVerObj.bindings.repository_manifest_sha256 -ne $preReviewFingerprint) {
    Fail "ParentVerificationFile repository_manifest_sha256 '$($parentVerObj.bindings.repository_manifest_sha256)' does not match current repository manifest '$preReviewFingerprint'."
}

# 9. Gather Diffs and Untracked Presentation with Fail-Closed Resource Caps
$stagedDiffBytes = Get-GitBinaryDiffBytes $physicalWs @("--cached", "--binary")
$unstagedDiffBytes = Get-GitBinaryDiffBytes $physicalWs @("--binary")
$totalDiffBytes = $stagedDiffBytes.Length + $unstagedDiffBytes.Length

if ($totalDiffBytes -gt 2097152) {
    Fail "Total review diff presentation exceeds 2MB limit ($totalDiffBytes bytes). Bounded review limits fail closed."
}

$stagedDiffStr = if ($stagedDiffBytes.Length -gt 0) { $utf8NoBom.GetString($stagedDiffBytes) } else { "None" }
$unstagedDiffStr = if ($unstagedDiffBytes.Length -gt 0) { $utf8NoBom.GetString($unstagedDiffBytes) } else { "None" }

$untrackedRaw = Invoke-GitCmd $physicalWs @("ls-files", "--others", "--exclude-standard", "-z")
$untrackedFilesStr = ""
$totalUntrackedTextBytes = 0

if (-not [string]::IsNullOrEmpty($untrackedRaw)) {
    $sb = [System.Text.StringBuilder]::new()
    $untrackedList = $untrackedRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($untracked in $untrackedList) {
        $normUntracked = $untracked.Replace("\", "/").TrimStart('/')
        if (Test-IsIgnoredRuntimeCachePath $normUntracked) { continue }
        $fullPath = [System.IO.Path]::Combine($physicalWs, $untracked)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $fInfo = Get-FileSha256AndLength $fullPath
            $isBinary = $false

            # Check for binary null byte in first 8KB
            $buf = New-Object byte[] ([Math]::Min(8192, $fInfo.Length))
            if ($buf.Length -gt 0) {
                $fs = [System.IO.File]::OpenRead($fullPath)
                try {
                    $bytesRead = $fs.Read($buf, 0, $buf.Length)
                    for ($bi = 0; $bi -lt $bytesRead; $bi++) {
                        if ($buf[$bi] -eq 0) { $isBinary = $true; break }
                    }
                } finally {
                    $fs.Dispose()
                }
            }

            $sb.AppendLine("--- UNTRACKED FILE: $untracked ---")
            if ($isBinary) {
                $sb.AppendLine("[BINARY FILE: $untracked, Size: $($fInfo.Length) bytes, SHA256: $($fInfo.Sha256)]")
            } else {
                if ($fInfo.Length -gt 262144) {
                    Fail "Untracked text file '$untracked' exceeds 256KB individual presentation limit ($($fInfo.Length) bytes)."
                }
                $totalUntrackedTextBytes += $fInfo.Length
                if ($totalUntrackedTextBytes -gt 1048576) {
                    Fail "Total untracked text presentation exceeds 1MB limit ($totalUntrackedTextBytes bytes)."
                }
                try {
                    $txt = [System.IO.File]::ReadAllText($fullPath, $utf8NoBom)
                    $sb.AppendLine($txt)
                } catch {
                    $sb.AppendLine("[NON-UTF8 FILE: $untracked, Size: $($fInfo.Length) bytes, SHA256: $($fInfo.Sha256)]")
                }
            }
        }
    }
    $untrackedFilesStr = $sb.ToString()
}

if ([string]::IsNullOrWhiteSpace($untrackedFilesStr)) {
    $untrackedFilesStr = "None"
}

# Bindings to echo
$planHash = [string]$parentVerObj.bindings.plan_sha256
$specHash = [string]$parentVerObj.bindings.spec_sha256
$preWinHash = [string]$parentVerObj.bindings.pre_window_manifest_sha256
$postWinHash = [string]$parentVerObj.bindings.post_window_manifest_sha256
$aggDeltaHash = [string]$parentVerObj.bindings.aggregate_delta_manifest_sha256

$bindingsSummary = @"
- task_sha256: $taskHash
- plan_sha256: $planHash
- spec_sha256: $specHash
- implementer_evidence_sha256: $implEvHash
- parent_verification_sha256: $parentVerHash
- pre_window_manifest_sha256: $preWinHash
- post_window_manifest_sha256: $postWinHash
- repository_manifest_sha256: $preReviewFingerprint
- aggregate_delta_manifest_sha256: $aggDeltaHash
"@

# 10. Construct Review Prompt
$reviewerModelDesc = if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) { "model: $effectiveModel" } else { "inherited Codex model" }
$reviewerEffortDesc = if (-not [string]::IsNullOrWhiteSpace($effectiveReasoningEffort)) { $effectiveReasoningEffort } else { "inherited" }
$reviewPrompt = @"
ROLE
You are a fresh, ephemeral, read-only final reviewer ($reviewerModelDesc with reasoning effort: $reviewerEffortDesc).
You MUST remain strictly read-only: do not create, modify, delete, format, or implement files.
Inspect the stated goal, staged & unstaged diffs relative to HEAD, untracked files, implementer evidence, and parent verification evidence in a fresh context.
The canonical repository is intentionally not mounted as your working directory. Review only the complete evidence bundle supplied below; do not attempt to locate or access the canonical workspace.
Note: Ignored files (.gitignore) are excluded from integrity scope; tracked and non-ignored files are strictly verified.
Implementer-reported test commands are untrusted implementer self-reports.

STATED GOAL
$goalContent

STAGED CHANGES (vs HEAD)
$stagedDiffStr

UNSTAGED WORKING TREE CHANGES (vs INDEX)
$unstagedDiffStr

UNTRACKED FILES AND CONTENTS
$untrackedFilesStr

IMPLEMENTER EVIDENCE
$evidenceContent

PARENT VERIFICATION EVIDENCE
$parentVerText

CRYPTOGRAPHIC BINDINGS
$bindingsSummary

REVIEW INSTRUCTIONS
Judge correctness, completeness, regressions, scope discipline, interface preservation, and test adequacy.
When parent verification reports all_checks_passed: true and no dedicated parent verification script was supplied, evaluate code correctness, logic, and test coverage through rigorous inspection of the diffs, untracked files, and test suites. Do not reject with FIX-FIRST solely because implementer-reported execution is marked untrusted or because suggested commands were left unexecuted by the parent machine, unless you identify concrete code bugs, test defects, or unmet requirements.
If no changes were needed or made to satisfy the goal, indicate reviewed_no_change: true.
You MUST echo all 9 reviewed_bindings exactly as provided above.
Return ONLY a structured JSON object with the following schema:
{
  "verdict": "SHIP" | "FIX-FIRST" | "RETHINK",
  "reason": "<evidence-based decisive reason>",
  "findings": "<precise file references and required fixes, or none>",
  "residual_risk": "<most important remaining risk, or none>",
  "reviewed_no_change": false,
  "reviewed_bindings": {
    "task_sha256": "$taskHash",
    "plan_sha256": "$planHash",
    "spec_sha256": "$specHash",
    "implementer_evidence_sha256": "$implEvHash",
    "parent_verification_sha256": "$parentVerHash",
    "pre_window_manifest_sha256": "$preWinHash",
    "post_window_manifest_sha256": "$postWinHash",
    "repository_manifest_sha256": "$preReviewFingerprint",
    "aggregate_delta_manifest_sha256": "$aggDeltaHash"
  }
}
Do not wrap in markdown fences or include any conversational text outside the JSON object.
"@

# Check prompt size cap (4MB)
$promptBytes = [System.Text.Encoding]::UTF8.GetBytes($reviewPrompt)
if ($promptBytes.Length -gt 4194304) {
    Fail "Total reviewer prompt size exceeds 4MB limit ($($promptBytes.Length) bytes)."
}

# 11. Determine Codex Executable & Test Mode
$codexExe = "codex"
if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    $foundCodex = Get-Command "codex" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($foundCodex) { $codexExe = $foundCodex.Source }
}
$effectiveTestMode = $TestMode.IsPresent

if (-not [string]::IsNullOrWhiteSpace($TestCodexBin)) {
    if (-not $effectiveTestMode) {
        Fail "Test executable argument (-TestCodexBin) specified without -TestMode switch."
    }
    if (-not (Test-Path -LiteralPath $TestCodexBin -PathType Leaf)) {
        Fail "Test executable specified in -TestCodexBin does not exist: $TestCodexBin"
    }
    $codexExe = (Resolve-Path -LiteralPath $TestCodexBin -ErrorAction Stop).Path
} else {
    $testCodexCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($tc in @($env:_MY_SOL_ADVISOR_TEST_CODEX_BIN, $env:_SOL_ADVISOR_TEST_CODEX_BIN)) {
        if (-not [string]::IsNullOrWhiteSpace($tc)) { $testCodexCandidates.Add($tc) }
    }

    if ($testCodexCandidates.Count -gt 0) {
        if (-not $effectiveTestMode) {
            Fail "Test executable override variable specified without explicit test mode switch (-TestMode)."
        }
        $testPath = $testCodexCandidates[0]
        if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
            Fail "Test executable override does not exist or is not a file: $testPath"
        }
        $codexExe = (Resolve-Path -LiteralPath $testPath -ErrorAction Stop).Path
    }
}

# 12. Execute Codex Fresh Review
$tempMsgFile = [System.IO.Path]::Combine($physicalOutputParent, ".codex-review-msg." + [System.Guid]::NewGuid().ToString("N") + ".tmp")
$reviewExecutionRoot = [System.IO.Path]::Combine($physicalOutputParent, ".sol-review-root." + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $reviewExecutionRoot | Out-Null
$exitCode = 1
$rawOutput = ""
$timedOut = $false
$proc = $null

try {
    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = $codexExe
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardInput = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.CreateNoWindow = $true
    # The complete review bundle is already embedded in the prompt. Running the
    # read-only reviewer from an empty disposable root avoids Windows AppContainer
    # traversal failures on dynamic Git worktrees and prevents direct repository access.
    $pinfo.WorkingDirectory = $reviewExecutionRoot

    $pinfo.ArgumentList.Add("exec")
    if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) {
        $pinfo.ArgumentList.Add("-m")
        $pinfo.ArgumentList.Add($effectiveModel)
    }
    $pinfo.ArgumentList.Add("-s")
    $pinfo.ArgumentList.Add("read-only")
    $pinfo.ArgumentList.Add("--ephemeral")
    $pinfo.ArgumentList.Add("--ignore-user-config")
    if (-not [string]::IsNullOrWhiteSpace($inheritedReasoningEffort)) {
        $pinfo.ArgumentList.Add("-c")
        $pinfo.ArgumentList.Add("model_reasoning_effort=`"$inheritedReasoningEffort`"")
    }
    foreach ($feature in @("apps", "plugins", "remote_plugin", "recommended_plugins", "browser_use", "browser_use_external", "computer_use", "in_app_browser", "memories", "image_generation", "workspace_dependencies", "skill_search")) {
        $pinfo.ArgumentList.Add("--disable")
        $pinfo.ArgumentList.Add($feature)
    }
    $pinfo.ArgumentList.Add("-C")
    $pinfo.ArgumentList.Add($reviewExecutionRoot)
    $pinfo.ArgumentList.Add("--skip-git-repo-check")
    $pinfo.ArgumentList.Add("--color")
    $pinfo.ArgumentList.Add("never")
    $pinfo.ArgumentList.Add("-o")
    $pinfo.ArgumentList.Add($tempMsgFile)

    $proc = [System.Diagnostics.Process]::Start($pinfo)
    if ($null -eq $proc) {
        Fail "Failed to start Codex process: $codexExe"
    }

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($reviewPrompt)
    $stdinTask = $proc.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
    $writeBudget = Get-RemainingTimeoutMs
    if (-not $stdinTask.Wait($writeBudget)) {
        Stop-ProcessTree $proc
        Fail "Fresh review prompt write exceeded hard outer deadline."
    }
    $proc.StandardInput.BaseStream.Close()

    $remMs = Get-RemainingTimeoutMs
    if (-not $proc.WaitForExit($remMs)) {
        $timedOut = $true
        Stop-ProcessTree $proc
        Fail "Fresh review Codex process exceeded timeout of $Timeout ($timeoutSec seconds)."
    }

    $exitCode = $proc.ExitCode
    $rawStdout = $stdoutTask.Result
    $rawStderr = $stderrTask.Result

    if (Test-Path -LiteralPath $tempMsgFile) {
        $rawOutput = [System.IO.File]::ReadAllText($tempMsgFile, $utf8NoBom)
    } else {
        $rawOutput = $rawStdout
    }
} finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-ProcessTree $proc
    }
    if (Test-Path -LiteralPath $tempMsgFile) {
        try { [System.IO.File]::Delete($tempMsgFile) } catch {}
    }
    if (Test-Path -LiteralPath $reviewExecutionRoot) {
        try { Remove-Item -LiteralPath $reviewExecutionRoot -Recurse -Force } catch {}
    }
}

if ($exitCode -ne 0) {
    if ($timedOut) { Fail "Fresh review Codex process exceeded timeout of $Timeout." }
    Fail "Fresh review Codex process exited with non-zero code $exitCode. Error: $rawStderr"
}

# Check model output size cap (2MB)
if ($rawOutput.Length -gt 2097152) {
    Fail "Fresh reviewer output exceeds 2MB limit ($($rawOutput.Length) chars)."
}

# 13. Post-Review Repository Immutability Check
$postReviewManifest = Get-DeterministicRepoManifest $physicalWs
$postReviewFingerprint = $postReviewManifest.ManifestHash
if ($preReviewFingerprint -ne $postReviewFingerprint) {
    Fail "Repository immutability violated: repository state was modified during fresh read-only review! (pre: $preReviewFingerprint, post: $postReviewFingerprint)"
}

# 14. Parse and Strictly Validate Reviewer JSON
if ([string]::IsNullOrWhiteSpace($rawOutput)) {
    Fail "Fresh reviewer produced empty output."
}

$cleanReviewJson = $rawOutput.Trim()
if ($cleanReviewJson.StartsWith('```')) {
    $lines = [regex]::Split($cleanReviewJson, '\r?\n') | Where-Object { -not $_.Trim().StartsWith('```') }
    $cleanReviewJson = ($lines -join "`n").Trim()
}

$parsedReviewDoc = $null
try {
    $parsedReviewDoc = [System.Text.Json.JsonDocument]::Parse($cleanReviewJson)
} catch {
    Fail "Fresh reviewer output is not valid JSON: $rawOutput"
}

if ($parsedReviewDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
    Fail "Fresh reviewer output must be a JSON object."
}

$parsedReview = $cleanReviewJson | ConvertFrom-Json

# Strict allowed keys in raw reviewer output
$allowedReviewerRawKeys = @("verdict", "reason", "findings", "residual_risk", "reviewed_no_change", "reviewed_bindings")
foreach ($prop in $parsedReview.PSObject.Properties) {
    if ($prop.Name -notin $allowedReviewerRawKeys) {
        Fail "Unknown key '$($prop.Name)' in reviewer JSON output (strict schema validation)."
    }
}

$rawReviewElem = $parsedReviewDoc.RootElement
foreach ($name in @("verdict", "reason", "findings", "residual_risk")) { if ($rawReviewElem.GetProperty($name).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "Fresh review JSON field '$name' must be a string." } }
$verdictRaw = if ($null -ne $parsedReview.PSObject.Properties['verdict']) { [string]$parsedReview.verdict } else { "" }
if ([string]::IsNullOrWhiteSpace($verdictRaw)) {
    Fail "Fresh review JSON missing 'verdict' field."
}
$verdict = $verdictRaw.Trim().ToUpperInvariant()
if ($verdict -notin @("SHIP", "FIX-FIRST", "RETHINK")) {
    Fail "Invalid review verdict '$verdictRaw'. Must be one of SHIP, FIX-FIRST, RETHINK."
}

$reason = if ($null -ne $parsedReview.PSObject.Properties['reason']) { [string]$parsedReview.reason } else { "" }
if ([string]::IsNullOrWhiteSpace($reason)) {
    Fail "Fresh review JSON missing or empty 'reason' field."
}
$findings = if ($null -ne $parsedReview.PSObject.Properties['findings']) { [string]$parsedReview.findings } else { "" }
$residualRisk = if ($null -ne $parsedReview.PSObject.Properties['residual_risk']) { [string]$parsedReview.residual_risk } else { "" }

$reviewedNoChange = $false
foreach ($prop in $parsedReviewDoc.RootElement.EnumerateObject()) {
    if ($prop.Name -eq "reviewed_no_change") {
        if ($prop.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::True -and $prop.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::False) {
            Fail "Fresh reviewer 'reviewed_no_change' field must be an actual JSON boolean (true/false), not string or number."
        }
        $reviewedNoChange = $prop.Value.GetBoolean()
        break
    }
}

# Validate Mandatory Closed-Set Reviewed Bindings
if ($null -eq $parsedReview.PSObject.Properties['reviewed_bindings'] -or $null -eq $parsedReview.reviewed_bindings -or -not ($parsedReview.reviewed_bindings -is [System.Management.Automation.PSCustomObject] -or $parsedReview.reviewed_bindings -is [System.Collections.IDictionary])) {
    Fail "Fresh review JSON missing mandatory 'reviewed_bindings' object."
}

$echoedBindings = $parsedReview.reviewed_bindings
$requiredBindingKeys = @(
    "task_sha256",
    "plan_sha256",
    "spec_sha256",
    "implementer_evidence_sha256",
    "parent_verification_sha256",
    "pre_window_manifest_sha256",
    "post_window_manifest_sha256",
    "repository_manifest_sha256",
    "aggregate_delta_manifest_sha256"
)

# Closed set check: no extra keys allowed in reviewed_bindings
foreach ($prop in $echoedBindings.PSObject.Properties) {
    if ($prop.Name -notin $requiredBindingKeys) {
        Fail "Unknown key '$($prop.Name)' in reviewer reviewed_bindings (closed set validation)."
    }
}

$expectedBindingMap = @{
    task_sha256 = $taskHash
    plan_sha256 = $planHash
    spec_sha256 = $specHash
    implementer_evidence_sha256 = $implEvHash
    parent_verification_sha256 = $parentVerHash
    pre_window_manifest_sha256 = $preWinHash
    post_window_manifest_sha256 = $postWinHash
    repository_manifest_sha256 = $preReviewFingerprint
    aggregate_delta_manifest_sha256 = $aggDeltaHash
}

foreach ($bk in $requiredBindingKeys) {
    if ($parsedReviewDoc.RootElement.GetProperty("reviewed_bindings").GetProperty($bk).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "Reviewer binding '$bk' must be string." }
    if ($null -eq $echoedBindings.PSObject.Properties[$bk] -or [string]::IsNullOrWhiteSpace([string]$echoedBindings.$bk)) {
        Fail "Reviewer reviewed_bindings missing mandatory key '$bk'."
    }
    $echoedVal = ([string]$echoedBindings.$bk).Trim()
    if ($echoedVal -notmatch '^[0-9a-f]{64}$') {
        Fail "Reviewer binding '$bk' value '$echoedVal' is not a 64-lowercase-hex string."
    }
    $expectedVal = $expectedBindingMap[$bk]
    if ($echoedVal -ne $expectedVal) {
        Fail "Reviewer binding mismatch for '$bk': '$echoedVal' != '$expectedVal'"
    }
}

# 15. Build and Publish Review Envelope Atomically
$envelope = [ordered]@{
    schema_version = 1
    reviewer = [ordered]@{
        model_requested = if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) { $effectiveModel } else { "inherited" }
        effort_requested = "inherited"
        sandbox_mode_requested = "read-only"
        ephemeral = $true
        exit_code_observed = $exitCode
        repository_unchanged_verified = $true
    }
    review = [ordered]@{
        verdict = $verdict
        reason = $reason
        findings = $findings
        residual_risk = $residualRisk
        reviewed_no_change = $reviewedNoChange
    }
    reviewed_bindings = $echoedBindings
}

$tmpFileName = ".review-tmp." + [System.Guid]::NewGuid().ToString("N") + ".tmp"
$tmpFilePath = [System.IO.Path]::Combine($physicalOutputParent, $tmpFileName)
$tmpCreated = $false

try {
    $envelopeJson = $envelope | ConvertTo-Json -Depth 16
    $stream = [System.IO.FileStream]::new(
        $tmpFilePath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $tmpCreated = $true

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $sb = [System.Text.StringBuilder]::new(1024)
        $res = [SolAdvisorReviewer.Win32Path]::GetFinalPathNameByHandle($stream.SafeFileHandle, $sb, 1024, 0)
        if ($res -eq 0) {
            Fail "Failed to determine final canonical path of created temporary review file handle."
        }
        $finalHandlePath = $sb.ToString()
        if ($finalHandlePath.StartsWith("\\?\UNC\")) {
            $finalHandlePath = "\\" + $finalHandlePath.Substring(8)
        } elseif ($finalHandlePath.StartsWith("\\?\")) {
            $finalHandlePath = $finalHandlePath.Substring(4)
        }
        $expectedParent = $physicalOutputParent.TrimEnd('\', '/')
        $finalParent = [System.IO.Path]::GetDirectoryName($finalHandlePath).TrimEnd('\', '/')
        if ($finalParent -ne $expectedParent) {
            Fail "Adversarial parent path swap detected: created temporary file target '$finalHandlePath' does not reside in validated parent '$expectedParent'."
        }
    }

    $writer = [System.IO.StreamWriter]::new($stream, $utf8NoBom)
    $writer.Write($envelopeJson + "`n")
    $writer.Flush()
    $stream.Flush($true)
    $writer.Dispose()
    $writer = $null
    $stream.Dispose()
    $stream = $null

    if (Test-Path -LiteralPath $ReviewOutputFile) {
        Fail "Review output file already exists (no-clobber): $ReviewOutputFile"
    }

    try {
        [System.IO.File]::Move($tmpFilePath, $ReviewOutputFile)
        $tmpCreated = $false
    } catch [System.IO.IOException] {
        Fail "Review output file already exists or appeared during publishing (no-clobber): $_"
    }
} catch {
    Fail "Could not publish review output file: $_"
} finally {
    if ($tmpCreated -and (Test-Path -LiteralPath $tmpFilePath)) {
        try { [System.IO.File]::Delete($tmpFilePath) } catch {}
    }
}

[Console]::WriteLine("Fresh review completed successfully: verdict = $verdict")
exit 0
