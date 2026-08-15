# Native operations

This is the maintainer and operator reference for Sol Advisor's native custom-agent
workflow. Keep the README user-facing; use this page when installing, delegating,
inspecting routing, or validating a release.

## Role pins and spawn contract

The installed TOMLs are the source of truth:

| Role type | Model | Effort | Use |
|---|---|---|---|
| sol_advisor_luna_implementer | gpt-5.6-luna | max | Default bounded routine implementation |
| sol_advisor_terra_implementer | gpt-5.6-terra | high | Explicit judgment-heavy/high-risk escalation |
| sol_advisor_sol_reviewer | gpt-5.6-sol | high | Fresh final review; requests read-only sandbox |

Native spawn requests name the role and use a fresh context:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

Use the Terra type only when escalation is selected:

~~~text
agent_type: sol_advisor_terra_implementer
fork_turns: none
~~~

Always use a fresh Sol reviewer after parent verification:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

Do not attach model or reasoning overrides. A missing, conflicting, unavailable, or
unobservable role/model/effort is a hard stop; never substitute another role.

## Task-scoped preflight and caching

The primary session must be Sol / High. Companion installation is separate from task
routing because plugin installation does not register user-owned TOMLs.

At installation or update time, run the repository-relative installer and its exactness
check:

~~~sh
sh plugins/sol-advisor/scripts/install-agents.sh
sh plugins/sol-advisor/scripts/install-agents.sh --check
~~~

When operating from an installed skill, resolve the same script relative to this
reference's parent skill:

~~~sh
skill_dir=<directory-containing-this-SKILL.md>
installer="$skill_dir/../../scripts/install-agents.sh"
sh "$installer" --check
~~~

The installer is fail-closed and performs its own post-install exactness check. It
recognizes only byte-exact historical templates, including the shipped v0.2.0 profiles
and the v0.5.0 Luna/Terra profiles during a v0.5.1 update. Modified/unsafe/nonregular/
symlinked/conflicting destinations remain refusals, and all mutations are preflighted.

The existing --check flag verifies all three roles. For task-scoped preflight, choose
the starting path and use the repeatable selective form; each check is non-mutating
and fail-closed.

For the normal routine path, check Luna+Sol:

~~~sh
sh plugins/sol-advisor/scripts/install-agents.sh --check --check-role luna --check-role sol
~~~

For known complexity or high-risk work selected up front, check Terra+Sol instead;
Luna does not block this path:

~~~sh
sh plugins/sol-advisor/scripts/install-agents.sh --check --check-role terra --check-role sol
~~~

When Terra escalation follows a Luna result, check Terra separately and reuse the successful Sol result cached for the task:

~~~sh
sh plugins/sol-advisor/scripts/install-agents.sh --check --check-role terra
~~~

Unknown or missing role arguments fail before any destination mutation. A selective
check ignores unselected role destinations, so a conflicting Terra file cannot block
normal Luna / Sol preflight and a conflicting Luna file cannot block up-front Terra /
Sol preflight; the all-role --check behavior remains unchanged.

For each task, cache native preflight results for that task only:

1. Confirm the primary Sol / High session.
2. Before normal routine delegation, run the selective Luna / Sol check above, then
   confirm native exposure of Luna and the fresh Sol reviewer. Compare public
   role/model/effort metadata when it is available.
3. Do not require Terra exposure for the normal path. If the first Luna result clearly
   demonstrates judgment-heavy, high-risk, or misclassified work, select Terra and then
   run the selective Terra check and confirm Terra exposure and its public pin before
   spawning it.
4. If the specification was incomplete or wrong, send one corrected Luna
   specification. A corrected attempt is not a mandatory toll before Terra; an
   immediate Terra escalation remains valid when the result itself demonstrates
   complexity or risk.
5. Do not repeat successful role preflight before every delegation in the same task.
   Never carry a cached result into a later task, after an installation/update, or
   after a routing/configuration change.

If public metadata omits model or effort, use the local inspector below as a fallback
for those omitted fields only. Do not use it to replace available public evidence.

## Runtime routing evidence

The public spawn/details record is authoritative for the selected role and any exposed
model/effort. When model or effort is omitted, resolve the helper relative to the
installed skill and inspect the exact native thread ID:

~~~sh
skill_dir=<directory-containing-this-SKILL.md>
runtime_inspector="$skill_dir/../../scripts/inspect-agent-runtime.sh"
sh "$runtime_inspector" <native-subagent-thread-id>
~~~

For a disposable fixture or non-default session root:

~~~sh
sh "$runtime_inspector" --sessions-dir /absolute/path/to/sessions <native-subagent-thread-id>
~~~

The helper searches one exact rollout filename suffix and emits only allowlisted
routing fields. It refuses invalid IDs, zero/multiple matches, missing fields, or
conflicting model/effort/sandbox/permission/working-directory values. It never prints
prompts, messages, environment variables, tokens, configuration, or arbitrary rollout
payloads.

Accepted routing is Luna / max for routine work, Terra / high for escalation, and Sol /
high for review. If public and local evidence both exist, they must agree. The local
inspector is not a model-selection fallback.

## Read-only reviewer interpretation

The reviewer TOML requests sandbox_mode = read-only. Capture the observed sandbox
policy type and permission profile type from public metadata or the inspector:

- Observed read-only sandbox: isolation is enforced.
- Broader host policy: continue only when hard isolation is not required, the prompt
  forbids edits, and the parent captures exact before/after repository and artifact
  state. Report the broader policy and profile as residual risk.
- Unobservable isolation, required hard isolation, or any mutation: stop the review and
  do not claim read-only isolation.

A reviewer returns exactly ship, fix-first, or rethink. A fix invalidates the prior
verdict; parent verification and a new fresh review are required.

## Worker packet and parent acceptance

Every Luna or Terra prompt uses the five-part packet in role-contracts.md:

- OBJECTIVE
- FILES AND OWNERSHIP
- INTERFACES
- CONSTRAINTS
- VERIFICATION

It must also request the structured implementation report. The parent owns architecture,
complete diff inspection, verification reruns, correction/escalation decisions, and
acceptance. Worker claims never replace direct inspection.

For routine work, the primary verifies the Luna result and then requests the fresh Sol
review. For explicit Terra escalation, the primary verifies the Terra result and then
requests the same fresh Sol review. A reviewer never fixes its own findings.

## Maintainer verification

From the repository root, run:

~~~sh
sh plugins/sol-advisor/scripts/verify.sh
git diff --check
git status --short
git diff --stat
~~~

The verifier covers the v0.5.1 manifest, exact three-role TOMLs, native routing
contracts, concise README journey, absence of retired workflow references, installer
safety fixtures, Luna runtime evidence, JSON/TOML validity, and shell syntax.
