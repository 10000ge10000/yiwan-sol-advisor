---
name: orchestration
description: Orchestrates software delivery with a dedicated GPT-5.6 Sol controller using the user's configured reasoning effort, Google Antigravity CLI (Gemini 3.8 Flash High) as sole implementer, and an ephemeral read-only Sol reviewer using the same inherited effort policy.
---

# Sol Advisor Orchestration

`$yiwan-sol-advisor` is an explicit, standalone orchestration skill. It establishes an autonomous, machine-enforced delivery pipeline where task architecture, specification planning, working-tree verification, and acceptance are governed by a dedicated **GPT-5.6 Sol** controller using the reasoning effort inherited from the user's current Codex configuration; all code edits are executed exclusively by the local **Google Antigravity CLI** (`gemini-3.8-flash-high`, `--effort high`, `--mode accept-edits`); and final inspection is performed by a fresh, ephemeral, read-only **GPT-5.6 Sol** reviewer using the same inherited-effort policy.

## On Explicit Invocation

When `$yiwan-sol-advisor` is explicitly invoked in an interactive conversation, the activating interactive model acts strictly as a **thin launcher**. It **must not analyze** repository code, design architecture, author specifications, plan steps, review diffs, or implement code itself before handing off.

Follow this exact activation procedure:

1. **Identify Target Workspace**: Determine the canonical Git workspace root from the conversation context or user prompt. If the workspace path is genuinely missing or ambiguous, ask the user only for the workspace path.
2. **Preserve User Task**: Extract the user's exact task instructions and save them to a UTF-8 task file (<= 1MB) outside the target workspace (e.g. in the system temporary directory). If the task description is genuinely missing, ask only for the task details. Do not require secret code phrases or modifications to `AGENTS.md` / `GEMINI.md`. Do not ask the user to switch reasoning effort: the dedicated Sol processes inherit the user's current Codex reasoning-effort configuration instead of pinning a tier.
3. **Allocate Result Destination**: Allocate a unique, non-existent result file path outside the target workspace (e.g. `task-result-<timestamp>.md` in the temporary directory) to ensure structured, no-clobber output.
4. **Execute Dedicated Platform Launcher**: Derive the absolute path to the bundled platform launcher from the Skill root and invoke it:
   - On Windows: invoke `$env:USERPROFILE\.codex\skills\yiwan-sol-advisor\scripts\launch-sol-advisor.ps1`
   - On POSIX: invoke `${CODEX_HOME:-$HOME/.codex}/skills/yiwan-sol-advisor/scripts/launch-sol-advisor.sh`
   Pass `-Workspace` / `--workspace`, `-TaskFile` / `--task-file`, `-ResultFile` / `--result-file`, optional `-Timeout` / `--timeout` (default `60m`), and optional `-MaxCorrections` / `--max-corrections` (default `1`). On Windows, when independent test evidence is required, the caller may also pass an explicit UTF-8 `-TrustedVerificationScript` outside the workspace; the launcher runs it with `bash` after the writer window, records its real exit code/output, and rejects repository mutation by the verifier. Planner-suggested commands remain untrusted and are never executed automatically. The launcher reserves independent planner / implementer / reviewer budgets and refuses to start a new writer window when the remaining total cannot complete one safe iteration. On Windows, planning runs against a disposable Git mirror outside the canonical worktree and review runs from an empty disposable root; this avoids AppContainer failures on dynamic worktrees while preserving the `read-only` Codex sandbox and machine-verifying that the canonical repository never changes during either Sol stage. The implementer wrapper always enables `--dangerously-skip-permissions` together with `--sandbox`; callers do not need to add a permission flag.
5. **Relay Dedicated Controller Output**: Wait for launcher completion, read the final structured result from the result file, and relay the controller's implementation report (`STATUS`, `OBJECTIVE`, `CHANGES`, `VERIFIED`, `JUDGMENT CALLS`, `GAPS`) directly to the user.
6. **Append Skill-Only Model Division Report**: Because this Skill was explicitly invoked, read [references/model-report.md](references/model-report.md) and append its model division report after the implementation result. Report only runtime activity actually observed in this Skill run. Do not emit this report outside an explicit `$yiwan-sol-advisor` invocation.

## Delivery Workflow

The orchestration pipeline follows five strict stages with zero fallback, machine-enforced by the launcher state machine with discrete stage artifacts and cryptographic evidence bindings:

