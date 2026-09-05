# Operations and Operational Guide

This document describes the operational procedures, commands, preflight checks, test mode flags, and safety guarantees for `yiwan-sol-advisor`.

## 0. Distribution Setup

After Skill Installer or `git clone` places the repository in the user-level Skill directory, run the platform setup helper.

Windows:

```powershell
pwsh -NoProfile -File .\scripts\setup-yiwan-sol-advisor.ps1
```

POSIX / Linux / macOS / WSL:

```sh
sh ./scripts/setup-yiwan-sol-advisor.sh
```

Both helpers verify Codex, Git, Python, `agy`, and the required `gemini-3.8-flash-high` model. If `agy` is missing, they prefer Google's official online installer. When that download fails, pass a user-supplied official release archive and its independently recorded SHA-256:

After authentication, setup backs up an existing `~/.gemini/antigravity-cli/settings.json`, configures `toolPermission` as `proceed-in-sandbox` and `enableTerminalSandbox` as `true`, then runs a real `agy --sandbox` headless command smoke test. `--check-only` validates this state without changing it. This is a user-level Antigravity preference and also affects other AGY sessions for that user.

```powershell
pwsh -NoProfile -File .\scripts\setup-yiwan-sol-advisor.ps1 `
  -AgyOfflinePackage "D:\offline\agy_cli_windows_x64.zip" `
  -AgyOfflineSha256 "<64-hex-sha256>"
```

```sh
sh ./scripts/setup-yiwan-sol-advisor.sh \
  --agy-offline-package /media/offline/agy_cli_linux_x64.tar.gz \
  --agy-offline-sha256 '<64-hex-sha256>'
```

The repository does not redistribute Google binaries. Authentication remains interactive: the helper launches `agy` when needed, the user completes Google sign-in and terms acceptance, and the helper then rechecks model availability. Use `-CheckOnly` / `--check-only` for a read-only prerequisite audit or `-SkipLogin` / `--skip-login` when login must be completed later.

## 1. Launcher Usage

The launcher executes a machine-enforced state machine orchestrating Sol specification planning, Antigravity code implementation, parent verification, and fresh review.

### Windows (PowerShell 7):
```powershell
pwsh .codex/skills/yiwan-sol-advisor/scripts/launch-sol-advisor.ps1 `
  -Workspace "C:\path\to\repo" `
  -TaskFile "C:\path\to\task.md" `
  -ResultFile "C:\path\to\output\result.md" `
    [-Timeout "75m"] `
  [-MaxCorrections 3] `
  [-DangerouslySkipPermissions] `
  [-TestMode] `
  [-TestAgyExe "C:\path\to\mock_agy.exe"] `
  [-TestCodexBin "C:\path\to\mock_codex.exe"]
```

### POSIX / Linux / WSL (bash):
```sh
sh .codex/skills/yiwan-sol-advisor/scripts/launch-sol-advisor.sh \
  --workspace /path/to/repo \
  --task-file /path/to/task.md \
  --result-file /path/to/output/result.md \
    [--timeout 75m] \
  [--max-corrections 3] \
  [--dangerously-skip-permissions] \
  [--test-mode] \
  [--test-agy-exe /path/to/mock_agy] \
  [--test-codex-bin /path/to/mock_codex]
