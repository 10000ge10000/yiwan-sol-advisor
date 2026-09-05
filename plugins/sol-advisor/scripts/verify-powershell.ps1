#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Behavioral verification suite for Sol Advisor's PowerShell implementation wrapper.
.DESCRIPTION
    Tests run-antigravity-implementer.ps1 dynamically against:
    - Nonexistent and non-Git workspace refusal
    - Evidence containment, relative path, missing parent, and existing destination refusal
    - Junction / reparse point parent refusal (with explicit SKIP if unsupported)
    - Junction workspace alias with physical repository evidence path containment refusal
    - Negative five-part specification validation (missing, duplicate, out of order, empty)
    - Response contract and report schema validation (STATUS, CHANGES, VERIFIED, JUDGMENT CALLS, GAPS)
    - Interruption / partial-write safety proving no authoritative file appears
    - Doubly gated fake executable override enforcement (_SOL_ADVISOR_TEST_MODE=1)
    - Non-object JSON rejection (array, scalar, multiple documents)
    - Valid object envelope creation, dynamic mismatch rejection, and no-clobber preservation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WrapperPath = ""
)

if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
    $WrapperPath = Join-Path $PSScriptRoot "run-antigravity-implementer.ps1"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$powerShellExe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell.exe" }
$isWindowsPlatform = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $IsWindows } else { [System.Environment]::OSVersion.Platform -match "Win" -or [System.IO.Path]::DirectorySeparatorChar -eq '\' }

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

if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
    Fail "Wrapper script not found at $WrapperPath"
}
$resolvedWrapper = (Resolve-Path -LiteralPath $WrapperPath).Path

$tmpBase = [System.IO.Path]::GetTempPath()
$tempGuid = "sol-advisor-ps-verify." + [System.Guid]::NewGuid().ToString("N")
$tempRoot = Join-Path $tmpBase $tempGuid

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$resolvedTempRoot = (Resolve-Path -LiteralPath $tempRoot).Path

