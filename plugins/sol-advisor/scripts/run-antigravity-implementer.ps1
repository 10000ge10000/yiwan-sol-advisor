#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs Google Antigravity CLI as the sole implementation provider for Sol Advisor.
.DESCRIPTION
    Validates workspace as a Git top-level repository, validates spec file (must be absolute,
    outside workspace, without symlinks/reparse points, and follow strict five-part format),
    checks evidence destination (must not exist, outside workspace), resolves agy/agy.exe,
    verifies gemini-3.8-flash-high model availability, and executes agy with pinned flags
    (--sandbox --model gemini-3.8-flash-high --effort high --mode accept-edits --output-format json).
    Writes structured evidence envelope containing execution metadata and parsed agy result to EvidenceFile.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceFile,

    [Parameter(Mandatory = $false)]
    [string]$PrintTimeout = "25m",

    [Parameter(Mandatory = $false)]
    [string]$IdleTimeout = "8m",

    [Parameter(Mandatory = $false)]
    [string]$GenerationPreflightTimeout = "90s",

    [Parameter(Mandatory = $false)]
    [string]$HeartbeatInterval = "30s",

    [Parameter(Mandatory = $false)]
    [switch]$DangerouslySkipPermissions,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGenerationPreflight,

    [Parameter(Mandatory = $false)]
    [switch]$TestMode,

    [Parameter(Mandatory = $false)]
    [string]$TestAgyExe = ""
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine("ERROR: PowerShell 7+ (pwsh) is required; detected PowerShell version $($PSVersionTable.PSVersion)")
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Message, [int]$ExitCode = 1) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $ExitCode
}

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
        Fail "Invalid duration format '$d'. Supported formats: '20m', '600s', '1h', '1h30m'."
    }
    if ($totalSec -le 0) {
        Fail "Duration must be greater than zero: $d"
    }
    return $totalSec
}

$timeoutSec = Parse-Duration $PrintTimeout
$idleTimeoutSec = Parse-Duration $IdleTimeout
$preflightTimeoutSec = Parse-Duration $GenerationPreflightTimeout
$heartbeatIntervalSec = Parse-Duration $HeartbeatInterval
if ($idleTimeoutSec -gt $timeoutSec) {
    $idleTimeoutSec = $timeoutSec
    [Console]::Error.WriteLine("WATCHDOG: IdleTimeout $IdleTimeout was capped to the shorter PrintTimeout $PrintTimeout.")
}
if ($preflightTimeoutSec -ge $timeoutSec) {
    $preflightTimeoutSec = [Math]::Max(1, $timeoutSec - 1)
    [Console]::Error.WriteLine("WATCHDOG: GenerationPreflightTimeout $GenerationPreflightTimeout was capped to ${preflightTimeoutSec}s by PrintTimeout $PrintTimeout.")
}

function Test-IsReparsePoint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    } catch {
        Fail "Failed to inspect reparse point attributes for '$Path': $($_.Exception.Message)"
    }
}

function Assert-NoReparseInAncestors([string]$DirectoryPath, [string]$Label) {
    $curr = $DirectoryPath
    while (-not [string]::IsNullOrEmpty($curr)) {
        if (Test-IsReparsePoint $curr) {
            Fail "$Label or its ancestor is a symbolic link, junction, or reparse point: $curr"
        }
        $parent = [System.IO.Path]::GetDirectoryName($curr)
        if ($parent -eq $curr -or [string]::IsNullOrEmpty($parent)) { break }
        $curr = $parent
    }
}

