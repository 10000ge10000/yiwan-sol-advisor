<#
.SYNOPSIS
    Configures Yiwan Sol Advisor dependencies on Windows.
.DESCRIPTION
    Verifies Codex, Git and Python, installs Google Antigravity CLI with the
    official online installer when needed, falls back to a user-provided
    official ZIP plus SHA-256, then guides interactive authentication.
#>

[CmdletBinding()]
param(
    [string]$AgyOfflinePackage,
    [string]$AgyOfflineSha256,
    [switch]$SkipLogin,
    [switch]$CheckOnly,
    [switch]$SkipHeadlessSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OfficialInstallerUrl = "https://antigravity.google/cli/install.ps1"
$RequiredModel = "gemini-3.8-flash-high"

function Write-Step([string]$Message) {
    [Console]::WriteLine("==> $Message")
}

function Fail([string]$Message) {
    throw $Message
}

function Require-Command([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Fail "Required command '$Name' was not found in PATH."
    }
    [Console]::WriteLine("FOUND: $Name -> $($command.Source)")
}

function Get-AgyExecutable {
    $command = Get-Command "agy" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidate = Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Install-AgyOnline {
    Write-Step "Downloading the official Google Antigravity CLI installer"
    $installerFile = Join-Path ([System.IO.Path]::GetTempPath()) ("agy-install-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Invoke-WebRequest -Uri $OfficialInstallerUrl -OutFile $installerFile -UseBasicParsing -TimeoutSec 90
        $pwsh = Join-Path $PSHOME "pwsh.exe"
        if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
            $pwsh = (Get-Command "pwsh" -ErrorAction Stop).Source
        }
        & $pwsh -NoProfile -File $installerFile
        if ($LASTEXITCODE -ne 0) {
            Fail "Official Antigravity installer exited with code $LASTEXITCODE."
        }
    } finally {
        if (Test-Path -LiteralPath $installerFile) {
            Remove-Item -LiteralPath $installerFile -Force
        }
    }
}

function Install-AgyOffline {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
    if ([System.IO.Path]::GetExtension($resolvedPackage).ToLowerInvariant() -ne ".zip") {
        Fail "Windows offline package must be an official agy_cli_windows_*.zip archive."
    }
    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        Fail "-AgyOfflineSha256 must be the 64-character SHA-256 recorded when the official package was downloaded."
    }

    $actualSha256 = (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        Fail "Offline package SHA-256 mismatch. Expected $($ExpectedSha256.ToLowerInvariant()), observed $actualSha256."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPackage)
    try {
        $agyEntries = @($archive.Entries | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name) -and $_.Name.Equals("agy.exe", [StringComparison]::OrdinalIgnoreCase)
        })
        if ($agyEntries.Count -ne 1) {
            Fail "Offline archive must contain exactly one agy.exe; observed $($agyEntries.Count)."
        }

        $installDir = Join-Path $env:LOCALAPPDATA "agy\bin"
        [System.IO.Directory]::CreateDirectory($installDir) | Out-Null
        $destination = Join-Path $installDir "agy.exe"
        $temporaryDestination = Join-Path $installDir ("agy.exe." + [Guid]::NewGuid().ToString("N") + ".tmp")
        try {
            $input = $agyEntries[0].Open()
            try {
                $output = [System.IO.File]::Create($temporaryDestination)
                try {
                    $input.CopyTo($output)
                } finally {
                    $output.Dispose()
                }
            } finally {
                $input.Dispose()
            }
            Move-Item -LiteralPath $temporaryDestination -Destination $destination -Force
        } finally {
            if (Test-Path -LiteralPath $temporaryDestination) {
                Remove-Item -LiteralPath $temporaryDestination -Force
            }
        }
        $env:PATH = "$installDir;$env:PATH"
        Write-Step "Installed verified offline package to $destination"
    } finally {
        $archive.Dispose()
    }
}

function Test-RequiredModel([string]$AgyExecutable) {
    $modelOutput = & $AgyExecutable models 2>&1
    $modelExit = $LASTEXITCODE
    if ($modelExit -ne 0) {
        return $false
    }
    $escapedModel = [regex]::Escape($RequiredModel)
    return [bool]($modelOutput | Where-Object { $_.ToString() -match "^$escapedModel(?:\s|$)" })
}

function Get-AgySettingsPath {
    return Join-Path $env:USERPROFILE ".gemini\antigravity-cli\settings.json"
}

function Test-AgySandboxSettings {
    $settingsPath = Get-AgySettingsPath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $false
    }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Fail "Antigravity settings are not valid JSON: $settingsPath. Fix the file before continuing."
    }
    return (
        $settings['toolPermission'] -eq "proceed-in-sandbox" -and
        $settings['enableTerminalSandbox'] -eq $true
    )
}

