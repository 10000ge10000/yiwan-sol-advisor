---
name: orchestration
description: "Codex-native architect and delegation workflow with default GPT-5.6 Luna / Max routine implementation, explicit GPT-5.6 Terra / High escalation, and a fresh GPT-5.6 Sol / High final review."
---

# Sol Advisor Orchestration

Act as the architect. Own the user's intent, architecture, decomposition, complete
task specification, parent verification, and final acceptance. The normal native
path is Sol / High planning, Luna / Max routine implementation, parent verification,
and a fresh Sol / High review. Explicitly escalate judgment-heavy or high-risk work,
or work that one corrected Luna attempt shows was misclassified as routine, to Terra
/ High. All three workers are native Codex custom agents; this skill has one native
workflow and no secondary implementation mechanism.

Read [references/role-contracts.md](references/role-contracts.md) before the first
delegation in a session.

## Confirm the primary session

Run the primary Codex session on gpt-5.6-sol with high reasoning. Verify the current
model and effort when runtime metadata exposes them. If either differs, tell the user
to select Sol / High and stop before delegation. If runtime metadata does not expose
them, ask the user to confirm Sol / High and stop until confirmed. A skill cannot
change the primary model itself; never assume or claim this prerequisite is satisfied.

## Choose the native implementation lane

Luna / Max is the default routine implementation lane. Route bounded, well-specified
work through the exact native role:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

The installed role pins GPT-5.6 Luna at max reasoning. Omit per-spawn model and
reasoning fields. If a corrected Luna attempt reveals that the work is judgment-heavy,
high-risk, or otherwise misclassified as routine, route the corrected specification
to the exact escalation role:

~~~text
agent_type: sol_advisor_terra_implementer
fork_turns: none
~~~

The installed role pins GPT-5.6 Terra at high reasoning. Terra is also the explicit
choice for judgment-heavy, high-risk, context-heavy, or wide-blast-radius work from
the outset. There is no silent model, effort, role, or native-lane fallback.

## Preflight the native companion custom agents

The three role files are user-owned native custom-agent TOML files. Installing or
updating the plugin does not automatically register them. Install or update them
separately, then start a fresh Codex task so native discovery sees the current
profiles.

Before every native delegation, complete steps 1-2. After spawning a native lane,
complete steps 3-4 before accepting its result:

1. Resolve `../../scripts/install-agents.sh` relative to this SKILL.md and run its
   non-mutating exactness check:

   ~~~sh
   skill_dir=<directory-containing-this-SKILL.md>
   installer="$skill_dir/../../scripts/install-agents.sh"
   sh "$installer" --check
   ~~~

   It must exit zero. This proves Luna, Terra, and Sol match the shipped templates
   exactly. If the check reports a missing, stale, unsafe, or conflicting file, stop
   the affected lane. Give the user the installer path and reported destination.
   Never work around failure with another agent, model, or effort.

2. Inspect the native spawn tool's available `agent_type` entries. All exact names
   must be exposed:

   - `sol_advisor_luna_implementer`
   - `sol_advisor_terra_implementer`
   - `sol_advisor_sol_reviewer`

   If a name is missing, tell the user to install/check the companion files, start a
   fresh task, and update Codex if the name remains unavailable. Do not substitute a
   built-in or similarly named role.

3. Treat exact templates plus observed runtime routing as an acceptance gate. Inspect
   public native spawn/details metadata first. It must identify the selected custom
   role. When it exposes model or effort, compare them with the role pin.

   If public details omit model or effort and the local rollout is accessible, resolve
   `../../scripts/inspect-agent-runtime.sh` relative to this SKILL.md and run:

   ~~~sh
   skill_dir=<directory-containing-this-SKILL.md>
   runtime_inspector="$skill_dir/../../scripts/inspect-agent-runtime.sh"
   sh "$runtime_inspector" <native-subagent-thread-id>
   ~~~

   The helper's allowlisted output is the authoritative local fallback for omitted
   model and effort. If public and local values both exist, they must agree. Accepted
   values are Luna / max for routine work, Terra / high for escalation, and Sol / high
   for review. Missing, inconsistent, unavailable, or unobservable routing stops that
   lane.

4. For every Sol review, capture the observed sandbox policy type and permission
   profile type. The shipped reviewer requests read-only sandboxing, but the host may
   broaden it. Never call the review OS-enforced read-only unless the observed sandbox
   policy type is `read-only`.

The custom-agent TOML, not the spawn call, pins model and effort. Never add per-spawn
model or reasoning overrides.

## Keep architect work in the primary session

Keep these responsibilities in the primary session:

- Resolve requirements and material ambiguity.
- Choose architecture, interfaces, and decomposition.
- Write the complete five-part implementation specification.
- Inspect the actual diff and rerun verification.
- Judge worker findings and reviewer feedback, decide escalation, and accept the deliverable.

Do not type implementation code, tests, boilerplate, or mechanical configuration in
the primary session when the selected delegated lane can do it. If the Luna result is
wrong, correct the specification and delegate one bounded correction to Luna. If that
corrected attempt exposes a lane misclassification, escalate the work to Terra / High
with a corrected specification. Do not silently repair a failed child patch or hide an
unresolved correction.

## Route implementation through native roles

Give each worker one owned file set or bounded responsibility. State that it is not
alone in the codebase, must preserve other edits, and must adapt to concurrent
changes. Run independent non-overlapping work concurrently only when useful. Keep
shared-file edits and dependency chains serial.

Every implementation prompt must contain the five sections in
[the role contracts](references/role-contracts.md): OBJECTIVE, FILES AND OWNERSHIP,
INTERFACES, CONSTRAINTS, and VERIFICATION, followed by the structured return. Give a
failed lane a corrected specification; never repeat an unchanged prompt.

## Verify every implementation

Treat worker reports as claims. Before acceptance:

1. Inspect the working tree and complete diff.
2. Confirm only in-scope files changed.
3. Rerun the specification's verification commands in the primary session.
4. Compare the evidence with the objective, interfaces, and constraints.
5. Delegate corrections through the same appropriate native role and repeat parent
   verification. Escalate only under the explicit Terra rule above.

## Require the final Sol review

After native implementation and parent verification, always spawn a new, fresh
reviewer:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

The role pins Sol / High and requests a read-only sandbox. Omit per-spawn model and
reasoning fields. Instruct the reviewer to remain behaviorally read-only, inspect the
actual files and accumulated diff, and return exactly `ship`, `fix-first`, or
`rethink`.

- `ship`: report completion with verification evidence.
- `fix-first`: delegate the required fixes, verify again, and obtain a new review.
- `rethink`: revise architecture and do not report completion.

Never let the reviewer implement its own fixes. A fix invalidates the prior verdict;
run a new fresh review after the corrected implementation.

Apply the observed isolation, not requested isolation:

- If it is `read-only`, isolation is enforced.
- If the host broadens it, proceed only when hard isolation is not required, the
  prompt forbids edits, and the parent captures and verifies exact before-and-after
  repository and artifact state. Report the observed sandbox and permission profile.
- If hard isolation is required, the sandbox is unobservable, or any mutation occurs,
  stop the review and do not claim read-only isolation or hide the mutation.

Use the complete native packet and return schema in
[references/role-contracts.md](references/role-contracts.md).