try {
    # 1. Setup mock workspace and valid five-part spec
    $ws = Join-Path $resolvedTempRoot "ps_ws"
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    git -C $ws init -q

    $spec = Join-Path $resolvedTempRoot "ps_spec.md"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $validSpecContent = @"
OBJECTIVE
Test spec objective for PowerShell wrapper verification.

FILES AND OWNERSHIP
You own only:
- test_ps.txt

INTERFACES
- Preserve mock test interfaces.

CONSTRAINTS
- Strict mock test constraints.

VERIFICATION
- Run: pwsh -Command "exit 0"
  Success: exit code 0
"@
    [System.IO.File]::WriteAllText($spec, $validSpecContent, $utf8NoBom)

    $evDir = Join-Path $resolvedTempRoot "ps_ev_dir"
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null
    $evFile = Join-Path $evDir "ps_evidence.json"

    # 2. Nonexistent workspace refusal
    $nonexistentWs = Join-Path $resolvedTempRoot "nonexistent_ws"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $nonexistentWs -SpecFile $spec -EvidenceFile $evFile
    } "nonexistent workspace must be refused"
    Pass "nonexistent workspace refusal"

    # 3. Non-Git workspace refusal
    $nonGitWs = Join-Path $resolvedTempRoot "nongit_ws"
    New-Item -ItemType Directory -Path $nonGitWs -Force | Out-Null
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $nonGitWs -SpecFile $spec -EvidenceFile $evFile
    } "non-git workspace must be refused"
    Pass "non-Git workspace refusal"

    # 4. Evidence inside workspace refusal
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $ws "evidence.json")
    } "evidence inside workspace must be refused"
    Pass "evidence inside workspace refusal"

    # 5. Relative evidence path refusal (and workspace unchanged)
    $wsSnapshotBefore = Get-ChildItem -LiteralPath $ws -Recurse | Select-Object -ExpandProperty FullName
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile "relative_evidence.json"
    } "relative evidence path must be refused"
    $wsSnapshotAfter = Get-ChildItem -LiteralPath $ws -Recurse | Select-Object -ExpandProperty FullName
    if (($wsSnapshotBefore -join "`n") -ne ($wsSnapshotAfter -join "`n")) {
        Fail "relative evidence path refusal modified workspace"
    }
    Pass "relative evidence path refusal and workspace preservation"

    # 6. Missing evidence parent directory refusal (and not created)
    $missingParentDir = Join-Path $resolvedTempRoot "missing_parent"
    $missingParentEv = Join-Path $missingParentDir "ev.json"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $missingParentEv
    } "missing evidence parent directory must be refused"
    if (Test-Path -LiteralPath $missingParentDir) {
        Fail "missing evidence parent directory was created during failed run"
    }
    Pass "missing evidence parent directory refusal"

    # 7. Existing evidence destination refusal (no-clobber preservation)
    $preexistingEv = Join-Path $evDir "preexisting.json"
    [System.IO.File]::WriteAllText($preexistingEv, "PREEXISTING_CONTENT", $utf8NoBom)
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $preexistingEv
    } "pre-existing evidence destination must be refused (no-clobber)"
    $preexistingContent = [System.IO.File]::ReadAllText($preexistingEv, $utf8NoBom)
    if ($preexistingContent -ne "PREEXISTING_CONTENT") {
        Fail "pre-existing evidence destination was modified during failed run"
    }
    Pass "pre-existing evidence destination refusal and no-clobber preservation"

    # 8. Alternate Data Stream (ADS) and invalid path syntax refusal
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "evidence.json:stream")
    } "evidence path with ADS stream name must be refused"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "evidence.json::`$DATA")
    } "evidence path with ADS ::`$DATA stream specifier must be refused"
    Pass "alternate data stream (ADS) syntax refusal"

    # 9. Device path and reserved DOS device name refusal
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile "\\.\C:\temp\evidence.json"
    } "evidence path using device namespace \\.\ must be refused"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "CON.json")
    } "evidence path with reserved CON device name must be refused"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "NUL.json")
    } "evidence path with reserved NUL device name must be refused"
    Pass "device path and reserved DOS device name refusal"

    # 10. Junction / Reparse point parent refusal
    $junctionTarget = Join-Path $resolvedTempRoot "junc_target"
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionDir = Join-Path $resolvedTempRoot "junc_parent"
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionDir -Target $junctionTarget -Force -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        [Console]::WriteLine("SKIP: Junction / reparse creation not supported by OS capability in current environment: $($_.Exception.Message)")
    }
    if ($junctionCreated) {
        $juncEv = Join-Path $junctionDir "ev.json"
        Assert-Fails {
            & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $juncEv
        } "junction parent directory must be rejected as reparse point"
        Pass "junction / reparse point parent refusal"
    }

    # 10b. Junction workspace alias with evidence path inside physical repository refusal
    if ($junctionCreated) {
        $realWs = Join-Path $resolvedTempRoot "real_physical_ws"
        New-Item -ItemType Directory -Path $realWs -Force | Out-Null
        git -C $realWs init -q
        $juncWs = Join-Path $resolvedTempRoot "junc_ws_alias"
        try {
            New-Item -ItemType Junction -Path $juncWs -Target $realWs -Force -ErrorAction Stop | Out-Null
            $physEvInside = Join-Path $realWs "ev_inside.json"
            Assert-Fails {
                & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $juncWs -SpecFile $spec -EvidenceFile $physEvInside
            } "evidence pointing into physical repository through junction workspace alias must be refused"
            Pass "junction workspace alias physical containment refusal"
        } catch {
            [Console]::WriteLine("SKIP: Junction workspace alias test could not create junction: $($_.Exception.Message)")
        }
    }

    # 10c. Negative five-part spec tests
    # 10c1: Spec missing CONSTRAINTS
    $specMissingConstraints = Join-Path $resolvedTempRoot "spec_missing_constraints.md"
    [System.IO.File]::WriteAllText($specMissingConstraints, "OBJECTIVE`nTest`n`nFILES AND OWNERSHIP`nOwns: test.txt`n`nINTERFACES`nTest`n`nVERIFICATION`nTest`n", $utf8NoBom)
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $specMissingConstraints -EvidenceFile (Join-Path $evDir "ev_mc.json")
    } "spec missing CONSTRAINTS must be refused"

    # 10c2: Spec with duplicate OBJECTIVE
    $specDupObj = Join-Path $resolvedTempRoot "spec_dup_obj.md"
    [System.IO.File]::WriteAllText($specDupObj, "OBJECTIVE`nTest1`n`nOBJECTIVE`nTest2`n`nFILES AND OWNERSHIP`nOwns: test.txt`n`nINTERFACES`nTest`n`nCONSTRAINTS`nTest`n`nVERIFICATION`nTest`n", $utf8NoBom)
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $specDupObj -EvidenceFile (Join-Path $evDir "ev_do.json")
    } "spec with duplicate OBJECTIVE must be refused"

    # 10c3: Spec out of order
    $specOutOfOrder = Join-Path $resolvedTempRoot "spec_out_of_order.md"
    [System.IO.File]::WriteAllText($specOutOfOrder, "OBJECTIVE`nTest`n`nINTERFACES`nTest`n`nFILES AND OWNERSHIP`nOwns: test.txt`n`nCONSTRAINTS`nTest`n`nVERIFICATION`nTest`n", $utf8NoBom)
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $specOutOfOrder -EvidenceFile (Join-Path $evDir "ev_ooo.json")
    } "spec with out-of-order sections must be refused"

    # 10c4: Spec with empty section
    $specEmptySec = Join-Path $resolvedTempRoot "spec_empty_sec.md"
    [System.IO.File]::WriteAllText($specEmptySec, "OBJECTIVE`n`nFILES AND OWNERSHIP`nOwns: test.txt`n`nINTERFACES`nTest`n`nCONSTRAINTS`nTest`n`nVERIFICATION`nTest`n", $utf8NoBom)
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $specEmptySec -EvidenceFile (Join-Path $evDir "ev_es.json")
    } "spec with empty section must be refused"
    Pass "negative five-part specification validation"

    # 11. Command shim (.cmd / .bat) deterministic fail-closed refusal and zero evidence creation
    $mockShimCmd = Join-Path $resolvedTempRoot "mock_shim.cmd"
    $mockShimBat = Join-Path $resolvedTempRoot "mock_shim.bat"
    [System.IO.File]::WriteAllText($mockShimCmd, "@echo off`necho SHOULD_NOT_RUN`nexit /b 1`n", $utf8NoBom)
    [System.IO.File]::WriteAllText($mockShimBat, "@echo off`necho SHOULD_NOT_RUN`nexit /b 1`n", $utf8NoBom)

    $shimEvCmd = Join-Path $evDir "ev_shim_cmd.json"
    $env:_SOL_ADVISOR_TEST_MODE = "1"
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $mockShimCmd
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $shimEvCmd
    } ".cmd command shim must fail closed without execution"
    if (Test-Path -LiteralPath $shimEvCmd) {
        Fail "Authoritative evidence file was created during .cmd shim refusal"
    }

    $shimEvBat = Join-Path $evDir "ev_shim_bat.json"
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $mockShimBat
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $shimEvBat
    } ".bat command shim must fail closed without execution"
    if (Test-Path -LiteralPath $shimEvBat) {
        Fail "Authoritative evidence file was created during .bat shim refusal"
    }
    Pass "command shim (.cmd/.bat) deterministic fail-closed refusal and zero evidence creation"

    # 12. Native mock executable setup & compilation
    $mockNativeExeName = if ($isWindowsPlatform) { "mock_agy.exe" } else { "mock_agy_native" }
    $mockNativeExe = Join-Path $resolvedTempRoot $mockNativeExeName
    $mockNativePayloadFile = Join-Path $resolvedTempRoot "mock_native_payload.txt"
    $mockNativeLogFile = Join-Path $resolvedTempRoot "mock_native_invocations.jsonl"
    $mockNativeModelFile = Join-Path $resolvedTempRoot "mock_native_model.txt"
    $mockNativeVerFile = Join-Path $resolvedTempRoot "mock_native_version.txt"
    $mockNativeModeFile = Join-Path $resolvedTempRoot "mock_native_mode.txt"

    function Set-MockNativeAgyContent([string]$OutputPayload, [string]$ModelOverride = "gemini-3.8-flash-high (Gemini 3.8 Flash High)", [string]$VersionOverride = "1.1.21", [string]$Mode = "normal") {
        [System.IO.File]::WriteAllText($mockNativePayloadFile, $OutputPayload, $utf8NoBom)
        [System.IO.File]::WriteAllText($mockNativeModelFile, $ModelOverride, $utf8NoBom)
        [System.IO.File]::WriteAllText($mockNativeVerFile, $VersionOverride, $utf8NoBom)
        [System.IO.File]::WriteAllText($mockNativeModeFile, $Mode, $utf8NoBom)
    }

    if ($isWindowsPlatform) {
        $nativeCsSrc = Join-Path $resolvedTempRoot "MockNativeAgy.cs"
        $nativeCsCode = @"
using System;
using System.IO;
using System.Text;

class Program {
    static string EscapeJson(string s) {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        foreach (char c in s) {
            switch (c) {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\r': sb.Append("\\r"); break;
                case '\n': sb.Append("\\n"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 32) {
                        sb.AppendFormat("\\u{0:x4}", (int)c);
                    } else {
                        sb.Append(c);
                    }
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    static int Main(string[] args) {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string logPath = Path.Combine(baseDir, "mock_native_invocations.jsonl");
        
        StringBuilder sb = new StringBuilder();
        sb.Append("[");
        for (int i = 0; i < args.Length; i++) {
            if (i > 0) sb.Append(", ");
            sb.Append(EscapeJson(args[i]));
        }
        sb.Append("]\n");
        File.AppendAllText(logPath, sb.ToString(), Encoding.UTF8);

        if (args.Length > 0 && args[0] == "models") {
            string mFile = Path.Combine(baseDir, "mock_native_model.txt");
            if (File.Exists(mFile)) {
                Console.WriteLine(File.ReadAllText(mFile).Trim());
            } else {
                Console.WriteLine("gemini-3.8-flash-high (Gemini 3.8 Flash High)");
            }
            return 0;
        }

        if (args.Length > 0 && args[0] == "--version") {
            string vFile = Path.Combine(baseDir, "mock_native_version.txt");
            if (File.Exists(vFile)) {
                Console.WriteLine(File.ReadAllText(vFile).Trim());
            } else {
                Console.WriteLine("1.1.21");
            }
            return 0;
        }

        foreach (string arg in args) {
            const string prefix = "sol-advisor-generation-preflight-";
            int index = arg.IndexOf(prefix, StringComparison.Ordinal);
            if (index >= 0) {
                int end = index;
                while (end < arg.Length && (char.IsLetterOrDigit(arg[end]) || arg[end] == '-')) end++;
                string nonce = arg.Substring(index, end - index);
                Console.Write("{\"status\":\"ok\",\"nonce\":" + EscapeJson(nonce) + "}");
                return 0;
            }
        }

        string modePath = Path.Combine(baseDir, "mock_native_mode.txt");
        if (File.Exists(modePath) && File.ReadAllText(modePath).Trim() == "hang-main") {
            System.Threading.Thread.Sleep(30000);
        }
        if (File.Exists(modePath) && File.ReadAllText(modePath).Trim() == "json-error") {
            Console.Write("{\"status\":\"ERROR\",\"response\":\"\",\"error\":\"timeout waiting for response\"}");
            return 1;
        }

        string payloadPath = Path.Combine(baseDir, "mock_native_payload.txt");
        if (File.Exists(payloadPath)) {
            Console.Write(File.ReadAllText(payloadPath, Encoding.UTF8));
        }
        return 0;
    }
}
"@
        [System.IO.File]::WriteAllText($nativeCsSrc, $nativeCsCode, $utf8NoBom)
        $cscCandidates = @(
            "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
            "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe",
            "$env:SystemRoot\Microsoft.NET\Framework64\v3.5\csc.exe",
            "$env:SystemRoot\Microsoft.NET\Framework\v3.5\csc.exe"
        )
        $cscPath = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $cscPath) {
            Fail "C# compiler (csc.exe) not found to compile native test helper binary."
        }
        & $cscPath /nologo /target:exe "/out:$mockNativeExe" $nativeCsSrc
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mockNativeExe -PathType Leaf)) {
            Fail "Failed to compile native test helper binary $mockNativeExe"
        }
    } else {
        $shNativeContent = @"
#!/bin/sh
base_dir=`$(CDPATH= cd "`$(dirname "`$0")" && pwd)
log_file="`$base_dir/mock_native_invocations.jsonl"
python3 -c "import sys, json; open(sys.argv[1], 'a', encoding='utf-8').write(json.dumps(sys.argv[2:], ensure_ascii=False) + '\n')" "`$log_file" "`$@"

if [ "`$1" = "models" ]; then
    m_file="`$base_dir/mock_native_model.txt"
    if [ -f "`$m_file" ]; then cat "`$m_file"; else printf '%s\n' "gemini-3.8-flash-high (Gemini 3.8 Flash High)"; fi
    exit 0
fi
if [ "`$1" = "--version" ]; then
    v_file="`$base_dir/mock_native_version.txt"
    if [ -f "`$v_file" ]; then cat "`$v_file"; else printf '%s\n' "1.1.21"; fi
    exit 0
fi
case "`$*" in
  *sol-advisor-generation-preflight-*)
    nonce=`$(printf '%s\n' "`$*" | sed -n 's/.*nonce=\(sol-advisor-generation-preflight-[A-Za-z0-9-]*\).*/\1/p')
    printf '{"status":"ok","nonce":"%s"}\n' "`$nonce"
    exit 0
    ;;