function Assert-ValidPathSyntax([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail "$Label path cannot be empty."
    }
    if ($Path.StartsWith("\\.\") -or $Path.StartsWith("\\?\") -or $Path.StartsWith("//./") -or $Path.StartsWith("//?/")) {
        Fail "$Label path uses unsupported device namespace syntax: $Path"
    }
    $firstColon = $Path.IndexOf(':')
    if ($firstColon -ge 0) {
        if ($firstColon -ne 1 -or -not ($Path[0] -match '^[A-Za-z]$')) {
            Fail "$Label path contains invalid or alternate-data-stream (ADS) syntax: $Path"
        }
        $secondColon = $Path.IndexOf(':', 2)
        if ($secondColon -ge 0) {
            Fail "$Label path contains alternate-data-stream (ADS) stream specifier: $Path"
        }
    }
    $fileName = [System.IO.Path]::GetFileName($Path)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    if ($baseName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        Fail "$Label path uses reserved DOS device name: $fileName"
    }
}

Assert-ValidPathSyntax $Workspace "Workspace"
Assert-ValidPathSyntax $SpecFile "SpecFile"
Assert-ValidPathSyntax $EvidenceFile "EvidenceFile"

if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    if (-not ([System.Management.Automation.PSTypeName]'SolAdvisorImplementer.Win32Path').Type) {
        Add-Type -TypeDefinition @"
        using System;
        using System.IO;
        using System.Runtime.InteropServices;
        using System.Text;
        using Microsoft.Win32.SafeHandles;

        namespace SolAdvisorImplementer {
            public static class Win32Path {
                private const uint FILE_SHARE_READ = 1;
                private const uint FILE_SHARE_WRITE = 2;
                private const uint FILE_SHARE_DELETE = 4;
                private const uint OPEN_EXISTING = 3;
                private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

                [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                public static extern SafeFileHandle CreateFile(
                    string lpFileName,
                    uint dwDesiredAccess,
                    uint dwShareMode,
                    IntPtr lpSecurityAttributes,
                    uint dwCreationDisposition,
                    uint dwFlagsAndAttributes,
                    IntPtr hTemplateFile
                );

                [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                public static extern uint GetFinalPathNameByHandle(
                    SafeFileHandle hFile,
                    StringBuilder lpszFilePath,
                    uint cchFilePath,
                    uint dwFlags
                );

                public static string GetPhysicalPath(string path) {
                    if (string.IsNullOrEmpty(path)) return path;
                    using (SafeFileHandle handle = CreateFile(
                        path,
                        0,
                        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        IntPtr.Zero,
                        OPEN_EXISTING,
                        FILE_FLAG_BACKUP_SEMANTICS,
                        IntPtr.Zero
                    )) {
                        if (handle.IsInvalid) {
                            throw new IOException("Unable to open handle for path: " + path + " (Win32 error " + Marshal.GetLastWin32Error() + ")");
                        }
                        StringBuilder sb = new StringBuilder(1024);
                        uint res = GetFinalPathNameByHandle(handle, sb, 1024, 0);
                        if (res == 0) {
                            throw new IOException("GetFinalPathNameByHandle failed for path: " + path + " (Win32 error " + Marshal.GetLastWin32Error() + ")");
                        }
                        string result = sb.ToString();
                        if (result.StartsWith(@"\\?\UNC\")) {
                            result = @"\\" + result.Substring(8);
                        } else if (result.StartsWith(@"\\?\")) {
                            result = result.Substring(4);
                        }
                        return result;
                    }
                }
            }
        }
"@
    }
}

function Get-PhysicalDirectoryPath([string]$Path) {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return [SolAdvisorImplementer.Win32Path]::GetPhysicalPath($Path)
    } else {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

# 1. Resolve and validate Workspace
if (-not [System.IO.Path]::IsPathRooted($Workspace)) {
    Fail "Workspace path must be absolute: $Workspace"
}

try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
} catch {
    Fail "Workspace path does not exist: $Workspace"
}

if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
    Fail "Workspace is not a directory: $resolvedWorkspace"
}

Assert-NoReparseInAncestors $resolvedWorkspace "Workspace directory"
$physicalWorkspace = Get-PhysicalDirectoryPath $resolvedWorkspace

# Verify Git repository top-level directory
try {
    $gitRoot = (git -C $resolvedWorkspace rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
        Fail "Workspace is not a Git repository: $resolvedWorkspace"
    }
} catch {
    Fail "Workspace is not a Git repository: $resolvedWorkspace"
}

$resolvedGitRoot = (Resolve-Path -LiteralPath $gitRoot.Trim() -ErrorAction Stop).Path
$physicalGitRoot = Get-PhysicalDirectoryPath $resolvedGitRoot

if ($physicalGitRoot.TrimEnd('\', '/') -ne $physicalWorkspace.TrimEnd('\', '/')) {
    Fail "Workspace must be the Git top-level directory: expected '$physicalGitRoot', got '$physicalWorkspace'"
}

$physicalWsPrefix = $physicalWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

# 2. Resolve and validate SpecFile (must be absolute, leaf file, outside workspace, no symlink/reparse ancestors)
if (-not [System.IO.Path]::IsPathRooted($SpecFile)) {
    Fail "SpecFile path must be absolute: $SpecFile"
}

try {
    $resolvedSpecFile = (Resolve-Path -LiteralPath $SpecFile -ErrorAction Stop).Path
} catch {
    Fail "Spec file does not exist: $SpecFile"
}

if (-not (Test-Path -LiteralPath $resolvedSpecFile -PathType Leaf)) {
    Fail "Spec file is not a regular file: $resolvedSpecFile"
}

$specParentDir = [System.IO.Path]::GetDirectoryName($resolvedSpecFile)
Assert-NoReparseInAncestors $specParentDir "Spec file parent directory"
if (Test-IsReparsePoint $resolvedSpecFile) {
    Fail "Spec file is a symbolic link, junction, or reparse point: $resolvedSpecFile"
}

$physicalSpecDir = Get-PhysicalDirectoryPath $specParentDir
$physicalSpecFile = [System.IO.Path]::Combine($physicalSpecDir, [System.IO.Path]::GetFileName($resolvedSpecFile))

if ($physicalSpecDir.StartsWith($physicalWsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalSpecDir.Equals($physicalWorkspace, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalSpecFile.StartsWith($physicalWsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalSpecFile.Equals($physicalWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Spec file cannot be inside target workspace ($physicalSpecFile is inside $physicalWorkspace)."
}

$specFileItem = Get-Item -LiteralPath $resolvedSpecFile -ErrorAction Stop
if ($specFileItem.Length -gt 24576) {
    Fail "Spec file exceeds maximum allowed size of 24 KiB ($($specFileItem.Length) bytes)."
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    $specContent = [System.IO.File]::ReadAllText($resolvedSpecFile, $utf8NoBom)
} catch {
    Fail "Could not read spec file: $_"
}

if ([string]::IsNullOrWhiteSpace($specContent)) {
    Fail "Spec file is empty: $resolvedSpecFile"
}

# Validate five-part specification structure (OBJECTIVE, FILES AND OWNERSHIP, INTERFACES, CONSTRAINTS, VERIFICATION)
$requiredSections = @(
    "OBJECTIVE",
    "FILES AND OWNERSHIP",
    "INTERFACES",
    "CONSTRAINTS",
    "VERIFICATION"
)

$headingRegex = '^(?:#{1,6}\s+)?(OBJECTIVE|FILES AND OWNERSHIP|INTERFACES|CONSTRAINTS|VERIFICATION)\s*$'
$foundHeadings = [System.Collections.Generic.List[string]]::new()
$sectionContents = @{}
foreach ($sec in $requiredSections) {
    $sectionContents[$sec] = [System.Collections.Generic.List[string]]::new()
}
$currentSection = $null

$specLines = $specContent -split "`r?`n"
foreach ($line in $specLines) {
    $trimmed = $line.Trim()
    if ($trimmed -match $headingRegex) {
        $headingRaw = $Matches[1].ToUpperInvariant()
        $canonical = $null
        foreach ($sec in $requiredSections) {
            if ($headingRaw -eq $sec) {
                $canonical = $sec
                break
            }
        }
        if ($canonical) {
            $foundHeadings.Add($canonical)
            $currentSection = $canonical
        }
    } elseif ($null -ne $currentSection) {
        $sectionContents[$currentSection].Add($line)
    }
}

$foundArray = $foundHeadings.ToArray()
if ($foundArray.Length -ne $requiredSections.Length -or ($foundArray -join ",") -ne ($requiredSections -join ",")) {
    $duplicates = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($sec in $requiredSections) {
        $cnt = 0
        foreach ($h in $foundHeadings) {
            if ($h -eq $sec) { $cnt++ }
        }
        if ($cnt -gt 1) { $duplicates.Add($sec) }
        if ($cnt -eq 0) { $missing.Add($sec) }
    }
    if ($duplicates.Count -gt 0) {
        Fail "Spec file contains duplicate section heading(s): $($duplicates -join ', ')"
    }
    if ($missing.Count -gt 0) {
        Fail "Spec file is missing mandatory five-part section(s): $($missing -join ', ')"
    }
    Fail "Spec file sections are out of order. Expected: $($requiredSections -join ', '); Found: $($foundArray -join ', ')"
}

foreach ($sec in $requiredSections) {
    $secText = ($sectionContents[$sec] -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($secText)) {
        Fail "Spec file section '$sec' is empty."
    }
}

# Extract exact owned paths for worktree-progress observation. The launcher is the
# authority for ownership enforcement; this list is used only by the idle watchdog.
$ownedFileList = [System.Collections.Generic.List[string]]::new()
foreach ($line in $sectionContents["FILES AND OWNERSHIP"]) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^[-*]\s+(.+)$') {
        $candidate = $Matches[1].Trim('`', ' ', '"', "'")
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            -not [System.IO.Path]::IsPathRooted($candidate) -and
            -not $candidate.Contains('..') -and
            -not $candidate.Contains(':')) {
            $ownedFileList.Add($candidate.Replace('\', '/'))
        }
    }
}
if ($ownedFileList.Count -eq 0) {
    Fail "Spec file FILES AND OWNERSHIP section contains no valid relative owned paths."
}
if ($ownedFileList.Count -gt 12) {
    Fail "Spec file declares $($ownedFileList.Count) owned paths; the bounded implementation window permits at most 12."
}

# 3. Resolve and validate EvidenceFile
if (-not [System.IO.Path]::IsPathRooted($EvidenceFile)) {
    Fail "Evidence file path must be absolute: $EvidenceFile"
}

if (Test-Path -LiteralPath $EvidenceFile) {
    Fail "Evidence destination already exists: $EvidenceFile. Evidence destination must not exist before execution."
}
if (Test-IsReparsePoint $EvidenceFile) {
    Fail "Evidence file destination is a symbolic link, junction, or reparse point: $EvidenceFile"
}

$evidenceParentDir = [System.IO.Path]::GetDirectoryName($EvidenceFile)
if ([string]::IsNullOrWhiteSpace($evidenceParentDir) -or -not (Test-Path -LiteralPath $evidenceParentDir -PathType Container)) {
    Fail "Evidence parent directory does not exist or is not a directory: $evidenceParentDir. Evidence parent directory must already exist."
}

Assert-NoReparseInAncestors $evidenceParentDir "Evidence parent directory"

$canonicalParent = (Resolve-Path -LiteralPath $evidenceParentDir -ErrorAction Stop).Path
$physicalParent = Get-PhysicalDirectoryPath $canonicalParent

if ($physicalParent.StartsWith($physicalWsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalParent.Equals($physicalWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Evidence parent directory is inside the physical target workspace ($physicalParent is inside $physicalWorkspace)."
}

$resolvedEvidenceFile = [System.IO.Path]::Combine($canonicalParent, [System.IO.Path]::GetFileName($EvidenceFile))
$physicalEvidenceFile = [System.IO.Path]::Combine($physicalParent, [System.IO.Path]::GetFileName($EvidenceFile))
if ($physicalEvidenceFile.StartsWith($physicalWsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalEvidenceFile.Equals($physicalWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Evidence file cannot be inside the target workspace ($physicalEvidenceFile is inside $physicalWorkspace). Do not contaminate the target diff with evidence."
}

# 4. Resolve agy / agy.exe
$agyExe = $null
$effectiveTestMode = $TestMode.IsPresent -or ($env:_SOL_ADVISOR_TEST_MODE -eq "1") -or ($env:_MY_SOL_ADVISOR_TEST_MODE -eq "1")

if (-not [string]::IsNullOrWhiteSpace($TestAgyExe)) {
    if (-not $effectiveTestMode) {
        Fail "Test executable argument (-TestAgyExe) specified without -TestMode switch."
    }
    if (-not (Test-Path -LiteralPath $TestAgyExe -PathType Leaf)) {
        Fail "Test executable specified in -TestAgyExe does not exist: $TestAgyExe"
    }
    $agyExe = (Resolve-Path -LiteralPath $TestAgyExe -ErrorAction Stop).Path
} else {
    $testOverrideCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($tc in @($env:_MY_SOL_ADVISOR_TEST_AGY_EXE, $env:_MY_SOL_ADVISOR_TEST_AGY_BIN, $env:_SOL_ADVISOR_TEST_AGY_EXE, $env:_SOL_ADVISOR_TEST_AGY_BIN)) {
        if (-not [string]::IsNullOrWhiteSpace($tc)) { $testOverrideCandidates.Add($tc) }
    }

    if ($testOverrideCandidates.Count -gt 0) {
        if (-not $effectiveTestMode) {
            Fail "Test executable override variable specified without explicit test mode switch (-TestMode)."
        }
        $testPath = $testOverrideCandidates[0]
        if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
            Fail "Test executable override does not exist or is not a file: $testPath"
        }
        $agyExe = (Resolve-Path -LiteralPath $testPath -ErrorAction Stop).Path
    }
}

if ($null -eq $agyExe) {
    $onWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    if ($onWindowsHost) {
        $agyCmd = Get-Command "agy.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $agyCmd) {
            $shimCmd = Get-Command "agy.cmd", "agy.bat" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($shimCmd) {
                Fail "Antigravity CLI command shim ('$($shimCmd.Source)') is not supported on Windows. A native Antigravity executable ('agy.exe') is required."
            }
            $fallbackCmd = Get-Command "agy" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($fallbackCmd) {
                $ext = [System.IO.Path]::GetExtension($fallbackCmd.Source).ToLowerInvariant()
                if ($ext -in @(".cmd", ".bat")) {
                    Fail "Antigravity CLI command shim ('$($fallbackCmd.Source)') is not supported on Windows. A native Antigravity executable ('agy.exe') is required."
                }
                $agyExe = $fallbackCmd.Source
            } else {
                Fail "Antigravity CLI executable ('agy.exe') not found in PATH."
            }
        } else {
            $agyExe = $agyCmd.Source
        }
    } else {
        $agyCmd = Get-Command "agy", "agy.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $agyCmd) {
            Fail "Antigravity CLI executable ('agy') not found in PATH."
        }
        $agyExe = $agyCmd.Source
    }
}

$agyExt = [System.IO.Path]::GetExtension($agyExe).ToLowerInvariant()
if ($agyExt -in @(".cmd", ".bat")) {
    Fail "Antigravity CLI command shim ('$agyExe') is not supported. A native Antigravity executable ('agy.exe') is required."
}

if (-not $effectiveTestMode) {
    $agySettingsPath = Join-Path $env:USERPROFILE ".gemini\antigravity-cli\settings.json"
    if (-not (Test-Path -LiteralPath $agySettingsPath -PathType Leaf)) {
        Fail "Antigravity sandbox automation is not configured. Run setup-yiwan-sol-advisor.ps1 first."
    }
    try {
        $agySettings = Get-Content -LiteralPath $agySettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Fail "Antigravity settings are invalid JSON: $agySettingsPath. Run setup-yiwan-sol-advisor.ps1 after fixing the file."
    }
    if ($agySettings['toolPermission'] -ne "proceed-in-sandbox" -or $agySettings['enableTerminalSandbox'] -ne $true) {
        Fail "Antigravity must use toolPermission=proceed-in-sandbox and enableTerminalSandbox=true. Run setup-yiwan-sol-advisor.ps1."
    }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-RemainingTimeoutMs() {
    $remSec = $timeoutSec - $sw.Elapsed.TotalSeconds
    if ($remSec -le 0) {
        Fail "Antigravity CLI execution exceeded timeout of $PrintTimeout ($timeoutSec seconds)."
    }
    return [int]($remSec * 1000)
}

function New-AgyProcessStartInfo(
    [string[]]$Arguments,
    [string]$WorkingDirectory = $null
) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $agyExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
        $existingCount = 0
        if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_COUNT)) {
            if (-not [int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$existingCount) -or $existingCount -lt 0 -or $existingCount -gt 100) {
                Fail "Inherited GIT_CONFIG_COUNT is invalid or unreasonably large."
            }
        }
        $psi.Environment["GIT_CONFIG_COUNT"] = ($existingCount + 1).ToString([Globalization.CultureInfo]::InvariantCulture)
        $psi.Environment["GIT_CONFIG_KEY_$existingCount"] = "safe.directory"
        $psi.Environment["GIT_CONFIG_VALUE_$existingCount"] = $physicalWorkspace
    }
    foreach ($arg in $Arguments) {
        $psi.ArgumentList.Add($arg)
    }
    return $psi
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

function Get-ProcessTreeCpuMs([int]$RootPid) {
    if ($RootPid -le 0) { return [long]0 }
    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            $all = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,KernelModeTime,UserModeTime -ErrorAction Stop)
            $ids = [System.Collections.Generic.HashSet[int]]::new()
            [void]$ids.Add($RootPid)
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($entry in $all) {
                    if ($ids.Contains([int]$entry.ParentProcessId) -and $ids.Add([int]$entry.ProcessId)) { $changed = $true }
                }
            }
            [long]$ticks100ns = 0
            foreach ($entry in $all) {
                if ($ids.Contains([int]$entry.ProcessId)) {
                    $ticks100ns += [long]$entry.KernelModeTime + [long]$entry.UserModeTime
                }
            }
            return [long]($ticks100ns / 10000)
        }
        return [long]([System.Diagnostics.Process]::GetProcessById($RootPid).TotalProcessorTime.TotalMilliseconds)
    } catch {
        return [long]0
    }
}

function Get-OwnedWorktreeFingerprint {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($owned in $ownedFileList) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $physicalWorkspace $owned))
        if (-not (Test-Path -LiteralPath $full)) {
            $parts.Add("$owned|missing")
            continue
        }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $parts.Add("$owned|unreadable")
        } elseif (-not $item.PSIsContainer) {
            $parts.Add("$owned|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)")
        } else {
            $count = 0
            [long]$totalLength = 0
            [long]$latestTicks = $item.LastWriteTimeUtc.Ticks
            foreach ($child in Get-ChildItem -LiteralPath $full -File -Recurse -Force -ErrorAction SilentlyContinue) {
                $count++
                $totalLength += [long]$child.Length
                if ($child.LastWriteTimeUtc.Ticks -gt $latestTicks) { $latestTicks = $child.LastWriteTimeUtc.Ticks }
                if ($count -ge 5000) { break }
            }
            $parts.Add("$owned|dir|$count|$totalLength|$latestTicks")
        }
    }
    return ($parts -join ';')
}

