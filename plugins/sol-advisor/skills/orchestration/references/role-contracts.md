# Role Contracts and Orchestration Specification

This document defines the strict role boundaries, specification formats, machine-enforced stage schemas, cryptographic bindings, and execution protocols for the `yiwan-sol-advisor` skill.

## 1. Five-Stage Machine-Enforced Delivery Workflow

The workflow consists of five stages governed strictly by the launcher state machine with discrete stage artifacts and cryptographic evidence bindings:

```
[User Task]
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 1: Architecture & Specification Planning            │
│   Ephemeral Read-Only Sol (inherits user effort)          │
│   Produces: plan.json, worker-spec.md (<= 24 KiB)         │
│   Guarantees: zero workspace modifications                │
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 2: Code Implementation Window                       │
│   Google Antigravity CLI (gemini-3.8-flash-high)          │
│   Sole write-capable implementer                          │
│   Produces: implementer-evidence.json                     │
│   Guarantees: per-window Δ_window bounded to owned_files  │
│               scoped Git metadata integrity enforced      │
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 3: Parent Machine Integrity & Verification          │
│   Deterministic machine-owned checks                      │
│   Labels implementer test reports as untrusted            │
│   Produces: parent-verification.json                      │
│   Guarantees: zero unowned modifications, HEAD unchanged  │
│               cryptographic SHA-256 bindings              │
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────┐
│ Stage 4: Fresh Read-Only Sol Review Gate                  │
│   Ephemeral Read-Only Sol (inherits user effort)          │
│   Inspects: Goal, Staged & Unstaged Diffs, Untracked,     │
│             Implementer & Parent Verification Evidences   │
│   Produces: review-evidence.json                          │
│   Guarantees: repository immutability, echoes all bindings│
└───────────────────────────┬───────────────────────────────┘
                            │
                            ▼
                   [Review Verdict]
                    /      │      \
                   /       │       \
          [SHIP]  /  [FIX-FIRST]    \  [RETHINK]
                 /         │         \
                ▼          ▼          ▼
         ┌──────────┐ ┌──────────┐ ┌──────────┐
         │ Publish  │ │ Bounded  │ │ Halt and │
         │  Report  │ │ Re-loop  │ │  Report  │
         │ (Result) │ │ (≤ Max)  │ │ (Failure)│
         └──────────┘ └──────────┘ └──────────┘
```

1. **Architecture & Specification (Dedicated Sol Planner / Corrector)**:
   - Dedicated `gpt-5.6-sol` process at `max` reasoning effort running in a read-only sandbox (`-s read-only`). On Windows, it inspects a disposable Git mirror outside the canonical workspace because restricted AppContainer processes can fail to traverse dynamic worktrees. The mirror contains tracked and non-ignored working-tree content, while canonical pre/post manifests remain the authority for immutability.
   - Analyzes requirements, checks workspace conventions, and authors `plan.json` and rendered `worker-spec.md` (bounded to <= 24 KiB for command-line safety).
   - Never writes directly to the workspace; pre- and post-planning content fingerprints verify zero modification.
   - In correction iterations (iteration > 1), receives prior review findings, full prior parent verification evidence, full prior implementer evidence, and their verified digests.

2. **Antigravity Implementation**:
   - Google Antigravity CLI (`gemini-3.8-flash-high`, `--effort high`, `--mode accept-edits`, `--output-format json`) executes the spec within the workspace.
   - Antigravity is the sole implementation provider. Runtime CLI version is observed and preflighted via `agy models` and `agy --version` (installed CLI binaries are observed/preflighted, not version-locked).
   - Attributions bracket the window: computes window delta $\Delta_{window} = S_{post\_impl} - S_{pre\_impl}$. Both destination and source paths of rename/copy records are verified. Any change in $\Delta_{window}$ outside declared `owned_files` fails immediately. Pre-existing dirty files untouched during this window are not attributed to Antigravity.
   - Enforces scoped Git metadata integrity: verifies current HEAD commit hash, symbolic ref, config, hooks, non-HEAD refs, attributes, exclude info, shallow state, and lack of in-progress Git operations.

3. **Parent Machine Integrity & Inspection**:
   - Performs deterministic machine-owned checks: verifies scoped Git metadata integrity, zero unowned mutations in the window (including rename destinations), and schema version 1 implementer evidence envelope.
   - Model-authored verification commands are treated as suggested untrusted hints; parent does not execute arbitrary model-authored shell commands on the trusted verification path. Implementer test reports are explicitly labeled as untrusted implementer self-reports.
   - Binds all stage digests (`task_sha256`, `plan_sha256`, `spec_sha256`, `implementer_evidence_sha256`, `pre_window_manifest_sha256`, `post_window_manifest_sha256`, `repository_manifest_sha256`, `aggregate_delta_manifest_sha256`) in `parent-verification.json`.