esac
p_file="`$base_dir/mock_native_payload.txt"
if [ -f "`$p_file" ]; then cat "`$p_file"; fi
exit 0
"@
        [System.IO.File]::WriteAllText($mockNativeExe, $shNativeContent, $utf8NoBom)
        & chmod +x $mockNativeExe
    }

    $validJsonPayload = '{"conversation_id": "ps-conv-123", "status": "completed", "response": "STATUS: complete\nOBJECTIVE: Test spec objective for PowerShell wrapper verification.\nCHANGES: Modified test_ps.txt\nVERIFIED: Executed pwsh -Command \"exit 0\" (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Set-MockNativeAgyContent -OutputPayload $validJsonPayload

    # 13. Doubly gated fake executable override enforcement
    # 13a: Test override variable without _SOL_ADVISOR_TEST_MODE=1 fails closed
    $env:_SOL_ADVISOR_TEST_MODE = $null
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $mockNativeExe
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ungated.json")
    } "test executable override without _SOL_ADVISOR_TEST_MODE=1 must fail closed"
    Pass "ungated fake executable override fail-closed enforcement"

    # Enable test mode for subsequent fake executable tests
    $env:_SOL_ADVISOR_TEST_MODE = "1"
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $mockNativeExe

    # 14. Non-object JSON rejection: Array
    Set-MockNativeAgyContent -OutputPayload '[{"item": 1}, {"item": 2}]'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_arr.json")
    } "array JSON output from agy must be rejected"
    Pass "non-object JSON array rejection"

    # 15. Non-object JSON rejection: Scalar string
    Set-MockNativeAgyContent -OutputPayload '"scalar_result_string"'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_str.json")
    } "scalar string JSON output from agy must be rejected"
    Pass "non-object JSON scalar string rejection"

    # 16. Non-object JSON rejection: Multiple documents
    Set-MockNativeAgyContent -OutputPayload '{"doc": 1} {"doc": 2}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_multi.json")
    } "multiple JSON documents output from agy must be rejected"
    Pass "non-object JSON multiple documents rejection"

    # 17. Dynamic field mismatch rejection
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "model": "wrong-model", "status": "completed", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_mismatch.json")
    } "dynamic model mismatch in agy_result must be rejected"
    Pass "dynamic model mismatch rejection"

    # 18. Comprehensive Response contract negative tests
    # 18a: Missing STATUS
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "OBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_status.json")
    } "agy output missing STATUS must be rejected"

    # 18b: Transport status present but report STATUS missing (transport/report status confusion)
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "status": "completed", "response": "OBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_transport_confusion.json")
    } "transport status must not be confused with missing report STATUS"

    # 18c: Missing OBJECTIVE
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_obj.json")
    } "agy output missing OBJECTIVE must be rejected"

    # 18d: Missing CHANGES
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_changes.json")
    } "agy output missing CHANGES must be rejected"

    # 18e: Missing VERIFIED
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_verified.json")
    } "agy output missing VERIFIED must be rejected"

    # 18f: Missing JUDGMENT CALLS (must not synthesize default "none")
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_judgment.json")
    } "agy output missing JUDGMENT CALLS must be rejected without synthesizing default"

    # 18g: Missing GAPS (must not synthesize default "none")
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_neg_gaps.json")
    } "agy output missing GAPS must be rejected without synthesizing default"

    # 18h: STATUS: blocked
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: blocked\nOBJECTIVE: Test\nCHANGES: None\nVERIFIED: Executed pwsh (exit code 1)\nJUDGMENT CALLS: none\nGAPS: blocked on requirements"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_blocked.json")
    } "agy output with STATUS: blocked must be rejected"

    # 18i: STATUS: partial
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: partial\nOBJECTIVE: Test\nCHANGES: Some\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: some"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_partial.json")
    } "agy output with STATUS: partial must be rejected"

    # 18j: VERIFIED substring false positive: "bypass"
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Ran tests with security bypass (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_bypass.json")
    } "agy output with VERIFIED containing bypass must be rejected"

    # 18k: VERIFIED substring false positive: "exit pending"
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed test command, exit pending confirmation\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_exit_pending.json")
    } "agy output with VERIFIED containing exit pending must be rejected"

    # 18l: VERIFIED with negative "not tested"
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: not tested\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_noverify.json")
    } "agy output with not tested in VERIFIED must be rejected"

    # 18m: VERIFIED without numeric exit code
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh and all tests passed\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_no_exitcode.json")
    } "agy output without numeric exit code in VERIFIED must be rejected"

    # 18n: VERIFIED without command
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: exited with code: 0\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_no_cmd.json")
    } "agy output without explicit command in VERIFIED must be rejected"
    Pass "response contract and report schema rejection tests"

    # 19. Interruption / partial write safety (injected crash before evidence publication)
    Set-MockNativeAgyContent -OutputPayload $validJsonPayload
    $crashedEv = Join-Path $evDir "crashed_evidence.json"
    $env:_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH = "simulate_write_crash"
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $crashedEv
    } "simulated crash before evidence publication must fail"
    if (Test-Path -LiteralPath $crashedEv) {
        Fail "Authoritative evidence file was created despite write crash/interruption"
    }
    $env:_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH = $null
    Pass "interruption and partial write safety (no authoritative file created)"

    # 20. Valid JSON object output and envelope generation
    Set-MockNativeAgyContent -OutputPayload $validJsonPayload
    $validEv = Join-Path $evDir "valid_envelope.json"
    & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $validEv
    if ($LASTEXITCODE -ne 0) {
        Fail "Valid mock execution failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $validEv -PathType Leaf)) {
        Fail "Evidence envelope was not created at $validEv"
    }

    $evJsonText = [System.IO.File]::ReadAllText($validEv, $utf8NoBom)
    $evData = $evJsonText | ConvertFrom-Json
    if ($evData.schema_version -ne 1) { Fail "schema_version must be 1" }
    if ($evData.invocation.provider -ne "google-antigravity-cli") { Fail "invocation.provider mismatch" }
    if ($evData.invocation.model_requested -ne "gemini-3.8-flash-high") { Fail "invocation.model_requested mismatch" }
    if ($evData.invocation.model_catalog_exact_match_observed -ne $true) { Fail "invocation.model_catalog_exact_match_observed mismatch" }
    if ($evData.invocation.effort_requested -ne "high") { Fail "invocation.effort_requested mismatch" }
    if ($evData.invocation.mode_requested -ne "accept-edits") { Fail "invocation.mode_requested mismatch" }
    if ($evData.invocation.output_format_requested -ne "json") { Fail "invocation.output_format_requested mismatch" }
    if ($evData.invocation.permission_mode_requested -ne "standard") { Fail "invocation.permission_mode_requested mismatch" }
    if ($evData.invocation.cli_version_observed -ne "1.1.21") { Fail "invocation.cli_version_observed mismatch" }
    if ($evData.invocation.exit_code_observed -ne 0) { Fail "invocation.exit_code_observed mismatch" }
    if ($evData.runtime_observability.model_field_observed -ne $false) { Fail "model_field_observed must be false" }
    if ($evData.runtime_observability.effort_field_observed -ne $false) { Fail "effort_field_observed must be false" }
    if ($evData.runtime_observability.mode_field_observed -ne $false) { Fail "mode_field_observed must be false" }
    if ($evData.runtime_observability.cwd_field_observed -ne $false) { Fail "cwd_field_observed must be false" }
    if ($evData.agy_result.conversation_id -ne "ps-conv-123") { Fail "agy_result.conversation_id mismatch" }
    if ($evData.agy_result.status -ne "completed") { Fail "agy_result.status mismatch" }
    Pass "valid JSON object envelope creation and schema verification"

    # 21. No-clobber preservation on second run with same evidence destination
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $validEv
    } "re-running against existing valid evidence file must fail (no-clobber)"
    Pass "valid evidence envelope no-clobber preservation"

    # 22. Strengthened native helper argument integrity test with Adversarial Spec
    $adversarialSpec = Join-Path $resolvedTempRoot "ps_adversarial_spec.md"
    $adversarialSpecContent = @"
