# Sol Advisor

**Sol runs the show. Normal delivery is Sol / High plans → native Luna / Max
implements routine work → the parent verifies → a fresh Sol / High reviews. Terra /
High is the explicit escalation lane for judgment-heavy or high-risk work, or after
one corrected Luna attempt shows that routine routing was a misclassification.**

Sol Advisor is a Codex-only architect workflow for capability-routed software
delivery. The primary Sol session owns requirements, architecture, specifications,
verification, escalation decisions, and acceptance; native custom agents handle the
bounded implementation work.

## Go deeper

I write [**Attention Heads**](https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) — deep, evidence-backed writing on AI, cognition, and agentic engineering. The **Agentic Engineering Field Notes** series is where I publish practical advice on the craft of using AI. [Subscribe](https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) to get new posts to your inbox.

## Native routing

| Stage | Native role | Responsibility |
|---|---|---|
| Plan | Sol / High primary | Resolve intent, architecture, decomposition, and the complete specification |
| Routine implementation | `sol_advisor_luna_implementer` | GPT-5.6 Luna / Max handles bounded, well-specified work by default |
| Explicit escalation | `sol_advisor_terra_implementer` | GPT-5.6 Terra / High handles judgment-heavy/high-risk work or a corrected routine misclassification |
| Final review | `sol_advisor_sol_reviewer` | Fresh GPT-5.6 Sol / High reviews the actual diff and returns `ship`, `fix-first`, or `rethink` |

Native spawns use the exact named role and `fork_turns: none`; the role TOML pins the
model and reasoning level, so the spawn omits per-spawn model or effort overrides.
The final review is required after parent verification. A reviewer never implements
its own fixes, and any correction requires a new fresh review.

## Install from GitHub

Requirements:

- A current Codex CLI or ChatGPT desktop app with plugins enabled.
- GPT-5.6 Sol / High for the primary session.
- Native custom-agent support with access to GPT-5.6 Luna / Max and GPT-5.6 Terra / High.
- `jq` for locating the installed plugin package.

Add the GitHub repository as a Codex marketplace, then install the plugin:

~~~sh
codex plugin marketplace add DannyMac180/sol-advisor --ref main
codex plugin add sol-advisor@sol-advisor
~~~

### Install the native companion custom agents

Plugin installation does not automatically register user-owned custom-agent files.
Install the three shipped role templates separately, then run the non-mutating check:

~~~sh
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')"
test -n "$plugin_dir"
test -d "$plugin_dir"
sh "$plugin_dir/scripts/install-agents.sh"
sh "$plugin_dir/scripts/install-agents.sh" --check
~~~

Without an explicit target, the installer uses the existing `CODEX_HOME` value when
one is set, otherwise the user's default Codex agents directory. It does not invoke
Codex, edit `config.toml`, or overwrite a differing agent file. It installs missing
templates, safely migrates only recognized byte-exact historical templates, and
verifies all three installed copies byte-for-byte.

Start a **new Codex task** after the check passes. Native agent types are discovered
at task creation, so an existing task may not see newly installed roles. Select
GPT-5.6 Sol with High reasoning for the primary session and invoke the orchestration
skill explicitly when useful:

~~~text
Use $sol-advisor:orchestration to build this feature, verify it, and obtain the fresh Sol review before reporting done.
~~~

## Check and update native mode

Run this check whenever native routing must be trusted:

~~~sh
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')"
test -d "$plugin_dir"
sh "$plugin_dir/scripts/install-agents.sh" --check
~~~

To update the marketplace plugin and migrate recognized historical role files:

~~~sh
codex plugin marketplace upgrade sol-advisor
codex plugin add sol-advisor@sol-advisor
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')"
test -d "$plugin_dir"
sh "$plugin_dir/scripts/install-agents.sh"
sh "$plugin_dir/scripts/install-agents.sh" --check
~~~

The installer is fail-closed and non-destructive: modified, unsafe, nonregular,
symlinked, unknown, or differing destinations remain untouched and are reported as
conflicts. Preflight completes before any destination mutation.

## Native runtime evidence

Native spawn/details metadata is the primary routing evidence and must identify the
selected custom-agent type. When model or effort is omitted, use the local read-only
inspector with the exact native thread ID:

~~~sh
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')"
sh "$plugin_dir/scripts/inspect-agent-runtime.sh" <native-subagent-thread-id>
~~~

For a disposable fixture or a non-default local session root, pass it explicitly:

~~~sh
sh "$plugin_dir/scripts/inspect-agent-runtime.sh" --sessions-dir /absolute/path/to/sessions <native-subagent-thread-id>
~~~

The helper searches only the rollout filename ending in the exact thread ID and
emits allowlisted routing fields. It refuses invalid, missing, multiple, or
inconsistent evidence; it never infers a model or effort fallback.

## How routing works

The primary Sol orchestrator writes the complete five-part implementation
specification, then chooses the native role:

~~~text
agent_type: sol_advisor_luna_implementer
fork_turns: none
~~~

Use Luna / Max by default for bounded routine work. Choose Terra / High explicitly
for judgment-heavy or high-risk work, or when one corrected Luna attempt shows the
work was misclassified. After the parent verifies the actual diff and reruns the
checks, always use a fresh reviewer:

~~~text
agent_type: sol_advisor_sol_reviewer
fork_turns: none
~~~

Read the complete native packet, evidence rules, escalation rule, and return schema
in [the role contracts](plugins/sol-advisor/skills/orchestration/references/role-contracts.md).

## Local development

Install a checkout as a local marketplace when you want Codex to use its skill:

~~~sh
cd /absolute/path/to/sol-advisor
codex plugin marketplace add /absolute/path/to/sol-advisor
codex plugin add sol-advisor@sol-advisor
~~~