function Emit-Heartbeat([int]$ElapsedSeconds, [int]$IdleSeconds, [string]$ActivityKind) {
    $heartbeat = [ordered]@{
        event = "SOL_ADVISOR_HEARTBEAT"
        stage = "antigravity-implementer"
        elapsed_seconds = $ElapsedSeconds
        hard_timeout_seconds = $timeoutSec
        idle_timeout_seconds = $idleTimeoutSec
        idle_seconds = $IdleSeconds
        last_activity_kind = $ActivityKind
    } | ConvertTo-Json -Compress
    [Console]::Error.WriteLine($heartbeat)
}

function Emit-Failure([string]$Reason) {
    $failure = [ordered]@{
        event = "SOL_ADVISOR_FAILURE"
        stage = "antigravity-implementer"
        reason = $Reason
        completed = $false
        reviewed = $false
        partial_worktree_trusted = $false
        worktree_preserved = $true
    } | ConvertTo-Json -Compress
    [Console]::Error.WriteLine($failure)
}

# 5. Query agy models for exact model slug gemini-3.8-flash-high
$modelsPsi = New-AgyProcessStartInfo -Arguments @("models")

try {
    $modelsProc = [System.Diagnostics.Process]::Start($modelsPsi)
    $modelsOutTask = $modelsProc.StandardOutput.ReadToEndAsync()
    $modelsErrTask = $modelsProc.StandardError.ReadToEndAsync()
    $remModelsMs = Get-RemainingTimeoutMs
    if (-not $modelsProc.WaitForExit($remModelsMs)) {
        try { $modelsProc.Kill($true) } catch {}
        Fail "Timed out while querying agy models."
    }
    [System.Threading.Tasks.Task]::WaitAll($modelsOutTask, $modelsErrTask)
    $modelsOut = $modelsOutTask.Result
    $modelsErr = $modelsErrTask.Result
} catch {
    Fail "Failed to query agy models: $_"
}

