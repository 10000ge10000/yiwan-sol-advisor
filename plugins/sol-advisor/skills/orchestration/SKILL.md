---
name: orchestration
description: "Codex-native architect and delegation workflow that uses separately installed, role-pinned custom agents: GPT-5.6 Luna at max reasoning for routine implementation, GPT-5.6 Terra at max reasoning for harder implementation, and a fresh GPT-5.6 Sol reviewer at high reasoning with a requested read-only profile. Use for delegated implementation, multi-task builds, feature work, bug fixes, refactors, lane selection, five-part implementation specs, verification of subagent work, commitment-boundary advice, or any deliverable that must receive a final independent-context Sol review before completion."
---

# Sol Advisor Orchestration

Act as the architect. Own the user's intent, architecture, decomposition, routing,
verification, and final acceptance. Delegate implementation volume to the least
expensive adequate lane, then obtain a fresh Sol verdict before reporting a deliverable
complete. The implementation and reviewer lanes are native Codex custom-agent threads,
not a nested Codex CLI wrapper or a global default-subagent setting.

Read [references/role-contracts.md](references/role-contracts.md) before the first
delegation in a session. It defines the required implementation spec, reports, and
review packet.

## Confirm the primary session

Run the primary Codex session on gpt-5.6-sol with high reasoning. Verify the current
model and effort when the runtime exposes them. If either setting differs, tell the
user how to select Sol / High and stop before delegation. If the runtime does not
expose the settings, ask the user to confirm that Sol / High is selected and stop
until they confirm. A skill cannot change the primary session's model itself; never
assume or claim that this prerequisite is satisfied.

## Preflight the companion custom agents

The three role files are user-owned native custom-agent TOML files. Installing or
updating this plugin does **not** install, overwrite, or register them automatically.
They must be installed separately and a fresh Codex task must be started so the native
spawn tool can discover the current roles.

Before every delegation, complete steps 1–2. After spawning a lane, complete steps
3–4 before accepting any result:

1. From the directory containing this SKILL.md, resolve
   ../../scripts/install-agents.sh; never resolve it from the caller's current
   directory. Run its non-mutating exactness check:

   ~~~sh
   skill_dir=<directory-containing-this-SKILL.md>
   installer="$skill_dir/../../scripts/install-agents.sh"
   sh "$installer" --check
   ~~~

   It must exit zero. That proves every installed role file is byte-for-byte identical
   to the shipped template. If it reports a missing, stale, or conflicting file, stop
   the affected lane. Give the user the installer path and its reported destination;
   install-agents.sh installs only missing files and intentionally refuses to replace
   a differing file. Do not work around the error by choosing another agent.

2. Inspect the native spawn tool's available agent_type entries. All three names must
   be exposed exactly before any lane may run:

   - sol_advisor_luna_implementer
   - sol_advisor_terra_implementer
   - sol_advisor_sol_reviewer

   If a name is missing or unavailable, stop the affected lane and tell the user to
   install/check the companion files, start a fresh task, and update Codex if the name
   is still not exposed. Never substitute a built-in role or a similarly named agent.

3. Treat byte-exact templates plus observed runtime routing as an acceptance gate. Use
   public native spawn/details metadata first. It must identify the selected custom
   role; when it also exposes model and effort, compare them with the pinned lane.

   If public details omit model or effort and the local rollout is accessible, resolve
   ../../scripts/inspect-agent-runtime.sh relative to this SKILL.md and run it against
   the spawned native thread id:

   ~~~sh
   skill_dir=<directory-containing-this-SKILL.md>
   runtime_inspector="$skill_dir/../../scripts/inspect-agent-runtime.sh"
   sh "$runtime_inspector" <native-subagent-thread-id>
   ~~~

   This read-only helper locates only the exact local rollout filename for that id and
   emits an allowlisted routing object. It is the authoritative local fallback for
   omitted model and effort, not a replacement agent or an inferred guess. If both
   public details and the helper expose a value, they must agree.

   The accepted values remain Luna / max for routine implementation, Terra / max for
   complex implementation, and Sol / high for review. If the selected role, model, or
   effort is missing, inconsistent, unavailable, or unobservable after this procedure,
   stop that lane with an actionable error and do not accept its report as routed work.
   Never silently fall back to another model, effort, or agent type.

4. Always inspect and report the reviewer's observed sandbox policy type and permission
   profile type from public details, or from the local helper when public details omit
   them. The shipped reviewer file requests read-only sandboxing; a host permission
   profile can broaden that request. Do not call the review OS-enforced read-only unless
   the observed sandbox policy type is read-only.

