<#
.SYNOPSIS
    Deterministic test suite for yiwan-sol-advisor skill on Windows PowerShell 7.
.DESCRIPTION
    Validates skill metadata, YAML config, Markdown code fence balance and syntax,
    thin-launcher activation procedure, AST parsing, grep pins, implementer wrapper behavior,
    fresh reviewer immutability and verdict validation with 9 cryptographic bindings, parent verification gate,
    per-window snapshot attribution with pre-existing dirty files, baseline HEAD and scoped Git metadata immutability,
    test-mode switch gate, 24 KiB spec size cap, invalid duration rejection,
    adversarial porcelain rename detection, truthful completion (reviewed_no_change),
    hard total deadline enforcement, and an observable two-cycle FIX-FIRST -> SHIP state machine fixture.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Pass([string]$Msg) {
    [Console]::WriteLine("PASS: $Msg")
}

function Fail([string]$Msg) {
    [Console]::Error.WriteLine("FAIL: $Msg")
    exit 1
}

function Assert-Fails([scriptblock]$Sb, [string]$Msg) {
    $failed = $false
    try {
        & $Sb
        if ($LASTEXITCODE -ne 0) {
            $failed = $true
        }
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        Fail "Expected failure but command succeeded: $Msg"
    }
}

function Compute-Sha256Hex([byte[]]$Bytes) {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $hash = $hasher.ComputeHash($Bytes)
    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLower()
}

$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$scriptsDir = Join-Path $skillRoot "scripts"
$launcherPs1 = Join-Path $scriptsDir "launch-sol-advisor.ps1"
$implementerPs1 = Join-Path $scriptsDir "run-antigravity-implementer.ps1"
$reviewerPs1 = Join-Path $scriptsDir "run-fresh-reviewer.ps1"
$setupPs1 = Join-Path $scriptsDir "setup-yiwan-sol-advisor.ps1"
$powerShellExe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }

[Console]::WriteLine("=== STARTING YIWAN-SOL-ADVISOR POWERSHELL VERIFICATION SUITE ===")
[Console]::WriteLine("Skill Root: $skillRoot")

# 0. Pre-run check: Assert no parent-root contamination exists before suite
$rootDirtyCheck = Join-Path $skillRoot "dirty_mutation.txt"
if (Test-Path -LiteralPath $rootDirtyCheck) {
    Fail "Parent repository contamination detected before running suite: $rootDirtyCheck exists"
}

$isPluginLayout = Test-Path -LiteralPath (Join-Path $skillRoot "skills\orchestration")
$skillDir = if ($isPluginLayout) { (Resolve-Path -LiteralPath (Join-Path $skillRoot "skills\orchestration")).Path } else { $skillRoot }

# 1. Validate via skill-creator quick_validate.py
$quickValidatePy = "C:\Users\Administrator\.codex\skills\.system\skill-creator\scripts\quick_validate.py"
if (Test-Path -LiteralPath $quickValidatePy) {
    $qvOutput = & python $quickValidatePy $skillDir 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "quick_validate.py failed: $qvOutput" }
    Pass "quick_validate.py passed"
} else {
    [Console]::WriteLine("SKIP: quick_validate.py not found at $quickValidatePy")
}

# 2. YAML parsing and UI metadata validation of agents/openai.yaml
$yamlFile = Join-Path $skillDir "agents\openai.yaml"
if (-not (Test-Path -LiteralPath $yamlFile)) {
    Fail "agents/openai.yaml not found at $yamlFile"
}
$yamlCheckCode = @'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f)
policy = data.get('policy', {})
if policy.get('allow_implicit_invocation') is not False:
    print("ERROR: allow_implicit_invocation must be false")
    sys.exit(1)
prompt = data.get('interface', {}).get('default_prompt', '')
if '$yiwan-sol-advisor' not in prompt and '$orchestration' not in prompt:
    print("ERROR: default_prompt must explicitly mention $yiwan-sol-advisor or $orchestration")
    sys.exit(2)
short_desc = data.get('interface', {}).get('short_description', '')
if not isinstance(short_desc, str) or len(short_desc) < 20:
    print(f"ERROR: short_description length ({len(short_desc)}) must be at least 20 characters")
    sys.exit(3)
display_name = data.get('interface', {}).get('display_name', '')
if not isinstance(display_name, str) or len(display_name.strip()) == 0:
    print("ERROR: display_name must be a non-empty string")
    sys.exit(4)
sys.exit(0)
'@
$yamlTempPy = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "yaml_check_" + [System.Guid]::NewGuid().ToString("N") + ".py")
try {
    [System.IO.File]::WriteAllText($yamlTempPy, $yamlCheckCode, [System.Text.UTF8Encoding]::new($false))
    $yamlRes = & python $yamlTempPy $yamlFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "agents/openai.yaml schema validation failed: $yamlRes"
    }
} finally {
    if (Test-Path -LiteralPath $yamlTempPy) {
        Remove-Item -LiteralPath $yamlTempPy -Force -ErrorAction SilentlyContinue
    }
}
Pass "agents/openai.yaml strict policy and UI metadata validated"

# 3. Markdown code fence balance & header structure check
$mdFiles = Get-ChildItem -LiteralPath $skillRoot -Recurse -Filter "*.md" | Where-Object { $_.FullName -notmatch '\\\.git\\' }
foreach ($mf in $mdFiles) {
    $content = [System.IO.File]::ReadAllText($mf.FullName, [System.Text.Encoding]::UTF8)
    $lines = [regex]::Split($content, '\r?\n')
    $fenceCount = 0
    foreach ($l in $lines) {
        if ($l.Trim().StartsWith('```')) { $fenceCount++ }
    }
    if ($fenceCount % 2 -ne 0) {
        Fail "Unbalanced code fences in markdown file: $($mf.FullName) (found $fenceCount triple-backtick lines)"
    }
}
Pass "Markdown code fence balance verified across all documentation files"

# 4. PowerShell AST Parse Check on all .ps1 scripts
$ps1Files = Get-ChildItem -LiteralPath $scriptsDir -Filter "*.ps1"
foreach ($pf in $ps1Files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($pf.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        Fail "PowerShell AST syntax errors in $($pf.Name): $($errors -join '; ')"
    }
}
Pass "PowerShell AST syntax validation passed on all bundled .ps1 scripts"

