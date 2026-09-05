<#
.SYNOPSIS
    Machine-enforced orchestration launcher for yiwan-sol-advisor on Windows PowerShell 7.
.DESCRIPTION
    Executes the autonomous five-stage software delivery state machine:
    1. Dedicated ephemeral read-only Sol planning/spec authoring using the user's configured reasoning effort (plan.json, worker-spec.md <= 24 KiB)
    2. Antigravity CLI (gemini-3.8-flash-high) implementation window with per-window snapshot attribution
    3. Parent working-tree machine integrity inspection, scoped Git metadata integrity, and cryptographic binding verification
    4. Ephemeral read-only fresh Sol review gate using the user's configured reasoning effort (SHIP / FIX-FIRST / RETHINK)
    5. Bounded fix-first correction loop (up to MaxCorrections) or final structured delivery publication.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$TaskFile,

    [Parameter(Mandatory = $true)]
    [string]$ResultFile,

    [Parameter(Mandatory = $false)]
    [string]$Timeout = "60m",

    [Parameter(Mandatory = $false)]
    [string]$PlannerTimeout = "6m",

    [Parameter(Mandatory = $false)]
    [string]$PlannerHeartbeatInterval = "30s",

    [Parameter(Mandatory = $false)]
    [string]$PlannerIdleTimeout = "2m",

    [Parameter(Mandatory = $false)]
    [string]$ImplementerTimeout = "15m",

    [Parameter(Mandatory = $false)]
    [string]$ReviewerTimeout = "8m",

    [Parameter(Mandatory = $false)]
    [string]$IdleTimeout = "4m",

    [Parameter(Mandatory = $false)]
    [string]$GenerationPreflightTimeout = "60s",

    [Parameter(Mandatory = $false)]
    [string]$MachineReserve = "2m",

    [Parameter(Mandatory = $false)]
    [string]$TrustedVerificationScript = "",

    [Parameter(Mandatory = $false)]
    [string]$VerificationTimeout = "10m",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxOwnedFiles = 6,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 50)]
    [int]$MaxVerificationCommands = 4,

    [Parameter(Mandatory = $false)]
    [int]$MaxCorrections = 1,

    [Parameter(Mandatory = $false)]
    [switch]$DangerouslySkipPermissions,

    [Parameter(Mandatory = $false)]
    [switch]$EnforceInteractivePermissions,

    [Parameter(Mandatory = $false)]
    [switch]$TestMode,

    [Parameter(Mandatory = $false)]
    [string]$TestAgyExe = "",

    [Parameter(Mandatory = $false)]
    [string]$TestCodexBin = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    [Parameter(Mandatory = $false)]
    [string]$ReasoningEffort = ""
)

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine("ERROR: PowerShell 7+ (pwsh) is required; detected PowerShell version $($PSVersionTable.PSVersion)")
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Msg) {
    [Console]::Error.WriteLine("ERROR: $Msg")
    exit 1
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
        Fail "Invalid duration format '$d'. Supported formats: '30m', '15m', '1800s', '1h'."
    }
    if ($totalSec -le 0) { Fail "Duration must be greater than zero: $d" }
    return $totalSec
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

$totalTimeoutSec = Parse-Duration $Timeout
$plannerTimeoutSec = Parse-Duration $PlannerTimeout
$plannerHeartbeatIntervalSec = Parse-Duration $PlannerHeartbeatInterval
$plannerIdleTimeoutSec = Parse-Duration $PlannerIdleTimeout
$implementerTimeoutSec = Parse-Duration $ImplementerTimeout
$reviewerTimeoutSec = Parse-Duration $ReviewerTimeout
$idleTimeoutSec = Parse-Duration $IdleTimeout
$generationPreflightTimeoutSec = Parse-Duration $GenerationPreflightTimeout
$machineReserveSec = Parse-Duration $MachineReserve
$verificationTimeoutSec = Parse-Duration $VerificationTimeout

$inheritedCodexConfig = Get-CurrentCodexConfig
$effectiveCodexModel = if (-not [string]::IsNullOrWhiteSpace($Model)) {
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
$effectiveMaxVerificationCommands = if ([string]::IsNullOrWhiteSpace($TrustedVerificationScript)) { $MaxVerificationCommands } else { [Math]::Min($MaxVerificationCommands, 2) }
if ($MaxCorrections -lt 0) {
    Fail "MaxCorrections must be non-negative (got $MaxCorrections)."
}

$hasExplicitPlannerTimeout = $PSBoundParameters.ContainsKey('PlannerTimeout')
$hasExplicitImplementerTimeout = $PSBoundParameters.ContainsKey('ImplementerTimeout')
$hasExplicitReviewerTimeout = $PSBoundParameters.ContainsKey('ReviewerTimeout')
$hasExplicitMachineReserve = $PSBoundParameters.ContainsKey('MachineReserve')
$anyExplicitPhaseBudget = $hasExplicitPlannerTimeout -or $hasExplicitImplementerTimeout -or $hasExplicitReviewerTimeout -or $hasExplicitMachineReserve

$minimumIterationBudgetSec = $plannerTimeoutSec + $implementerTimeoutSec + $reviewerTimeoutSec + $machineReserveSec

$isDynamicallyScaled = $false
if ($anyExplicitPhaseBudget) {
    if ($totalTimeoutSec -lt $minimumIterationBudgetSec) {
        Fail "Total timeout $Timeout is too short for one safe iteration. It must cover PlannerTimeout + ImplementerTimeout + ReviewerTimeout + MachineReserve (${minimumIterationBudgetSec}s)."
    }
} else {
    # If the user did not explicitly configure phase budgets, dynamically scale them proportionally to fit total timeout
    if ($totalTimeoutSec -lt $minimumIterationBudgetSec) {
        $minSafeTotalSec = 180 # absolute minimal floor for an automated iteration (3 min)
        if ($totalTimeoutSec -lt $minSafeTotalSec) {
            Fail "Total timeout $Timeout is too short for one safe iteration. It must cover PlannerTimeout + ImplementerTimeout + ReviewerTimeout + MachineReserve (${minimumIterationBudgetSec}s)."
        }
        $isDynamicallyScaled = $true
        $plannerTimeoutSec = [Math]::Max(45, [int]($totalTimeoutSec * 0.20))
        $implementerTimeoutSec = [Math]::Max(90, [int]($totalTimeoutSec * 0.50))
        $reviewerTimeoutSec = [Math]::Max(45, [int]($totalTimeoutSec * 0.25))
        $machineReserveSec = [Math]::Max(10, $totalTimeoutSec - ($plannerTimeoutSec + $implementerTimeoutSec + $reviewerTimeoutSec))
        $minimumIterationBudgetSec = 190

        if ($idleTimeoutSec -gt $implementerTimeoutSec) { $idleTimeoutSec = $implementerTimeoutSec }
        if ($generationPreflightTimeoutSec -ge $implementerTimeoutSec) { $generationPreflightTimeoutSec = [Math]::Max(10, [int]($implementerTimeoutSec * 0.2)) }
        if ($plannerHeartbeatIntervalSec -gt $plannerTimeoutSec) { $plannerHeartbeatIntervalSec = [Math]::Max(10, [int]($plannerTimeoutSec * 0.25)) }
        if ($plannerIdleTimeoutSec -gt $plannerTimeoutSec) { $plannerIdleTimeoutSec = $plannerTimeoutSec }

        [Console]::Error.WriteLine("INFO: Total timeout (${totalTimeoutSec}s) is smaller than default phase budget sum. Dynamically scaled phase budgets: Planner=${plannerTimeoutSec}s, Implementer=${implementerTimeoutSec}s, Reviewer=${reviewerTimeoutSec}s, MachineReserve=${machineReserveSec}s")
    }
}

if ($idleTimeoutSec -gt $implementerTimeoutSec) {
    Fail "IdleTimeout ($IdleTimeout) must be less than or equal to ImplementerTimeout ($ImplementerTimeout)."
}
if ($generationPreflightTimeoutSec -ge $implementerTimeoutSec) {
    Fail "GenerationPreflightTimeout ($GenerationPreflightTimeout) must be shorter than ImplementerTimeout ($ImplementerTimeout)."
}
if ($plannerHeartbeatIntervalSec -gt $plannerTimeoutSec) {
    $plannerHeartbeatIntervalSec = $plannerTimeoutSec
}
if ($PSBoundParameters.ContainsKey('PlannerIdleTimeout') -and $plannerIdleTimeoutSec -gt $plannerTimeoutSec) {
    Fail "PlannerIdleTimeout ($PlannerIdleTimeout) must be less than or equal to PlannerTimeout ($PlannerTimeout)."
}
if ($plannerIdleTimeoutSec -gt $plannerTimeoutSec) {
    $plannerIdleTimeoutSec = $plannerTimeoutSec
}

$effectiveSkipPermissions = $true
if ($EnforceInteractivePermissions.IsPresent) {
    $effectiveSkipPermissions = $false
}

# 1. P/Invoke for Win32 path normalization and handle inspection
if (-not ([System.Management.Automation.PSTypeName]'SolAdvisorLauncher.Win32Path').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SolAdvisorLauncher {
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
    $h = [SolAdvisorLauncher.Win32Path]::CreateFile(
        $Path,
        [SolAdvisorLauncher.Win32Path]::FILE_READ_ATTRIBUTES,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete,
        [System.IntPtr]::Zero,
        [System.IO.FileMode]::Open,
        [SolAdvisorLauncher.Win32Path]::FILE_FLAG_BACKUP_SEMANTICS,
        [System.IntPtr]::Zero
    )
    if ($h.IsInvalid) {
        Fail "Cannot open handle for directory path resolution: $Path"
    }
    try {
        $sb = [System.Text.StringBuilder]::new(1024)
        $res = [SolAdvisorLauncher.Win32Path]::GetFinalPathNameByHandle($h, $sb, 1024, 0)
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

$script:activeChildProcs = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

function Register-ActiveProcess([System.Diagnostics.Process]$p) {
    if ($null -ne $p) {
        if (-not $script:activeChildProcs.Contains($p)) {
            $script:activeChildProcs.Add($p)
        }
    }
}

function Unregister-ActiveProcess([System.Diagnostics.Process]$p) {
    if ($null -ne $p) {
        [void]$script:activeChildProcs.Remove($p)
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

# 2. Validate Workspace
if ([string]::IsNullOrWhiteSpace($Workspace)) { Fail "Workspace path is empty." }
if (-not [System.IO.Path]::IsPathRooted($Workspace)) { Fail "Workspace must be an absolute path: $Workspace" }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    Fail "Target workspace does not exist or is not a directory: $Workspace"
}
Assert-NoReparseInAncestors $Workspace "Workspace directory"
$resolvedWs = (Resolve-Path -LiteralPath $Workspace).Path
$physicalWs = Get-PhysicalDirectoryPath $resolvedWs

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

function Get-RemainingTimeoutMs([int]$MaxStepMs = [int]::MaxValue) {
    $remSec = $totalTimeoutSec - $swTotal.Elapsed.TotalSeconds
    if ($remSec -le 0) {
        Fail "Sol Advisor orchestration exceeded total timeout of $Timeout ($totalTimeoutSec seconds)."
    }
    $remMs = [int][Math]::Floor($remSec * 1000)
    # This helper enforces the global deadline. Every model stage also passes its own
    # explicit planner/implementer/reviewer cap; short machine checks use smaller caps.
    return [Math]::Min($MaxStepMs, $remMs)
}

# Git command helpers
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

function Invoke-GitNullList([string]$Ws, [string[]]$GitArgs) {
    $waitMs = Get-RemainingTimeoutMs 30000
    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = "git"
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.CreateNoWindow = $true
    $pinfo.WorkingDirectory = $Ws
    $pinfo.ArgumentList.Add("-C")
    $pinfo.ArgumentList.Add($Ws)
    foreach ($a in $GitArgs) { $pinfo.ArgumentList.Add($a) }

    $p = [System.Diagnostics.Process]::Start($pinfo)
    if ($null -eq $p) { Fail "Failed to start Git command: git $($GitArgs -join ' ')" }
    $ms = [System.IO.MemoryStream]::new()
    $copyTask = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $stderrTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($waitMs)) {
        try { $p.Kill($true) } catch {}
        Fail "Git command timed out: git $($GitArgs -join ' ')"
    }
    [System.Threading.Tasks.Task]::WaitAll($copyTask, $stderrTask)
    if ($p.ExitCode -ne 0) {
        Fail "Git command failed (exit code $($p.ExitCode)): git $($GitArgs -join ' ')`n$($stderrTask.Result)"
    }

    $raw = [System.Text.UTF8Encoding]::new($false, $true).GetString($ms.ToArray())
    return @($raw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
}

function Assert-SafeSnapshotRelativePath([string]$RelativePath, [string]$SnapshotRoot) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(":")) {
        Fail "Unsafe path returned while building the disposable planner snapshot: '$RelativePath'"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $SnapshotRoot $RelativePath))
    $rootPrefix = $SnapshotRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "Planner snapshot path escapes its disposable root: '$RelativePath'"
    }
    return $candidate
}

function New-PlannerWorkspaceSnapshot([string]$SourceWorkspace, [string]$Destination, [string]$HeadSha) {
    if (Test-Path -LiteralPath $Destination) {
        Fail "Planner snapshot destination already exists: $Destination"
    }

    $destinationParent = [System.IO.Path]::GetDirectoryName($Destination)
    Invoke-GitCmd $destinationParent @("clone", "--quiet", "--no-hardlinks", "--no-checkout", "--local", $SourceWorkspace, $Destination) | Out-Null
    Invoke-GitCmd $Destination @("checkout", "--quiet", "--detach", $HeadSha) | Out-Null

    # Overlay the exact tracked and non-ignored working-tree view. This preserves
    # pre-existing edits for planning without granting the planner access to the
    # canonical workspace that Antigravity will later modify.
    $visiblePaths = Invoke-GitNullList $SourceWorkspace @("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    foreach ($relativePath in $visiblePaths) {
        $destinationPath = Assert-SafeSnapshotRelativePath $relativePath $Destination
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $SourceWorkspace $relativePath))
        $sourcePrefix = $SourceWorkspace.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $sourcePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail "Source path escapes the canonical workspace while building planner snapshot: '$relativePath'"
        }

        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            $parent = [System.IO.Path]::GetDirectoryName($destinationPath)
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        } elseif (Test-Path -LiteralPath $sourcePath -PathType Container) {
            if (Test-Path -LiteralPath $destinationPath) {
                Remove-Item -LiteralPath $destinationPath -Recurse -Force
            }
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
        } elseif (Test-Path -LiteralPath $destinationPath) {
            # A tracked file deleted in the canonical worktree must also be absent
            # from the disposable clone. The resolved path was confined above.
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }
    }

    return Get-PhysicalDirectoryPath $Destination
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