function Enable-AgySandboxAutomation {
    $settingsPath = Get-AgySettingsPath
    $settingsDir = [System.IO.Path]::GetDirectoryName($settingsPath)
    [System.IO.Directory]::CreateDirectory($settingsDir) | Out-Null
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            Fail "Antigravity settings are not valid JSON: $settingsPath. No changes were made."
        }
    } else {
        $settings = [ordered]@{}
    }

    if ($settings['toolPermission'] -eq 'proceed-in-sandbox' -and $settings['enableTerminalSandbox'] -eq $true) {
        Write-Step "Antigravity sandbox automation is already configured"
        return
    }

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $backupPath = "$settingsPath.yiwan-sol-advisor-backup-$stamp"
        [System.IO.File]::Copy($settingsPath, $backupPath, $false)
        Write-Step "Backed up Antigravity settings to $backupPath"
    }

    $settings['toolPermission'] = 'proceed-in-sandbox'
    $settings['enableTerminalSandbox'] = $true
    $json = ($settings | ConvertTo-Json -Depth 100) + [Environment]::NewLine
    $tempPath = "$settingsPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
        [System.IO.File]::Move($tempPath, $settingsPath, $true)
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
    Write-Step "Configured Antigravity for sandboxed headless automation"
}

function Test-AgyHeadlessSandbox([string]$AgyExecutable) {
    $tempWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ("yiwan-agy-smoke-" + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($tempWorkspace) | Out-Null
    try {
        $sentinelPath = Join-Path $tempWorkspace "yiwan-command-ok.txt"
        $prompt = "Installation self-test in a disposable directory. Use the command tool to run exactly: [IO.File]::WriteAllText('yiwan-command-ok.txt','true'). Do not run Git and do not modify any other file."
        Push-Location -LiteralPath $tempWorkspace
        try {
            $output = & $AgyExecutable --new-project --sandbox --dangerously-skip-permissions --model $RequiredModel --effort high --mode accept-edits --output-format json --print-timeout 2m --print $prompt 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            Fail "Sandboxed Antigravity headless smoke test failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
        }
        if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
            Fail "Sandboxed Antigravity headless smoke test did not execute its command in the target workspace."
        }
        $sentinel = Get-Content -LiteralPath $sentinelPath -Raw -ErrorAction Stop
        if ($sentinel.Trim() -cne 'true') {
            Fail "Sandboxed Antigravity headless smoke test produced unexpected command evidence: $($sentinel.Trim())"
        }
        Write-Step "Sandboxed Antigravity headless command test passed"
    } finally {
        if (Test-Path -LiteralPath $tempWorkspace) {
            Remove-Item -LiteralPath $tempWorkspace -Recurse -Force
        }
    }
}

try {
    Write-Step "Checking Yiwan Sol Advisor prerequisites"
    Require-Command "codex"
    Require-Command "git"
    Require-Command "python"
    Require-Command "pwsh"

    $agyExecutable = Get-AgyExecutable
    if ($null -eq $agyExecutable) {
        if ($CheckOnly) {
            Fail "agy is not installed. Re-run without -CheckOnly to install it."
        }

        $onlineError = $null
        try {
            Install-AgyOnline
        } catch {
            $onlineError = $_.Exception.Message
            [Console]::Error.WriteLine("WARNING: Official online installation failed: $onlineError")
        }

        $agyExecutable = Get-AgyExecutable
        if ($null -eq $agyExecutable -and -not [string]::IsNullOrWhiteSpace($AgyOfflinePackage)) {
            Install-AgyOffline -PackagePath $AgyOfflinePackage -ExpectedSha256 $AgyOfflineSha256
            $agyExecutable = Get-AgyExecutable
        }

        if ($null -eq $agyExecutable) {
            Fail "agy installation did not complete. If Google is unreachable, provide -AgyOfflinePackage and -AgyOfflineSha256 for an official Windows ZIP."
        }
    }

    Write-Step "Verifying Antigravity CLI"
    & $agyExecutable --version
    if ($LASTEXITCODE -ne 0) {
        Fail "agy --version failed with exit code $LASTEXITCODE."
    }

    $modelReady = Test-RequiredModel -AgyExecutable $agyExecutable
    if (-not $modelReady -and -not $SkipLogin -and -not $CheckOnly) {
        Write-Step "Antigravity authentication or model access is required. Complete the interactive Google sign-in, then exit agy."
        & $agyExecutable
        if ($LASTEXITCODE -ne 0) {
            Fail "Interactive agy login exited with code $LASTEXITCODE."
        }
        $modelReady = Test-RequiredModel -AgyExecutable $agyExecutable
    }

    if (-not $modelReady) {
        Fail "Required model '$RequiredModel' is not currently available. Run 'agy', complete sign-in, then run this setup again."
    }

    if ($CheckOnly) {
        if (-not (Test-AgySandboxSettings)) {
            Fail "Antigravity sandbox automation is not configured. Re-run setup without -CheckOnly."
        }
    } else {
        Enable-AgySandboxAutomation
    }

    if (-not $CheckOnly -and -not $SkipHeadlessSmokeTest) {
        Test-AgyHeadlessSandbox -AgyExecutable $agyExecutable
    }

    [Console]::WriteLine("READY: Yiwan Sol Advisor prerequisites, $RequiredModel, and sandboxed headless automation are available.")
    exit 0
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