# 4a. Distribution installer invariants
$setupText = [System.IO.File]::ReadAllText($setupPs1, [System.Text.Encoding]::UTF8)
foreach ($requiredSetupToken in @(
    "https://antigravity.google/cli/install.ps1",
    "AgyOfflinePackage",
    "AgyOfflineSha256",
    "gemini-3.8-flash-high",
    "Get-FileHash",
    "proceed-in-sandbox",
    "enableTerminalSandbox",
    "yiwan-sol-advisor-backup",
    "--sandbox"
)) {
    if (-not $setupText.Contains($requiredSetupToken)) {
        Fail "setup-yiwan-sol-advisor.ps1 missing required installer invariant: $requiredSetupToken"
    }
}
Pass "Windows setup helper online-first, offline SHA-256, and model checks validated"

$implementerText = [System.IO.File]::ReadAllText((Join-Path $scriptsDir "run-antigravity-implementer.ps1"), [System.Text.Encoding]::UTF8)
foreach ($requiredImplementerToken in @("--new-project", "--sandbox", "proceed-in-sandbox", "--dangerously-skip-permissions", "sandboxed-dangerously-skip-permissions", "SkipGenerationPreflight", "Stop-ProcessTree", "taskkill.exe")) {
    if (-not $implementerText.Contains($requiredImplementerToken)) {
        Fail "run-antigravity-implementer.ps1 missing required sandbox invariant: $requiredImplementerToken"
    }
}
Pass "Windows implementer sandbox enforcement, preflight skip, and process tree termination validated"

$reviewerText = [System.IO.File]::ReadAllText((Join-Path $scriptsDir "run-fresh-reviewer.ps1"), [System.Text.Encoding]::UTF8)
foreach ($requiredReviewerToken in @("Stop-ProcessTree", "taskkill.exe")) {
    if (-not $reviewerText.Contains($requiredReviewerToken)) {
        Fail "run-fresh-reviewer.ps1 missing required process tree termination invariant: $requiredReviewerToken"
    }
}
Pass "Windows fresh reviewer process tree termination invariants validated"

# 5. Model & Provider Static String Invariant Check
$roleContractsMd = [System.IO.File]::ReadAllText((Join-Path $skillDir "references\role-contracts.md"), [System.Text.Encoding]::UTF8)
if (-not $roleContractsMd.Contains("gpt-5.6-sol")) { Fail "role-contracts.md missing gpt-5.6-sol reference" }
if (-not $roleContractsMd.Contains("gemini-3.8-flash-high")) { Fail "role-contracts.md missing gemini-3.8-flash-high reference" }
if (-not $roleContractsMd.Contains("google-antigravity-cli")) { Fail "role-contracts.md missing google-antigravity-cli provider reference" }
Pass "Model and provider static string invariants verified in role-contracts.md"

# 6. Comprehensive Integration & Edge Case Fixtures
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not (Get-Command "pwsh" -ErrorAction SilentlyContinue)) {
    [Console]::WriteLine("SKIP: PowerShell 5.1 detected: AST syntax validation and static invariants passed; dynamic execution fixtures require PowerShell 7+ (pwsh).")
    [Console]::WriteLine("ALL YIWAN-SOL-ADVISOR POWERSHELL VERIFICATION CHECKS PASSED.")
    exit 0
}

$resolvedTempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "sol-adv-test." + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $resolvedTempRoot -Force | Out-Null

