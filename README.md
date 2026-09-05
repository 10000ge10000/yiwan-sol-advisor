# Sol Advisor

[![Blog](https://img.shields.io/badge/Blog-910501.xyz-orange)](https://blog.910501.xyz/)
[![Bilibili](https://img.shields.io/badge/B%E7%AB%99-59438380-00a1d6?logo=bilibili)](https://space.bilibili.com/59438380)
[![YouTube](https://img.shields.io/badge/YouTube-10000%20AI%20Share-ff0000?logo=youtube&logoColor=white)](https://www.youtube.com/channel/UCqgvZnCN9-9pZcL4SWxmnDw)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Sol plans and reviews using the user's active Codex model (GPT-6, GPT-5.6, GPT-5.5, etc.) and reasoning effort; Google Antigravity CLI (Gemini 3.8 Flash High) implements.**

Sol Advisor is an orchestration release for high-assurance software delivery. Sol acts as
architect and reviewer; Antigravity acts as the sole implementation engine.

## Go deeper

I write [**Attention Heads**](https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) — deep, evidence-backed writing on AI, cognition, and agentic engineering. The **Agentic Engineering Field Notes** series is where I publish practical advice on the craft of using AI. [Subscribe](https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) to get new posts to your inbox.

## Quick start

You need a current Codex CLI or ChatGPT desktop app with plugins enabled, your active Codex
model (GPT-6, GPT-5.6, GPT-5.5, etc.) at your configured reasoning effort, native Antigravity CLI (`agy.exe` on Windows, `agy` on Linux/WSL), and jq.

~~~sh
codex plugin marketplace add DannyMac180/sol-advisor --ref main
codex plugin add sol-advisor@sol-advisor
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')" && test -n "$plugin_dir" && test "$plugin_dir" != null && test -d "$plugin_dir" && test -f "$plugin_dir/scripts/install-agents.sh" && sh "$plugin_dir/scripts/install-agents.sh"
~~~

The companion installer verifies the Sol reviewer role file after installation. It is
fail-closed: modified, unsafe, nonregular, symlinked, unknown, or differing files
are left untouched. It does not edit Codex configuration. Start a fresh Codex task
after installation so native roles are discovered.

Use this one prompt in the new task:

~~~text
Use $sol-advisor:orchestration to plan this feature, implement it with Antigravity, and verify with Sol review.
~~~

## What you do

Give Sol the outcome, constraints, and repository context. Sol owns architecture, planning,
Antigravity dispatching, verification, and final acceptance.

## Workflow

| Stage | Owner | Execution |
|---|---|---|
| **1. Plan** | Primary Sol / active model | Architect design, declare constraints, author 5-part worker specification. |
| **2. Implement** | Google Antigravity CLI | `gemini-3.8-flash-high` (`--effort high`, `--mode accept-edits`, headless sandbox, `--add-dir`) implements the spec. |
| **3. Parent Verify** | Primary Sol / active model | Direct inspection of working-tree diff, Git metadata digest, and ownership verification. |
| **4. Fresh Review** | Companion Sol / active model | Fresh read-only review returning `ship`, `fix-first`, or `rethink`. |
| **5. Correction** | Antigravity Loop | `fix-first` corrections route back to Antigravity with adaptive timeouts. |

## What happens automatically

Sol dynamically inherits the user's active Codex model (GPT-6, GPT-5.6, GPT-5.5, etc.) and reasoning effort, keeping architecture, decomposition, parent verification, and acceptance in the primary task. Implementation executes via Google Antigravity CLI with explicit workspace binding (`--add-dir`), sandboxed headless mode, dynamic phase timeout scaling, multi-language runtime cache isolation, nonce-bound generation preflight, and heartbeat watchdogs. Plans larger than 12 owned paths must be split into independently verifiable phases. The root inspects the complete diff and scoped Git metadata. A fresh read-only Sol reviewer evaluates the final diff and evidence; fixes route back to Antigravity.

## Updating

Update the marketplace plugin, reinstall the companion role, and start a new task:

~~~sh
codex plugin marketplace upgrade sol-advisor
codex plugin add sol-advisor@sol-advisor
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')" && test -n "$plugin_dir" && test "$plugin_dir" != null && test -d "$plugin_dir" && test -f "$plugin_dir/scripts/install-agents.sh" && sh "$plugin_dir/scripts/install-agents.sh"
~~~

For exact launcher/wrapper invocation, plan limits, preflight, heartbeats, runtime evidence, and maintainer verification
details, read [advanced native operations](references/operations.md).
For local development, install this checkout as a marketplace:

~~~sh
cd /absolute/path/to/sol-advisor
codex plugin marketplace add /absolute/path/to/sol-advisor
codex plugin add sol-advisor@sol-advisor
~~~