if ($modelsProc.ExitCode -ne 0) {
    Fail "Failed to query agy models (exit code $($modelsProc.ExitCode)): $modelsErr"
}

$hasModel = $false
foreach ($line in ($modelsOut -split "`r?`n")) {
    $slug = ($line -split "`t| ")[0].Trim()
    if ($slug -eq "gemini-3.8-flash-high") {
        $hasModel = $true
        break
    }
}
if (-not $hasModel) {
    Fail "Required model 'gemini-3.8-flash-high' was not found in 'agy models' output."
}

# 6. Query agy CLI version
$verPsi = New-AgyProcessStartInfo -Arguments @("--version")

$cliVersion = ""
try {
    $verProc = [System.Diagnostics.Process]::Start($verPsi)
    $verOutTask = $verProc.StandardOutput.ReadToEndAsync()
    $verErrTask = $verProc.StandardError.ReadToEndAsync()
    $remVerMs = Get-RemainingTimeoutMs
    if ($verProc.WaitForExit($remVerMs)) {
        [System.Threading.Tasks.Task]::WaitAll($verOutTask, $verErrTask)
        if ($verProc.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($verOutTask.Result)) {
            $cliVersion = $verOutTask.Result.Trim()
        } else {
            Fail "Failed to query Antigravity CLI version via 'agy --version' (exit code $($verProc.ExitCode)): $($verErrTask.Result)"
        }
    } else {
        try { $verProc.Kill($true) } catch {}
        Fail "Timed out while querying agy --version."
    }
} catch {
    Fail "Failed to query agy --version: $_"
}

if ([string]::IsNullOrWhiteSpace($cliVersion)) {
    Fail "Failed to query Antigravity CLI version via 'agy --version'."
}