try {
    $ws = Join-Path $resolvedTempRoot "repo with spaces"
    $outDir = Join-Path $resolvedTempRoot "out with spaces"
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    git -C $ws init -b main 2>$null | Out-Null
    git -C $ws config user.name "Test User" | Out-Null
    git -C $ws config user.email "test@example.com" | Out-Null

    $initFile = Join-Path $ws "initial.txt"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($initFile, "initial commit line`n", $utf8NoBom)
    git -C $ws add initial.txt | Out-Null
    git -C $ws commit -m "initial commit" 2>$null | Out-Null

    $specFile = Join-Path $resolvedTempRoot "spec.md"
    $validSpec = @"
OBJECTIVE
Implement test feature in workspace.

FILES AND OWNERSHIP
You own only:
- test_feature.txt

INTERFACES
- Feature interface v1.

CONSTRAINTS
- Standard conventions.

VERIFICATION
- Run: pwsh -Command "exit 0"
  Success: exit code 0
"@
    [System.IO.File]::WriteAllText($specFile, $validSpec, $utf8NoBom)

    $cscCandidates = @(
        "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $cscPath = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $cscPath) { Fail "C# compiler (csc.exe) not found." }

    # Setup Mock AGY executable
    $mockAgyDir = Join-Path $resolvedTempRoot "mock_agy"
    New-Item -ItemType Directory -Path $mockAgyDir -Force | Out-Null
    $mockAgyExe = Join-Path $mockAgyDir "agy.exe"
    $mockAgyModeFile = Join-Path $mockAgyDir "mock_agy_mode.txt"
    $env:_MOCK_AGY_MODE_FILE = $mockAgyModeFile
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)

    $mockAgyCs = Join-Path $mockAgyDir "MockAgy.cs"
    $mockAgySrc = @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;

public class MockAgy {
    public static int Main(string[] args) {
        string modePath = Environment.GetEnvironmentVariable("_MOCK_AGY_MODE_FILE") ?? "";
        string mode = File.Exists(modePath) ? File.ReadAllText(modePath, Encoding.UTF8).Trim() : "edit_owned_file";

        if (args.Length > 0 && args[0] == "models") {
            if (mode == "hang_preflight") {
                Thread.Sleep(60000);
                return 0;
            }
            Console.WriteLine("gemini-3.8-flash-high");
            Console.WriteLine("gemini-2.5-pro");
            return 0;
        }
        if (args.Length > 0 && args[0] == "--version") {
            if (mode == "fail_version") {
                return 1;
            }
            Console.WriteLine("antigravity-cli 1.5.0");
            return 0;
        }

        foreach (string arg in args) {
            int marker = arg.IndexOf("nonce=sol-advisor-generation-preflight-", StringComparison.Ordinal);
            if (marker >= 0) {
                string nonce = arg.Substring(marker + 6).Split('.')[0].Trim();
                Console.WriteLine("{\"status\":\"ok\",\"nonce\":\"" + nonce + "\"}");
                return 0;
            }
        }

        string cwd = Environment.CurrentDirectory;

        if (mode == "edit_owned_file") {
            File.AppendAllText(Path.Combine(cwd, "test_feature.txt"), "feature implementation line\n", Encoding.UTF8);
        } else if (mode == "no_changes") {
            // Do not modify files
        } else if (mode == "ownership_violation") {
            File.WriteAllText(Path.Combine(cwd, "unowned_file.txt"), "UNOWNED EDIT\n", Encoding.UTF8);
        } else if (mode == "adversarial_rename") {
            string target = Path.Combine(cwd, "test_feature.txt");
            File.AppendAllText(target, "renamed file content\n", Encoding.UTF8);
            ProcessStartInfo psi = new ProcessStartInfo("git", "add test_feature.txt");
            psi.WorkingDirectory = cwd;
            psi.UseShellExecute = false;
            Process.Start(psi).WaitForExit();
            ProcessStartInfo psiMv = new ProcessStartInfo("git", "mv test_feature.txt unowned_renamed.txt");
            psiMv.WorkingDirectory = cwd;
            psiMv.UseShellExecute = false;
            Process.Start(psiMv).WaitForExit();
        } else if (mode == "modify_git_meta") {
            File.AppendAllText(Path.Combine(cwd, ".git", "config"), "# mutation\n", Encoding.UTF8);
        } else if (mode == "create_merge_head") {
            File.WriteAllText(Path.Combine(cwd, ".git", "MERGE_HEAD"), "1234567890123456789012345678901234567890\n", Encoding.UTF8);
        } else if (mode == "index_only_delta") {
            string blobSha = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
            ProcessStartInfo psi = new ProcessStartInfo("git", "update-index --add --cacheinfo 100644," + blobSha + ",staged_unowned.txt");
            psi.WorkingDirectory = cwd;
            psi.UseShellExecute = false;
            Process.Start(psi).WaitForExit();
        } else if (mode == "hanging_child") {
            Thread.Sleep(60000);
            return 0;
        } else if (mode == "exit_code_failure") {
            return 1;
        } else if (mode == "json_error_failure") {
            Console.WriteLine("{\"status\":\"ERROR\",\"response\":\"\",\"error\":\"timeout waiting for response\"}");
            return 1;
        }

        string report = "STATUS: complete\nOBJECTIVE: Implement test feature\nCHANGES: Added test_feature.txt\nVERIFIED: Executed pwsh -Command \"exit 0\" (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none";
        string escapedReport = report.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
        Console.WriteLine("{\n  \"model\": \"gemini-3.8-flash-high\",\n  \"status\": \"completed\",\n  \"response\": \"" + escapedReport + "\"\n}");
        return 0;
    }
}
'@
    [System.IO.File]::WriteAllText($mockAgyCs, $mockAgySrc, $utf8NoBom)
    & $cscPath /nologo /target:exe "/out:$mockAgyExe" $mockAgyCs

    # Setup Mock Codex executable
    $mockCodexDir = Join-Path $resolvedTempRoot "mock_codex"
    New-Item -ItemType Directory -Path $mockCodexDir -Force | Out-Null
    $mockCodexExe = Join-Path $mockCodexDir "codex.exe"
    $mockCodexModeFile = Join-Path $mockCodexDir "mock_codex_mode.txt"
    $mockCodexCounterFile = Join-Path $mockCodexDir "mock_codex_counter.txt"
    $mockCodexInvocationLog = Join-Path $mockCodexDir "mock_codex_invocations.log"
    $env:_MOCK_CODEX_MODE_FILE = $mockCodexModeFile
    $env:_MOCK_CODEX_COUNTER_FILE = $mockCodexCounterFile
    $env:_MOCK_CODEX_INVOCATION_LOG = $mockCodexInvocationLog
    [System.IO.File]::WriteAllText($mockCodexModeFile, "two_cycle_flow", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)

    $mockCodexCs = Join-Path $mockCodexDir "MockCodex.cs"
    $mockCodexSrc = @'
using System;
using System.IO;
using System.Text;

public class MockCodex {
    private static string ExtractBinding(string stdin, string key) {
        string marker = "- " + key + ": ";
        int idx = stdin.IndexOf(marker);
        if (idx < 0) return "0000000000000000000000000000000000000000000000000000000000000000";
        int start = idx + marker.Length;
        int end = stdin.IndexOf('\n', start);
        if (end < 0) end = stdin.Length;
        return stdin.Substring(start, end - start).Trim().Trim('\r');
    }

    public static int Main(string[] args) {
        string modePath = Environment.GetEnvironmentVariable("_MOCK_CODEX_MODE_FILE") ?? "";
        string counterPath = Environment.GetEnvironmentVariable("_MOCK_CODEX_COUNTER_FILE") ?? "";
        string mode = File.Exists(modePath) ? File.ReadAllText(modePath, Encoding.UTF8).Trim() : "two_cycle_flow";
        int counter = 0;
        if (File.Exists(counterPath)) {
            int.TryParse(File.ReadAllText(counterPath, Encoding.UTF8).Trim(), out counter);
        }
        counter++;
        if (counterPath != "") {
            File.WriteAllText(counterPath, counter.ToString(), Encoding.UTF8);
        }

        string stdin = Console.IsInputRedirected ? Console.In.ReadToEnd() : "";
        string outMsgFile = "";
        string cdArg = "";
        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "-o") outMsgFile = args[i + 1];
            if (args[i] == "-C" || args[i] == "--cd") cdArg = args[i + 1];
        }

        bool isReviewer = stdin.Contains("REVIEW INSTRUCTIONS");
        string invocationLog = Environment.GetEnvironmentVariable("_MOCK_CODEX_INVOCATION_LOG") ?? "";
        if (invocationLog != "") {
            string record = (isReviewer ? "reviewer" : "planner") + "|" + Environment.CurrentDirectory + "|" + cdArg + "|" + File.Exists(Path.Combine(Environment.CurrentDirectory, "initial.txt")) + Environment.NewLine;
            File.AppendAllText(invocationLog, record, Encoding.UTF8);
        }
        if (mode == "hang_planner" && !isReviewer) {
            System.Threading.Thread.Sleep(5000);
            return 1;
        }
        if (mode == "usage_limit" && !isReviewer) {
            Console.Error.WriteLine("ERROR: You've hit your usage limit. Try again at 2:10 PM.");
            return 1;
        }
        string response = "";

        string taskSha = ExtractBinding(stdin, "task_sha256");
        string planSha = ExtractBinding(stdin, "plan_sha256");
        string specSha = ExtractBinding(stdin, "spec_sha256");
        string implEvSha = ExtractBinding(stdin, "implementer_evidence_sha256");
        string pvSha = ExtractBinding(stdin, "parent_verification_sha256");
        string preWinSha = ExtractBinding(stdin, "pre_window_manifest_sha256");
        string postWinSha = ExtractBinding(stdin, "post_window_manifest_sha256");
        string repoSha = ExtractBinding(stdin, "repository_manifest_sha256");
        string aggDeltaSha = ExtractBinding(stdin, "aggregate_delta_manifest_sha256");

        string bindingsBlock = "  \"reviewed_bindings\": {\n" +
            "    \"task_sha256\": \"" + taskSha + "\",\n" +
            "    \"plan_sha256\": \"" + planSha + "\",\n" +
            "    \"spec_sha256\": \"" + specSha + "\",\n" +
            "    \"implementer_evidence_sha256\": \"" + implEvSha + "\",\n" +
            "    \"parent_verification_sha256\": \"" + pvSha + "\",\n" +
            "    \"pre_window_manifest_sha256\": \"" + preWinSha + "\",\n" +
            "    \"post_window_manifest_sha256\": \"" + postWinSha + "\",\n" +
            "    \"repository_manifest_sha256\": \"" + repoSha + "\",\n" +
            "    \"aggregate_delta_manifest_sha256\": \"" + aggDeltaSha + "\"\n" +
            "  }";

        if (mode == "oversized_plan" && !isReviewer) {
            response = "{\n  \"objective\": \"Oversized plan\",\n  \"owned_files\": [\"f01\",\"f02\",\"f03\",\"f04\",\"f05\",\"f06\",\"f07\",\"f08\",\"f09\",\"f10\",\"f11\",\"f12\",\"f13\"],\n  \"interfaces\": \"none\",\n  \"constraints\": \"bounded\",\n  \"verification_commands\": []\n}";
        } else if (mode == "two_cycle_flow") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Implement test feature with fix\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                if (counter <= 2) {
                    response = "{\n  \"verdict\": \"FIX-FIRST\",\n  \"reason\": \"Need correction on first pass.\",\n  \"findings\": \"Add additional assertions.\",\n  \"residual_risk\": \"None\",\n" + bindingsBlock + "\n}";
                } else {
                    response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"All verification checks and corrections verified.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n" + bindingsBlock + "\n}";
                }
            }
        } else if (mode == "review_ship") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Implement test feature\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"All verification checks passed.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_no_change") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Verify codebase without modifications\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"Verified existing implementation requires no changes.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n  \"reviewed_no_change\": true,\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_no_change_false") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Verify codebase without modifications\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"No changes made but not confirmed.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n  \"reviewed_no_change\": false,\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_string_false_no_change") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Verify codebase without modifications\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"String false no change.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n  \"reviewed_no_change\": \"false\",\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_unknown_nested_key") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Implement test feature\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"SHIP\",\n  \"reason\": \"All verification checks passed.\",\n  \"findings\": \"None\",\n  \"residual_risk\": \"None\",\n  \"unknown_extra_field\": true,\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_fix_first_repeat") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Implement test feature\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"FIX-FIRST\",\n  \"reason\": \"Correction required repeatedly.\",\n  \"findings\": \"Still failing checks.\",\n  \"residual_risk\": \"High\",\n" + bindingsBlock + "\n}";
            }
        } else if (mode == "review_rethink") {
            if (!isReviewer) {
                response = "{\n  \"objective\": \"Implement test feature\",\n  \"owned_files\": [\"test_feature.txt\"],\n  \"interfaces\": \"Feature interface v1\",\n  \"constraints\": \"Standard conventions\",\n  \"verification_commands\": [\"pwsh -NoProfile -Command \\\"exit 0\\\"\"]\n}";
            } else {
                response = "{\n  \"verdict\": \"RETHINK\",\n  \"reason\": \"Architecture fundamentally incompatible.\",\n  \"findings\": \"Total redesign needed.\",\n  \"residual_risk\": \"High\",\n" + bindingsBlock + "\n}";
            }
        }

        if (outMsgFile != "") File.WriteAllText(outMsgFile, response, Encoding.UTF8);
        else Console.WriteLine(response);
        return 0;
    }
}
'@
    [System.IO.File]::WriteAllText($mockCodexCs, $mockCodexSrc, $utf8NoBom)
    & $cscPath /nologo /target:exe "/out:$mockCodexExe" $mockCodexCs

    # ---------------------------------------------------------------------------------
    # Test Gate: Test Mode Switch Enforcement (rejects override variable without TestMode)
    # ---------------------------------------------------------------------------------
    $env:_MY_SOL_ADVISOR_TEST_CODEX_BIN = $mockCodexExe
    $env:_MY_SOL_ADVISOR_TEST_AGY_EXE = $mockAgyExe
    $env:_MY_SOL_ADVISOR_TEST_MODE = $null

    $dummyTask = Join-Path $resolvedTempRoot "dummy_task.md"
    [System.IO.File]::WriteAllText($dummyTask, "dummy task`n", $utf8NoBom)
    $dummyRes = Join-Path $outDir "dummy_res.md"

    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $dummyTask -ResultFile $dummyRes
    } "Launcher must fail when test overrides are specified without explicit -TestMode"
    Pass "Test-mode switch gate enforcement verified"

    # Regression: preserve the global deadline helper while requiring explicit, bounded
    # planner/implementer/reviewer budgets. No stage may consume the whole remaining run.
    $launcherSource = [System.IO.File]::ReadAllText($launcherPs1, $utf8NoBom)
    if ($launcherSource -notmatch 'function\s+Get-RemainingTimeoutMs\s*\(\s*\[int\]\$MaxStepMs\s*=\s*\[int\]::MaxValue\s*\)') {
        Fail "Windows launcher regression: Get-RemainingTimeoutMs must preserve the global remaining deadline."
    }
    if ($launcherSource -match 'function\s+Get-RemainingTimeoutMs\s*\(\s*\[int\]\$MaxStepMs\s*=\s*60000\s*\)') {
        Fail "Windows launcher regression: the global deadline helper is silently capped at 60 seconds."
    }
    foreach ($requiredBudget in @('PlannerTimeout', 'ImplementerTimeout', 'ReviewerTimeout', 'IdleTimeout', 'GenerationPreflightTimeout', 'MachineReserve')) {
        if ($launcherSource -notmatch [regex]::Escape("[string]`$$requiredBudget")) {
            Fail "Windows launcher regression: missing explicit $requiredBudget stage budget."
        }
    }
    foreach ($requiredLauncherToken in @("SOL_ADVISOR_TELEMETRY", "stageTelemetryList", "-SkipGenerationPreflight", "Stop-ProcessTree", "taskkill.exe", "Register-ActiveProcess", "Unregister-ActiveProcess", "activeChildProcs")) {
        if (-not $launcherSource.Contains($requiredLauncherToken)) {
            Fail "Windows launcher regression: missing required telemetry or process cleanup token: $requiredLauncherToken"
        }
    }
    Pass "Windows launcher process tree and active child process registration validated"

    $posixLauncherText = [System.IO.File]::ReadAllText((Join-Path $scriptsDir "launch-sol-advisor.sh"), [System.Text.Encoding]::UTF8)
    foreach ($requiredPosixToken in @("active_child_procs", "register_process", "unregister_process", "terminate_tree")) {
        if (-not $posixLauncherText.Contains($requiredPosixToken)) {
            Fail "POSIX launcher regression: missing required process cleanup token: $requiredPosixToken"
        }
    }
    Pass "POSIX launcher process group tracking and cleanup validated"
    $launcherTokens = $null
    $launcherParseErrors = $null
    $launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $launcherPs1,
        [ref]$launcherTokens,
        [ref]$launcherParseErrors
    )
    $remainingFnAst = $launcherAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-RemainingTimeoutMs"
    }, $true) | Select-Object -First 1
    if ($null -eq $remainingFnAst) {
        Fail "Windows launcher regression: Get-RemainingTimeoutMs function was not found."
    }
    $timeoutProbe = [scriptblock]::Create(@"
`$totalTimeoutSec = 120
`$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
function Fail([string]`$Message) { throw `$Message }
$($remainingFnAst.Extent.Text)
Get-RemainingTimeoutMs
"@)
    $probeBudgetMs = [int](& $timeoutProbe)
    if ($probeBudgetMs -lt 100000) {
        Fail "Windows launcher regression: a 120-second remaining budget was truncated to $probeBudgetMs ms."
    }
    Pass "Windows global deadline and explicit stage-budget contracts verified"

    # Re-enable Test Mode
    $env:_MY_SOL_ADVISOR_TEST_MODE = "1"

    # Test Implementer wrapper
    $evFile = Join-Path $outDir "ev.json"
    & $powerShellExe -NoProfile -File $implementerPs1 -Workspace $ws -SpecFile $specFile -EvidenceFile $evFile -PrintTimeout "5m" -TestMode
    if ($LASTEXITCODE -ne 0) { Fail "run-antigravity-implementer.ps1 failed: exit code $LASTEXITCODE" }
    Pass "run-antigravity-implementer.ps1 executed successfully"

    # Test SpecFile size cap (> 24 KiB must fail)
    $oversizeSpec = Join-Path $resolvedTempRoot "oversize_spec.md"
    $oversizeData = New-Object byte[] (24576 + 1024)
    [System.IO.File]::WriteAllBytes($oversizeSpec, $oversizeData)
    $evOversize = Join-Path $outDir "ev_oversize.json"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $implementerPs1 -Workspace $ws -SpecFile $oversizeSpec -EvidenceFile $evOversize -TestMode
    } "Spec file > 24 KiB must fail size check"
    Pass "SpecFile 24 KiB size cap enforcement verified"

    # Test Invalid Duration Format Rejection
    Assert-Fails {
        & $powerShellExe -NoProfile -File $implementerPs1 -Workspace $ws -SpecFile $specFile -EvidenceFile $evFile -PrintTimeout "invalid_duration" -TestMode
    } "Invalid duration format must fail closed"
    Pass "Implementer strict duration format parsing verified"

    # Idle supervision must emit live heartbeat evidence and stop a sleeping writer.
    [System.IO.File]::WriteAllText($mockAgyModeFile, "hanging_child", $utf8NoBom)
    $idleEvidence = Join-Path $outDir "idle_timeout_evidence.json"
    $idleWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $idleOutput = (& $powerShellExe -NoProfile -File $implementerPs1 -Workspace $ws -SpecFile $specFile -EvidenceFile $idleEvidence -PrintTimeout "8s" -IdleTimeout "2s" -GenerationPreflightTimeout "2s" -HeartbeatInterval "1s" -TestMode 2>&1 | Out-String)
    $idleExit = $LASTEXITCODE
    $idleWatch.Stop()
    if ($idleExit -eq 0) { Fail "Idle watchdog test unexpectedly succeeded." }
    if (-not $idleOutput.Contains('SOL_ADVISOR_HEARTBEAT')) { Fail "Idle watchdog did not emit a live heartbeat." }
    if (-not $idleOutput.Contains('idle timeout')) { Fail "Idle watchdog failure did not identify idle timeout." }
    if ($idleWatch.Elapsed.TotalSeconds -gt 10) { Fail "Idle watchdog exceeded expected bound ($($idleWatch.Elapsed.TotalSeconds)s)." }
    if (Test-Path -LiteralPath $idleEvidence) { Fail "Idle watchdog published trusted evidence after failure." }
    Pass "Implementer heartbeat and idle timeout supervision verified"

    # A structured AGY failure must report its actual status/error instead of being
    # misclassified as a missing implementation-report contract.
    [System.IO.File]::WriteAllText($mockAgyModeFile, "json_error_failure", $utf8NoBom)
    $jsonFailureEvidence = Join-Path $outDir "json_failure_evidence.json"
    $jsonFailureOutput = (& $powerShellExe -NoProfile -File $implementerPs1 -Workspace $ws -SpecFile $specFile -EvidenceFile $jsonFailureEvidence -PrintTimeout "8s" -IdleTimeout "2s" -GenerationPreflightTimeout "2s" -HeartbeatInterval "1s" -TestMode 2>&1 | Out-String)
    $jsonFailureExit = $LASTEXITCODE
    if ($jsonFailureExit -eq 0) { Fail "Structured AGY failure unexpectedly succeeded." }
    if (-not $jsonFailureOutput.Contains('status=ERROR') -or -not $jsonFailureOutput.Contains('timeout waiting for response')) { Fail "Structured AGY failure detail was not preserved." }
    if ($jsonFailureOutput.Contains('missing or empty report field')) { Fail "Structured AGY failure was misclassified as a report-contract failure." }
    if (Test-Path -LiteralPath $jsonFailureEvidence) { Fail "Structured AGY failure published trusted evidence." }
    Pass "Structured AGY nonzero failure classification verified"
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)

    # ---------------------------------------------------------------------------------
    # Per-Window Snapshot Attribution with Pre-existing Dirty File & 2-Cycle State Machine
    # ---------------------------------------------------------------------------------
    $taskFile = Join-Path $resolvedTempRoot "task.md"
    [System.IO.File]::WriteAllText($taskFile, "# Task: Implement test feature`n", $utf8NoBom)

    # Reject an unsafe total budget before the planner or writer can touch the workspace.
    $beforeBudgetHash = (Get-FileHash -LiteralPath (Join-Path $ws "initial.txt") -Algorithm SHA256).Hash
    $shortBudgetResult = Join-Path $outDir "short_budget_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $shortBudgetResult -Timeout "4s" -PlannerTimeout "2s" -ImplementerTimeout "2s" -ReviewerTimeout "1s" -IdleTimeout "1s" -GenerationPreflightTimeout "1s" -MachineReserve "1s" -TestMode
    } "Launcher must reject insufficient total budget before a writer window"
    $afterBudgetHash = (Get-FileHash -LiteralPath (Join-Path $ws "initial.txt") -Algorithm SHA256).Hash
    if ($beforeBudgetHash -ne $afterBudgetHash -or (Test-Path -LiteralPath $shortBudgetResult)) { Fail "Insufficient-budget rejection mutated or published output." }
    Pass "Insufficient total budget fails before planner and writer execution"

    # A live planner must not look hung while it is still bounded by its stage cap.
    [System.IO.File]::WriteAllText($mockCodexModeFile, "hang_planner", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)
    $plannerHangResult = Join-Path $outDir "planner_hang_result.md"
    $plannerHangWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $plannerHangOutput = (& $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $plannerHangResult -Timeout "8s" -PlannerTimeout "3s" -PlannerHeartbeatInterval "1s" -ImplementerTimeout "2s" -ReviewerTimeout "1s" -IdleTimeout "1s" -GenerationPreflightTimeout "1s" -MachineReserve "1s" -TestMode 2>&1 | Out-String)
    $plannerHangExit = $LASTEXITCODE
    $plannerHangWatch.Stop()
    if ($plannerHangExit -eq 0) { Fail "Hanging planner test unexpectedly succeeded." }
    if (-not $plannerHangOutput.Contains('"stage":"sol-planner"')) { Fail "Planner did not emit a live structured heartbeat." }
    if (-not $plannerHangOutput.Contains('exceeded its cap')) { Fail "Planner timeout did not identify its bounded stage cap." }
    if ($plannerHangWatch.Elapsed.TotalSeconds -gt 8) { Fail "Planner timeout exceeded expected bound ($($plannerHangWatch.Elapsed.TotalSeconds)s)." }
    if (Test-Path -LiteralPath $plannerHangResult) { Fail "Hanging planner published a trusted result." }
    Pass "Planner heartbeat and hard stage timeout verified"

    # Planner idle watchdog must stop an unprogressing planner before the hard cap and dump diagnostics.
    [System.IO.File]::WriteAllText($mockCodexModeFile, "hang_planner", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)
    $plannerIdleResult = Join-Path $outDir "planner_idle_result.md"
    $plannerIdleWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $plannerIdleOutput = (& $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $plannerIdleResult -Timeout "12s" -PlannerTimeout "6s" -PlannerIdleTimeout "2s" -PlannerHeartbeatInterval "1s" -ImplementerTimeout "2s" -ReviewerTimeout "1s" -IdleTimeout "1s" -GenerationPreflightTimeout "1s" -MachineReserve "1s" -TestMode 2>&1 | Out-String)
    $plannerIdleExit = $LASTEXITCODE
    $plannerIdleWatch.Stop()
    if ($plannerIdleExit -eq 0) { Fail "Planner idle watchdog test unexpectedly succeeded." }
    if (-not $plannerIdleOutput.Contains('"stage":"sol-planner"')) { Fail "Planner idle test did not emit a live structured heartbeat." }
    if (-not $plannerIdleOutput.Contains('idle timeout')) { Fail "Planner idle test did not identify idle timeout ($plannerIdleOutput)." }
    if ($plannerIdleWatch.Elapsed.TotalSeconds -gt 5) { Fail "Planner idle watchdog exceeded expected bound ($($plannerIdleWatch.Elapsed.TotalSeconds)s, expected < 5s)." }
    if (Test-Path -LiteralPath $plannerIdleResult) { Fail "Idle-timed-out planner published a trusted result." }
    $expectedDiagDir = Join-Path $outDir "planner-diagnostics-iter-1"
    if (-not (Test-Path -LiteralPath $expectedDiagDir -PathType Container)) { Fail "Planner idle watchdog did not preserve diagnostics directory: $expectedDiagDir" }
    $expectedDiagJson = Join-Path $expectedDiagDir "diagnostics.json"
    if (-not (Test-Path -LiteralPath $expectedDiagJson -PathType Leaf)) { Fail "Planner diagnostics directory missing diagnostics.json" }
    Pass "Planner idle watchdog and diagnostics preservation verified"

    # Account quota is an external blocker: report it concisely and never fall back.
    [System.IO.File]::WriteAllText($mockCodexModeFile, "usage_limit", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)
    $usageLimitResult = Join-Path $outDir "usage_limit_result.md"
    $usageLimitOutput = (& $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $usageLimitResult -TestMode 2>&1 | Out-String)
    $usageLimitExit = $LASTEXITCODE
    if ($usageLimitExit -eq 0) { Fail "Usage-limit planner test unexpectedly succeeded." }
    if (-not $usageLimitOutput.Contains('usage limit was reached') -or -not $usageLimitOutput.Contains('No alternate model was used')) {
        Fail "Planner usage-limit failure was not classified safely and concisely."
    }
    if (Test-Path -LiteralPath $usageLimitResult) { Fail "Usage-limit failure published a trusted result." }
    Pass "Planner usage-limit classification and no-fallback behavior verified"

    # Reject planner scopes that exceed the bounded phase size.
    [System.IO.File]::WriteAllText($mockCodexModeFile, "oversized_plan", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)
    $oversizedPlanResult = Join-Path $outDir "oversized_plan_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $oversizedPlanResult -MaxOwnedFiles 12 -TestMode
    } "Launcher must reject planner ownership scopes above MaxOwnedFiles"
    if (Test-Path -LiteralPath $oversizedPlanResult) { Fail "Oversized planner scope published a result." }
    Pass "Planner owned-file phase-size gate verified"

    $preExistingDirty = Join-Path $ws "initial.txt"
    [System.IO.File]::AppendAllText($preExistingDirty, "pre-existing uncommitted edit`n", $utf8NoBom)

    [System.IO.File]::WriteAllText($mockCodexModeFile, "two_cycle_flow", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexCounterFile, "0", $utf8NoBom)
    if (Test-Path -LiteralPath $mockCodexInvocationLog) { [System.IO.File]::Delete($mockCodexInvocationLog) }
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)

    $resultFile = Join-Path $outDir "final_result.md"
    & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $resultFile -MaxCorrections 3 -TestMode
    if ($LASTEXITCODE -ne 0) {
        Fail "launch-sol-advisor.ps1 failed during two-cycle orchestration with pre-existing dirty file: exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
        Fail "launch-sol-advisor.ps1 did not publish result file"
    }

    $resText = [System.IO.File]::ReadAllText($resultFile, $utf8NoBom)
    if (-not $resText.Contains("STATUS: complete")) { Fail "Result file missing STATUS: complete" }
    if (-not $resText.Contains("OBJECTIVE:")) { Fail "Result file missing OBJECTIVE:" }
    if (-not $resText.Contains("CHANGES:")) { Fail "Result file missing CHANGES:" }
    if (-not $resText.Contains("VERIFIED:")) { Fail "Result file missing VERIFIED:" }

    if ($resText.Contains("initial.txt")) {
        Fail "Result CHANGES incorrectly attributed pre-existing dirty file initial.txt to this task!"
    }
    if (-not $resText.Contains("test_feature.txt")) {
        Fail "Result CHANGES missing task modified file test_feature.txt"
    }
    $invocations = [System.IO.File]::ReadAllLines($mockCodexInvocationLog, $utf8NoBom)
    $plannerInvocations = @($invocations | Where-Object { $_.StartsWith('planner|') })
    $reviewerInvocations = @($invocations | Where-Object { $_.StartsWith('reviewer|') })
    if ($plannerInvocations.Count -lt 1 -or -not ($plannerInvocations | Where-Object { $_ -match '\\planner-workspace\|' -and $_.EndsWith('|True') })) {
        Fail "Planner did not execute from a populated disposable Git mirror."
    }
    if ($plannerInvocations | Where-Object { $_ -match [regex]::Escape("|$ws|") }) {
        Fail "Planner executed directly from the canonical workspace instead of its disposable mirror."
    }
    if ($reviewerInvocations.Count -lt 1 -or -not ($reviewerInvocations | Where-Object { $_ -match '\\.sol-review-root\.' })) {
        Fail "Reviewer did not execute from an isolated disposable root."
    }
    if ($reviewerInvocations | Where-Object { $_ -match [regex]::Escape("|$ws|") }) {
        Fail "Reviewer executed directly from the canonical workspace."
    }
    Pass "Windows planner mirror and isolated reviewer execution roots verified"
    Pass "Per-window snapshot attribution successfully ignored pre-existing dirty files and reported truthful task changes"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Adversarial Rename / Copy Detection
    [System.IO.File]::WriteAllText($mockAgyModeFile, "adversarial_rename", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $renameResultFile = Join-Path $outDir "rename_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $renameResultFile -TestMode
    } "Launcher must fail when Antigravity renames to an unowned destination"
    if (Test-Path -LiteralPath $renameResultFile) { Fail "ResultFile was published despite adversarial rename failure!" }
    Pass "Adversarial porcelain rename destination ownership verification verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Scoped Git Metadata Mutation Detection (.git/config)
    [System.IO.File]::WriteAllText($mockAgyModeFile, "modify_git_meta", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $metaResultFile = Join-Path $outDir "meta_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $metaResultFile -TestMode
    } "Launcher must fail when Git metadata (.git/config) is modified"
    if (Test-Path -LiteralPath $metaResultFile) { Fail "ResultFile was published despite Git metadata mutation!" }
    Pass "Scoped Git metadata integrity verification (.git/config) verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test In-Progress Git Operation Marker Detection (.git/MERGE_HEAD)
    [System.IO.File]::WriteAllText($mockAgyModeFile, "create_merge_head", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $mergeHeadResultFile = Join-Path $outDir "merge_head_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $mergeHeadResultFile -TestMode
    } "Launcher must fail when in-progress Git operation marker (.git/MERGE_HEAD) is created"
    if (Test-Path -LiteralPath $mergeHeadResultFile) { Fail "ResultFile was published despite MERGE_HEAD!" }
    Pass "In-progress Git operation marker detection (.git/MERGE_HEAD) verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Index-Only Unowned Mutation Detection (git ls-files --stage)
    [System.IO.File]::WriteAllText($mockAgyModeFile, "index_only_delta", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $indexDeltaResultFile = Join-Path $outDir "index_delta_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $indexDeltaResultFile -TestMode
    } "Launcher must fail when Antigravity stages an unowned index entry without worktree file"
    if (Test-Path -LiteralPath $indexDeltaResultFile) { Fail "ResultFile was published despite unowned staged index mutation!" }
    Pass "Index-only staged delta ownership verification verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Truthful Completion: reviewed_no_change outcome
    [System.IO.File]::WriteAllText($mockAgyModeFile, "no_changes", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_no_change", $utf8NoBom)
    $noChangeResultFile = Join-Path $outDir "no_change_result.md"
    $noChangeOutput = (& $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $noChangeResultFile -TestMode 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Fail "launch-sol-advisor.ps1 failed during reviewed_no_change flow: exit code $LASTEXITCODE"
    }
    $noChangeText = [System.IO.File]::ReadAllText($noChangeResultFile, $utf8NoBom)
    if (-not $noChangeText.Contains("STATUS: reviewed_no_change")) {
        Fail "Truthful completion failed: expected STATUS: reviewed_no_change"
    }
    if (-not $noChangeOutput.Contains("SOL_ADVISOR_TELEMETRY") -or -not $noChangeOutput.Contains("Sol Advisor Stage Telemetry")) {
        Fail "Stage telemetry report or SOL_ADVISOR_TELEMETRY event missing from launcher execution output."
    }
    Pass "Truthful completion with STATUS: reviewed_no_change and stage telemetry verified"

    # Test False No-Change Rejection (empty delta with reviewed_no_change: false must fail)
    [System.IO.File]::WriteAllText($mockAgyModeFile, "no_changes", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_no_change_false", $utf8NoBom)
    $falseNoChangeResultFile = Join-Path $outDir "false_no_change_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $falseNoChangeResultFile -TestMode
    } "Launcher must fail when aggregate delta is empty but reviewer did not confirm reviewed_no_change: true"
    if (Test-Path -LiteralPath $falseNoChangeResultFile) { Fail "ResultFile was published despite reviewed_no_change: false!" }
    Pass "Truthful no-change gate rejection verified when reviewed_no_change is false"

    # Test String 'false' for reviewed_no_change Rejection (must be JSON boolean)
    [System.IO.File]::WriteAllText($mockAgyModeFile, "no_changes", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_string_false_no_change", $utf8NoBom)
    $strFalseResultFile = Join-Path $outDir "str_false_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $strFalseResultFile -TestMode
    } "Launcher must fail when reviewer outputs string 'false' for reviewed_no_change"
    if (Test-Path -LiteralPath $strFalseResultFile) { Fail "ResultFile was published despite string 'false' reviewed_no_change!" }
    Pass "Strict typed JSON boolean validation for reviewed_no_change verified"

    # Test Unknown Nested Schema Key in Review Output
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_unknown_nested_key", $utf8NoBom)
    $unknownKeyResultFile = Join-Path $outDir "unknown_key_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $unknownKeyResultFile -TestMode
    } "Launcher must fail when review output contains unknown nested keys"
    if (Test-Path -LiteralPath $unknownKeyResultFile) { Fail "ResultFile was published despite schema violation!" }
    Pass "Closed-schema review validation verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Hard Outer Timeout Deadline with Hanging Preflight
    [System.IO.File]::WriteAllText($mockAgyModeFile, "hang_preflight", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $hangResultFile = Join-Path $outDir "hang_result.md"
    $swHang = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $hangResultFile -Timeout "6s" -PlannerTimeout "1s" -ImplementerTimeout "2s" -ReviewerTimeout "1s" -IdleTimeout "1s" -GenerationPreflightTimeout "1s" -MachineReserve "1s" -TestMode
    } "Launcher must terminate on hard outer timeout when child preflight hangs"
    $swHang.Stop()
    if ($swHang.Elapsed.TotalSeconds -gt 15) {
        Fail "Hanging preflight exceeded expected deadline window ($($swHang.Elapsed.TotalSeconds)s)"
    }
    if (Test-Path -LiteralPath $hangResultFile) { Fail "ResultFile was published after hanging timeout!" }
    Pass "Hard outer timeout deadline enforcement verified (elapsed: $($swHang.Elapsed.TotalSeconds.ToString('F1'))s)"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Version Failure Immediate Exit
    [System.IO.File]::WriteAllText($mockAgyModeFile, "fail_version", $utf8NoBom)
    $versionFailResult = Join-Path $outDir "ver_fail_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $versionFailResult -TestMode
    } "Launcher must fail when agy --version preflight fails"
    if (Test-Path -LiteralPath $versionFailResult) { Fail "ResultFile was published after version check failure!" }
    Pass "Antigravity --version preflight failure rejection verified"

    # Reset workspace
    git -C $ws reset --hard HEAD 2>$null | Out-Null
    git -C $ws clean -fdx 2>$null | Out-Null

    # Test Ownership Violation Rejection
    [System.IO.File]::WriteAllText($mockAgyModeFile, "ownership_violation", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_ship", $utf8NoBom)
    $unownedResultFile = Join-Path $outDir "unowned_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $unownedResultFile -TestMode
    } "Launcher must fail when Antigravity modifies an unowned file"
    Pass "Launcher ownership violation rejection verified"

    # Clean unowned edit
    $unownedFile = Join-Path $ws "unowned_file.txt"
    if (Test-Path -LiteralPath $unownedFile) { Remove-Item -LiteralPath $unownedFile -Force }

    # Test MaxCorrections Exhaustion
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_fix_first_repeat", $utf8NoBom)
    $exhaustResultFile = Join-Path $outDir "exhaust_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $exhaustResultFile -MaxCorrections 1 -TestMode
    } "Launcher must halt when MaxCorrections is exhausted"
    Pass "Launcher MaxCorrections exhaustion verified"

    # Test RETHINK Rejection
    [System.IO.File]::WriteAllText($mockAgyModeFile, "edit_owned_file", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockCodexModeFile, "review_rethink", $utf8NoBom)
    $rethinkResultFile = Join-Path $outDir "rethink_result.md"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $rethinkResultFile -TestMode
    } "Launcher must halt without success when reviewer issues RETHINK"
    Pass "Launcher RETHINK verdict halting verified"

    # Test ResultFile No-Clobber
    Assert-Fails {
        & $powerShellExe -NoProfile -File $launcherPs1 -Workspace $ws -TaskFile $taskFile -ResultFile $resultFile -TestMode
    } "Launcher must fail when ResultFile already exists (no-clobber)"
    Pass "Launcher ResultFile no-clobber verified"

    # Post-run check: Assert no parent-root contamination occurred
    if (Test-Path -LiteralPath $rootDirtyCheck) {
        Fail "Parent repository contamination detected after running suite: $rootDirtyCheck was created"
    }
    Pass "Parent-root contamination check passed: no dirty_mutation.txt in Skill root"

    [Console]::WriteLine("ALL YIWAN-SOL-ADVISOR POWERSHELL VERIFICATION CHECKS PASSED.")
} finally {
    $env:_MY_SOL_ADVISOR_TEST_MODE = $null
    $env:_MY_SOL_ADVISOR_TEST_AGY_EXE = $null
    $env:_MY_SOL_ADVISOR_TEST_CODEX_BIN = $null
    $env:_SOL_ADVISOR_TEST_MODE = $null
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $null
    $env:_SOL_ADVISOR_TEST_CODEX_BIN = $null

    if ($resolvedTempRoot -and (Test-Path -LiteralPath $resolvedTempRoot) -and ($resolvedTempRoot -like "*sol-adv-test.*")) {
        try { Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