```

### Launcher Parameters:
- `-Workspace` / `--workspace`: Absolute path to target Git top-level repository.
- `-TaskFile` / `--task-file`: Absolute path to a UTF-8 markdown or text file (<= 1MB) describing the task outside the workspace.
- `-ResultFile` / `--result-file`: Absolute path outside the workspace where final report is published (fails if file already exists).
- `-Timeout` / `--timeout`: Hard orchestration deadline. One iteration default budget covers planner `6m`, implementer `15m`, reviewer `8m`, and machine reserve `2m`. When `-Timeout` is smaller than the default phase sum (e.g. `-Timeout 25m`) and phase budgets are not explicitly configured, the launcher dynamically scales planner (20%), implementer (50%), reviewer (25%), and machine reserve proportionally. If sub-stage budgets are explicitly specified and exceed the total timeout, the launcher fails closed before planning or writing.
- `-PlannerIdleTimeout` / `--planner-idle-timeout`: Sol planner no-progress deadline (default: `2m`). Progress means stdout/stderr bytes, plan output file growth, or process-tree CPU activity. On timeout, the launcher terminates the process tree, dumps restricted diagnostics (`planner-stdout.log`, `planner-stderr.log`, `diagnostics.json`, partial plan), and fails closed.
- `-IdleTimeout` / `--idle-timeout`: Implementer no-progress deadline (default: `4m`). Progress means stdout/stderr bytes, declared-worktree changes, or process-tree CPU growth. Network connectivity alone is not progress.
- `-GenerationPreflightTimeout` / `--generation-preflight-timeout`: Disposable exact-model generation probe (default: `60s`) performed before the implementation window. Executed on iteration 1; subsequent correction iterations pass `-SkipGenerationPreflight` / `--skip-generation-preflight` to save execution time.
- `Stage Duration Telemetry`: The launcher collects precise per-stage execution times across all iterations (Planner, Implementer, Parent Verify, Reviewer), emits a structured `SOL_ADVISOR_TELEMETRY` JSON event on stderr, prints an ASCII waterfall table to stdout, and writes `telemetry.json` into the private run directory.
- `-MaxOwnedFiles` / `--max-owned-files` and `-MaxVerificationCommands` / `--max-verification-commands`: default `6` (max 50); oversized plans fail closed and should be split into phases.
- `-MaxCorrections` / `--max-corrections`: Maximum number of fix-first correction iterations (default: `1`).
- `-DangerouslySkipPermissions` / `--dangerously-skip-permissions`: Enabled by default for headless implementer execution within the safety sandbox (protected by parent repository snapshot diffing, strict `owned_files` whitelist, and parent verification gate). Use `-EnforceInteractivePermissions` / `--enforce-interactive-permissions` to require interactive approval.
- `-TestMode` / `--test-mode`: Explicit switch required to activate test overrides/fakes.
- `-TestAgyExe` / `--test-agy-exe`: Executable path override for Antigravity CLI (requires `-TestMode`).
- `-TestCodexBin` / `--test-codex-bin`: Executable path override for Codex binary (requires `-TestMode`).

## 2. Antigravity Implementer Wrapper Usage

The implementer wrapper dispatches a five-part specification directly to Google Antigravity CLI.

### Windows:
```powershell
pwsh .codex/skills/yiwan-sol-advisor/scripts/run-antigravity-implementer.ps1 `
  -Workspace "C:\path\to\repo" `
  -SpecFile "C:\path\to\spec.md" `
  -EvidenceFile "C:\path\to\evidence.json" `
    [-PrintTimeout "25m"] `
    [-IdleTimeout "8m"] `
    [-GenerationPreflightTimeout "90s"] `
  [-SkipGenerationPreflight] `
  [-DangerouslySkipPermissions] `
  [-TestMode] `
  [-TestAgyExe "C:\path\to\mock_agy.exe"]
```

### POSIX:
```sh
sh .codex/skills/yiwan-sol-advisor/scripts/run-antigravity-implementer.sh \
  --workspace /path/to/repo \
  --spec-file /path/to/spec.md \
  --evidence-file /path/to/evidence.json \
    [--print-timeout 25m] \
    [--idle-timeout 8m] \
    [--generation-preflight-timeout 90s] \
  [--skip-generation-preflight] \
  [--dangerously-skip-permissions] \
  [--test-mode] \
  [--test-agy-exe /path/to/mock_agy]
```

### Wrapper Guarantees:
- Verifies target workspace is the exact physical Git root via `git rev-parse --show-toplevel`.
- Enforces strict five-part specification structure (`OBJECTIVE`, `FILES AND OWNERSHIP`, `INTERFACES`, `CONSTRAINTS`, `VERIFICATION`) with conservative 24 KiB size limit for command-line safety.
- Rejects relative specification paths, specification paths inside the target workspace, and pre-existing evidence files.
- Rejects symbolic links, junctions, reparse points in directory ancestors, alternate data streams (ADS `:`), and device namespaces.
- Requires native `agy.exe` on Windows (rejects `.cmd`/`.bat` wrappers).
- Verifies model `gemini-3.8-flash-high` availability via `agy models`.
- Verifies actual generation with a nonce-bound request in a disposable temporary directory before any workspace write (skippable via `-SkipGenerationPreflight` / `--skip-generation-preflight` in subsequent correction iterations once verified).
- Requires the setup-managed sandbox policy and pins `--new-project --sandbox --dangerously-skip-permissions --model gemini-3.8-flash-high --effort high --mode accept-edits --output-format json`. `--new-project` is required to bind the headless tool CWD to the requested workspace. Runtime version is observed/preflighted but not version-locked. The bypass removes AGY's interactive permission gate, including sandbox-escalation confirmations; parent integrity checks do not eliminate command side effects outside the workspace.
- Emits `SOL_ADVISOR_HEARTBEAT` records on stderr and kills the complete implementation process tree on idle or hard timeout. Stdout remains reserved for the final JSON payload.
- Enforces parsed timeout duration with process tree termination on timeout.
- Validates six-field report contract and evidence of real verification commands with numeric exit codes.
- Atomically publishes schema version 1 evidence envelope using two-phase private staging with parent directory handle identity verification.

## 3. Fresh Sol Reviewer Usage

The fresh reviewer launches an ephemeral read-only Codex process (inheriting the active model such as `gpt-6-astra`, `gpt-5.6-sol`, or `gpt-5.5`, and configured reasoning effort) to inspect diffs and parent verification evidence. On Windows it starts from an empty disposable execution root and reviews only the bounded evidence bundle; it does not mount the canonical dynamic worktree as its current directory.

### Windows:
```powershell
pwsh .codex/skills/yiwan-sol-advisor/scripts/run-fresh-reviewer.ps1 `
  -Workspace "C:\path\to\repo" `
  -GoalFile "C:\path\to\task.md" `
  -EvidenceFile "C:\path\to\evidence.json" `
  -ParentVerificationFile "C:\path\to\parent-verification.json" `
  -ReviewOutputFile "C:\path\to\review.json" `
  [-Model "gpt-6-astra"] `
  [-ReasoningEffort "high"] `
  [-Timeout "15m"] `
  [-TestMode] `
  [-TestCodexBin "C:\path\to\mock_codex.exe"]