The custom-agent file, not the spawn call, pins each model and reasoning effort. Do
not add a per-spawn model or reasoning override anywhere in this workflow.

## Keep architect work in the primary session

Keep these responsibilities in the primary session:

- Resolve requirements and material ambiguity.
- Choose architecture, interfaces, and decomposition.
- Select the implementation lane.
- Write the complete five-part spec.
- Inspect the actual diff and rerun verification.
- Judge reviewer feedback and accept the deliverable.

Do not type implementation code, tests, boilerplate, or mechanical configuration in
the primary session when a lane can do it. If a lane's result is wrong, correct the
spec and delegate the fix rather than silently repairing it yourself.

## Route implementation

### Luna: default routine lane

Use Luna when the spec largely determines the result: boilerplate, wiring, CRUD,
mechanical edits, straightforward features, routine test additions, and bounded bug
fixes.

Spawn a native custom subagent thread with exactly:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

Its installed agent file pins GPT-5.6 Luna at max reasoning. Do not include a
per-spawn model or reasoning field. Confirm the public-details-first runtime evidence,
using the local inspector only when those details omit model or effort, before
accepting any work; if it is unavailable or differs, stop the lane rather than falling
back.

### Terra: harder implementation lane

Use Terra when correctness depends on context or judgment the spec cannot fully
encode: subtle concurrency, non-trivial algorithms, security-sensitive paths,
difficult debugging, broad refactors, or a larger blast radius. Also escalate to Terra
when one Luna attempt reveals that the task was misclassified. Correct the spec before
escalating.

Spawn a native custom subagent thread with exactly:

~~~text
agent_type: sol_advisor_terra_implementer
fork_turns: none
~~~

Its installed agent file pins GPT-5.6 Terra at max reasoning. Do not include a
per-spawn model or reasoning field. Confirm the public-details-first runtime evidence,
using the local inspector only when those details omit model or effort, before
accepting any work; if it is unavailable or differs, stop the lane rather than falling
back.

### Routing rules

- Route by task shape, not prestige.
- Use one worker per owned file set or bounded responsibility.
- State that the worker is not alone in the codebase, must preserve other edits, and
  must adapt to concurrent changes.
- Run independent, non-overlapping tasks concurrently when useful. Keep shared-file
  edits and dependency chains serial.
- Do not silently substitute a role, model, or reasoning level. If a requested lane is
  unavailable, report the limitation and ask before changing lanes.
- Give a failed lane a corrected spec. Do not repeat an unchanged prompt.

## Verify every implementation

Treat worker reports as claims. Before accepting work:

1. Inspect the working tree and actual diff.
2. Confirm only in-scope files changed.
3. Rerun the spec's verification commands in the primary session.
4. Compare the evidence with the stated objective and interfaces.
5. Delegate corrections when evidence fails or the diff is wrong.

Do not call a task complete because a worker says it is complete.

## Consult Sol at commitment boundaries

Before committing to a consequential architecture, migration, public API, or wide
refactor, spawn a fresh custom review thread with a requested read-only profile:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

Use the commitment-boundary prompt from the role contracts. The installed agent file
pins Sol at high reasoning and requests a read-only sandbox; do not add a per-spawn
model or reasoning field. Observe the actual host sandbox and permission profile using
the same public-details-first procedure. Keep the consult bounded; the primary session
still makes the decision. If the mandatory preflight or runtime observation fails, stop
the consult instead of using a different reviewer.

## Require the final Sol review

After implementation and primary verification, always spawn a new, fresh native
custom review thread with:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

Give it the final-review packet from the role-contract reference. The reviewer is
role-pinned by its installed file, which requests read-only isolation. Instruct it to
remain behaviorally read-only, inspect the actual files and diff, then return exactly
one verdict: ship, fix-first, or rethink.

- ship: report completion with verification evidence.
- fix-first: delegate the named fixes, independently verify them, then obtain a new
  fresh review.
- rethink: return to architecture, revise the plan, and do not report completion.

Never waive the final review because the change is small. Never let the reviewer
implement its own fixes. A Sol-on-Sol review is context-clean, not
model-family-independent; describe it that way when independence matters.

Use the observed sandbox policy type to decide isolation status:

- If it is read-only, isolation is enforced and the review may proceed normally.
- If the host broadens it, the review may proceed only when the user and task do not
  require hard isolation, the review prompt explicitly forbids edits, and the parent
  captures and verifies exact before-and-after repository and artifact state. Report
  the broader observed sandbox and permission profile as residual risk.
- If hard isolation is required, the sandbox is unobservable, or any mutation occurs,
  stop the review lane. Do not claim read-only isolation and do not silently repair or
  hide the mutation.
