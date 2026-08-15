# Sol Advisor

**Sol runs the show. Normal delivery is Sol / High plans → native Luna / Max
implements routine work → the parent verifies → a fresh Sol / High reviews. Terra /
High can be selected up front, or immediately when a Luna result reveals
judgment-heavy or high-risk work.**

Sol Advisor is a Codex-only architect workflow for capability-routed software
delivery. You bring the goal and constraints; Sol owns the plan, the parent verifies
the actual change, and a fresh Sol review is required before acceptance.

## Go deeper

I write [**Attention Heads**](https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) — deep, evidence-backed writing on AI, cognition, and agentic engineering. The **Agentic Engineering Field Notes** series is where I publish practical advice on the craft of using AI. [Subscribe](https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) to get new posts to your inbox.

## Quick start

You need a current Codex CLI or ChatGPT desktop app with plugins enabled, GPT-5.6
Sol / High for the primary session, native custom-agent support, jq, and GPT-5.6
Luna / Max access for the normal routine path. GPT-5.6 Terra / High access is needed
only when escalation is selected.

~~~sh
codex plugin marketplace add DannyMac180/sol-advisor --ref main
codex plugin add sol-advisor@sol-advisor
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')" && test -n "$plugin_dir" && test "$plugin_dir" != null && test -d "$plugin_dir" && test -f "$plugin_dir/scripts/install-agents.sh" && sh "$plugin_dir/scripts/install-agents.sh"
~~~

The companion installer verifies all three exact role files after installation. It is
fail-closed: modified, unsafe, nonregular, symlinked, unknown, or differing files
are left untouched. It does not edit Codex configuration. Start a fresh Codex task
after installation so native roles are discovered.

Use this one prompt in the new task:

~~~text
Use $sol-advisor:orchestration to build this feature, verify it, and obtain the fresh Sol review before reporting done.
~~~

## What you do

Give Sol the outcome, constraints, and any important repository context. You do not need to select or manage an implementation lane; Sol chooses the route and the parent owns verification and acceptance.

## When Terra is used

Routine-only work needs Luna / Max and Sol / High; Terra / High access is conditional
and needed only when escalation is selected. Sol selects Terra / High up front when
the work is judgment-heavy or high-risk, or immediately after Luna reveals that
complexity or risk. If the specification itself was incomplete or wrong, the parent
may send one corrected Luna attempt. That retry is only for a specification error, not
a mandatory step before Terra.

## What happens automatically

Sol / High keeps architecture, decomposition, parent verification, escalation
decisions, and acceptance in the primary task. Luna / Max implements routine work.
The parent inspects the complete diff and reruns the requested checks. A fresh Sol /
High reviewer then returns ship, fix-first, or rethink; any fix requires a new review.

## Updating

Update the marketplace plugin, reinstall the companion roles, and start a new task:

~~~sh
codex plugin marketplace upgrade sol-advisor
codex plugin add sol-advisor@sol-advisor
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')" && test -n "$plugin_dir" && test "$plugin_dir" != null && test -d "$plugin_dir" && test -f "$plugin_dir/scripts/install-agents.sh" && sh "$plugin_dir/scripts/install-agents.sh"
~~~

For exact spawn, runtime-evidence, sandbox, installer, and maintainer verification
details, read [advanced native operations](plugins/sol-advisor/skills/orchestration/references/operations.md).
For local development, install this checkout as a marketplace:

~~~sh
cd /absolute/path/to/sol-advisor
codex plugin marketplace add /absolute/path/to/sol-advisor
codex plugin add sol-advisor@sol-advisor
~~~