# 7. Verify that the pinned model can actually generate before opening a writer
# window in the target repository. Model catalog presence alone is insufficient.
if ($SkipGenerationPreflight) {
    [Console]::Error.WriteLine("[run-antigravity-implementer] Skipping disposable generation preflight as requested (already verified or subsequent iteration).")
} else {
    $preflightNonce = "sol-advisor-generation-preflight-" + [System.Guid]::NewGuid().ToString("N")
    $preflightDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sol-advisor-preflight-" + [System.Guid]::NewGuid().ToString("N"))
    $preflightProc = $null
    try {
        [System.IO.Directory]::CreateDirectory($preflightDir) | Out-Null
        $preflightPrompt = "Return only one JSON object with status=ok and nonce=$preflightNonce. Do not create or modify files."
        $preflightArgs = @(
            "--sandbox",
            "--model", "gemini-3.8-flash-high",
            "--effort", "high",
            "--mode", "accept-edits",
            "--output-format", "json",
            "--print-timeout", "${preflightTimeoutSec}s",
            "--dangerously-skip-permissions",
            "--print", $preflightPrompt
        )
        $preflightPsi = New-AgyProcessStartInfo -Arguments $preflightArgs -WorkingDirectory $preflightDir
        $preflightProc = [System.Diagnostics.Process]::Start($preflightPsi)
        if ($null -eq $preflightProc) { Fail "Failed to start Antigravity generation preflight." }
        $preflightOutTask = $preflightProc.StandardOutput.ReadToEndAsync()
        $preflightErrTask = $preflightProc.StandardError.ReadToEndAsync()
        $preflightBudgetMs = [Math]::Min($preflightTimeoutSec * 1000, (Get-RemainingTimeoutMs))
        if (-not $preflightProc.WaitForExit($preflightBudgetMs)) {
            Stop-ProcessTree $preflightProc
            Fail "Antigravity generation preflight timed out after ${preflightTimeoutSec}s. Refusing to enter the implementation window."
        }
        [System.Threading.Tasks.Task]::WaitAll($preflightOutTask, $preflightErrTask)
        $preflightOut = $preflightOutTask.Result
        $preflightErr = $preflightErrTask.Result
        if ($preflightProc.ExitCode -ne 0) {
            Fail "Antigravity generation preflight failed with exit code $($preflightProc.ExitCode): $preflightErr"
        }
        try {
            $preflightJson = $preflightOut | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Fail "Antigravity generation preflight did not return valid JSON: $($_.Exception.Message)"
        }
        if (-not $preflightOut.Contains($preflightNonce)) {
            Fail "Antigravity generation preflight response did not echo its nonce. Refusing to enter the implementation window."
        }
    } finally {
        if ($null -ne $preflightProc -and -not $preflightProc.HasExited) { Stop-ProcessTree $preflightProc }
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $resolvedPreflight = [System.IO.Path]::GetFullPath($preflightDir)
        if ($resolvedPreflight.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            [System.IO.Path]::GetFileName($resolvedPreflight).StartsWith('sol-advisor-preflight-', [System.StringComparison]::Ordinal)) {
            try { if ([System.IO.Directory]::Exists($resolvedPreflight)) { [System.IO.Directory]::Delete($resolvedPreflight, $true) } } catch {}
        }
    }
}

# 8. Compose Prompt
$promptHeader = @"
ROLE CONTRACT:
You are the sole implementation provider (Google Antigravity CLI).
Sol (GPT-5.6 Sol using the user's current reasoning effort) is the architect and planner.
Do not redesign or redo architecture; stay within the owned files and follow the five-part specification below.
Execute the implementation, perform verification, and return a structured report including: status, files changed, commands, verification outputs, warnings, and blockers.
Never run git config --global or git config --system. The wrapper supplies repository trust only to this subprocess.

STRUCTURED IMPLEMENTATION REPORT CONTRACT:
Your final response must provide a structured implementation report with the following fields:
STATUS: complete | partial | blocked
OBJECTIVE: <restatement of objective>
CHANGES: <file-by-file summary of changes made>
VERIFIED: <exact verification commands run, exit codes, and output evidence>
JUDGMENT CALLS: <material decisions made or none>
GAPS: <remaining gaps or none>

SPECIFICATION:
"@
$fullPrompt = "$promptHeader`n$specContent"

# 8. Permission mode handling
# Sandbox invariants: --new-project, --sandbox, sandboxed-dangerously-skip-permissions
$permModeStr = if ($DangerouslySkipPermissions.IsPresent) {
    "dangerously-skip-permissions"
} else {
    "standard"
}
if ($DangerouslySkipPermissions.IsPresent) {
    [Console]::Error.WriteLine("PERMISSION MODE: DangerouslySkipPermissions enabled for workspace $physicalWorkspace")
}

# 9. Run agy with a hard stage cap, an independent idle watchdog, and live
# stderr heartbeats. Stdout stays private because it is the signed JSON result.
$mainArgs = [System.Collections.Generic.List[string]]::new()
$mainArgs.Add("--model")
$mainArgs.Add("gemini-3.8-flash-high")
$mainArgs.Add("--effort")
$mainArgs.Add("high")
$mainArgs.Add("--mode")
$mainArgs.Add("accept-edits")
$mainArgs.Add("--output-format")
$mainArgs.Add("json")
$mainArgs.Add("--print-timeout")
$mainArgs.Add($PrintTimeout)
if ($DangerouslySkipPermissions.IsPresent) {
    $mainArgs.Add("--dangerously-skip-permissions")
}
$mainArgs.Add("--print")
$mainArgs.Add($fullPrompt)

$psi = New-AgyProcessStartInfo -Arguments $mainArgs -WorkingDirectory $physicalWorkspace

$startedAtUtc = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$stdoutBuilder = [System.Text.StringBuilder]::new()
$stderrBuilder = [System.Text.StringBuilder]::new()
$lastActivityUtc = [System.DateTime]::UtcNow
$lastActivityKind = "startup"
$lastFingerprint = Get-OwnedWorktreeFingerprint
$lastCpuMs = [long]0
$lastProbeElapsed = -2
$lastHeartbeatElapsed = -$heartbeatIntervalSec
$failureReason = ""
$proc = $null

try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) { throw "Failed to start Antigravity CLI process." }
    $lastCpuMs = Get-ProcessTreeCpuMs $proc.Id
    $stdoutClosed = $false
    $stderrClosed = $false
    $stdoutLineTask = $proc.StandardOutput.ReadLineAsync()
    $stderrLineTask = $proc.StandardError.ReadLineAsync()

    while (-not $proc.HasExited -or -not $stdoutClosed -or -not $stderrClosed) {
        if (-not $stdoutClosed -and $stdoutLineTask.IsCompleted) {
            $line = $stdoutLineTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $stdoutClosed = $true
            } else {
                [void]$stdoutBuilder.AppendLine($line)
                $lastActivityUtc = [System.DateTime]::UtcNow
                $lastActivityKind = "stdout"
                $stdoutLineTask = $proc.StandardOutput.ReadLineAsync()
            }
        }
        if (-not $stderrClosed -and $stderrLineTask.IsCompleted) {
            $line = $stderrLineTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $stderrClosed = $true
            } else {
                [void]$stderrBuilder.AppendLine($line)
                [Console]::Error.WriteLine($line)
                $lastActivityUtc = [System.DateTime]::UtcNow
                $lastActivityKind = "stderr"
                $stderrLineTask = $proc.StandardError.ReadLineAsync()
            }
        }

        if ($stdoutBuilder.Length -gt 4194304 -or $stderrBuilder.Length -gt 4194304) {
            $failureReason = "Antigravity CLI output exceeded the 4 MiB per-stream safety limit."
            break
        }

        $elapsedSec = [int][Math]::Floor($sw.Elapsed.TotalSeconds)
        if ($elapsedSec -ge $timeoutSec) {
            $failureReason = "Antigravity implementation hard timeout of ${timeoutSec}s exceeded."
            break
        }

        if (($elapsedSec - $lastProbeElapsed) -ge 2 -and -not $proc.HasExited) {
            $lastProbeElapsed = $elapsedSec
            $fingerprint = Get-OwnedWorktreeFingerprint
            if ($fingerprint -ne $lastFingerprint) {
                $lastFingerprint = $fingerprint
                $lastActivityUtc = [System.DateTime]::UtcNow
                $lastActivityKind = "owned-worktree"
            }
            $cpuMs = Get-ProcessTreeCpuMs $proc.Id
            if ($cpuMs -ge ($lastCpuMs + 100)) {
                $lastCpuMs = $cpuMs
                $lastActivityUtc = [System.DateTime]::UtcNow
                $lastActivityKind = "process-cpu"
            }
        }

        $idleSec = [int][Math]::Floor(([System.DateTime]::UtcNow - $lastActivityUtc).TotalSeconds)
        if ($idleSec -ge $idleTimeoutSec -and -not $proc.HasExited) {
            $failureReason = "Antigravity implementation idle timeout of ${idleTimeoutSec}s exceeded; no stdout, stderr, owned-worktree, or process CPU progress was observed."
            break
        }
        if (($elapsedSec - $lastHeartbeatElapsed) -ge $heartbeatIntervalSec -and -not $proc.HasExited) {
            $lastHeartbeatElapsed = $elapsedSec
            Emit-Heartbeat $elapsedSec $idleSec $lastActivityKind
        }

        if (-not $proc.HasExited -or -not $stdoutClosed -or -not $stderrClosed) { Start-Sleep -Milliseconds 100 }
    }

    if (-not [string]::IsNullOrWhiteSpace($failureReason)) {
        Stop-ProcessTree $proc
        Emit-Failure $failureReason
        Fail $failureReason
    }
    [void]$proc.WaitForExit(3000)
    $stdout = $stdoutBuilder.ToString()
    $stderr = $stderrBuilder.ToString()
    $exitCode = $proc.ExitCode
} catch {
    if ($null -ne $proc -and -not $proc.HasExited) { Stop-ProcessTree $proc }
    $reason = "Failed to execute Antigravity CLI: $($_.Exception.Message)"
    Emit-Failure $reason
    Fail $reason
}