OBJECTIVE
Resolve argument-integrity with "embedded double quotes", 'single quotes', `
and C:\trailing\slash\ and \\unc\share\ path.
Test %PATH% and %USERPROFILE% and %~dp0 and !EXCLAMATION! and !! expansions.
Test carets: ^ and ^^ and ^& and ^| and parentheses: (nested (parens)) and ((math)).
Test pipes and operators: | and || and & and && and > and < and ;.
Unicode: 中文测试 🚀 𝄞 \u00e9 \u2014 and multiline text.

FILES AND OWNERSHIP
- "test file with spaces.txt"
- C:\path\with\trailing\backslash\
- special_chars_^%!&().txt

INTERFACES
- Keep standard interfaces: args[0] == "models", args[0] == "--version".
- Function: Test-Escaping -Input "%VAR% ^| & () ! \" ' \\"

CONSTRAINTS
- Strict constraints: No cmd.exe mangling of %, ^, &, |, !, (, ), ", \, `r, `n.
- Line 1 of constraints.
- Line 2 of constraints with "quotes" and %TEMP%.

VERIFICATION
- Run: pwsh -NoProfile -Command "Write-Output 'VERIFY_OK'; exit 0"
  Exit code: 0
  Evidence: Executed pwsh with exit code: 0
"@
    [System.IO.File]::WriteAllText($adversarialSpec, $adversarialSpecContent, $utf8NoBom)

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
    $expectedFullPrompt = "$promptHeader`n$adversarialSpecContent"

    $advObjectiveExtract = @"