# Baseline HEAD validation
$baselineHeadSha = (Invoke-GitCmd $physicalWs @("rev-parse", "HEAD")).Trim()
if ([string]::IsNullOrWhiteSpace($baselineHeadSha) -or $baselineHeadSha -notmatch '^[0-9a-f]{40}$') {
    Fail "Could not determine baseline HEAD commit hash in workspace: $physicalWs"
}

function Assert-HeadUnchanged([string]$WsPath, [string]$StageLabel) {
    $currentHead = (Invoke-GitCmd $WsPath @("rev-parse", "HEAD")).Trim()
    if ($currentHead -ne $baselineHeadSha) {
        Fail "Baseline HEAD immutability violated during $StageLabel (initial: $baselineHeadSha, current: $currentHead). Head mutations/commits are prohibited."
    }
}

# 3. Validate TaskFile
if ([string]::IsNullOrWhiteSpace($TaskFile)) { Fail "TaskFile path is empty." }
if (-not [System.IO.Path]::IsPathRooted($TaskFile)) { Fail "TaskFile must be an absolute path: $TaskFile" }
if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) {
    Fail "TaskFile does not exist or is not a file: $TaskFile"
}
$taskFileItem = Get-Item -LiteralPath $TaskFile -ErrorAction Stop
if ($taskFileItem.Length -gt 1048576) {
    Fail "TaskFile exceeds maximum allowed size of 1MB ($($taskFileItem.Length) bytes)."
}

$taskParentDir = [System.IO.Path]::GetDirectoryName($TaskFile)
Assert-NoReparseInAncestors $taskParentDir "TaskFile parent directory"
Assert-NoReparseInAncestors $TaskFile "TaskFile"
$resolvedTaskFile = (Resolve-Path -LiteralPath $TaskFile).Path
$physicalTaskDir = Get-PhysicalDirectoryPath $taskParentDir
$physicalTaskFile = [System.IO.Path]::Combine($physicalTaskDir, [System.IO.Path]::GetFileName($resolvedTaskFile))