4. **Fresh Read-Only Sol Review**:
   - Launches a separate ephemeral read-only `gpt-5.6-sol` / `max` Codex process. The Windows process starts in an empty disposable root and consumes the complete review bundle from its prompt rather than directly opening the canonical workspace.
   - Supplies staged diff (`git diff --cached --binary`) and unstaged diff (`git diff --binary`) separately, untracked files with binary metadata and streaming SHA-256 hashing, implementer evidence, and parent verification evidence within fail-closed presentation caps (diff <= 2MB, untracked text <= 1MB).
   - Evaluates changes in a fresh context and returns `SHIP`, `FIX-FIRST`, or `RETHINK` in structured JSON (`review-evidence.json`) with strictly echoed 64-hex cryptographic bindings.
   - Verifies the reviewed repository remains unmodified via SHA-256 repository manifest of all tracked, staged, and untracked files.

5. **Correction Loop (Fix-First) or Delivery**:
   - On `SHIP`: Verifies parent verification passed, validates all 9 reviewer bindings, computes aggregate task changes $\Delta_{task}$, enforces truthful completion (`reviewed_no_change: true` is strictly required if $\Delta_{task}$ is empty), formats the six-field implementation report (`STATUS`, `OBJECTIVE`, `CHANGES`, `VERIFIED`, `JUDGMENT CALLS`, `GAPS`), and publishes atomically to the result destination.
   - On `FIX-FIRST`: If iteration count $\le$ `MaxCorrections`, authors a targeted five-part correction specification with findings, re-dispatches to Antigravity (Stage 2), re-verifies in parent (Stage 3), and triggers another fresh review (Stage 4).
   - On `RETHINK`: Halts implementation, outputs structured failure reason, and does not publish success.
   - On timeout (hard total deadline) or max corrections exhaustion: Halts without publishing success.

## 2. Stage Artifact Schemas

### A. Plan Artifact (`plan.json`)
Emitted by the read-only Sol planner:
```json
{
  "objective": "<concrete observable outcome>",
  "owned_files": [
    "path/to/file1.py",
    "path/to/file2.py"
  ],
  "interfaces": "<signatures, schemas, or commands to preserve>",
  "constraints": "<conventions, safety boundaries, excluded scope>",
  "verification_commands": [
    "pytest tests/test_feature.py",
    "git diff --check"
  ]
}
```

### B. Five-Part Worker Specification (`worker-spec.md`)
Rendered from `plan.json` for Google Antigravity CLI (maximum 24 KiB):
```text
OBJECTIVE
<Concrete observable outcome and rationale.>

FILES AND OWNERSHIP
You own only:
- <exact relative file or directory path>

You are not alone in the codebase. Other agents or the user may be editing concurrently.
Preserve their edits, do not revert unrelated work, and adapt to changes already present.
Do not modify files outside your ownership.

INTERFACES
- <Signatures, types, schemas, commands, or protocol behaviors to preserve.>

CONSTRAINTS
- <Repository conventions, safety boundaries, excluded scope, and settled decisions.>
- Do not redesign or redo architecture; follow the specification strictly.
- No fallback models or alternate execution providers.

VERIFICATION
- Run: <exact command>
  Success: <concrete expected result and numeric exit code 0>
```

### C. Implementer Evidence Envelope (`implementer-evidence.json`)
Emitted by `run-antigravity-implementer` wrapper:
```json
{
  "schema_version": 1,
  "invocation": {
    "provider": "google-antigravity-cli",
    "cli_version_observed": "antigravity-cli 1.5.0",
    "model_requested": "gemini-3.8-flash-high",
    "model_catalog_exact_match_observed": true,
    "effort_requested": "high",
    "mode_requested": "accept-edits",
    "output_format_requested": "json",
    "cwd_observed": "/path/to/repo",
    "permission_mode_requested": "standard",
    "started_at_utc": "2026-08-26T12:00:00Z",
    "ended_at_utc": "2026-08-26T12:01:30Z",
    "duration_ms_observed": 90000,
    "exit_code_observed": 0
  },
  "runtime_observability": {
    "model_field_observed": true,
    "effort_field_observed": true,
    "mode_field_observed": true,
    "cwd_field_observed": true,
    "note": "Requested invocation pins and model-catalog preflight are configuration/process evidence."
  },
  "agy_result": {
    "status": "completed",
    "response": "STATUS: complete\nOBJECTIVE: ...\nCHANGES: ...\nVERIFIED: ...\nJUDGMENT CALLS: ...\nGAPS: ..."
  }
}
```

### D. Parent Verification Artifact (`parent-verification.json`)
Emitted by the parent verification stage:
```json
{
  "schema_version": 1,
  "iteration": 1,
  "verified_at_utc": "2026-08-26T12:02:00Z",
  "ownership_check": {
    "passed": true,
    "declared_owned_files": ["src/feature.py"],
    "window_modified_files": ["src/feature.py"],
    "unowned_modifications": []
  },
  "integrity_check": {
    "passed": true,
    "head_unchanged": true,
    "baseline_head_sha": "a1b2c3d4...",
    "current_head_sha": "a1b2c3d4...",
    "scoped_git_metadata_unchanged": true,
    "in_progress_git_operations": []
  },
  "implementer_evidence_assessment": {
    "passed": true,
    "implementer_status": "completed",
    "implementer_reported_tests_untrusted": true,
    "implementer_reported_test_summary": "Implementer reported tests (untrusted): ..."
  },
  "suggested_commands_unexecuted": ["pytest tests/test_feature.py"],
  "all_checks_passed": true,
  "bindings": {
    "task_sha256": "...",
    "plan_sha256": "...",
    "spec_sha256": "...",
    "implementer_evidence_sha256": "...",
    "pre_window_manifest_sha256": "...",
    "post_window_manifest_sha256": "...",
    "repository_manifest_sha256": "...",
    "aggregate_delta_manifest_sha256": "..."
  }
}
```