Resolve argument-integrity with "embedded double quotes", 'single quotes', `
and C:\trailing\slash\ and \\unc\share\ path.
Test %PATH% and %USERPROFILE% and %~dp0 and !EXCLAMATION! and !! expansions.
Test carets: ^ and ^^ and ^& and ^| and parentheses: (nested (parens)) and ((math)).
Test pipes and operators: | and || and & and && and > and < and ;.
Unicode: 中文测试 🚀 𝄞 \u00e9 \u2014 and multiline text.
"@

    $advResponseObj = [ordered]@{
        conversation_id = "ps-conv-adv-456"
        status = "completed"
        response = "STATUS: complete`nOBJECTIVE:`n$advObjectiveExtract`nCHANGES: Modified special files.`nVERIFIED: Executed pwsh -NoProfile -Command `"Write-Output 'VERIFY_OK'; exit 0`" (exit code 0)`nJUDGMENT CALLS: none`nGAPS: none"
    }
    $advPayload = $advResponseObj | ConvertTo-Json -Depth 10
    Set-MockNativeAgyContent -OutputPayload $advPayload

    # 22a. Standard execution with adversarial prompt
    if (Test-Path -LiteralPath $mockNativeLogFile) {
        Remove-Item -LiteralPath $mockNativeLogFile -Force
    }

    $advEv = Join-Path $evDir "adv_evidence.json"
    & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $adversarialSpec -EvidenceFile $advEv
    if ($LASTEXITCODE -ne 0) {
        Fail "Standard execution with adversarial spec failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $advEv -PathType Leaf)) {
        Fail "Evidence envelope was not created at $advEv"
    }

    $advEvData = [System.IO.File]::ReadAllText($advEv, $utf8NoBom) | ConvertFrom-Json
    if ($advEvData.invocation.permission_mode_requested -ne "standard") {
        Fail "permission_mode_requested mismatch on standard run"
    }
    if ($advEvData.agy_result.conversation_id -ne "ps-conv-adv-456") {
        Fail "agy_result.conversation_id mismatch on standard run"
    }

    # Verify exact argument integrity from log
    if (-not (Test-Path -LiteralPath $mockNativeLogFile -PathType Leaf)) {
        Fail "Native invocations log was not generated at $mockNativeLogFile"
    }
    $invocations = [System.IO.File]::ReadAllLines($mockNativeLogFile, $utf8NoBom)
    if ($invocations.Length -ne 4) {
        Fail "Expected exactly 4 native agy invocations (models, --version, generation preflight, main); observed $($invocations.Length)"
    }
    $invModels = @($invocations[0] | ConvertFrom-Json)
    if ($invModels.Length -ne 1 -or $invModels[0] -ne "models") {
        Fail "Native model listing invocation argument mismatch: $($invocations[0])"
    }
    $invVer = @($invocations[1] | ConvertFrom-Json)
    if ($invVer.Length -ne 1 -or $invVer[0] -ne "--version") {
        Fail "Native version query invocation argument mismatch: $($invocations[1])"
    }
    $invPreflight = @($invocations[2] | ConvertFrom-Json)
    if (-not (($invPreflight -join ' ').Contains('sol-advisor-generation-preflight-'))) {
        Fail "Native generation preflight invocation or nonce is missing: $($invocations[2])"
    }
    $invMain = @($invocations[3] | ConvertFrom-Json)
    if ($invMain.Length -ne 12) {
        Fail "Expected 12 arguments in standard main invocation; observed $($invMain.Length): $($invocations[3])"
    }
    if ($invMain[0] -ne "--model" -or $invMain[1] -ne "gemini-3.8-flash-high") {
        Fail "Native main invocation --model mismatch: $($invocations[2])"
    }
    if ($invMain[2] -ne "--effort" -or $invMain[3] -ne "high") {
        Fail "Native main invocation --effort mismatch: $($invocations[2])"
    }
    if ($invMain[4] -ne "--mode" -or $invMain[5] -ne "accept-edits") {
        Fail "Native main invocation --mode mismatch: $($invocations[2])"
    }
    if ($invMain[6] -ne "--output-format" -or $invMain[7] -ne "json") {
        Fail "Native main invocation --output-format mismatch: $($invocations[2])"
    }
    if ($invMain[8] -ne "--print-timeout" -or $invMain[9] -ne "25m") {
        Fail "Native main invocation --print-timeout mismatch: $($invocations[2])"
    }
    if ($invMain[10] -ne "--print") {
        Fail "Native main invocation --print flag missing: $($invocations[2])"
    }
    # Assert exact full prompt argument equality (byte-for-byte including quotes, carets, percents, unicode, newlines)
    $capturedPrompt = $invMain[11]
    if ($capturedPrompt -cne $expectedFullPrompt) {
        Fail "Adversarial prompt argument integrity check failed: captured prompt does not match expected prompt exactly."
    }
    # Sanity-check presence of adversarial tokens in captured prompt
    if (-not ($capturedPrompt.Contains('embedded double quotes') -and
              $capturedPrompt.Contains('%PATH%') -and
              $capturedPrompt.Contains('%USERPROFILE%') -and
              $capturedPrompt.Contains('%~dp0') -and
              $capturedPrompt.Contains('!EXCLAMATION!') -and
              $capturedPrompt.Contains('^&') -and
              $capturedPrompt.Contains('^|') -and
              $capturedPrompt.Contains('(nested (parens))') -and
              $capturedPrompt.Contains('||') -and
              $capturedPrompt.Contains('&&') -and
              $capturedPrompt.Contains('C:\trailing\slash\') -and
              $capturedPrompt.Contains('\\unc\share\') -and
              $capturedPrompt.Contains('中文测试 🚀 𝄞') -and
              $capturedPrompt.Contains("`n"))) {
        Fail "Adversarial tokens missing from captured prompt"
    }
    Pass "standard invocation argument integrity with fixed flags and adversarial prompt"

    # 22b. Dangerous permissions invocation with adversarial prompt and custom timeout
    if (Test-Path -LiteralPath $mockNativeLogFile) {
        Remove-Item -LiteralPath $mockNativeLogFile -Force
    }

    $advDangerEv = Join-Path $evDir "adv_danger_evidence.json"
    & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $adversarialSpec -EvidenceFile $advDangerEv -PrintTimeout "45m" -DangerouslySkipPermissions
    if ($LASTEXITCODE -ne 0) {
        Fail "DangerouslySkipPermissions execution with adversarial spec failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $advDangerEv -PathType Leaf)) {
        Fail "Evidence envelope was not created at $advDangerEv"
    }

    $advDangerEvData = [System.IO.File]::ReadAllText($advDangerEv, $utf8NoBom) | ConvertFrom-Json
    if ($advDangerEvData.invocation.permission_mode_requested -ne "dangerously-skip-permissions") {
        Fail "permission_mode_requested mismatch on dangerous run"
    }

    $invocationsDanger = [System.IO.File]::ReadAllLines($mockNativeLogFile, $utf8NoBom)
    if ($invocationsDanger.Length -ne 4) {
        Fail "Expected exactly 4 native agy invocations on dangerous run; observed $($invocationsDanger.Length)"
    }
    $invMainDanger = @($invocationsDanger[3] | ConvertFrom-Json)
    if ($invMainDanger.Length -ne 13) {
        Fail "Expected 13 arguments in dangerous main invocation; observed $($invMainDanger.Length): $($invocationsDanger[2])"
    }
    if ($invMainDanger[0] -ne "--model" -or $invMainDanger[1] -ne "gemini-3.8-flash-high") {
        Fail "Native dangerous invocation --model mismatch: $($invocationsDanger[2])"
    }
    if ($invMainDanger[2] -ne "--effort" -or $invMainDanger[3] -ne "high") {
        Fail "Native dangerous invocation --effort mismatch: $($invocationsDanger[2])"
    }
    if ($invMainDanger[4] -ne "--mode" -or $invMainDanger[5] -ne "accept-edits") {
        Fail "Native dangerous invocation --mode mismatch: $($invocationsDanger[2])"
    }
    if ($invMainDanger[6] -ne "--output-format" -or $invMainDanger[7] -ne "json") {
        Fail "Native dangerous invocation --output-format mismatch: $($invocationsDanger[2])"
    }
    if ($invMainDanger[8] -ne "--print-timeout" -or $invMainDanger[9] -ne "45m") {
        Fail "Native dangerous invocation --print-timeout mismatch: $($invocationsDanger[2])"
    }
    if ($invMainDanger[10] -ne "--dangerously-skip-permissions") {
        Fail "Native dangerous invocation --dangerously-skip-permissions flag missing or misplaced: $($invocationsDanger[2])"
    }
    if ($invMainDanger[11] -ne "--print") {
        Fail "Native dangerous invocation --print flag missing: $($invocationsDanger[2])"
    }
    $capturedPromptDanger = $invMainDanger[12]
    if ($capturedPromptDanger -cne $expectedFullPrompt) {
        Fail "Adversarial prompt argument integrity check failed on dangerous run: captured prompt does not match expected prompt exactly."
    }
    Pass "dangerous permissions invocation argument integrity with all flags and adversarial prompt"

    # 22c. Idle watchdog must terminate a silent implementation process and publish no evidence.
    Set-MockNativeAgyContent -OutputPayload $validJsonPayload -Mode "hang-main"
    $idleEvidence = Join-Path $evDir "idle-watchdog.json"
    $idleStderr = Join-Path $resolvedTempRoot "idle-watchdog.stderr.txt"
    $idleTimer = [System.Diagnostics.Stopwatch]::StartNew()
    & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $idleEvidence `
        -PrintTimeout "8s" -IdleTimeout "2s" -GenerationPreflightTimeout "2s" -HeartbeatInterval "1s" 2> $idleStderr
    $idleExit = $LASTEXITCODE
    $idleTimer.Stop()
    if ($idleExit -eq 0) { Fail "Idle watchdog accepted a silent hanging implementation process" }
    if ($idleTimer.Elapsed.TotalSeconds -gt 10) { Fail "Idle watchdog exceeded bounded test window: $($idleTimer.Elapsed.TotalSeconds)s" }
    if (Test-Path -LiteralPath $idleEvidence) { Fail "Idle watchdog failure published authoritative evidence" }
    $idleLog = [System.IO.File]::ReadAllText($idleStderr, $utf8NoBom)
    if (-not $idleLog.Contains('SOL_ADVISOR_HEARTBEAT') -or -not $idleLog.Contains('idle timeout')) {
        Fail "Idle watchdog did not emit heartbeat and structured timeout evidence"
    }
    Pass "PowerShell implementer heartbeat and idle watchdog"

    Set-MockNativeAgyContent -OutputPayload $validJsonPayload -Mode "json-error"
    $jsonErrorEvidence = Join-Path $evDir "json-error.json"
    $jsonErrorLog = Join-Path $resolvedTempRoot "json-error.stderr.txt"
    & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $jsonErrorEvidence `
        -PrintTimeout "8s" -IdleTimeout "2s" -GenerationPreflightTimeout "2s" -HeartbeatInterval "1s" 2> $jsonErrorLog
    if ($LASTEXITCODE -eq 0) { Fail "Structured AGY failure unexpectedly succeeded" }
    if (Test-Path -LiteralPath $jsonErrorEvidence) { Fail "Structured AGY failure published authoritative evidence" }
    $jsonErrorText = [System.IO.File]::ReadAllText($jsonErrorLog, $utf8NoBom)
    if (-not $jsonErrorText.Contains('status=ERROR') -or -not $jsonErrorText.Contains('timeout waiting for response') -or $jsonErrorText.Contains('missing or empty report field')) {
        Fail "Structured AGY failure was not classified truthfully"
    }
    Pass "PowerShell structured AGY nonzero failure classification"

    # 22d. Native dynamic mismatch rejection
    Set-MockNativeAgyContent -OutputPayload '{"conversation_id": "ps-conv-123", "model": "wrong-model", "status": "completed", "response": "STATUS: complete\nOBJECTIVE: Test\nCHANGES: test\nVERIFIED: Executed pwsh (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"}'
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile (Join-Path $evDir "ev_native_mismatch.json")
    } "dynamic model mismatch with native executable must be rejected"
    Pass "native executable dynamic mismatch rejection"

    # 22e. Native no-clobber preservation
    Assert-Fails {
        & $powerShellExe -NoProfile -File $resolvedWrapper -Workspace $ws -SpecFile $spec -EvidenceFile $validEv
    } "re-running against existing native evidence file must fail (no-clobber)"
    Pass "native executable valid evidence envelope no-clobber preservation"

    [Console]::WriteLine("ALL POWERSHELL VERIFICATION CHECKS PASSED.")
} finally {
    $env:_SOL_ADVISOR_TEST_MODE = $null
    $env:_SOL_ADVISOR_TEST_AGY_EXE = $null
    $env:_SOL_ADVISOR_TEST_AGY_BIN = $null
    $env:_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH = $null

    if ($resolvedTempRoot -and (Test-Path -LiteralPath $resolvedTempRoot -PathType Container)) {
        try {
            $item = Get-Item -LiteralPath $resolvedTempRoot -Force
            if ($item.FullName.StartsWith($tmpBase, [System.StringComparison]::OrdinalIgnoreCase) -and $item.Name.StartsWith("sol-advisor-ps-verify.")) {
                # Delete any junction points first so recursion doesn't cross filesystem boundaries
                Get-ChildItem -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
                } | ForEach-Object {
                    try { $_.Delete() } catch {}
                }
                Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}