1. **Architecture & Specification (Dedicated Sol Planner / Corrector)**:
   - Evaluates requirements, inspects current workspace conventions, and authors a structured machine plan `plan.json` containing `objective`, declared `owned_files` (1..6 clean relative paths by default), `interfaces`, `constraints`, and at most 4 focused verification commands (reduced to 2 when a parent trusted verifier is supplied). Larger work is split into independently verifiable phases instead of one unbounded implementation call.
   - Renders a clean five-part worker specification `worker-spec.md` (`OBJECTIVE`, `FILES AND OWNERSHIP`, `INTERFACES`, `CONSTRAINTS`, `VERIFICATION`) bounded to a conservative maximum of 24 KiB for command-line safety.
   - Planner executes with read-only sandbox (`-s read-only`) as ephemeral `gpt-5.6-sol`, without overriding `model_reasoning_effort`; the user's current Codex configuration selects the tier. Windows uses a disposable Git mirror containing the canonical tracked and non-ignored working-tree view, so a restricted AppContainer never needs to traverse the real dynamic worktree. Nonessential Codex apps, plugins, browser integrations, memories, and skill discovery are disabled for the bounded planner process so unavailable remote catalogs or MCP transports cannot consume the planning budget. A CLI-enforced JSON output schema constrains the plan. Structured planner heartbeats and an independent idle watchdog make the bounded 6-minute stage observable and fail-closed on stalls, preserving restricted diagnostic logs outside the workspace on timeout. Pre- and post-planning repository manifests verify zero canonical mutations occur. In correction iterations, the planner receives prior review findings, full prior implementer and parent verification evidence, and verified SHA-256 bindings. A Codex usage-limit error stops concisely with no model fallback.

2. **Code Implementation (Google Antigravity CLI)**:
   - Dispatches `worker-spec.md` (<= 24 KiB) to Google Antigravity CLI via bundled wrappers (`scripts/run-antigravity-implementer.ps1` on Windows or `scripts/run-antigravity-implementer.sh` on POSIX).
   - Pins model `gemini-3.8-flash-high`, `--effort high`, `--mode accept-edits`, `--new-project`, `--sandbox`, `--dangerously-skip-permissions`, and `--output-format json`. `--new-project` binds every isolated AGY run to the requested Git workspace instead of its scratch directory. The bypass is required because current Windows AGY headless AppContainer execution requests non-interactive `escalate_admin` approval even for ordinary development commands. The setup helper also configures Antigravity's official `proceed-in-sandbox` policy once, after backing up existing settings. Runtime CLI version is observed and preflighted via `agy models` and `agy --version` (installed CLI binaries are observed/preflighted, not version-locked).
   - Records a structured schema version 1 evidence envelope (`implementer-evidence.json`) to a private run directory outside the workspace.
   - Before touching the workspace, performs a disposable real-generation preflight for the exact pinned model in iteration 1 (subsequent correction iterations pass `-SkipGenerationPreflight` / `--skip-generation-preflight` to skip redundant generation checks). During implementation it emits structured stderr heartbeats, observes stdout/stderr, owned-worktree and process-tree CPU progress, and terminates the process tree after an independent idle timeout or hard stage cap. A failed window is preserved but explicitly marked untrusted and never published as success.
   - Enforces per-window snapshot attribution: computes window delta $\Delta_{window} = S_{post\_impl} - S_{pre\_impl}$. Both destination and source paths of rename/copy records are verified. Every file in $\Delta_{window}$ must match declared `owned_files`. Pre-existing dirty files untouched in this window are not attributed to Antigravity.
   - Enforces scoped Git metadata integrity: verifies baseline HEAD SHA, symbolic ref, config, hooks, non-HEAD refs, attributes, exclude info, shallow state, and lack of in-progress Git operations.

3. **Parent Machine Integrity & Inspection**:
   - Performs deterministic machine-owned checks: verifies scoped Git metadata integrity, zero unowned mutations in the window (including rename destinations), and schema version 1 implementer evidence envelope.
   - Model-authored verification commands are treated as suggested untrusted hints; parent does not execute arbitrary model-authored shell commands on the trusted verification path. Implementer test reports are explicitly labeled as untrusted implementer self-reports. A caller-authored `TrustedVerificationScript`, when explicitly supplied from outside the workspace, is SHA-256-bound, executed independently with a bounded timeout, and must exit zero without mutating the repository.
   - Binds all stage digests (`task_sha256`, `plan_sha256`, `spec_sha256`, `implementer_evidence_sha256`, `pre_window_manifest_sha256`, `post_window_manifest_sha256`, `repository_manifest_sha256`, `aggregate_delta_manifest_sha256`) in `parent-verification.json` over exact raw published bytes. Note: Ignored files (`.gitignore`) are excluded from integrity scope; objects database and reflogs are explicitly outside scope.

