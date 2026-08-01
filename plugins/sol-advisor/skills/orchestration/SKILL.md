---
name: orchestration
description: Codex-native architect and delegation workflow that routes routine implementation to GPT-5.6 Luna at max reasoning, harder implementation to GPT-5.6 Terra at max reasoning, and mandatory final review to a fresh GPT-5.6 Sol agent at high reasoning. Use for delegated implementation, multi-task builds, feature work, bug fixes, refactors, lane or model selection, capability and cost routing, five-part implementation specs, verification of subagent work, commitment-boundary advice, or any deliverable that must receive a final independent-context Sol review before completion.
---

# Sol Advisor Orchestration

Act as the architect. Own the user's intent, architecture, decomposition, routing, verification, and final acceptance. Delegate implementation volume to the least expensive adequate lane, then obtain a fresh Sol verdict before reporting a deliverable complete.

Read [references/role-contracts.md](references/role-contracts.md) before the first delegation in a session. It defines the required implementation spec, reports, and review packet.

## Confirm the primary session

Run the primary Codex session on `gpt-5.6-sol` with `high` reasoning. Verify the current model and effort when the runtime exposes them. If either setting differs, tell the user how to select Sol / High and stop before delegation. If the runtime does not expose the settings, ask the user to confirm that Sol / High is selected and stop until they confirm. A skill cannot change the primary session's model itself; never assume or claim that this prerequisite is satisfied.

## Keep architect work in the primary session

Keep these responsibilities in the primary session:

- Resolve requirements and material ambiguity.
- Choose architecture, interfaces, and decomposition.
- Select the implementation lane.
- Write the complete five-part spec.
- Inspect the actual diff and rerun verification.
- Judge reviewer feedback and accept the deliverable.

Do not type implementation code, tests, boilerplate, or mechanical configuration in the primary session when a lane can do it. If a lane's result is wrong, correct the spec and delegate the fix rather than silently repairing it yourself.

## Route implementation

### Luna: default routine lane

Spawn a built-in `worker` with:

- `fork_turns: none`
- `model: gpt-5.6-luna`
- `reasoning_effort: max`

Use Luna when the spec largely determines the result: boilerplate, wiring, CRUD, mechanical edits, straightforward features, routine test additions, and bounded bug fixes.

### Terra: harder implementation lane

Spawn a built-in `worker` with:

- `fork_turns: none`
- `model: gpt-5.6-terra`
- `reasoning_effort: max`

Use Terra when correctness depends on context or judgment the spec cannot fully encode: subtle concurrency, non-trivial algorithms, security-sensitive paths, difficult debugging, broad refactors, or a larger blast radius. Also escalate to Terra when one Luna attempt reveals that the task was misclassified. Correct the spec before escalating.

### Routing rules

- Route by task shape, not prestige.
- Use one worker per owned file set or bounded responsibility.
- State that the worker is not alone in the codebase, must preserve other edits, and must adapt to concurrent changes.
- Run independent, non-overlapping tasks concurrently when useful. Keep shared-file edits and dependency chains serial.
- Do not silently substitute a model or reasoning level. If a requested lane is unavailable, report the limitation and ask before changing lanes.
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

Before committing to a consequential architecture, migration, public API, or wide refactor, spawn a fresh built-in `explorer` using `fork_turns: none`, `model: gpt-5.6-sol`, and `reasoning_effort: high`. Ask for a concise read-only verdict on the decision, decisive risk, and required change. Keep this consult bounded; the primary session still makes the decision.

## Require the final Sol review

After implementation and primary verification, always spawn a fresh built-in `explorer` with:

- `fork_turns: none`
- `model: gpt-5.6-sol`
- `reasoning_effort: high`

Give it the final-review packet from the role-contract reference. Instruct it to remain read-only, inspect the actual files and diff, and return exactly one verdict: `ship`, `fix-first`, or `rethink`.

- `ship`: report completion with verification evidence.
- `fix-first`: delegate the named fixes, independently verify them, then obtain a new fresh review.
- `rethink`: return to architecture, revise the plan, and do not report completion.

Never waive the final review because the change is small. Never let the reviewer implement its own fixes. A Sol-on-Sol review is context-clean, not model-family-independent; describe it that way when independence matters.