```

### POSIX:
```sh
sh .codex/skills/yiwan-sol-advisor/scripts/run-fresh-reviewer.sh \
  --workspace /path/to/repo \
  --goal-file /path/to/task.md \
  --evidence-file /path/to/evidence.json \
  --parent-verification-file /path/to/parent-verification.json \
  --review-output-file /path/to/review.json \
  [--model gpt-6-astra] \
  [--reasoning-effort high] \
  [--timeout 15m] \
  [--test-mode] \
  [--test-codex-bin /path/to/mock_codex]
```

### Reviewer Guarantees:
- Captures pre-review repository state with streaming SHA-256 hashes of all tracked, staged, and untracked file contents.
- Supplies staged diff (`git diff --cached --binary`) and unstaged diff (`git diff --binary`) separately within fail-closed limits (total diff <= 2MB, untracked text <= 1MB).
- Requires independent parent verification artifact as input with strict schema version 1 verification.
- Strictly binds and echoes all 9 cryptographic digests (`task_sha256`, `plan_sha256`, `spec_sha256`, `implementer_evidence_sha256`, `parent_verification_sha256`, `pre_window_manifest_sha256`, `post_window_manifest_sha256`, `repository_manifest_sha256`, `aggregate_delta_manifest_sha256`).
- Executes `codex exec` with `-m <model> -s read-only --ephemeral`; it dynamically detects and inherits the active model (such as `gpt-6-astra`, `gpt-5.6-sol`, or `gpt-5.5`) and reasoning effort from the user's Codex configuration (`~/.codex/config.toml`) while supporting explicit `-Model` / `--model` and `-ReasoningEffort` / `--reasoning-effort` overrides.
- For independent acceptance evidence on Windows, pass `-TrustedVerificationScript <absolute-path-outside-workspace>`. The caller owns and audits this script; planner suggestions are never promoted to trusted commands automatically. The launcher records stdout, stderr, SHA-256, and the observed exit code, and fails if the verifier mutates the repository.
- On Windows, the planner inspects a disposable local Git mirror populated with the canonical tracked and non-ignored working-tree view. This avoids `CreateProcessWithLogonW failed: 267` / access-denied failures caused by restricted AppContainer traversal of dynamic worktrees without weakening the Sol sandbox.
- If Codex reports an account usage limit, orchestration stops with a concise no-fallback diagnostic. Wait for the stated reset; do not substitute another planner/reviewer model.
- Enforces timeout duration and kills subprocess tree on expiry.
- Captures post-review repository content manifest and proves repository remained completely unmodified.
- Validates structured JSON verdict (`SHIP`, `FIX-FIRST`, `RETHINK`).
- Atomically publishes review envelope to `-ReviewOutputFile`.

## 4. Verification and Self-Tests

Run the bundled test suites to verify skill integrity:

### Windows:
```powershell
pwsh -NoProfile -File .codex/skills/yiwan-sol-advisor/scripts/verify-skill.ps1
```

### POSIX / Linux / WSL:
```sh
sh .codex/skills/yiwan-sol-advisor/scripts/verify-skill.sh
```

### Individual Verification Checks:
1. **Skill Quick Validation**:
   ```powershell
   python "C:\Users\Administrator\.codex\skills\.system\skill-creator\scripts\quick_validate.py" "C:\Users\Administrator\.codex\skills\yiwan-sol-advisor"
   ```
2. **Git Diff Syntax Check**:
   ```powershell
   git -C "C:\Users\Administrator\.codex\skills\yiwan-sol-advisor" diff --check
   ```
3. **PowerShell Script Syntax / AST Check**:
   ```powershell
   Get-ChildItem -Path "C:\Users\Administrator\.codex\skills\yiwan-sol-advisor\scripts" -Filter "*.ps1" | ForEach-Object {
       [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
   }
   ```
4. **POSIX Script Syntax (`sh -n`)**:
   ```sh
   for f in scripts/*.sh; do sh -n "$f"; done
   ```

## 5. Maintainer Guarantees and Failure Scope Boundaries

- **Process Interruption and Recovery**: While pre-mutation checks, lockfiles, and transactional staging prevent corrupt partial writes, automatic restoration after installer process interruption is not promised. Unique backup and quarantine recovery artifacts are preserved with timestamped paths for manual recovery.
- **Filesystem Security Boundaries**: Atomic publication validates physical directory handle identity before moving staged files; however, hostile parent directory replacement after handle validation and power-loss durability are excluded from the userland threat model.