4. **Fresh Read-Only Sol Review Gate**:
   - Launches an isolated ephemeral `gpt-5.6-sol` reviewer without overriding `model_reasoning_effort` via bundled scripts (`scripts/run-fresh-reviewer.ps1` or `scripts/run-fresh-reviewer.sh`). The Windows reviewer runs from an empty disposable root with nonessential apps/plugins/browser/memory/skill integrations disabled and receives the complete bounded review bundle in its prompt, so it has no direct canonical-worktree dependency or remote plugin-catalog startup dependency.
   - Supplies staged diff (`git diff --cached --binary`) and unstaged diff (`git diff --binary`) separately, untracked files with binary metadata and streaming SHA-256 hashing, implementer evidence, and parent verification evidence within fail-closed presentation caps (diff <= 2MB, untracked text <= 1MB).
   - SHA-256 repository manifest verifies the repository remains completely unmodified throughout the review.
   - Receives structured verdict (`SHIP`, `FIX-FIRST`, or `RETHINK`) and strictly echoes all mandatory 64-hex cryptographic bindings in `review-evidence.json`.

5. **Fix-First Correction Loop or Final Delivery**:
   - On `SHIP`: Launcher verifies parent verification passed, validates all 9 reviewer bindings, computes aggregate task changes $\Delta_{task}$, enforces truthful completion (`reviewed_no_change: true` is strictly required if $\Delta_{task}$ is empty), formats the six-field implementation report (`STATUS`, `OBJECTIVE`, `CHANGES`, `VERIFIED`, `JUDGMENT CALLS`, `GAPS`), outputs structured stage duration metrics (`SOL_ADVISOR_TELEMETRY` on stderr and ASCII waterfall table on stdout), and publishes atomically to the result destination.
   - On `FIX-FIRST`: Launcher starts a new bounded correction cycle (up to `MaxCorrections` within the hard total deadline): a fresh Sol correction planner using inherited effort receives findings and prior evidence, emits a new five-part correction spec, Antigravity implements in a new window, parent re-verifies, and fresh review runs.
   - On `RETHINK`: Stops implementation, halts with structured error, and does not publish success.
   - On `Timeout` (hard total deadline) or `MaxCorrections` exhaustion: Halts without publishing success.

## Launcher Entry Points

Run the dedicated controller from your terminal or automation:

- **Windows (PowerShell 7)**:
  ```powershell
  pwsh "$env:USERPROFILE\.codex\skills\yiwan-sol-advisor\scripts\launch-sol-advisor.ps1" `
    -Workspace "C:\path\to\repo" `
    -TaskFile "C:\path\to\temp\task.md" `
    -ResultFile "C:\path\to\temp\result.md" `
    [-Timeout "75m"] `
    [-MaxCorrections 3]
  ```

- **POSIX / Linux / WSL (bash)**:
  ```sh
  sh "${CODEX_HOME:-$HOME/.codex}/skills/yiwan-sol-advisor/scripts/launch-sol-advisor.sh" \
    --workspace /path/to/repo \
    --task-file /path/to/temp/task.md \
    --result-file /path/to/temp/result.md \
    [--timeout 75m] \
    [--max-corrections 3]
  ```

## Bundled Components and References

- **Setup Helpers**: `scripts/setup-yiwan-sol-advisor.ps1` and `scripts/setup-yiwan-sol-advisor.sh` verify prerequisites, prefer Google's official online installer, accept a user-provided official offline package only with a matching SHA-256, guide interactive authentication, verify `gemini-3.8-flash-high`, back up and configure Antigravity's sandbox automation settings, and run a real headless command smoke test. They never bundle or redistribute the `agy` binary.
- **Role Contracts**: See [references/role-contracts.md](references/role-contracts.md) for full five-part spec format, six-part report schema, reviewer contracts, parent verification schemas, cryptographic bindings, and permission constraints.
- **Model Report**: Read [references/model-report.md](references/model-report.md) only when preparing the final response for an explicitly invoked Skill run.
- **Operations Guide**: See [references/operations.md](references/operations.md) for CLI commands, test mode flags, preflight checks, sandbox policy, troubleshooting, and maintainer verification.
- **Implementer Wrappers**: [scripts/run-antigravity-implementer.ps1](scripts/run-antigravity-implementer.ps1), [scripts/run-antigravity-implementer.sh](scripts/run-antigravity-implementer.sh).
- **Fresh Reviewer Wrappers**: [scripts/run-fresh-reviewer.ps1](scripts/run-fresh-reviewer.ps1), [scripts/run-fresh-reviewer.sh](scripts/run-fresh-reviewer.sh).
- **Self-Test Suites**: [scripts/verify-skill.ps1](scripts/verify-skill.ps1), [scripts/verify-skill.sh](scripts/verify-skill.sh).