$endedAtUtc = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$durationMs = [int]$sw.ElapsedMilliseconds

if ($exitCode -ne 0) {
    $detail = "exit code $exitCode"
    try {
        $failureJson = $stdout | ConvertFrom-Json -ErrorAction Stop
        $remoteStatus = if ($null -ne $failureJson.PSObject.Properties['status']) { [string]$failureJson.status } else { "unknown" }
        $remoteError = if ($null -ne $failureJson.PSObject.Properties['error']) { [string]$failureJson.error } else { "" }
        if ($remoteError.Length -gt 512) { $remoteError = $remoteError.Substring(0, 512) }
        $remoteError = $remoteError -replace '[\r\n\t]+', ' '
        $detail = "exit code $exitCode, status=$remoteStatus"
        if (-not [string]::IsNullOrWhiteSpace($remoteError)) { $detail += ", error=$remoteError" }
    } catch {}
    $reason = "Antigravity CLI failed before a valid implementation report was produced ($detail)."
    Emit-Failure $reason
    Fail $reason
}

# Bound stdout and stderr stream size (4 MiB)
if ($stdout.Length -gt 4194304 -or $stderr.Length -gt 4194304) {
    Fail "Antigravity CLI output exceeded 4 MiB stream limit."
}

# 10. Validate JSON output
if ([string]::IsNullOrWhiteSpace($stdout)) {
    Fail "Antigravity CLI produced empty output."
}

try {
    $jsonDoc = [System.Text.Json.JsonDocument]::Parse($stdout)
} catch {
    Fail "Antigravity stdout is not valid JSON evidence: $_"
}

if ($jsonDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
    Fail "Antigravity stdout JSON must be a single JSON object (observed $($jsonDoc.RootElement.ValueKind))."
}

try {
    $parsedJson = $stdout | ConvertFrom-Json
} catch {
    Fail "Antigravity stdout is not valid JSON evidence: $_"
}

if ($null -eq $parsedJson -or -not ($parsedJson -is [System.Management.Automation.PSCustomObject] -or $parsedJson -is [System.Collections.IDictionary])) {
    Fail "Antigravity stdout JSON must be a single JSON object."
}

# 11. Check dynamic fields in parsedJson if present
$modelFieldObserved = $null -ne ($parsedJson.PSObject.Properties['model'])
$effortFieldObserved = ($null -ne ($parsedJson.PSObject.Properties['effort'])) -or ($null -ne ($parsedJson.PSObject.Properties['model_reasoning_effort']))
$modeFieldObserved = $null -ne ($parsedJson.PSObject.Properties['mode'])
$cwdFieldObserved = ($null -ne ($parsedJson.PSObject.Properties['cwd'])) -or ($null -ne ($parsedJson.PSObject.Properties['working_directory']))