### E. Fresh Review Evidence Envelope (`review-evidence.json`)
Emitted by `run-fresh-reviewer` wrapper:
```json
{
  "schema_version": 1,
  "reviewer": {
    "model_requested": "gpt-5.6-sol",
    "effort_requested": "inherited",
    "sandbox_mode_requested": "read-only",
    "ephemeral": true,
    "exit_code_observed": 0,
    "repository_unchanged_verified": true
  },
  "review": {
    "verdict": "SHIP",
    "reason": "All verification checks passed and implementation adheres to declared interfaces.",
    "findings": "None",
    "residual_risk": "None",
    "reviewed_no_change": false
  },
  "reviewed_bindings": {
    "task_sha256": "...",
    "plan_sha256": "...",
    "spec_sha256": "...",
    "implementer_evidence_sha256": "...",
    "parent_verification_sha256": "...",
    "pre_window_manifest_sha256": "...",
    "post_window_manifest_sha256": "...",
    "repository_manifest_sha256": "...",
    "aggregate_delta_manifest_sha256": "..."
  }
}
```

## 3. Worker Implementation Report Contract

The final structured implementation report delivered to the user must contain truthful completion reporting, real commands, observed numeric exit codes, and all six non-empty fields:

```text
STATUS: complete | partial | blocked | reviewed_no_change
OBJECTIVE: <restatement of objective>
CHANGES: <file-by-file summary of changes made in this task>
VERIFIED: <exact verification commands run, exit codes, and output evidence>
JUDGMENT CALLS: <material decisions made or none>
GAPS: <remaining gaps or none>
```

Rules:
- `STATUS` must indicate successful completion (`complete` or `reviewed_no_change`). If aggregate task changes $\Delta_{task}$ is empty, `STATUS` is `reviewed_no_change` only if reviewer returned `reviewed_no_change: true`; otherwise publication is blocked.
- `CHANGES` reports only files modified during this task ($\Delta_{task}$), omitting pre-existing dirty files that were untouched.
- `VERIFIED` reports machine repository integrity and ownership verification, and clearly designates implementer-reported test runs as untrusted self-reports.

## 4. Scoped Git Metadata Integrity & Repository Manifest Guarantee

Scoped Git metadata integrity covers:
1. HEAD commit hash (`git rev-parse HEAD`).
2. Current HEAD ref / symbolic ref (`git symbolic-ref -q HEAD`).
3. Repository configuration (`.git/config`).
4. Packed refs (`.git/packed-refs`) and all ref files (`.git/refs/**`).
5. Hooks directory (`.git/hooks/**`).
6. Info attributes and exclude (`.git/info/exclude`, `.git/info/attributes`, `.git/info/grafts`).
7. Shallow / grafts / replace markers (`.git/shallow`, `.git/refs/replace/**`).
8. In-progress operation markers (`MERGE_HEAD`, `rebase-merge`, `rebase-apply`, `BISECT_LOG`, `CHERRY_PICK_HEAD`, `AUTO_MERGE`, `ORIG_HEAD`, `FETCH_HEAD`).
9. Git index file (`.git/index`) for read-only stages.

Objects database (`.git/objects/**`) and reflogs (`.git/logs/**`) are explicitly out of scope. Ignored files (`.gitignore`) are excluded from integrity scope; tracked and non-ignored files are strictly verified.

Repository manifests bracket read-only stages (planning, parent verification, review). The manifest is computed as a SHA-256 digest over:
1. HEAD commit hash.
2. Current HEAD ref.
3. Scoped Git metadata hash.
4. NUL-delimited porcelain status (`git status --porcelain=v1 -z`).
5. Staged binary diff (`git diff --cached --binary`).
6. Unstaged binary diff (`git diff --binary`).
7. Combined binary diff relative to HEAD (`git diff HEAD --binary`).
8. Sorted relative path, length, and streaming content SHA-256 hashes of all untracked files (`git ls-files --others --exclude-standard -z`).
9. Sorted relative path, length, and streaming content SHA-256 hashes of all modified tracked files.

## 5. Authorization and Permission Contract

- Default execution uses standard headless permissions.
- The Antigravity implementer always combines `--sandbox` with `--dangerously-skip-permissions` so Windows headless runs do not stop on non-interactive `escalate_admin` requests. This removes AGY's per-tool confirmation gate and must be disclosed as a residual risk; parent ownership and Git-integrity checks remain mandatory but do not contain command side effects outside the workspace.
- The dangerous flag applies only to the Antigravity implementation subprocess and is never persisted to global configuration.
- Controller, planner, and reviewer processes always run strictly in read-only sandbox mode.
