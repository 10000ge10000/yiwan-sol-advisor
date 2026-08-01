# Native Codex role contracts

Use these contracts with Sol Advisor's namespaced, role-pinned native custom agents.
They are not nested Codex CLI wrappers and they do not change global default-subagent
routing. Load only the contract needed for the next spawn. Adapt every placeholder;
do not remove a required field.

## Required custom-agent preflight

Before every spawn, complete steps 1–2 of the preflight in SKILL.md; complete steps
3–4 after spawn and before accepting the lane's result:

1. Resolve ../../scripts/install-agents.sh relative to SKILL.md and require its
   non-mutating --check to confirm all installed role files exactly match the shipped
   templates.
2. Require the native spawn tool to expose all three named custom agent types.
3. After spawn, inspect public native spawn/details metadata first. If it omits model
   or effort and the local rollout is accessible, resolve
   ../../scripts/inspect-agent-runtime.sh relative to SKILL.md and run it with the
   native subagent thread id. Its allowlisted JSON is the authoritative local fallback
   for omitted model and effort. Public and local values must agree when both exist.
4. Require exact role, model, and reasoning-effort observation before accepting the
   selected lane. Always inspect and report the Sol reviewer's observed sandbox policy
   type and permission profile type; the shipped TOML requests read-only but a host may
   broaden it.

A missing, stale, conflicting, unavailable, inconsistent, or unobservable
role/model/effort stops the affected lane. Report the actionable installer, local
runtime-inspection, or fresh-task step; never silently fall back to a built-in role,
another model, another effort, or a differently named agent. The custom-agent TOML
pins the role's model and effort, so omit all per-spawn model and reasoning overrides.

## Shared implementation contract

Every Luna or Terra prompt must contain all five sections below. Give each worker a
non-overlapping file set or bounded responsibility. Independent, non-overlapping work
may run in parallel; shared files and dependency chains must run serially.

~~~text
OBJECTIVE
<Observable outcome and why it matters.>

FILES AND OWNERSHIP
You own only:
- <exact file or module>

You are not alone in the codebase. Other agents or the user may be editing concurrently.
Preserve their edits, do not revert unrelated work, and adapt to changes already present.
Do not modify files outside your ownership.

INTERFACES
- <Signatures, types, schemas, commands, or behavior that must remain compatible.>

CONSTRAINTS
- <Repository conventions, safety boundaries, excluded scope, and settled decisions.>

VERIFICATION
- Run: <exact command>
  Success: <concrete expected result>
- Inspect: <exact file, diff, or generated artifact>
  Success: <concrete expected evidence>

RETURN
Return the report below. Include exact commands and actual output evidence; a completion
claim without evidence is invalid.

IMPLEMENTATION REPORT
STATUS: complete | partial | blocked
OBJECTIVE: <one-line restatement>
CHANGES: <file-by-file summary from the actual diff>
VERIFIED: <exact commands plus concrete output evidence>
JUDGMENT CALLS: <decisions the spec left open, or none>
GAPS: <unfinished work, ambiguity, or none>
~~~

The primary session must inspect the actual diff and rerun verification. The report is
not evidence by itself.

## Luna — routine implementer

Spawn a native custom subagent thread with exactly:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

The installed sol_advisor_luna_implementer file pins GPT-5.6 Luna at max reasoning.
Do not attach a per-spawn model or reasoning field. Require public-details-first
runtime observation of that role and pin, using the local inspector only if public
details omit model or effort, before accepting its report.

Prompt:

~~~text
ROLE
Act as the routine implementation worker. Execute the supplied specification exactly;
surface ambiguity instead of redesigning the architecture.

<paste and complete the Shared implementation contract>
~~~

If the exact template preflight, native type exposure, or runtime pin observation
fails, stop and report the limitation. Never silently fall back to another model or
reasoning level.

## Terra — complex implementer

Spawn a native custom subagent thread with exactly:

~~~text
agent_type: sol_advisor_terra_implementer
fork_turns: none
~~~

The installed sol_advisor_terra_implementer file pins GPT-5.6 Terra at max reasoning.
Do not attach a per-spawn model or reasoning field. Require public-details-first
runtime observation of that role and pin, using the local inspector only if public
details omit model or effort, before accepting its report.

Prompt:

~~~text
ROLE
Act as the complex implementation worker. Resolve the difficult implementation details
within the settled architecture, document material judgment calls, and preserve every
stated interface and constraint.

<paste and complete the Shared implementation contract>
~~~

If the exact template preflight, native type exposure, or runtime pin observation
fails, stop and report the limitation. Never silently fall back to another model or
reasoning level.

## Fresh Sol — requested-read-only final reviewer

Spawn a new native custom review thread after implementation and primary-session
verification, with exactly:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

The installed sol_advisor_sol_reviewer file pins GPT-5.6 Sol at high reasoning and
requests a read-only sandbox. Do not attach a per-spawn model or reasoning field.
Require public-details-first observation of the Sol/high pin, using the local inspector
only if public details omit model or effort. Also capture the observed sandbox policy
type and permission profile type; the requested profile does not prove host-enforced
read-only isolation.

Prompt:

~~~text
ROLE
Act as the fresh final reviewer. Remain strictly read-only: do not edit files, implement
fixes, or broaden scope.

STATED GOAL
<The user's requested outcome.>

ACCUMULATED CHANGE SET
<Exact allowed files plus the complete working-tree diff, or explicit base/head revisions.>

INTERFACES AND CONSTRAINTS
- <Required compatibility, repository rules, safety boundaries, and excluded scope.>

VERIFICATION EVIDENCE
- <command> -> <actual primary-session output evidence>
- <Relevant artifact or diff inspection> -> <actual evidence>

REVIEW
Inspect the actual files and accumulated change set. Judge correctness, completeness,
regressions, scope discipline, interface preservation, test adequacy, and material risk.
Return exactly one allowed verdict: ship, fix-first, or rethink.

SOL REVIEW
VERDICT: ship | fix-first | rethink
REASON: <decisive evidence-based reason>
FINDINGS: <precise file references and required fixes, or none>
RESIDUAL RISK: <most important remaining risk, or none>
~~~

Use ship only when the stated goal is met by the inspected change set and evidence.
Use fix-first for bounded required corrections. Use rethink when architecture or scope
must change. If any fix is made after review, discard that verdict and run a new,
fresh reviewer under the same observed-sandbox policy with a newly accumulated change
set and verification evidence.

If the exact template preflight, native type exposure, or required role/model/effort
observation fails, stop and report the limitation. Never silently fall back to another
model or reasoning level. Sol reviewing Sol is context-clean, but it is not
cross-model-family independence.

Apply the observed sandbox policy, not the requested TOML value, to review acceptance:

- If the observed sandbox policy type is read-only, proceed with enforced isolation.
- If the host broadens it, proceed only when hard isolation is not required, this prompt
  forbids edits, and the parent captures and verifies exact before-and-after repository
  and artifact state. Include the broader sandbox and permission profile as residual
  risk in the review packet and final report.
- If hard isolation is required, the sandbox cannot be observed, or any mutation
  occurs, stop the lane. Do not claim enforced read-only isolation.

## Commitment-boundary Sol consult

For a pre-implementation consult, use a fresh native custom review thread with a
requested read-only profile, exactly:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

Give it the proposed decision, stated goal, constraints, relevant paths, alternatives,
and the one question whose answer changes the plan. Require proceed, change, or stop,
followed by the decisive reason and largest risk. Apply the same exact-template,
native-exposure, public-details-first runtime-observation, sandbox-reporting, and
no-fallback rules as final review.