if ($modelFieldObserved -and $parsedJson.model -ne "gemini-3.8-flash-high") {
    Fail "Observed agy_result model '$($parsedJson.model)' does not match requested pin 'gemini-3.8-flash-high'"
}
if (($null -ne $parsedJson.PSObject.Properties['effort']) -and $parsedJson.effort -ne "high") {
    Fail "Observed agy_result effort '$($parsedJson.effort)' does not match requested pin 'high'"
}
if (($null -ne $parsedJson.PSObject.Properties['model_reasoning_effort']) -and $parsedJson.model_reasoning_effort -ne "high") {
    Fail "Observed agy_result model_reasoning_effort '$($parsedJson.model_reasoning_effort)' does not match requested pin 'high'"
}
if ($modeFieldObserved -and $parsedJson.mode -ne "accept-edits") {
    Fail "Observed agy_result mode '$($parsedJson.mode)' does not match requested pin 'accept-edits'"
}
if ($null -ne $parsedJson.PSObject.Properties['cwd']) {
    $obsCwd = [System.IO.Path]::GetFullPath($parsedJson.cwd).TrimEnd('\', '/')
    if ($obsCwd -ne $physicalWorkspace.TrimEnd('\', '/')) {
        Fail "Observed agy_result cwd '$($parsedJson.cwd)' does not match expected physical workspace '$physicalWorkspace'"
    }
}
if ($null -ne $parsedJson.PSObject.Properties['working_directory']) {
    $obsCwd = [System.IO.Path]::GetFullPath($parsedJson.working_directory).TrimEnd('\', '/')
    if ($obsCwd -ne $physicalWorkspace.TrimEnd('\', '/')) {
        Fail "Observed agy_result working_directory '$($parsedJson.working_directory)' does not match expected physical workspace '$physicalWorkspace'"
    }
}

# 12. Validate agy_result response contract (STATUS, OBJECTIVE, CHANGES, VERIFIED, JUDGMENT CALLS, GAPS)
$reportStatus = $null
$reportObjective = $null
$reportChanges = $null
$reportVerified = $null
$reportJudgment = $null
$reportGaps = $null

if ($null -ne $parsedJson.PSObject.Properties['report'] -and ($parsedJson.report -is [System.Management.Automation.PSCustomObject] -or $parsedJson.report -is [System.Collections.IDictionary])) {
    $rep = $parsedJson.report
    if ($null -ne $rep.PSObject.Properties['status']) { $reportStatus = [string]$rep.status }
    if ($null -ne $rep.PSObject.Properties['report_status']) { $reportStatus = [string]$rep.report_status }
    if ($null -ne $rep.PSObject.Properties['objective']) { $reportObjective = [string]$rep.objective }
    if ($null -ne $rep.PSObject.Properties['report_objective']) { $reportObjective = [string]$rep.report_objective }
    if ($null -ne $rep.PSObject.Properties['changes']) { $reportChanges = [string]$rep.changes }
    elseif ($null -ne $rep.PSObject.Properties['changes_made']) { $reportChanges = [string]$rep.changes_made }
    if ($null -ne $rep.PSObject.Properties['verified']) { $reportVerified = [string]$rep.verified }
    if ($null -ne $rep.PSObject.Properties['judgment_calls']) { $reportJudgment = [string]$rep.judgment_calls }
    elseif ($null -ne $rep.PSObject.Properties['judgment']) { $reportJudgment = [string]$rep.judgment }
    if ($null -ne $rep.PSObject.Properties['gaps']) { $reportGaps = [string]$rep.gaps }
}

if ($null -ne $parsedJson.PSObject.Properties['report_status']) { $reportStatus = [string]$parsedJson.report_status }
if ($null -ne $parsedJson.PSObject.Properties['report_objective']) { $reportObjective = [string]$parsedJson.report_objective }

$respText = ""
foreach ($fName in @("response", "content", "text", "output", "result", "message")) {
    if ($null -ne $parsedJson.PSObject.Properties[$fName] -and -not [string]::IsNullOrWhiteSpace([string]$parsedJson.$fName)) {
        $respText = [string]$parsedJson.$fName
        break
    }
}

if (-not [string]::IsNullOrWhiteSpace($respText)) {
    # Normalize markdown bold, headers, bullets, and numbers around standard keys
    # Matches keys whether colon is inside or outside asterisks: **STATUS:**, **STATUS**:, ### STATUS:, - **STATUS:**, etc.
    $keyPattern = '(?im)^[ \t]*(?:(?:[-*+]|\d+\.)[ \t]+)?(?:#{1,6}[ \t]*)?(?:\*\*|__)?(STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|JUDGMENT_CALLS|JUDGMENT|GAPS)(?:\*\*|__)?(?:\s*:\s*(?:\*\*|__)?|\s*(?:\*\*|__)?(?:\n|$))'
    $respText = [regex]::Replace($respText, $keyPattern, { param($m)
        $k = ($m.Groups[1].Value.ToUpper() -replace '\s+', ' ')
        if ($k -eq 'JUDGMENT_CALLS') { $k = 'JUDGMENT CALLS' }
        return "${k}: "
    })

    if ($respText -match '(?im)(?:^|\n)\s*STATUS\s*:\s*(?:[^\S\r\n]*\r?\n\s*)?(?!(?:OBJECTIVE|CHANGES|VERIFIED|JUDGMENT|GAPS)\s*:)([^\r\n]+)') {
        $reportStatus = $Matches[1].Trim()
    }
    if ($respText -match '(?is)(?:^|\n)\s*OBJECTIVE\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)') {
        $oText = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($oText)) { $reportObjective = $oText }
    }
    if ($respText -match '(?is)(?:^|\n)\s*CHANGES\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)') {
        $cText = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($cText)) { $reportChanges = $cText }
    }
    if ($respText -match '(?is)(?:^|\n)\s*VERIFIED\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)') {
        $vText = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($vText)) { $reportVerified = $vText }
    }
    if ($respText -match '(?is)(?:^|\n)\s*JUDGMENT(?:\s*CALLS)?\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)') {
        $jText = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($jText)) { $reportJudgment = $jText }
    }
    if ($respText -match '(?is)(?:^|\n)\s*GAPS\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)') {
        $gText = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($gText)) { $reportGaps = $gText }
    }
}

$missingReportFields = [System.Collections.Generic.List[string]]::new()
if ($null -eq $reportStatus -or [string]::IsNullOrWhiteSpace([string]$reportStatus)) { $missingReportFields.Add("STATUS") }
if ($null -eq $reportObjective -or [string]::IsNullOrWhiteSpace([string]$reportObjective)) { $missingReportFields.Add("OBJECTIVE") }
if ($null -eq $reportChanges -or [string]::IsNullOrWhiteSpace([string]$reportChanges)) { $missingReportFields.Add("CHANGES") }
if ($null -eq $reportVerified -or [string]::IsNullOrWhiteSpace([string]$reportVerified)) { $missingReportFields.Add("VERIFIED") }
if ($null -eq $reportJudgment -or [string]::IsNullOrWhiteSpace([string]$reportJudgment)) { $missingReportFields.Add("JUDGMENT CALLS") }
if ($null -eq $reportGaps -or [string]::IsNullOrWhiteSpace([string]$reportGaps)) { $missingReportFields.Add("GAPS") }

if ($missingReportFields.Count -gt 0) {
    Fail "agy_result does not satisfy response contract: missing or empty report field(s): $($missingReportFields -join ', ')"
}

$normStatus = ([string]$reportStatus).Trim().ToLowerInvariant()
if ($normStatus -notin @("complete", "completed", "success")) {
    Fail "agy_result report status '$reportStatus' does not indicate successful completion (expected complete/completed/success)."
}

$verifiedStr = [string]$reportVerified
$verifiedLower = $verifiedStr.ToLowerInvariant()
$forbiddenTokens = @(
    "not tested", "untested", "not verified", "no tests", "no test", "unverified",
    "bypass", "bypassed",
    "exit pending", "pending exit", "test pending", "verification pending",
    "not run", "to be tested", "will test", "skipped"
)
foreach ($bad in $forbiddenTokens) {
    if ($verifiedLower.Contains($bad)) {
        Fail "agy_result VERIFIED section contains forbidden/unverified token '$bad'."
    }
}