if ($physicalTaskDir.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalTaskDir.Equals($physicalWs, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalTaskFile.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "TaskFile is inside target workspace ($physicalTaskFile is inside $physicalWs)."
}

function Compute-Sha256Hex([byte[]]$Data) {
    if ($null -eq $Data) { $Data = [byte[]]@() }
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
        $len = $stream.Length
        return @{
            Length = $len
            Sha256 = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
        }
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$rawTaskBytes = [System.IO.File]::ReadAllBytes($resolvedTaskFile)
$taskSha256 = Compute-Sha256Hex $rawTaskBytes
$taskContent = $utf8NoBom.GetString($rawTaskBytes)

if ([string]::IsNullOrWhiteSpace($taskContent)) {
    Fail "TaskFile is empty: $resolvedTaskFile"
}

# Optional caller-authored verification script. Unlike planner-suggested commands, this
# file is an explicit trust boundary supplied by the launcher caller and is executed
# independently after the writer window. It must live outside the target workspace.
$resolvedTrustedVerificationScript = ""
$trustedVerificationScriptSha256 = ""
$trustedVerificationBashExe = ""
if (-not [string]::IsNullOrWhiteSpace($TrustedVerificationScript)) {
    if (-not [System.IO.Path]::IsPathRooted($TrustedVerificationScript)) { Fail "TrustedVerificationScript must be an absolute path." }
    if (-not (Test-Path -LiteralPath $TrustedVerificationScript -PathType Leaf)) { Fail "TrustedVerificationScript does not exist or is not a file: $TrustedVerificationScript" }
    $verificationItem = Get-Item -LiteralPath $TrustedVerificationScript -ErrorAction Stop
    if ($verificationItem.Length -gt 65536) { Fail "TrustedVerificationScript exceeds maximum allowed size of 64 KiB." }
    Assert-NoReparseInAncestors $TrustedVerificationScript "TrustedVerificationScript"
    $resolvedTrustedVerificationScript = (Resolve-Path -LiteralPath $TrustedVerificationScript).Path
    $verificationParent = Get-PhysicalDirectoryPath ([System.IO.Path]::GetDirectoryName($resolvedTrustedVerificationScript))
    $physicalVerificationScript = [System.IO.Path]::Combine($verificationParent, [System.IO.Path]::GetFileName($resolvedTrustedVerificationScript))
    if ($physicalVerificationScript.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalVerificationScript.Equals($physicalWs, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "TrustedVerificationScript must be outside the target workspace."
    }
    $trustedVerificationScriptSha256 = Compute-Sha256Hex ([System.IO.File]::ReadAllBytes($resolvedTrustedVerificationScript))
    $bashCandidates = @(
        (Join-Path $env:ProgramFiles "Git\bin\bash.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
    )
    foreach ($candidate in $bashCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $trustedVerificationBashExe = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($trustedVerificationBashExe)) {
        $bashCommand = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $bashCommand -or $bashCommand.Source -like "$env:SystemRoot\System32\bash.exe") {
            Fail "TrustedVerificationScript requires Git for Windows bash; WSL bash cannot safely verify a Windows Git worktree."
        }
        $trustedVerificationBashExe = $bashCommand.Source
    }
}

# 4. Validate ResultFile
if ([string]::IsNullOrWhiteSpace($ResultFile)) { Fail "ResultFile path is empty." }
if (-not [System.IO.Path]::IsPathRooted($ResultFile)) {
    Fail "ResultFile must be an absolute path: $ResultFile"
}
if ($ResultFile.StartsWith("\\.\") -or $ResultFile.StartsWith("\\?\")) {
    Fail "ResultFile contains unsupported device path syntax: $ResultFile"
}
$resultFileNameOnly = [System.IO.Path]::GetFileName($ResultFile)
if ($resultFileNameOnly.Contains(":")) {
    Fail "ResultFile contains Alternate Data Stream (ADS) syntax: $ResultFile"
}
$reservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")
$resultBaseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($ResultFile)
if ($resultBaseNoExt.ToUpperInvariant() -in $reservedNames) {
    Fail "ResultFile uses reserved DOS device name: $ResultFile"
}

if (Test-Path -LiteralPath $ResultFile) {
    Fail "Result output destination already exists (no-clobber): $ResultFile"
}

$resultParentDir = [System.IO.Path]::GetDirectoryName($ResultFile)
if (-not (Test-Path -LiteralPath $resultParentDir -PathType Container)) {
    Fail "Result output parent directory does not exist: $resultParentDir"
}
Assert-NoReparseInAncestors $resultParentDir "Result output parent directory"
$resolvedResultParent = (Resolve-Path -LiteralPath $resultParentDir).Path
$physicalResultParent = Get-PhysicalDirectoryPath $resolvedResultParent

if ($physicalResultParent.StartsWith($wsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or $physicalResultParent.Equals($physicalWs, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "Result output destination is inside target workspace: $physicalResultParent"
}

# 5. Locate Bundled Scripts
$scriptDir = $PSScriptRoot
$implScript = (Resolve-Path -LiteralPath (Join-Path $scriptDir "run-antigravity-implementer.ps1")).Path
$reviewerScript = (Resolve-Path -LiteralPath (Join-Path $scriptDir "run-fresh-reviewer.ps1")).Path

if (-not (Test-Path -LiteralPath $implScript -PathType Leaf)) {
    Fail "Bundled implementer script not found at: $implScript"
}
if (-not (Test-Path -LiteralPath $reviewerScript -PathType Leaf)) {
    Fail "Bundled reviewer script not found at: $reviewerScript"
}

# Scoped Git Metadata Digest Function
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

    # 6. Info directory
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

# 6. Repository Manifest & Snapshot Helpers
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
    $manifestHash = Compute-Sha256Hex($manifestBytes)
    $writer.Dispose()
    $ms.Dispose()

    return @{
        HeadSha = $headSha
        HeadRef = $headRef
        ManifestHash = $manifestHash
        ManifestString = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
    }
}

function Capture-RepositorySnapshot([string]$WsPath) {
    $map = @{}

    # 1. Tracked index entries via git ls-files --stage -z
    $stageRaw = Invoke-GitCmd $WsPath @("ls-files", "--stage", "-z")
    if (-not [string]::IsNullOrEmpty($stageRaw)) {
        $entries = $stageRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($entry in $entries) {
            $tabIdx = $entry.IndexOf("`t")
            if ($tabIdx -gt 0) {
                $meta = $entry.Substring(0, $tabIdx)
                $p = $entry.Substring($tabIdx + 1).Replace("\", "/").TrimStart('/')
                $fullP = [System.IO.Path]::Combine($WsPath, $p)
                $wtInfo = Get-FileSha256AndLength $fullP
                $record = "INDEX_RECORD:${meta}"
                if ($map.ContainsKey($p)) {
                    $map[$p] = "$($map[$p])|${record}"
                } else {
                    $map[$p] = "${record}|WT:$($wtInfo.Length):$($wtInfo.Sha256)"
                }
            }
        }
    }

    # 2. Augment with porcelain v1 -z output for rename/copy detection & status
    $statusRaw = Invoke-GitCmd $WsPath @("status", "--porcelain=v1", "-z")
    if (-not [string]::IsNullOrEmpty($statusRaw)) {
        $tokens = $statusRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
        $idx = 0
        while ($idx -lt $tokens.Length) {
            $token = $tokens[$idx]
            if ($token.Length -ge 4) {
                $st = $token.Substring(0, 2)
                $p = $token.Substring(3).Replace("\", "/").TrimStart('/')
                if ($st.Contains('R') -or $st.Contains('C')) {
                    $destPath = $p
                    $srcPath = ""
                    $idx++
                    if ($idx -lt $tokens.Length) {
                        $srcPath = $tokens[$idx].Replace("\", "/").TrimStart('/')
                    }
                    $fullDest = [System.IO.Path]::Combine($WsPath, $destPath)
                    $dInfo = Get-FileSha256AndLength $fullDest
                    $destBase = if ($map.ContainsKey($destPath)) { $map[$destPath] } else { "WT:$($dInfo.Length):$($dInfo.Sha256)" }
                    $map[$destPath] = "${destBase}|STATUS:${st}:DEST"

                    if (-not [string]::IsNullOrEmpty($srcPath)) {
                        $fullSrc = [System.IO.Path]::Combine($WsPath, $srcPath)
                        $sInfo = Get-FileSha256AndLength $fullSrc
                        $srcBase = if ($map.ContainsKey($srcPath)) { $map[$srcPath] } else { "WT:$($sInfo.Length):$($sInfo.Sha256)" }
                        $map[$srcPath] = "${srcBase}|STATUS:${st}:SRC"
                    }
                } else {
                    $fullP = [System.IO.Path]::Combine($WsPath, $p)
                    $fInfo = Get-FileSha256AndLength $fullP
                    $pBase = if ($map.ContainsKey($p)) { $map[$p] } else { "WT:$($fInfo.Length):$($fInfo.Sha256)" }
                    $map[$p] = "${pBase}|STATUS:${st}"
                }
            }
            $idx++
        }
    }

    # 3. Add untracked files
    $untrackedRaw = Invoke-GitCmd $WsPath @("ls-files", "--others", "--exclude-standard", "-z")
    if (-not [string]::IsNullOrEmpty($untrackedRaw)) {
        $uList = $untrackedRaw.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($uf in $uList) {
            $normUf = $uf.Replace("\", "/").TrimStart('/')
            if (Test-IsIgnoredRuntimeCachePath $normUf) { continue }
            $fullUf = [System.IO.Path]::Combine($WsPath, $uf)
            $fInfo = Get-FileSha256AndLength $fullUf
            $map[$normUf] = "UNTRACKED:$($fInfo.Length):$($fInfo.Sha256)"
        }
    }

    return @{
        HeadSha = (Invoke-GitCmd $WsPath @("rev-parse", "HEAD")).Trim()
        FileMap = $map
    }
}

function Get-WindowDelta($PreSnapshot, $PostSnapshot) {
    $changed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($k in $PostSnapshot.FileMap.Keys) {
        if (Test-IsIgnoredRuntimeCachePath $k) { continue }
        if (-not $PreSnapshot.FileMap.ContainsKey($k) -or ($PreSnapshot.FileMap[$k] -ne $PostSnapshot.FileMap[$k])) {
            $changed.Add($k) | Out-Null
        }
    }
    foreach ($k in $PreSnapshot.FileMap.Keys) {
        if (Test-IsIgnoredRuntimeCachePath $k) { continue }
        if (-not $PostSnapshot.FileMap.ContainsKey($k)) {
            $changed.Add($k) | Out-Null
        }
    }

    $arr = [string[]]::new($changed.Count)
    $changed.CopyTo($arr)
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

# Initial baseline snapshot S_0
$initialSnapshot = Capture-RepositorySnapshot $physicalWs

# 7. Setup Private Run Directory Outside Workspace
$runDir = [System.IO.Path]::Combine($physicalResultParent, ".sol-advisor-run." + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$cleanRunDir = $true

# Determine Codex Executable & Test Mode
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

# 8. State Machine Orchestration Loop
$iteration = 1
$finalReportContent = $null
$lastPlan = $null
$lastImplementerEvidenceRaw = ""
$lastParentVerificationRaw = ""
$lastImplementerEvidenceObj = $null
$lastParentVerificationObj = $null
$lastReviewFindings = ""
$lastReviewReason = ""
$reviewedNoChangeAccepted = $false
$stageTelemetryList = [System.Collections.Generic.List[PSObject]]::new()

try {
    while ($iteration -le ($MaxCorrections + 1)) {
        $remSec = [int]($totalTimeoutSec - $swTotal.Elapsed.TotalSeconds)
        if ($remSec -le 0) {
            Fail "Sol Advisor orchestration exceeded total timeout of $Timeout ($totalTimeoutSec seconds)."
        }
        if ($remSec -lt $minimumIterationBudgetSec) {
            Fail "Insufficient remaining budget for a safe complete iteration: ${remSec}s remain, ${minimumIterationBudgetSec}s are reserved. No new writer window was started."
        }

        if (-not $anyExplicitPhaseBudget -and $isDynamicallyScaled) {
            $currentIterBudget = [Math]::Min($totalTimeoutSec, $remSec)
            $plannerTimeoutSec = [Math]::Max(45, [int]($currentIterBudget * 0.20))
            $implementerTimeoutSec = [Math]::Max(90, [int]($currentIterBudget * 0.50))
            $reviewerTimeoutSec = [Math]::Max(45, [int]($currentIterBudget * 0.25))
            $machineReserveSec = [Math]::Max(10, $currentIterBudget - ($plannerTimeoutSec + $implementerTimeoutSec + $reviewerTimeoutSec))
        }

        $iterDir = Join-Path $runDir "iteration-$iteration"
        New-Item -ItemType Directory -Path $iterDir -Force | Out-Null

        [Console]::WriteLine("=== [Sol Advisor Iteration $iteration / $($MaxCorrections + 1)] ===")

        # -------------------------------------------------------------
        # STAGE 1: Architecture & Specification Planning (Sol, inherited effort, read-only)
        # -------------------------------------------------------------
        $swStage1 = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-HeadUnchanged $physicalWs "before planning stage"
        $fpBeforePlan = Get-DeterministicRepoManifest $physicalWs
        $plannerWs = New-PlannerWorkspaceSnapshot $physicalWs (Join-Path $iterDir "planner-workspace") $baselineHeadSha

        $plannerModelDesc = if (-not [string]::IsNullOrWhiteSpace($effectiveCodexModel)) { "model: $effectiveCodexModel" } else { "inherited Codex model" }
        $plannerPrompt = if ($iteration -eq 1) {
@"
ROLE CONTRACT:
You are the dedicated Sol planner and architect for canonical workspace: $physicalWs ($plannerModelDesc). Use the reasoning effort inherited from the user's current Codex configuration; do not require or claim a fixed effort tier.
You MUST NOT implement code directly. All code edits are performed exclusively by Google Antigravity CLI.
Your sandbox is strictly read-only.
Inspect the disposable, read-only Git mirror at: $plannerWs
The mirror contains the canonical workspace's tracked and non-ignored working-tree view. Author paths relative to the canonical repository root; never target the mirror path itself.
Analyze requirements, inspect repository conventions in that mirror, and author an implementation plan.
Bound this iteration to at most $MaxOwnedFiles exact owned file paths and at most $effectiveMaxVerificationCommands focused smoke commands. Prefer one independently verifiable phase; do not claim ownership of an entire repository or broad directory when exact files can be named. Do not include an umbrella full-suite command together with its leaf tests. The parent trusted verifier owns exhaustive regression execution when supplied.
Use only the repository mirror and evidence embedded in USER TASK. Do not browse the web, initialize MCP/apps/plugins, or repeat version discovery already supplied by the caller. Keep repository inspection bounded and produce the plan as soon as the owned files and verification surface are known.

USER TASK:
$taskContent

OUTPUT REQUIREMENTS:
You must output ONLY a valid JSON object matching the following schema (no markdown fences or conversational text):
{
  "objective": "<concrete observable outcome>",
  "owned_files": [
    "<exact relative file or directory path 1>",
    "<exact relative file or directory path 2>"
  ],
  "interfaces": "<signatures, types, schemas, commands, or protocol behaviors to preserve>",
  "constraints": "<repository conventions, safety boundaries, excluded scope>",
  "verification_commands": [
    "<suggested test/verification command 1>",
    "<suggested test/verification command 2>"
  ]
}
"@
        } else {
            $priorReviewSummary = if (-not [string]::IsNullOrWhiteSpace($lastReviewEnvelopeRaw)) {
                $lastReviewEnvelopeRaw
            } else { "None" }
            $priorImplSummary = if (-not [string]::IsNullOrWhiteSpace($lastImplementerEvidenceRaw)) {
                $lastImplementerEvidenceRaw
            } else { "None" }
            $priorParentSummary = if (-not [string]::IsNullOrWhiteSpace($lastParentVerificationRaw)) {
                $lastParentVerificationRaw
            } else { "None" }

            $priorReviewHash = Compute-Sha256String $lastReviewEnvelopeRaw
            $priorImplHash = Compute-Sha256String $lastImplementerEvidenceRaw
            $priorParentHash = Compute-Sha256String $lastParentVerificationRaw

@"
ROLE CONTRACT:
You are the dedicated Sol correction planner and architect for canonical workspace: $physicalWs ($plannerModelDesc). Use the reasoning effort inherited from the user's current Codex configuration; do not require or claim a fixed effort tier.
You MUST NOT implement code directly. All code edits are performed exclusively by Google Antigravity CLI.
Your sandbox is strictly read-only.
Inspect the disposable, read-only Git mirror at: $plannerWs
The mirror contains the canonical workspace's tracked and non-ignored working-tree view. Author paths relative to the canonical repository root; never target the mirror path itself.
The previous iteration received a FIX-FIRST verdict during review.
Analyze the complete prior review envelope, parent verification results, and prior implementer evidence, and author a targeted correction plan.
Focus strictly on the delta and the specific verification failures reported in the prior review. DO NOT re-scan or traverse the entire repository.
Bound this correction to at most $MaxOwnedFiles exact owned file paths and at most $effectiveMaxVerificationCommands focused smoke commands. Do not repeat an umbrella suite and its leaf tests; the parent trusted verifier owns exhaustive regression execution when supplied.

USER TASK:
$taskContent

PREVIOUS PLAN OBJECTIVE:
$($lastPlan.objective)

PREVIOUS REVIEW ENVELOPE (SHA-256: $priorReviewHash):
$priorReviewSummary

PREVIOUS IMPLEMENTER EVIDENCE (SHA-256: $priorImplHash):
$priorImplSummary

PREVIOUS PARENT VERIFICATION EVIDENCE (SHA-256: $priorParentHash):
$priorParentSummary

OUTPUT REQUIREMENTS:
You must output ONLY a valid JSON object matching the following schema (no markdown fences or conversational text):
{
  "objective": "<concrete observable outcome for this correction>",
  "owned_files": [
    "<exact relative file or directory path 1>",
    "<exact relative file or directory path 2>"
  ],
  "interfaces": "<signatures, types, schemas, commands, or protocol behaviors to preserve>",
  "constraints": "<repository conventions, safety boundaries, excluded scope>",
  "verification_commands": [
    "<suggested test/verification command 1>",
    "<suggested test/verification command 2>"
  ]
}
"@
        }

        # Bound correction planner prompt (3 MiB cap)
        $plannerPromptBytes = [System.Text.Encoding]::UTF8.GetBytes($plannerPrompt)
        if ($plannerPromptBytes.Length -gt 3145728) {
            Fail "Assembled planner prompt exceeds finite cap of 3 MiB ($($plannerPromptBytes.Length) bytes)."
        }

        $planMsgFile = Join-Path $iterDir ".plan-msg.tmp"
        $planSchemaFile = Join-Path $iterDir "plan-output-schema.json"
        $planSchema = [ordered]@{
            type = "object"
            additionalProperties = $false
            required = @("objective", "owned_files", "interfaces", "constraints", "verification_commands")
            properties = [ordered]@{
                objective = @{ type = "string"; minLength = 1 }
                owned_files = @{ type = "array"; minItems = 1; maxItems = $MaxOwnedFiles; items = @{ type = "string"; minLength = 1 } }
                interfaces = @{ type = "string" }
                constraints = @{ type = "string" }
                verification_commands = @{ type = "array"; maxItems = $MaxVerificationCommands; items = @{ type = "string"; minLength = 1 } }
            }
        } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($planSchemaFile, $planSchema, $utf8NoBom)
        $planExit = 1
        $planRaw = ""
        $plannerStageWatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfo.FileName = $codexExe
            $pinfo.UseShellExecute = $false
            $pinfo.RedirectStandardInput = $true
            $pinfo.RedirectStandardOutput = $true
            $pinfo.RedirectStandardError = $true
            $pinfo.CreateNoWindow = $true
            $pinfo.WorkingDirectory = $plannerWs

            $pinfo.ArgumentList.Add("exec")
            if (-not [string]::IsNullOrWhiteSpace($effectiveCodexModel)) {
                $pinfo.ArgumentList.Add("-m")
                $pinfo.ArgumentList.Add($effectiveCodexModel)
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
            $pinfo.ArgumentList.Add($plannerWs)
            $pinfo.ArgumentList.Add("--color")
            $pinfo.ArgumentList.Add("never")
            $pinfo.ArgumentList.Add("--output-schema")
            $pinfo.ArgumentList.Add($planSchemaFile)
            $pinfo.ArgumentList.Add("-o")
            $pinfo.ArgumentList.Add($planMsgFile)

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            if ($null -eq $proc) { Fail "Failed to start Codex planner process: $codexExe" }
            Register-ActiveProcess $proc

            $stdoutBuilder = [System.Text.StringBuilder]::new()
            $stderrBuilder = [System.Text.StringBuilder]::new()
            $stdoutClosed = $false
            $stderrClosed = $false
            $stdoutLineTask = $proc.StandardOutput.ReadLineAsync()
            $stderrLineTask = $proc.StandardError.ReadLineAsync()

            $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($plannerPrompt)
            $stdinTask = $proc.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
            $plannerStageRemainingMs = [Math]::Max(1, ($plannerTimeoutSec * 1000) - [int]$plannerStageWatch.ElapsedMilliseconds)
            $writeBudget = Get-RemainingTimeoutMs $plannerStageRemainingMs
            if (-not $stdinTask.Wait($writeBudget)) {
                Stop-ProcessTree $proc
                Fail "Sol planner prompt write exceeded the planner stage cap of $PlannerTimeout."
            }
            $proc.StandardInput.BaseStream.Close()

            $lastActivityUtc = [System.DateTime]::UtcNow
            $lastActivityKind = "startup"
            $lastCpuMs = Get-ProcessTreeCpuMs $proc.Id
            $lastPlanFileSize = [long]0
            $lastProbeElapsed = -2
            $nextPlannerHeartbeatSec = $plannerHeartbeatIntervalSec
            $plannerTimedOut = $false
            $plannerIdleTimedOut = $false

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
                        $lastActivityUtc = [System.DateTime]::UtcNow
                        $lastActivityKind = "stderr"
                        $stderrLineTask = $proc.StandardError.ReadLineAsync()
                    }
                }
                if ($stdoutBuilder.Length -gt 4194304 -or $stderrBuilder.Length -gt 4194304) {
                    Stop-ProcessTree $proc
                    Fail "Sol planner output exceeded the 4 MiB diagnostic limit."
                }

                $elapsedPlannerSec = [int][Math]::Floor($plannerStageWatch.Elapsed.TotalSeconds)

                # Periodic activity probe (CPU & plan file growth)
                if (($elapsedPlannerSec - $lastProbeElapsed) -ge 1 -and -not $proc.HasExited) {
                    $lastProbeElapsed = $elapsedPlannerSec
                    $cpuMs = Get-ProcessTreeCpuMs $proc.Id
                    if ($cpuMs -ge ($lastCpuMs + 100)) {
                        $lastCpuMs = $cpuMs
                        $lastActivityUtc = [System.DateTime]::UtcNow
                        $lastActivityKind = "process-cpu"
                    }
                    $currentPlanBytes = [long]0
                    if (Test-Path -LiteralPath $planMsgFile -PathType Leaf) {
                        try {
                            $item = Get-Item -LiteralPath $planMsgFile -ErrorAction SilentlyContinue
                            if ($null -ne $item) { $currentPlanBytes += [long]$item.Length }
                        } catch {}
                    }
                    $planCandidate = Join-Path $iterDir "plan.json"
                    if (Test-Path -LiteralPath $planCandidate -PathType Leaf) {
                        try {
                            $item = Get-Item -LiteralPath $planCandidate -ErrorAction SilentlyContinue
                            if ($null -ne $item) { $currentPlanBytes += [long]$item.Length }
                        } catch {}
                    }
                    if ($currentPlanBytes -gt $lastPlanFileSize) {
                        $lastPlanFileSize = $currentPlanBytes
                        $lastActivityUtc = [System.DateTime]::UtcNow
                        $lastActivityKind = "file-growth"
                    }
                }

                # Check timeouts: Hard timeout takes precedence if total elapsed reached plannerTimeoutSec
                $plannerStageRemainingMs = [Math]::Max(1, ($plannerTimeoutSec * 1000) - [int]$plannerStageWatch.ElapsedMilliseconds)
                $remMsNow = Get-RemainingTimeoutMs $plannerStageRemainingMs
                if (-not $proc.HasExited -and ($elapsedPlannerSec -ge $plannerTimeoutSec -or $remMsNow -le 1)) {
                    $plannerTimedOut = $true
                    break
                }

                $idleSec = [int][Math]::Floor(([System.DateTime]::UtcNow - $lastActivityUtc).TotalSeconds)
                if ($idleSec -ge $plannerIdleTimeoutSec -and -not $proc.HasExited) {
                    $plannerIdleTimedOut = $true
                    break
                }

                # Heartbeat
                if (-not $proc.HasExited -and $elapsedPlannerSec -ge $nextPlannerHeartbeatSec) {
                    $state = if ($lastActivityKind -eq "file-growth") {
                        "file-growth"
                    } elseif ($lastActivityKind -eq "process-cpu") {
                        "analyzing"
                    } elseif ($lastActivityKind -eq "stdout" -or $lastActivityKind -eq "stderr") {
                        "tool-execution"
                    } elseif ($idleSec -ge 5) {
                        "waiting-model"
                    } else {
                        "analyzing"
                    }

                    $heartbeat = [ordered]@{
                        event = "SOL_ADVISOR_HEARTBEAT"
                        stage = "sol-planner"
                        elapsed_seconds = $elapsedPlannerSec
                        hard_timeout_seconds = $plannerTimeoutSec
                        idle_timeout_seconds = $plannerIdleTimeoutSec
                        idle_seconds = $idleSec
                        last_activity_kind = $lastActivityKind
                        stdout_bytes = $stdoutBuilder.Length
                        stderr_bytes = $stderrBuilder.Length
                        plan_bytes = $lastPlanFileSize
                        cpu_ms = $lastCpuMs
                        state = $state
                    } | ConvertTo-Json -Compress
                    [Console]::Error.WriteLine($heartbeat)
                    $nextPlannerHeartbeatSec += $plannerHeartbeatIntervalSec
                }

                if (-not $proc.HasExited -or -not $stdoutClosed -or -not $stderrClosed) { Start-Sleep -Milliseconds 100 }
            }

            if ($plannerTimedOut -or $plannerIdleTimedOut) {
                Stop-ProcessTree $proc

                $diagDir = Join-Path $physicalResultParent ("planner-diagnostics-iter-" + $iteration)
                try {
                    if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) {
                        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllText((Join-Path $diagDir "planner-stdout.log"), $stdoutBuilder.ToString(), $utf8NoBom)
                    [System.IO.File]::WriteAllText((Join-Path $diagDir "planner-stderr.log"), $stderrBuilder.ToString(), $utf8NoBom)
                    if (Test-Path -LiteralPath $planMsgFile) {
                        try { Copy-Item -LiteralPath $planMsgFile -Destination (Join-Path $diagDir "plan-msg-partial.tmp") -Force } catch {}
                    }
                    $diagReport = [ordered]@{
                        timestamp = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        stage = "sol-planner"
                        iteration = $iteration
                        timeout_kind = if ($plannerIdleTimedOut) { "idle_timeout" } else { "hard_timeout" }
                        failure_reason = if ($plannerIdleTimedOut) {
                            "Sol planner idle timeout of ${plannerIdleTimeoutSec}s exceeded; no stdout, stderr, plan file growth, or process CPU progress was observed."
                        } else {
                            "Sol planning stage exceeded its cap of $PlannerTimeout."
                        }
                        elapsed_seconds = $elapsedPlannerSec
                        idle_seconds = $idleSec
                        last_activity_kind = $lastActivityKind
                        stdout_bytes = $stdoutBuilder.Length
                        stderr_bytes = $stderrBuilder.Length
                        plan_bytes = $lastPlanFileSize
                        cpu_ms = $lastCpuMs
                    } | ConvertTo-Json -Depth 4
                    [System.IO.File]::WriteAllText((Join-Path $diagDir "diagnostics.json"), $diagReport, $utf8NoBom)
                } catch {
                    [Console]::Error.WriteLine("WARNING: Failed to preserve planner diagnostics: $_")
                }

                if ($plannerIdleTimedOut) {
                    Fail "Sol planning stage idle timeout of ${plannerIdleTimeoutSec}s exceeded; no stdout, stderr, plan file growth, or process CPU progress was observed. Diagnostics preserved at: $diagDir"
                } else {
                    Fail "Sol planning stage exceeded its cap of $PlannerTimeout. Diagnostics preserved at: $diagDir"
                }
            }

            $planExit = $proc.ExitCode
            $rawStdout = $stdoutBuilder.ToString()
            $rawStderr = $stderrBuilder.ToString()

            if (Test-Path -LiteralPath $planMsgFile) {
                $planRaw = [System.IO.File]::ReadAllText($planMsgFile, $utf8NoBom)
            } else {
                $planRaw = $rawStdout
            }
        } finally {
            Unregister-ActiveProcess $proc
            if (Test-Path -LiteralPath $planMsgFile) { try { [System.IO.File]::Delete($planMsgFile) } catch {} }
        }

        if ($planExit -ne 0) {
            if ($rawStderr -match '(?i)hit your usage limit|usage limit.*try again') {
                $retryHint = ""
                if ($rawStderr -match '(?i)(try again at[^\r\n.]*)') { $retryHint = " $($Matches[1].Trim())." }
                Fail "Sol planner is unavailable because the Codex account usage limit was reached.$retryHint No alternate model was used; retry after the account limit resets."
            }
            if ($rawStderr -match 'CreateProcessWithLogonW failed:\s*267|Access to the path .* is denied') {
                Fail "Sol planner could not inspect its disposable workspace under the Windows sandbox. The canonical worktree was not modified. Error: $rawStderr"
            }
            Fail "Sol planner failed with exit code $planExit. Error: $rawStderr"
        }

        # Bound planner output size (2 MiB)
        if ($planRaw.Length -gt 2097152) {
            Fail "Sol planner output exceeds 2 MiB limit."
        }

        Assert-HeadUnchanged $physicalWs "after planning stage"
        $fpAfterPlan = Get-DeterministicRepoManifest $physicalWs
        if ($fpBeforePlan.ManifestHash -ne $fpAfterPlan.ManifestHash) {
            Fail "Repository attribution violation: repository was modified during read-only Sol planning stage!"
        }

        # Parse & Strictly Validate plan JSON
        $cleanPlanJson = $planRaw.Trim()
        if ($cleanPlanJson.StartsWith('```')) {
            $lines = [regex]::Split($cleanPlanJson, '\r?\n')
            $filtered = [System.Collections.Generic.List[string]]::new()
            foreach ($l in $lines) {
                if (-not $l.Trim().StartsWith('```')) { $filtered.Add($l) }
            }
            $cleanPlanJson = ($filtered -join [System.Environment]::NewLine).Trim()
        }

        $planObj = $null
        try {
            $planObj = $cleanPlanJson | ConvertFrom-Json
        } catch {
            Fail "Sol planner output is not valid JSON: $planRaw"
        }

        if ($null -eq $planObj -or -not ($planObj -is [System.Management.Automation.PSCustomObject] -or $planObj -is [System.Collections.IDictionary])) {
            Fail "Sol plan must be a JSON object."
        }

        # Strict allowed keys in plan.json
        $allowedPlanKeys = @("objective", "owned_files", "interfaces", "constraints", "verification_commands", "suggested_verification_commands")
        foreach ($prop in $planObj.PSObject.Properties) {
            if ($prop.Name -notin $allowedPlanKeys) {
                Fail "Unknown key '$($prop.Name)' in plan.json (strict schema validation)."
            }
        }

        if ([string]::IsNullOrWhiteSpace($planObj.objective)) { Fail "Sol plan missing or empty 'objective' field." }
        if ($null -eq $planObj.owned_files -or $planObj.owned_files.Count -eq 0) { Fail "Sol plan missing or empty 'owned_files' array." }
        if ($planObj.owned_files.Count -gt $MaxOwnedFiles) { Fail "Sol plan owned_files exceeds the bounded maximum of $MaxOwnedFiles items. Split the task into a smaller independently verifiable phase." }

        # Validate owned files are relative and clean
        foreach ($of in $planObj.owned_files) {
            $ofStr = [string]$of
            if ([string]::IsNullOrWhiteSpace($ofStr) -or [System.IO.Path]::IsPathRooted($ofStr) -or $ofStr.Contains("..") -or $ofStr.Contains(":")) {
                Fail "Invalid owned_file entry in plan: '$ofStr'. Must be a clean relative path."
            }
        }

        $verCmds = @()
        if ($null -ne $planObj.verification_commands) {
            $verCmds = $planObj.verification_commands
        } elseif ($null -ne $planObj.suggested_verification_commands) {
            $verCmds = $planObj.suggested_verification_commands
        }
        if ($verCmds.Count -gt $effectiveMaxVerificationCommands) { Fail "Sol plan verification_commands exceeds the bounded maximum of $effectiveMaxVerificationCommands items." }

        # Save plan.json
        $planJsonPath = Join-Path $iterDir "plan.json"
        $planJsonContent = $planObj | ConvertTo-Json -Depth 16
        [System.IO.File]::WriteAllText($planJsonPath, $planJsonContent, $utf8NoBom)
        $lastPlan = $planObj

        # Render five-part worker-spec.md (capped at 24 KiB)
        $ownedFilesListMd = ($planObj.owned_files | ForEach-Object { "- $_" }) -join "`n"
        $interfacesMd = if ($planObj.interfaces -is [System.Array]) { ($planObj.interfaces | ForEach-Object { "- $_" }) -join "`n" } else { [string]$planObj.interfaces }
        $constraintsMd = if ($planObj.constraints -is [System.Array]) { ($planObj.constraints | ForEach-Object { "- $_" }) -join "`n" } else { [string]$planObj.constraints }
        $verCommandsMd = if ($verCmds.Count -gt 0) {
            ($verCmds | ForEach-Object { "- Run: $_`n  Success: exit code 0" }) -join "`n"
        } else {
            "- Run: pwsh -Command `"exit 0`"`n  Success: exit code 0"
        }

        $workerSpecContent = @"
OBJECTIVE
$($planObj.objective)

FILES AND OWNERSHIP
You own only:
$ownedFilesListMd

You are not alone in the codebase. Other agents or the user may be editing concurrently.
Preserve their edits, do not revert unrelated work, and adapt to changes already present.
Do not modify files outside your ownership.

INTERFACES
$interfacesMd

CONSTRAINTS
$constraintsMd
- Do not redesign or redo architecture; follow the specification strictly.
- No fallback models or alternate execution providers.
- Focus strictly on owned files and incremental fixes; do not crawl or re-index the broader repository.
- Micro-verification only: do not run entire test suites or full regression suites; test only the specific changes or leaf tests relevant to owned files.
- In your final response under 'VERIFIED:', explicitly record each verification command run and its numeric exit code (e.g., "(exit code 0)").

VERIFICATION
$verCommandsMd
"@
        $specBytes = [System.Text.Encoding]::UTF8.GetBytes($workerSpecContent)
        if ($specBytes.Length -gt 24576) {
            Fail "Rendered worker-spec.md exceeds conservative maximum size of 24 KiB ($($specBytes.Length) bytes)."
        }

        $workerSpecPath = Join-Path $iterDir "worker-spec.md"
        [System.IO.File]::WriteAllText($workerSpecPath, $workerSpecContent, $utf8NoBom)
        $stage1Sec = [Math]::Round($swStage1.Elapsed.TotalSeconds, 2)

        # -------------------------------------------------------------
        # STAGE 2: Antigravity Code Implementation Window
        # -------------------------------------------------------------
        $swStage2 = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-HeadUnchanged $physicalWs "before Antigravity implementation window"
        $preImplSnapshot = Capture-RepositorySnapshot $physicalWs
        $preImplManifest = Get-DeterministicRepoManifest $physicalWs
        $preImplMetaHash = Get-ScopedGitMetadataDigest $physicalWs $false

        $implEvidencePath = Join-Path $iterDir "implementer-evidence.json"
        $implTimeoutSec = $implementerTimeoutSec
        $implTimeoutStr = "${implTimeoutSec}s"

        $implArgs = [System.Collections.Generic.List[string]]::new()
        $implArgs.Add("-NoProfile")
        $implArgs.Add("-File")
        $implArgs.Add($implScript)
        $implArgs.Add("-Workspace")
        $implArgs.Add($physicalWs)
        $implArgs.Add("-SpecFile")
        $implArgs.Add($workerSpecPath)
        $implArgs.Add("-EvidenceFile")
        $implArgs.Add($implEvidencePath)
        $implArgs.Add("-PrintTimeout")
        $implArgs.Add($implTimeoutStr)
        $implArgs.Add("-IdleTimeout")
        $implArgs.Add($IdleTimeout)
        $implArgs.Add("-GenerationPreflightTimeout")
        $implArgs.Add($GenerationPreflightTimeout)
        if ($iteration -gt 1) {
            $implArgs.Add("-SkipGenerationPreflight")
        }
        if ($effectiveSkipPermissions) {
            $implArgs.Add("-DangerouslySkipPermissions")
        }
        if ($effectiveTestMode) {
            $implArgs.Add("-TestMode")
            if (-not [string]::IsNullOrWhiteSpace($TestAgyExe)) {
                $implArgs.Add("-TestAgyExe")
                $implArgs.Add($TestAgyExe)
            }
        }

        $psiImpl = [System.Diagnostics.ProcessStartInfo]::new()
        $psiImpl.FileName = "pwsh"
        $psiImpl.UseShellExecute = $false
        $psiImpl.RedirectStandardOutput = $true
        $psiImpl.RedirectStandardError = $true
        $psiImpl.CreateNoWindow = $true
        $psiImpl.WorkingDirectory = $physicalWs
        foreach ($arg in $implArgs) { $psiImpl.ArgumentList.Add($arg) }

        $procImpl = [System.Diagnostics.Process]::Start($psiImpl)
        if ($null -eq $procImpl) { Fail "Failed to start Antigravity implementer process." }
        Register-ActiveProcess $procImpl
        $implOutTask = $procImpl.StandardOutput.ReadToEndAsync()
        $implErrBuilder = [System.Text.StringBuilder]::new()
        $implErrClosed = $false
        $implErrLineTask = $procImpl.StandardError.ReadLineAsync()
        $implOuterWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $implTimedOut = $false
        $implOuterCapMs = [Math]::Min(($implTimeoutSec + 5) * 1000, (Get-RemainingTimeoutMs))
        while (-not $procImpl.HasExited -or -not $implErrClosed) {
            if (-not $implErrClosed -and $implErrLineTask.IsCompleted) {
                $line = $implErrLineTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $implErrClosed = $true
                } else {
                    [void]$implErrBuilder.AppendLine($line)
                    [Console]::Error.WriteLine($line)
                    $implErrLineTask = $procImpl.StandardError.ReadLineAsync()
                }
            }
            if ($implErrBuilder.Length -gt 4194304) {
                $implTimedOut = $true
                break
            }
            if (-not $procImpl.HasExited -and $implOuterWatch.ElapsedMilliseconds -ge $implOuterCapMs) {
                $implTimedOut = $true
                break
            }
            if (-not $procImpl.HasExited -or -not $implErrClosed) { Start-Sleep -Milliseconds 100 }
        }
        if ($implTimedOut) {
            Stop-ProcessTree $procImpl
        }
        Unregister-ActiveProcess $procImpl
        $implOutCompleted = $implOutTask.Wait(3000)
        $implExit = if ($procImpl.HasExited) { $procImpl.ExitCode } else { -1 }
        if ($implOutCompleted -and $implOutTask.Result.Length -gt 0) { [Console]::Write($implOutTask.Result) }

        if ($implTimedOut -or $implExit -ne 0) {
            $postFailureSnapshot = Capture-RepositorySnapshot $physicalWs
            $partialFiles = @(Get-WindowDelta $preImplSnapshot $postFailureSnapshot)
            $failureEnvelope = [ordered]@{
                event = "SOL_ADVISOR_FAILURE"
                stage = "implementation-window"
                reason = if ($implTimedOut) { "Implementer wrapper exceeded the bounded stage timeout of $ImplementerTimeout." } else { "Implementer wrapper exited with code $implExit." }
                completed = $false
                reviewed = $false
                partial_worktree_trusted = $false
                worktree_preserved = $true
                window_modified_files = $partialFiles
            } | ConvertTo-Json -Compress
            [Console]::Error.WriteLine($failureEnvelope)
            Fail "Antigravity implementer window failed; partial worktree changes were preserved and are not accepted."
        }

        if (-not (Test-Path -LiteralPath $implEvidencePath -PathType Leaf)) {
            Fail "Antigravity implementer did not produce evidence file: $implEvidencePath"
        }

        $implEvidenceText = [System.IO.File]::ReadAllText($implEvidencePath, $utf8NoBom)
        $implEvidenceObj = $implEvidenceText | ConvertFrom-Json
        $lastImplementerEvidenceRaw = $implEvidenceText
        $lastImplementerEvidenceObj = $implEvidenceObj

        Assert-HeadUnchanged $physicalWs "after Antigravity implementation window"
        $postImplSnapshot = Capture-RepositorySnapshot $physicalWs
        $postImplManifest = Get-DeterministicRepoManifest $physicalWs
        $postImplMetaHash = Get-ScopedGitMetadataDigest $physicalWs $false

        # Verify Scoped Git Metadata Integrity
        $scopedGitMetaUnchanged = ($preImplMetaHash -eq $postImplMetaHash)
        if (-not $scopedGitMetaUnchanged) {
            Fail "Scoped Git metadata integrity violated during Antigravity implementation window: metadata hash changed from '$preImplMetaHash' to '$postImplMetaHash'."
        }

        # Detect In-Progress Git Operations
        $inProgressOps = [System.Collections.Generic.List[string]]::new()
        $gitDirRel = (Invoke-GitCmd $physicalWs @("rev-parse", "--git-dir")).Trim()
        $gitDirFull = [System.IO.Path]::GetFullPath((Join-Path $physicalWs $gitDirRel))
        $opMarkers = @("MERGE_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE")
        foreach ($marker in $opMarkers) {
            $mPath = Join-Path $gitDirFull $marker
            if (Test-Path -LiteralPath $mPath) {
                $inProgressOps.Add($marker)
            }
        }
        if ($inProgressOps.Count -gt 0) {
            Fail "In-progress Git operations detected after Antigravity implementation window: $($inProgressOps -join ', ')"
        }

        # Compute Window Delta
        $windowDeltaFiles = @(Get-WindowDelta $preImplSnapshot $postImplSnapshot)

        # Validate Ownership strictly on Window Delta (including rename destinations)
        $unownedMods = [System.Collections.Generic.List[string]]::new()
        foreach ($cf in $windowDeltaFiles) {
            $normCf = $cf.Replace("\", "/").TrimStart('/')
            if (Test-IsIgnoredRuntimeCachePath $normCf) {
                continue
            }
            $isOwned = $false
            foreach ($of in $planObj.owned_files) {
                $normOf = ([string]$of).Replace("\", "/").TrimStart('/')
                if ($normCf.Equals($normOf, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $normCf.StartsWith($normOf.TrimEnd('/') + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isOwned = $true
                    break
                }
            }
            if (-not $isOwned) {
                $unownedMods.Add($cf)
            }
        }

        if ($unownedMods.Count -gt 0) {
            Fail "Ownership violation: Antigravity modified file(s) outside declared owned_files: $($unownedMods -join ', ')"
        }
        $stage2Sec = [Math]::Round($swStage2.Elapsed.TotalSeconds, 2)

        # -------------------------------------------------------------
        # STAGE 3: Parent Machine Integrity & Verification Checks
        # -------------------------------------------------------------
        $swStage3 = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-HeadUnchanged $physicalWs "before parent verification stage"
        $preParentManifest = Get-DeterministicRepoManifest $physicalWs

        $headUnchangedVerified = ($postImplManifest.HeadSha -eq $baselineHeadSha)
        $ownershipCheckPassed = ($unownedMods.Count -eq 0)
        $integrityPassed = $headUnchangedVerified -and $scopedGitMetaUnchanged -and ($inProgressOps.Count -eq 0)

        $trustedVerification = [ordered]@{
            supplied = $false
            script_sha256 = ""
            command = ""
            exit_code_observed = $null
            passed = $null
            stdout = ""
            stderr = ""
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedTrustedVerificationScript)) {
            $trustedVerification.supplied = $true
            $trustedVerification.script_sha256 = $trustedVerificationScriptSha256
            $trustedVerification.command = "bash <trusted-verification-script>"
            $verifyBefore = Get-DeterministicRepoManifest $physicalWs
            $verifyPsi = [System.Diagnostics.ProcessStartInfo]::new()
            $verifyPsi.FileName = $trustedVerificationBashExe
            $verifyPsi.UseShellExecute = $false
            $verifyPsi.RedirectStandardOutput = $true
            $verifyPsi.RedirectStandardError = $true
            $verifyPsi.CreateNoWindow = $true
            $verifyPsi.WorkingDirectory = $physicalWs
            $verifyPsi.ArgumentList.Add($resolvedTrustedVerificationScript)
            $verifyProc = [System.Diagnostics.Process]::Start($verifyPsi)
            if ($null -eq $verifyProc) { Fail "Failed to start trusted verification script." }
            Register-ActiveProcess $verifyProc
            $verifyStdoutTask = $verifyProc.StandardOutput.ReadToEndAsync()
            $verifyStderrTask = $verifyProc.StandardError.ReadToEndAsync()
            $verifyWaitMs = Get-RemainingTimeoutMs ($verificationTimeoutSec * 1000)
            if (-not $verifyProc.WaitForExit($verifyWaitMs)) {
                Stop-ProcessTree $verifyProc
                Fail "Trusted verification script exceeded its bounded timeout of $VerificationTimeout."
            }
            Unregister-ActiveProcess $verifyProc
            [System.Threading.Tasks.Task]::WaitAll($verifyStdoutTask, $verifyStderrTask)
            $verifyStdout = $verifyStdoutTask.Result
            $verifyStderr = $verifyStderrTask.Result
            if ($verifyStdout.Length -gt 2097152 -or $verifyStderr.Length -gt 2097152) { Fail "Trusted verification output exceeded the 2 MiB per-stream limit." }
            $trustedVerification.exit_code_observed = $verifyProc.ExitCode
            $trustedVerification.passed = ($verifyProc.ExitCode -eq 0)
            $trustedVerification.stdout = $verifyStdout
            $trustedVerification.stderr = $verifyStderr
            $verifyAfter = Get-DeterministicRepoManifest $physicalWs
            if ($verifyBefore.ManifestHash -ne $verifyAfter.ManifestHash) { Fail "Trusted verification script mutated the repository." }
            if ($verifyProc.ExitCode -ne 0) {
                Fail "Trusted verification failed with exit code $($verifyProc.ExitCode).`nSTDOUT:`n$verifyStdout`nSTDERR:`n$verifyStderr"
            }
        }

        $trustedVerificationPassed = (-not $trustedVerification.supplied) -or ($trustedVerification.passed -eq $true)
        $allChecksPassed = $headUnchangedVerified -and $ownershipCheckPassed -and $integrityPassed -and ($implEvidenceObj.invocation.exit_code_observed -eq 0) -and $trustedVerificationPassed

        $postParentManifest = Get-DeterministicRepoManifest $physicalWs
        if ($preParentManifest.ManifestHash -ne $postParentManifest.ManifestHash) {
            Fail "Repository mutation detected during parent verification stage!"
        }

        # Compute Bindings over exact raw bytes
        $specHash = Compute-Sha256Hex $specBytes
        $planHash = Compute-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($planJsonContent))
        $implEvHash = Compute-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($implEvidenceText))

        $aggregateDeltaFiles = @(Get-WindowDelta $initialSnapshot $postImplSnapshot)

        # Construct aggregate delta manifest string and hash
        $aggDeltaMs = [System.IO.MemoryStream]::new()
        $aggWriter = [System.IO.StreamWriter]::new($aggDeltaMs, $utf8NoBom)
        foreach ($af in $aggregateDeltaFiles) {
            $preVal = if ($initialSnapshot.FileMap.ContainsKey($af)) { $initialSnapshot.FileMap[$af] } else { "MISSING" }
            $postVal = if ($postImplSnapshot.FileMap.ContainsKey($af)) { $postImplSnapshot.FileMap[$af] } else { "MISSING" }
            $aggWriter.WriteLine("PATH:$af")
            $aggWriter.WriteLine("PRE:$preVal")
            $aggWriter.WriteLine("POST:$postVal")
        }
        $aggWriter.Flush()
        $aggDeltaBytes = $aggDeltaMs.ToArray()
        $aggDeltaHash = Compute-Sha256Hex $aggDeltaBytes
        $aggWriter.Dispose()
        $aggDeltaMs.Dispose()

        $parentVerEnvelope = [ordered]@{
            schema_version = 1
            iteration = $iteration
            verified_at_utc = [System.DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            ownership_check = [ordered]@{
                passed = $ownershipCheckPassed
                declared_owned_files = $planObj.owned_files
                window_modified_files = $windowDeltaFiles
                unowned_modifications = $unownedMods
            }
            integrity_check = [ordered]@{
                passed = $integrityPassed
                head_unchanged = $headUnchangedVerified
                baseline_head_sha = $baselineHeadSha
                current_head_sha = $postParentManifest.HeadSha
                scoped_git_metadata_unchanged = $scopedGitMetaUnchanged
                in_progress_git_operations = @($inProgressOps)
            }
            implementer_evidence_assessment = [ordered]@{
                passed = ($implEvidenceObj.invocation.exit_code_observed -eq 0)
                implementer_status = [string]$implEvidenceObj.agy_result.status
                implementer_reported_tests_untrusted = $true
                implementer_reported_test_summary = "Implementer reported tests (untrusted): $($implEvidenceObj.agy_result.response)"
            }
            suggested_commands_unexecuted = $verCmds
            trusted_verification = $trustedVerification
            all_checks_passed = $allChecksPassed
            bindings = [ordered]@{
                task_sha256 = $taskSha256
                plan_sha256 = $planHash
                spec_sha256 = $specHash
                implementer_evidence_sha256 = $implEvHash
                pre_window_manifest_sha256 = $preImplManifest.ManifestHash
                post_window_manifest_sha256 = $postImplManifest.ManifestHash
                repository_manifest_sha256 = $postParentManifest.ManifestHash
                aggregate_delta_manifest_sha256 = $aggDeltaHash
            }
        }

        $parentVerPath = Join-Path $iterDir "parent-verification.json"
        $parentVerText = $parentVerEnvelope | ConvertTo-Json -Depth 16
        [System.IO.File]::WriteAllText($parentVerPath, $parentVerText, $utf8NoBom)
        $parentVerHash = Compute-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($parentVerText))

        $lastParentVerificationRaw = $parentVerText
        $lastParentVerificationObj = $parentVerEnvelope
        $stage3Sec = [Math]::Round($swStage3.Elapsed.TotalSeconds, 2)

        # -------------------------------------------------------------
        # STAGE 4: Fresh Read-Only Sol Review Gate
        # -------------------------------------------------------------
        $swStage4 = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-HeadUnchanged $physicalWs "before fresh review stage"
        $fpBeforeReview = Get-DeterministicRepoManifest $physicalWs
        $reviewOutPath = Join-Path $iterDir "review-evidence.json"
        $revTimeoutSec = $reviewerTimeoutSec
        $revTimeoutStr = "${revTimeoutSec}s"

        $revArgs = [System.Collections.Generic.List[string]]::new()
        $revArgs.Add("-NoProfile")
        $revArgs.Add("-File")
        $revArgs.Add($reviewerScript)
        $revArgs.Add("-Workspace")
        $revArgs.Add($physicalWs)
        $revArgs.Add("-GoalFile")
        $revArgs.Add($resolvedTaskFile)
        $revArgs.Add("-EvidenceFile")
        $revArgs.Add($implEvidencePath)
        $revArgs.Add("-ParentVerificationFile")
        $revArgs.Add($parentVerPath)
        $revArgs.Add("-ReviewOutputFile")
        $revArgs.Add($reviewOutPath)
        $revArgs.Add("-Timeout")
        $revArgs.Add($revTimeoutStr)
        if (-not [string]::IsNullOrWhiteSpace($effectiveCodexModel)) {
            $revArgs.Add("-Model")
            $revArgs.Add($effectiveCodexModel)
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveReasoningEffort)) {
            $revArgs.Add("-ReasoningEffort")
            $revArgs.Add($effectiveReasoningEffort)
        }
        if ($effectiveTestMode) {
            $revArgs.Add("-TestMode")
            if (-not [string]::IsNullOrWhiteSpace($TestCodexBin)) {
                $revArgs.Add("-TestCodexBin")
                $revArgs.Add($TestCodexBin)
            }
        }

        $psiRev = [System.Diagnostics.ProcessStartInfo]::new()
        $psiRev.FileName = "pwsh"
        $psiRev.UseShellExecute = $false
        $psiRev.RedirectStandardOutput = $true
        $psiRev.RedirectStandardError = $true
        $psiRev.CreateNoWindow = $true
        $psiRev.WorkingDirectory = $physicalWs
        foreach ($arg in $revArgs) { $psiRev.ArgumentList.Add($arg) }

        $procRev = [System.Diagnostics.Process]::Start($psiRev)
        if ($null -eq $procRev) { Fail "Failed to start fresh reviewer process." }
        Register-ActiveProcess $procRev
        $revOutTask = $procRev.StandardOutput.ReadToEndAsync()
        $revErrTask = $procRev.StandardError.ReadToEndAsync()

        $reviewOuterCapMs = [Math]::Min(($revTimeoutSec + 5) * 1000, (Get-RemainingTimeoutMs))
        if (-not $procRev.WaitForExit($reviewOuterCapMs)) {
            Stop-ProcessTree $procRev
            Fail "Fresh reviewer wrapper exceeded the bounded stage timeout of $ReviewerTimeout."
        }
        Unregister-ActiveProcess $procRev
        [System.Threading.Tasks.Task]::WaitAll($revOutTask, $revErrTask)
        $revExit = $procRev.ExitCode
        if ($revOutTask.Result.Length -gt 0) { [Console]::Write($revOutTask.Result) }
        if ($revErrTask.Result.Length -gt 0) { [Console]::Error.Write($revErrTask.Result) }

        if ($revExit -ne 0) {
            Fail "Fresh reviewer wrapper failed with exit code $revExit."
        }

        if (-not (Test-Path -LiteralPath $reviewOutPath -PathType Leaf)) {
            Fail "Fresh reviewer did not produce review output file: $reviewOutPath"
        }

        $rawReviewData = [System.IO.File]::ReadAllText($reviewOutPath, $utf8NoBom)
        $lastReviewEnvelopeRaw = $rawReviewData
        $lastReviewEnvelopeHash = Compute-Sha256String $rawReviewData

        $reviewDoc = $null
        try {
            $reviewDoc = [System.Text.Json.JsonDocument]::Parse($rawReviewData)
        } catch {
            Fail "review-evidence.json is not valid JSON: $_"
        }
        if ($reviewDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            Fail "review-evidence.json must be a JSON object."
        }

        $reviewData = $rawReviewData | ConvertFrom-Json
        $lastReviewEnvelopeObj = $reviewData

        Assert-HeadUnchanged $physicalWs "after fresh review stage"
        $fpAfterReview = Get-DeterministicRepoManifest $physicalWs
        if ($fpBeforeReview.ManifestHash -ne $fpAfterReview.ManifestHash) {
            Fail "Repository immutability violated during fresh review stage!"
        }

        # Validate Reviewer Output Schema & Bindings strictly
        $allowedRevTopKeys = @("schema_version", "reviewer", "review", "reviewed_bindings")
        foreach ($prop in $reviewData.PSObject.Properties) {
            if ($prop.Name -notin $allowedRevTopKeys) {
                Fail "Unknown key '$($prop.Name)' in review-evidence.json (strict schema validation)."
            }
        }

        if ($null -eq $reviewData.schema_version -or $reviewDoc.RootElement.GetProperty("schema_version").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or [int]$reviewData.schema_version -ne 1) {
            Fail "review-evidence.json schema_version must be integer 1."
        }

        # Validate reviewer object
        if ($null -eq $reviewData.reviewer -or -not ($reviewData.reviewer -is [System.Management.Automation.PSCustomObject])) {
            Fail "review-evidence.json reviewer missing or not an object."
        }
        $allowedReviewerObjKeys = @("model_requested", "effort_requested", "sandbox_mode_requested", "ephemeral", "exit_code_observed", "repository_unchanged_verified")
        foreach ($prop in $reviewData.reviewer.PSObject.Properties) {
            if ($prop.Name -notin $allowedReviewerObjKeys) {
                Fail "Unknown key '$($prop.Name)' in reviewer object (strict schema validation)."
            }
        }
        $expectedReviewerModel = if (-not [string]::IsNullOrWhiteSpace($effectiveCodexModel)) { $effectiveCodexModel } else { "inherited" }
        if ($reviewData.reviewer.model_requested -ne $expectedReviewerModel -or $reviewData.reviewer.effort_requested -ne "inherited" -or $reviewData.reviewer.sandbox_mode_requested -ne "read-only") {
            Fail "review-evidence.json reviewer pins mismatch (expected model '$expectedReviewerModel', got '$($reviewData.reviewer.model_requested)')."
        }
        $revObjElem = $reviewDoc.RootElement.GetProperty("reviewer")
        foreach ($name in @("model_requested", "effort_requested", "sandbox_mode_requested")) { if ($revObjElem.GetProperty($name).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "review-evidence.json reviewer.$name must be string." } }
        if ($revObjElem.GetProperty("ephemeral").ValueKind -ne [System.Text.Json.JsonValueKind]::True -or $revObjElem.GetProperty("repository_unchanged_verified").ValueKind -ne [System.Text.Json.JsonValueKind]::True) {
            Fail "review-evidence.json reviewer booleans must be true."
        }
        if ($revObjElem.GetProperty("exit_code_observed").ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or [int]$reviewData.reviewer.exit_code_observed -ne 0) { Fail "review-evidence.json reviewer.exit_code_observed must be integer 0." }

        # Validate review object
        if ($null -eq $reviewData.review -or -not ($reviewData.review -is [System.Management.Automation.PSCustomObject])) {
            Fail "review-evidence.json review missing or not an object."
        }
        $allowedReviewKeys = @("verdict", "reason", "findings", "residual_risk", "reviewed_no_change")
        foreach ($prop in $reviewData.review.PSObject.Properties) {
            if ($prop.Name -notin $allowedReviewKeys) {
                Fail "Unknown key '$($prop.Name)' in review object (strict schema validation)."
            }
        }
        $reviewElem = $reviewDoc.RootElement.GetProperty("review")
        foreach ($name in @("verdict", "reason", "findings", "residual_risk")) { if ($reviewElem.GetProperty($name).ValueKind -ne [System.Text.Json.JsonValueKind]::String) { Fail "review-evidence.json review.$name must be string." } }
        if ($reviewElem.GetProperty("reviewed_no_change").ValueKind -notin @([System.Text.Json.JsonValueKind]::True, [System.Text.Json.JsonValueKind]::False)) { Fail "review-evidence.json review.reviewed_no_change must be boolean." }

        # Mandatory closed set of 9 reviewed bindings verification
        if ($null -eq $reviewData.PSObject.Properties['reviewed_bindings'] -or $null -eq $reviewData.reviewed_bindings -or -not ($reviewData.reviewed_bindings -is [System.Management.Automation.PSCustomObject])) {
            Fail "Fresh reviewer output missing mandatory 'reviewed_bindings' object."
        }

        $expectedReviewBindings = @{
            task_sha256 = $taskSha256
            plan_sha256 = $planHash
            spec_sha256 = $specHash
            implementer_evidence_sha256 = $implEvHash
            parent_verification_sha256 = $parentVerHash
            pre_window_manifest_sha256 = $preImplManifest.ManifestHash
            post_window_manifest_sha256 = $postImplManifest.ManifestHash
            repository_manifest_sha256 = $postParentManifest.ManifestHash
            aggregate_delta_manifest_sha256 = $aggDeltaHash
        }

        $requiredRevKeys = @(
            "task_sha256", "plan_sha256", "spec_sha256", "implementer_evidence_sha256",
            "parent_verification_sha256", "pre_window_manifest_sha256",
            "post_window_manifest_sha256", "repository_manifest_sha256",
            "aggregate_delta_manifest_sha256"
        )

        foreach ($prop in $reviewData.reviewed_bindings.PSObject.Properties) {
            if ($prop.Name -notin $requiredRevKeys) {
                Fail "Unknown key '$($prop.Name)' in reviewer reviewed_bindings (closed set validation)."
            }
        }

        foreach ($bk in $requiredRevKeys) {
            if ($null -eq $reviewData.reviewed_bindings.PSObject.Properties[$bk] -or [string]::IsNullOrWhiteSpace([string]$reviewData.reviewed_bindings.$bk)) {
                Fail "Reviewer reviewed_bindings missing mandatory key '$bk'."
            }
            $actVal = [string]$reviewData.reviewed_bindings.$bk
            if ($actVal -notmatch '^[0-9a-f]{64}$') {
                Fail "Reviewer binding '$bk' value '$actVal' is not 64-hex string."
            }
            $expVal = $expectedReviewBindings[$bk]
            if ($actVal -ne $expVal) {
                Fail "Reviewer binding mismatch for '$bk': '$actVal' != '$expVal'"
            }
        }

        $verdict = if ($null -ne $reviewData.review.PSObject.Properties['verdict']) { [string]$reviewData.review.verdict } else { "" }
        $reason = if ($null -ne $reviewData.review.PSObject.Properties['reason']) { [string]$reviewData.review.reason } else { "" }
        $findings = if ($null -ne $reviewData.review.PSObject.Properties['findings']) { [string]$reviewData.review.findings } else { "" }
        $residualRisk = if ($null -ne $reviewData.review.PSObject.Properties['residual_risk']) { [string]$reviewData.review.residual_risk } else { "" }

        # Typed JSON boolean check for reviewed_no_change
        $reviewedNoChangeAccepted = $false
        foreach ($topProp in $reviewDoc.RootElement.EnumerateObject()) {
            if ($topProp.Name -eq "review" -and $topProp.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                foreach ($subProp in $topProp.Value.EnumerateObject()) {
                    if ($subProp.Name -eq "reviewed_no_change") {
                        if ($subProp.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::True -and $subProp.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::False) {
                            Fail "review-evidence.json reviewed_no_change must be an actual JSON boolean, not string or number."
                        }
                        $reviewedNoChangeAccepted = $subProp.Value.GetBoolean()
                        break
                    }
                }
            }
        }

        [Console]::WriteLine("Review Verdict: $verdict")
        [Console]::WriteLine("Review Reason: $reason")

        $stage4Sec = [Math]::Round($swStage4.Elapsed.TotalSeconds, 2)
        $iterTotalSec = [Math]::Round(($stage1Sec + $stage2Sec + $stage3Sec + $stage4Sec), 2)
        $iterTelemetry = [ordered]@{
            iteration = $iteration
            planner_seconds = $stage1Sec
            implementer_seconds = $stage2Sec
            parent_verify_seconds = $stage3Sec
            reviewer_seconds = $stage4Sec
            total_seconds = $iterTotalSec
        }
        $stageTelemetryList.Add([PSCustomObject]$iterTelemetry)

        # -------------------------------------------------------------
        # STAGE 5: Decision & State Transition
        # -------------------------------------------------------------
        if ($verdict -eq "SHIP") {
            if (-not $allChecksPassed) {
                Fail "Reviewer issued SHIP but parent verification checks failed."
            }

            # Aggregate Task Changes Check
            $aggregateChangedFiles = @(Get-WindowDelta $initialSnapshot $postImplSnapshot)

            $repStatus = "complete"
            $repObj = $planObj.objective

            if ($null -eq $aggregateChangedFiles -or $aggregateChangedFiles.Length -eq 0) {
                if (-not $reviewedNoChangeAccepted) {
                    Fail "Aggregate task delta is empty, but reviewer did not explicitly confirm reviewed_no_change: true."
                }
                $repStatus = "reviewed_no_change"
                $repChanges = "None (no changes required; verified existing codebase)."
            } else {
                $repChanges = ($aggregateChangedFiles | ForEach-Object { "- $_" }) -join "`n"
            }

            $repVerified = "Machine repository integrity, scoped Git metadata, and ownership verified (exit code 0); implementer reported tests: $($implEvidenceObj.agy_result.response.Trim()) [untrusted]"
            $repJudgment = "none"
            $repGaps = if ([string]::IsNullOrWhiteSpace($residualRisk) -or $residualRisk.ToLowerInvariant() -eq "none") { "none" } else { $residualRisk }

            $finalReportContent = @"
STATUS: $repStatus
OBJECTIVE: $repObj
CHANGES:
$repChanges
VERIFIED:
$repVerified
JUDGMENT CALLS: $repJudgment
GAPS: $repGaps
"@
            break
        } elseif ($verdict -eq "FIX-FIRST") {
            if ($iteration -gt $MaxCorrections) {
                Fail "Reviewer issued FIX-FIRST but maximum correction count ($MaxCorrections) has been exhausted."
            }
            $lastReviewFindings = $findings
            $lastReviewReason = $reason
            $iteration++
            continue
        } elseif ($verdict -eq "RETHINK") {
            Fail "Reviewer issued RETHINK verdict: $reason"
        } else {
            Fail "Unknown review verdict '$verdict'."
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalReportContent)) {
        Fail "Orchestration terminated without producing final report."
    }

    # 8.5 Publish Stage Telemetry Report & SOL_ADVISOR_TELEMETRY event
    if ($stageTelemetryList.Count -gt 0) {
        $totSec = [Math]::Round($swTotal.Elapsed.TotalSeconds, 2)
        $telemetryDoc = [ordered]@{
            event = "SOL_ADVISOR_TELEMETRY"
            total_seconds = $totSec
            iterations = $stageTelemetryList
        }
        $telemetryJson = $telemetryDoc | ConvertTo-Json -Depth 4 -Compress
        [Console]::Error.WriteLine($telemetryJson)

        try {
            $telemetryPath = Join-Path $runDir "telemetry.json"
            [System.IO.File]::WriteAllText($telemetryPath, ($telemetryDoc | ConvertTo-Json -Depth 4), $utf8NoBom)
        } catch {}

        [Console]::WriteLine("")
        [Console]::WriteLine("========================== Sol Advisor Stage Telemetry ==========================")
        [Console]::WriteLine(("{0,-6} | {1,-13} | {2,-17} | {3,-19} | {4,-14} | {5,-10}" -f "Iter", "Planner (s)", "Implementer (s)", "Parent Verify (s)", "Reviewer (s)", "Total (s)"))
        [Console]::WriteLine("-------+---------------+-------------------+---------------------+----------------+-----------")
        foreach ($row in $stageTelemetryList) {
            [Console]::WriteLine(("{0,6} | {1,13:F2} | {2,17:F2} | {3,19:F2} | {4,14:F2} | {5,10:F2}" -f $row.iteration, $row.planner_seconds, $row.implementer_seconds, $row.parent_verify_seconds, $row.reviewer_seconds, $row.total_seconds))
        }
        [Console]::WriteLine("-------+---------------+-------------------+---------------------+----------------+-----------")
        [Console]::WriteLine(("Total Orchestration Time: {0:F2}s (Iterations: {1})" -f $totSec, $stageTelemetryList.Count))
        [Console]::WriteLine("=================================================================================")
        [Console]::WriteLine("")
    }

    # 9. Atomic Two-Phase Publication to ResultFile
    $tmpFileName = ".result-tmp." + [System.Guid]::NewGuid().ToString("N") + ".tmp"
    $tmpFilePath = [System.IO.Path]::Combine($physicalResultParent, $tmpFileName)
    $tmpCreated = $false

    try {
        $stream = [System.IO.FileStream]::new(
            $tmpFilePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $tmpCreated = $true

        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            $sb = [System.Text.StringBuilder]::new(1024)
            $res = [SolAdvisorLauncher.Win32Path]::GetFinalPathNameByHandle($stream.SafeFileHandle, $sb, 1024, 0)
            if ($res -eq 0) {
                Fail "Failed to determine final canonical path of created temporary result file handle."
            }
            $finalHandlePath = $sb.ToString()
            if ($finalHandlePath.StartsWith("\\?\UNC\")) {
                $finalHandlePath = "\\" + $finalHandlePath.Substring(8)
            } elseif ($finalHandlePath.StartsWith("\\?\")) {
                $finalHandlePath = $finalHandlePath.Substring(4)
            }
            $expectedParent = $physicalResultParent.TrimEnd('\', '/')
            $finalParent = [System.IO.Path]::GetDirectoryName($finalHandlePath).TrimEnd('\', '/')
            if ($finalParent -ne $expectedParent) {
                Fail "Adversarial parent path swap detected: created temporary file target '$finalHandlePath' does not reside in validated parent '$expectedParent'."
            }
        }

        $writer = [System.IO.StreamWriter]::new($stream, $utf8NoBom)
        $writer.Write($finalReportContent + "`n")
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $ResultFile) {
            Fail "Result destination already exists (no-clobber): $ResultFile"
        }

        try {
            [System.IO.File]::Move($tmpFilePath, $ResultFile)
            $tmpCreated = $false
        } catch [System.IO.IOException] {
            Fail "Result file already exists or appeared during publishing (no-clobber): $_"
        }
    } catch {
        Fail "Could not publish result file: $_"
    } finally {
        if ($null -ne $writer) { try { $writer.Dispose() } catch {} }
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        if ($tmpCreated -and (Test-Path -LiteralPath $tmpFilePath)) {
            try { [System.IO.File]::Delete($tmpFilePath) } catch {}
        }
    }

    [Console]::WriteLine("Sol Advisor orchestration completed. Result published to: $ResultFile")
    exit 0
} finally {
    if ($null -ne $script:activeChildProcs) {
        foreach ($p in $script:activeChildProcs) {
            try { Stop-ProcessTree $p } catch {}
        }
        $script:activeChildProcs.Clear()
    }
    if ($cleanRunDir -and (Test-Path -LiteralPath $runDir)) {
        try { Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
