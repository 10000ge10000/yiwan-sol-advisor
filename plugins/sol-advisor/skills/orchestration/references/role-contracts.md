# Native Codex role contracts

Use these contracts with Sol Advisor's namespaced, role-pinned native custom agents.
They do not launch a nested Codex CLI or change global default-agent routing. Adapt
every placeholder without removing a required field.

For task-scoped preflight, runtime evidence, sandbox interpretation, and maintainer
commands, use [operations.md](operations.md).

## Required preflight

At the start of each task, confirm Sol / High, then choose the starting path. For the
normal routine path, run the selective Luna+Sol companion check from operations.md;
preflight Luna and the fresh Sol reviewer once and cache those results for this task.
For known complexity or high-risk work, run the selective Terra+Sol check instead.
Do not require Luna exposure or a Luna companion check, and cache Terra plus Sol. If a
first Luna result reveals complexity or risk, run the selective Terra check and reuse the task-cached Sol result.
After spawning, complete the selected role's routing and
reviewer isolation checks before accepting the result; do not repeat successful checks
before every delegation:

1. Require the selected exact native role and fresh-context spawn contract.
2. Observe the selected role, model, and effort through public spawn/details metadata
   first, using the local runtime inspector only for omitted fields. Accept Luna /
   Max for routine implementation, Terra / High for explicit escalation, and Sol /
   High for review.
3. For the reviewer, capture actual sandbox policy and permission profile types.

A missing, stale, unsafe, conflicting, unavailable, inconsistent, or unobservable
role/model/effort stops the native lane. Never silently fall back. Model and effort
are pinned by custom-agent TOML, so omit native per-spawn overrides.

## Shared implementation contract

Every Luna or Terra prompt must contain all five sections:

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
Return exact commands and actual evidence. A completion claim without evidence is invalid.

IMPLEMENTATION REPORT
STATUS: complete | partial | blocked
OBJECTIVE: <one-line restatement>
CHANGES: <file-by-file summary from the actual diff>
VERIFIED: <exact commands plus concrete output evidence>
JUDGMENT CALLS: <decisions the specification left open, or none>
GAPS: <unfinished work, ambiguity, or none>
~~~

The primary session must inspect the diff and rerun verification itself.

## Luna / Max - default routine native implementation lane

Use this lane for bounded, fully specified routine work. The installed role pins
GPT-5.6 Luna at max reasoning. It must surface ambiguity and failed checks rather
than redesigning the architecture. A first result that demonstrates judgment-heavy,
high-risk, wide-blast-radius, or misclassified work may go straight to Terra / High;
do not force a retry first. If the specification itself was incomplete or wrong,
return a precise correction for one corrected Luna attempt. That retry is not a
prerequisite for Terra escalation.

Spawn exactly:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

Do not attach per-spawn model or reasoning fields. Prompt:

~~~text
ROLE
Act as Sol Advisor's default routine implementation worker. Execute the supplied
specification within the settled architecture, preserve every stated interface and
constraint, and surface ambiguity instead of redesigning the architecture.

<paste and complete the Shared implementation contract>
~~~

## Terra / High - explicit high-complexity escalation lane

Use this lane for judgment-heavy, high-risk, context-heavy, or wide-blast-radius work
identified before delegation, and for complexity or risk revealed by a first Luna
result. The installed role pins GPT-5.6 Terra at high reasoning. A corrected Luna
attempt is reserved for a specification error and is not a prerequisite for Terra.

Spawn exactly:

~~~text
agent_type: sol_advisor_terra_implementer
fork_turns: none
~~~

Do not attach per-spawn model or reasoning fields. Prompt:

~~~text
ROLE
Act as Sol Advisor's explicit high-complexity escalation worker. Resolve the supplied
specification within the settled architecture, preserve every stated interface and
constraint, and surface ambiguity instead of redesigning the architecture.

<paste and complete the Shared implementation contract>
~~~

## Fresh Sol / High - requested-read-only final reviewer

After parent verification, spawn a new native thread exactly:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

The installed role pins Sol / High and requests a read-only sandbox. Do not attach
per-spawn model or reasoning fields. Observe the actual role, pin, sandbox policy, and
permission profile before accepting its verdict.

Prompt:

~~~text
ROLE
Act as the fresh final reviewer. Remain strictly read-only: do not edit files, implement
fixes, or broaden scope.

STATED GOAL
<The user's requested outcome.>

ACCUMULATED CHANGE SET
<Exact allowed files plus complete working-tree diff, or explicit base/head revisions.>

INTERFACES AND CONSTRAINTS
- <Compatibility, repository rules, safety boundaries, and excluded scope.>

VERIFICATION EVIDENCE
- <command> -> <actual primary-session output evidence>
- <artifact or diff inspection> -> <actual evidence>

REVIEW
Inspect the actual files and accumulated change set. Judge correctness, completeness,
regressions, scope discipline, interface preservation, test adequacy, and material risk.

SOL REVIEW
VERDICT: ship | fix-first | rethink
REASON: <decisive evidence-based reason>
FINDINGS: <precise file references and required fixes, or none>
RESIDUAL RISK: <most important remaining risk, or none>
~~~

If any fix is made after review, discard the verdict and run a new fresh review.
Sol reviewing Sol is context-clean, not cross-model-family independence.

Use observed isolation, not requested isolation:

- With observed `read-only`, proceed with enforced isolation.
- If the host broadens it, proceed only when hard isolation is not required, the
  prompt forbids edits, and the parent captures and verifies exact before-and-after
  repository and artifact state. Report the broader policy and profile.
- If isolation is unobservable, hard isolation is required, or any mutation occurs,
  stop the lane and do not hide or repair the mutation under that verdict.

## Commitment-boundary Sol consult

For a consequential architecture, migration, public API, or wide refactor, the
primary may spawn the same fresh Sol role with `fork_turns: none`. Give it the
proposed decision, goal, constraints, relevant paths, alternatives, and the one
question that changes the plan. Require `proceed`, `change`, or `stop`, plus the
decisive reason and largest risk. Apply the same preflight, runtime-observation,
sandbox-reporting, and no-fallback rules.
