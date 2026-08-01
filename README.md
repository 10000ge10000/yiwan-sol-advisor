# Sol Advisor

**Sol runs the show. Luna handles routine implementation, Terra takes the harder builds, and a fresh Sol review stands between the diff and “done.”**

Sol Advisor is a Codex-native architect workflow for capability-routed software delivery. The main session stays focused on requirements, architecture, specs, and verification while native Codex subagents handle implementation in clean contexts.

| Lane | Model | Reasoning | Use it for |
|---|---|---:|---|
| Orchestrator | GPT-5.6 Sol | High | Requirements, architecture, decomposition, routing, and acceptance |
| Routine implementation | GPT-5.6 Luna | Max | Mechanical, repeatable, fully specified work |
| Harder implementation | GPT-5.6 Terra | Max | Context-heavy, higher-risk, or wider-blast-radius work |
| Final review | Fresh GPT-5.6 Sol | High | Read-only review of the actual diff and verification evidence |

The final review is context-independent, not model-family-independent: Sol reviews Sol's orchestration with a fresh context. That still catches conversational assumptions, but it is not cross-vendor review.

## Install from GitHub

Requirements:

- A current Codex CLI or ChatGPT desktop app with plugins and native subagents enabled.
- Access to GPT-5.6 Sol, Terra, and Luna at the configured reasoning levels.

Add the GitHub repository as a Codex marketplace, then install the plugin:

```bash
codex plugin marketplace add DannyMac180/sol-advisor --ref main
codex plugin add sol-advisor@sol-advisor
```

Start a new Codex chat after installation. Select **GPT-5.6 Sol** with **High** reasoning for the primary session, then ask for implementation work normally or invoke the orchestration skill explicitly:

```text
Use $sol-advisor:orchestration to build this feature, verify it, and obtain the final Sol review before reporting done.
```

The skill requires explicit model and reasoning overrides on every spawned lane. It fails loudly when a requested combination is unavailable; it never changes the cost or capability tier silently.

## Update

Refresh the marketplace snapshot and reinstall the plugin, then start a new chat:

```bash
codex plugin marketplace upgrade sol-advisor
codex plugin add sol-advisor@sol-advisor
```

## How routing works

The Sol orchestrator writes a five-part spec for every implementation: objective, file ownership, interfaces, constraints, and verification. Luna is the default producer. Terra is selected when judgment, context, or blast radius is materially higher, or when one Luna attempt demonstrates that the task was misclassified.

The orchestrator inspects every diff and reruns verification. A fresh read-only Sol reviewer then returns `ship`, `fix-first`, or `rethink`. The session cannot report completion until the reviewer returns `ship`.

## Local development

Clone the repository, add its root as a local marketplace, and install the plugin:

```bash
codex plugin marketplace add /absolute/path/to/sol-advisor
codex plugin add sol-advisor@sol-advisor
```

After editing the plugin, validate both layers:

```bash
codex_skills="${CODEX_HOME:-${HOME}/.codex}/skills/.system"
uv run --no-project --with pyyaml python "${codex_skills}/skill-creator/scripts/quick_validate.py" plugins/sol-advisor/skills/orchestration
uv run --no-project --with pyyaml python "${codex_skills}/plugin-creator/scripts/validate_plugin.py" plugins/sol-advisor
jq empty .agents/plugins/marketplace.json plugins/sol-advisor/.codex-plugin/plugin.json
plugin_source="$(jq -r '.plugins[] | select(.name == "sol-advisor") | .source.path' .agents/plugins/marketplace.json)"
test -d "${plugin_source}"
```

The `uv` commands supply the validators' `PyYAML` dependency in a disposable environment. They do not install the marketplace or mutate Codex configuration.

Restart Codex or begin a new chat after reinstalling so the updated skill is loaded.

## License

MIT