$hasExitCode = ($verifiedStr -match '(?i)\b(?:exit(?:ed)?(?:\s+with)?(?:\s+(?:code|status))?|return\s+code|code|status)\s*[:=]?\s*\d+\b') -or
               ($verifiedStr -match '(?:退出码|返回码|退出代码|返回代码)\s*[:：=]?\s*`?\d+`?') -or
               ($verifiedStr -match '(?i)\bexit\s+\d+\b') -or
               ($verifiedStr -match '(?i)\(exit\s*(?:code)?\s*[:=]?\s*\d+\)')

$hasCmd = $false
$cmdIndicators = @(
    "git", "sh", "bash", "pwsh", "powershell", "python", "python3", "pytest",
    "npm", "cargo", "go", "make", "node", "verify", "install", "diff",
    "command", "executed", "run", "passed"
)
foreach ($ind in $cmdIndicators) {
    if ($verifiedStr -match "(?i)\b$ind\b" -or $verifiedLower.Contains("`$ind")) {
        $hasCmd = $true
        break
    }
}
if (-not $hasCmd -and ($verifiedStr.Contains('`') -or $verifiedStr.Contains('$ '))) {
    $hasCmd = $true
}

if (-not $hasExitCode -or -not $hasCmd) {
    Fail "agy_result VERIFIED section does not contain explicit command and numeric observed exit code evidence."
}

    $agyResultMap = [ordered]@{}
    if ($null -ne $parsedJson.PSObject.Properties['conversation_id']) {
        $agyResultMap['conversation_id'] = [string]$parsedJson.conversation_id
    }
    $agyFinalStatus = if ($null -ne $parsedJson.PSObject.Properties['status'] -and -not [string]::IsNullOrWhiteSpace([string]$parsedJson.status)) {
        [string]$parsedJson.status
    } else {
        ([string]$reportStatus).Trim()
    }
    $agyResultMap['status'] = $agyFinalStatus
    $agyResultMap['objective'] = ([string]$reportObjective).Trim()
    $agyResultMap['changes'] = ([string]$reportChanges).Trim()
    $agyResultMap['verified'] = ([string]$reportVerified).Trim()
    $agyResultMap['judgment_calls'] = ([string]$reportJudgment).Trim()
    $agyResultMap['gaps'] = ([string]$reportGaps).Trim()
    $agyResultMap['response'] = $respText.Trim()

    $envelope = [ordered]@{
        schema_version = 1
        invocation = [ordered]@{
            provider = "google-antigravity-cli"
            cli_version_observed = $cliVersion
            model_requested = "gemini-3.8-flash-high"
            model_catalog_exact_match_observed = $true
            effort_requested = "high"
            mode_requested = "accept-edits"
            output_format_requested = "json"
            cwd_observed = $physicalWorkspace
            permission_mode_requested = $permModeStr
            started_at_utc = $startedAtUtc
            ended_at_utc = $endedAtUtc
            duration_ms_observed = $durationMs
            exit_code_observed = $exitCode
        }
        runtime_observability = [ordered]@{
            model_field_observed = $modelFieldObserved
            effort_field_observed = $effortFieldObserved
            mode_field_observed = $modeFieldObserved
            cwd_field_observed = $cwdFieldObserved
            note = "Requested invocation pins, exact catalog lookup, and nonce-bound generation preflight are configuration/process evidence; absent agy result fields are not dynamic runtime observations."
        }
        agy_result = $agyResultMap
    }

# Re-verify parent directory and safety right before writing
if (-not (Test-Path -LiteralPath $evidenceParentDir -PathType Container)) {
    Fail "Evidence parent directory disappeared before writing: $evidenceParentDir"
}
Assert-NoReparseInAncestors $evidenceParentDir "Evidence parent directory"
$recheckParent = (Resolve-Path -LiteralPath $evidenceParentDir -ErrorAction Stop).Path
$recheckPhysicalParent = Get-PhysicalDirectoryPath $recheckParent
if ($recheckPhysicalParent.StartsWith($physicalWsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $recheckPhysicalParent.Equals($physicalWorkspace, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Evidence parent directory is inside target workspace: $recheckPhysicalParent"
}
if (Test-Path -LiteralPath $resolvedEvidenceFile) {
    Fail "Evidence destination already exists (no-clobber): $resolvedEvidenceFile"
}

# Injected crash test hook for interruption / partial-write testing
if ($effectiveTestMode) {
    $action = if (Test-Path "env:_MY_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH") { $env:_MY_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH } else { $env:_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH }
    if ($action -in @("simulate_write_crash", "simulate_interruption")) {
        Fail "TEST ERROR: Simulated crash before evidence publication."
    }
}

$tmpFileName = ".evidence-tmp." + [System.Guid]::NewGuid().ToString("N") + ".tmp"
$tmpFilePath = [System.IO.Path]::Combine($canonicalParent, $tmpFileName)
$tmpCreated = $false

$stream = $null
$writer = $null

try {
    $envelopeJson = $envelope | ConvertTo-Json -Depth 32
    $stream = [System.IO.FileStream]::new(
        $tmpFilePath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $tmpCreated = $true

    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        $sb = [System.Text.StringBuilder]::new(1024)
        $res = [SolAdvisorImplementer.Win32Path]::GetFinalPathNameByHandle($stream.SafeFileHandle, $sb, 1024, 0)
        if ($res -eq 0) {
            Fail "Failed to determine final canonical path of created temporary evidence file handle."
        }
        $finalHandlePath = $sb.ToString()
        if ($finalHandlePath.StartsWith("\\?\UNC\")) {
            $finalHandlePath = "\\" + $finalHandlePath.Substring(8)
        } elseif ($finalHandlePath.StartsWith("\\?\")) {
            $finalHandlePath = $finalHandlePath.Substring(4)
        }
        $expectedParent = $physicalParent.TrimEnd('\', '/')
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

    if (Test-Path -LiteralPath $resolvedEvidenceFile) {
        Fail "Evidence destination already exists (no-clobber): $resolvedEvidenceFile"
    }

    try {
        [System.IO.File]::Move($tmpFilePath, $resolvedEvidenceFile)
        $tmpCreated = $false
    } catch [System.IO.IOException] {
        Fail "Evidence file already exists or appeared during publishing (no-clobber): $_"
    }
} catch {
    Fail "Could not publish evidence file: $_"
} finally {
    if ($null -ne $writer) { try { $writer.Dispose() } catch {} }
    if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    if ($tmpCreated -and (Test-Path -LiteralPath $tmpFilePath)) {
        try { [System.IO.File]::Delete($tmpFilePath) } catch {}
    }
}

if ($exitCode -ne 0) {
    exit $exitCode
}

exit 0
