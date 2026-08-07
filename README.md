# Sol Advisor

**A configurable, architect-first orchestration plugin for compatible Agent Plugins v1 clients.**

Sol Advisor keeps requirements, architecture, decomposition, diff inspection,
verification, and acceptance in the parent chat. Native implementer and advisor roles
use the exact model IDs and supported reasoning settings the user chooses during lazy
first-use setup. The orchestrator always inherits the parent chat's selected model
and effort.

## Recent changes

v0.5.0 adds portable first-use setup, a zero-dependency Bun MCP server, configurable
client-native adapters, safe preview/consent/install/uninstall flows, and fail-closed
cross-client capability handling. See the full [CHANGELOG.md](https://github.com/DannyMac180/sol-advisor/blob/main/CHANGELOG.md).

## Architecture

The flattened plugin contains:

- `plugin.json`: canonical Agent Plugins v1 package manifest.
- `.codex-plugin/plugin.json`: Codex-specific compatibility metadata.
- `mcp.json`: stdio MCP registration for `bun ${PLUGIN_ROOT}/mcp/server.ts`.
- `mcp/server.ts`: newline-delimited JSON-RPC server and configuration/adapter engine.
- `skills/setup/SKILL.md`: parent-chat first-use and reconfiguration interview.
- `skills/orchestration/SKILL.md`: architect workflow, routing, and review loops.
- `agents/` and `scripts/`: retained exact Codex v0.5 compatibility lane.

Plugin installation only makes these surfaces discoverable. It does **not** run setup,
install a hook, choose models, or write native role files. On the first orchestration
invocation, the skill checks setup state and starts the interview when configuration
is missing, corrupt, or from an unsupported schema.

Logical, non-secret preferences live in `${PLUGIN_DATA}/config.json`. Generated
client files are separate and appear only after an exact preview and explicit bound
confirmation. Bun is the only runtime prerequisite for the MCP server; the packaged
runtime has no repository-root or third-party runtime dependency.

## First-use interview

The interview stays in the parent/main chat and asks for client, project/user scope,
and three exact client-native model IDs copied from the client's picker or `/model`:

| Role | Purpose | Current Codex recommendation |
|---|---|---|
| Routine implementer | Bounded, mechanical, fully specified work | `gpt-5.6-terra`, `high` |
| High-complexity implementer | Security, concurrency, algorithms, hard debugging, migrations, wide refactors | `gpt-5.6-terra`, `high` |
| Advisor | Commitment review and final diff/evidence verdict; requested read-only | `gpt-5.6-sol`, `high` |
| Orchestrator | Parent ownership and verification | `inherit` (Sol / High recommended) |

These are editable recommendations, not a universal model catalog. Sol Advisor never
guesses, normalizes, silently falls back, or claims a model exists in another client.
The optional Codex app-task lane remains a distinct explicit opt-in for
`gpt-5.6-luna` / Max; it is never a fallback or a native role.

## Client installation and adapter paths

### Codex installation from GitHub

Add the repository marketplace and install the plugin:

~~~sh
codex plugin marketplace add DannyMac180/sol-advisor --ref main
codex plugin add sol-advisor@sol-advisor
~~~

Start a new chat, then invoke the workflow explicitly or request orchestration normally:

~~~text
Use $sol-advisor:orchestration to build this feature, verify it, and obtain the configured advisor review before reporting done.
~~~

Update an existing marketplace installation with:

~~~sh
codex plugin marketplace upgrade sol-advisor
codex plugin add sol-advisor@sol-advisor
~~~

### Cursor installation from a local clone

Cursor officially supports loading Agent Plugins from `~/.cursor/plugins/local`.
Until Sol Advisor has a reviewed Marketplace listing, copy the Agent Plugin root into
that directory. Cursor 3.15.6 rejects a symlink whose resolved target is outside the
local-plugin directory even though Cursor's documentation currently recommends
symlinks, so do not use a repository symlink for this test.

~~~sh
git switch agent-plugin-conformance
bun install --frozen-lockfile
bun run ci

repo_root="$(git rev-parse --show-toplevel)"
plugin_src="$repo_root/plugins/sol-advisor"
plugin_dir="$HOME/.cursor/plugins/local/sol-advisor"
mkdir -p "$(dirname "$plugin_dir")"
if test -e "$plugin_dir" || test -L "$plugin_dir"; then
  echo "Refusing to replace existing Cursor local plugin: $plugin_dir" >&2
  exit 1
fi
cp -R "$plugin_src" "$plugin_dir"
test -f "$plugin_dir/plugin.json"
test -f "$plugin_dir/mcp.json"
printf 'Copied Sol Advisor into Cursor local plugins: %s\n' "$plugin_dir"
~~~

In Cursor:

1. Run **Developer: Reload Window** from Cursor's IDE command palette.
2. Do not require a card under **Customize → Plugins**: Cursor 3.15.6 can load a
   direct local plugin without listing it on that tab. If needed, confirm the load in
   Cursor's `Cursor Plugins` output/log: `loadUserLocalPlugin sol-advisor loaded`.
3. Confirm the `sol-advisor` MCP server connects and exposes eight tools. If its log
   reports `spawn bun ENOENT`, Cursor was launched without the directory containing
   Bun on its process `PATH`. Fully quit Cursor, then relaunch its executable from the
   same terminal where `command -v bun` succeeds:

   ~~~sh
   bun_bin="$(command -v bun)"
   cursor_app="$(mdfind 'kMDItemCFBundleIdentifier == "com.todesktop.230313mzl4w4u92"' | head -n 1)"
   cursor_bin="${cursor_app%/}/Contents/MacOS/Cursor"
   test -x "$bun_bin"
   test -x "$cursor_bin"
   PATH="$(dirname "$bun_bin"):$PATH" "$cursor_bin" "$repo_root" >/tmp/cursor-sol-advisor.log 2>&1 &
   ~~~

   This launch command is for macOS. Preserve any other `${PLUGIN_DATA}` or MCP error
   as smoke-test evidence; do not substitute another runtime or loosen permissions.
4. Open the project you want to use for the test and start a new Agent chat.
5. Ask: `Run the Sol Advisor setup skill in this parent chat. Use Cursor project scope,
   ask one question at a time, and stop after showing the complete adapter preview.`
6. Copy exact model IDs from Cursor's model picker. Inspect all three generated files,
   then repeat the exact `INSTALL <nonce>` token—not a generic “yes.”
7. Reload Cursor again. The native roles should be invocable as
   `/sol-advisor-routine`, `/sol-advisor-high`, and `/sol-advisor-advisor`.

Before removing the local plugin, use the setup skill to uninstall its generated
adapter files with the exact uninstall token. Then remove only an unchanged copy of
this plugin:

~~~sh
if test -d "$plugin_dir" && ! test -L "$plugin_dir" && diff -qr "$plugin_src" "$plugin_dir" >/dev/null; then
  rm -rf -- "$plugin_dir"
else
  echo "Refusing to remove changed or unexpected plugin path: $plugin_dir" >&2
  exit 1
fi
~~~

For the complete disposable-workspace procedure and evidence checklist, follow
[Developer smoke test: Cursor](#developer-smoke-test-cursor). The local loading method
is documented by [Cursor's plugin guide](https://cursor.com/docs/plugins#test-plugins-locally).

For other clients, use only that client's documented Agent Plugins v1 UI or local
package mechanism; Sol Advisor does not claim a universal install command.

Install `plugins/sol-advisor` as the plugin root through a compatible Agent Plugins v1
client. Ensure `bun` is on the client's PATH and that it supplies an absolute,
existing, private `${PLUGIN_DATA}` directory. Then invoke orchestration; setup previews
all native files before requesting consent.

| Client | Project adapter | User adapter | Binding limits |
|---|---|---|---|
| Codex | `.codex/agents/*.toml` | `~/.codex/agents/*.toml` | Model + effort. Advisor requests `sandbox_mode = "read-only"`; verify observed sandbox. |
| Cursor | `.cursor/agents/*.md` | `~/.cursor/agents/*.md` | Model; optional `[effort=…]` syntax. Cursor may fall back when a pin is unavailable/restricted; Sol Advisor cannot detect or prevent host fallback. Read-only remains client/behavior dependent. |
| VS Code | `.github/agents/*.agent.md` | `~/.copilot/agents/*.agent.md` | Model only; effort and parent cost tier are session constraints. |
| GitHub Copilot | `.github/agents/*.agent.md` | `~/.copilot/agents/*.agent.md` | Model only; effort and parent cost tier are session constraints. |
| Kiro IDE/CLI | `.kiro/agents/*.md` | `~/.kiro/agents/*.md` | Model only; effort is session/per-model, not per-agent. |

ChatGPT Work web, Kiro web/mobile, and skills-only surfaces are not native client
profiles and cannot be saved through `save_preferences`. Use parent-chat prompt
guidance only; role binding is not enforceable. No live smoke-test claim is made for
those surfaces.

After any adapter install, update, or uninstall, start a new chat or reload the client
so native role discovery observes the new state.

## Preview, consent, reconfigure, and uninstall

`render_client_adapter` returns exact destinations, full contents, SHA-256 plan
digest, target-state hashes, warnings, and a short-lived one-time confirmation token.
It computes destinations from an existing workspace and the selected client/scope;
the parent never hands MCP an arbitrary destination path. User scope requires a
second exact token bound to the same preview.

Installation rejects traversal, symlink ancestors/targets, unmanaged conflicts,
drifted managed files, expired/replayed consent, and target changes since preview.
Managed files carry the exact `sol-advisor-managed:v1` marker and are recorded with
hashes. Updates create private backups. Uninstall first previews its files and token,
then removes only exact, unchanged managed files. Reconfiguration repeats the
interview and preview; reset requires its own exact confirmation and must not be used
to bypass a live managed install.

## Reconfigure, adapter uninstall, and plugin uninstall

Re-run the parent-chat interview explicitly when preferences change:

~~~text
Use $sol-advisor:setup to reconfigure my Sol Advisor client, scope, workspace, and exact native role choices.
~~~

Reconfiguration saves/selects a profile but does not write adapters until the new
exact preview is confirmed. Adapter uninstall is the `uninstall_client_adapter` flow:
it previews the current profile's managed files and confirmation token, then removes
only unchanged managed files. It does **not** uninstall the plugin package. To remove
the plugin itself, first uninstall managed adapters, then use the specific client's
documented plugin manager or UI. No cross-client plugin-uninstall command is assumed.

## MCP tools

The server implements `initialize`, `ping`, `tools/list`, and `tools/call` over
newline-delimited JSON-RPC. Its tools are:

- `get_setup_status`
- `get_preferences`
- `save_preferences`
- `render_client_adapter`
- `install_client_adapter`
- `uninstall_client_adapter`
- `validate_configuration`
- `reset_configuration`

Configuration is schema-versioned and written atomically. Secret-like fields are
rejected recursively; model IDs and effort values cannot contain control characters.
No credentials belong in plugin configuration.

## Orchestration semantics

The parent owns the specification, architecture, decomposition, actual diff review,
rerun verification, correction loops, and acceptance. Routine versus high routing is
based on task complexity, never price alone. Worker reports are claims until the
parent verifies the working tree and checks. The advisor remains behaviorally
read-only unless the client exposes evidence of OS-enforced isolation; Sol Advisor
reports the observed guarantee rather than inventing one.

The historical exact Codex native lane remains compatible: separately installed
Terra / High implementation and a fresh Sol / High reviewer. It does not use a Luna
custom-agent TOML. The Luna lane instead uses app task tools and is outside native
subagent V2.

| Mode | Worker | Parent ownership |
|---|---|---|
| Native lane | Saved routine/high role, then saved advisor role | Architecture, diff/check verification, corrections, acceptance |
| Luna task (explicit opt-in) | User-visible `gpt-5.6-luna` / Max task | Monitoring, diff review, corrections, PR authorization, dependent ordering |

Use the Luna task lane only with current-request authorization such as: **“Use the
Luna task lane for this feature.”** It requires `list_projects`, `list_threads`,
`create_thread`, `wait_threads`, `read_thread`, and `send_message_to_thread`. A pending
`clientThreadId` is a setup handle, not a ready task ID. Missing tools, Luna, or Max
stop without fallback. The native lane remains the default for the exact retained
Codex compatibility workflow and does not use a Luna companion file.

### Requirements common to both modes

- Bun available for portable MCP runtime.
- A compatible plugin client and exact user-selected model access.
- Parent ownership of verification and acceptance.

### Additional native-mode requirements

- Codex native custom-agent support and the separately installed exact roles.
- Observable runtime routing; no unverified model/effort claim.
- `jq` for the retained companion lookup/install script.

### Additional Luna task-mode requirements

- Explicit authorization in the current request.
- Luna / Max availability and all six app task tools.

The native companion installation can be skipped for Luna-only use. Luna tasks do not require native subagents, Terra access, or companion TOML files. Luna-only users do not need to run `scripts/install-agents.sh`.

## Retained Codex companion lane

For exact legacy-compatible native use:

~~~sh
plugin_dir="$(codex plugin list --json | jq -r '.installed[] | select(.pluginId == "sol-advisor@sol-advisor") | .source.path')"
sh "$plugin_dir/scripts/install-agents.sh"
sh "$plugin_dir/scripts/install-agents.sh" --check
~~~

Start a fresh task afterward. The installer refuses conflicting or symlinked files and
retains the byte-exact v0.2.0 migration. Runtime routing may be inspected with:

~~~sh
sh "$plugin_dir/scripts/inspect-agent-runtime.sh" <native-subagent-thread-id>
~~~

## Security model and limitations

- Sol Advisor fails closed: it chooses no fallback models, guessed aliases, or arbitrary write paths.
- Cursor itself may fall back when a pinned model is unavailable or restricted. Sol Advisor never chooses that fallback but cannot detect or prevent it.
- `${PLUGIN_DATA}` must be an absolute existing `0700`-equivalent directory: never `/`, the home directory, the plugin root, or a path with symlink ancestors. Its realpath/device/inode are pinned for the server process; Sol Advisor never chmods the host-supplied root.
- Install and uninstall use fsynced transaction journals, same-directory staging/quarantine, immediate hash/ancestor checks, and no-clobber creation. Recovery mutates only validated active-profile allowlisted paths with exact recorded hashes.
- Configuration is non-secret state; adapter files are allowlisted.
- Exact preview consent is necessary but does not establish client capability.
- Client-native read-only and effort guarantees vary. Only observed evidence counts.
- Standard manifest conformance is packaging conformance, not behavioral parity.
- Unsupported web/mobile/skills-only surfaces are prompt-only.
- No live cross-client behavioral claim is made without a real client test.

## Developer smoke test: Cursor

Use this procedure from the `agent-plugin-conformance` branch before claiming live
Cursor support. It follows [Cursor's documented local-plugin flow](https://cursor.com/docs/plugins#test-plugins-locally)
and uses project scope plus a disposable workspace so it does not touch global agent
files. Record the Cursor version, chosen model IDs, observed subagent details, and any
fallback or permission message.

### 1. Validate and load the local plugin

From this repository:

~~~sh
git switch agent-plugin-conformance
bun install --frozen-lockfile
bun run ci

repo_root="$(git rev-parse --show-toplevel)"
plugin_src="$repo_root/plugins/sol-advisor"
plugin_dir="$HOME/.cursor/plugins/local/sol-advisor"
mkdir -p "$(dirname "$plugin_dir")"
if test -e "$plugin_dir" || test -L "$plugin_dir"; then
  echo "Refusing to replace existing Cursor local plugin: $plugin_dir" >&2
  exit 1
fi
cp -R "$plugin_src" "$plugin_dir"
test -f "$plugin_dir/plugin.json"
test -f "$plugin_dir/mcp.json"
printf 'Copied plugin root into: %s\n' "$plugin_dir"
~~~

Use a real directory copy for this test. Cursor 3.15.6 rejects external symlink targets
under `~/.cursor/plugins/local`, despite the current symlink example in Cursor's docs.

In Cursor's IDE, run **Developer: Reload Window**. A direct local plugin may not appear
under **Customize → Plugins**. Confirm `loadUserLocalPlugin sol-advisor loaded` in the
`Cursor Plugins` output/log instead, then confirm the `sol-advisor` MCP server exposes
eight tools. If the MCP log reports `spawn bun ENOENT`, fully quit Cursor and use the
macOS terminal-launch command in [Cursor installation from a local clone](#cursor-installation-from-a-local-clone)
so Cursor inherits Bun's directory on `PATH`. An unresolved `${PLUGIN_ROOT}` or
`${PLUGIN_DATA}`, or a non-private plugin-data directory, must produce a visible failure
rather than a silent fallback.

### 2. Create an isolated workspace

~~~sh
tmp_base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
smoke_dir="$(mktemp -d "$tmp_base/sol-advisor-cursor-smoke.XXXXXX")"
git -C "$smoke_dir" init
printf 'Open this folder in Cursor: %s\n' "$smoke_dir"
~~~

Open the printed folder in Cursor. Keep `smoke_dir`, `plugin_src`, and `plugin_dir` in
that terminal for the later checks and cleanup.

### 3. Run setup in the parent chat

Open a new Cursor Agent chat and say:

~~~text
Run the Sol Advisor setup skill in this parent chat. Configure Cursor project scope
for this exact workspace: <paste smoke_dir>. Ask one question at a time. I will copy
exact model IDs from Cursor's model picker. Show the full adapter preview and stop
before installation until I repeat the exact token.
~~~

Choose exact model IDs that are currently available to your Cursor account. Where the
model supports it, choose an effort value such as `high`; the generated Cursor model
value should use Cursor's documented `model-id[effort=high]` syntax. Before confirming,
verify that the preview contains only these three destinations and their complete
contents:

~~~text
<smoke_dir>/.cursor/agents/sol-advisor-routine.md
<smoke_dir>/.cursor/agents/sol-advisor-high.md
<smoke_dir>/.cursor/agents/sol-advisor-advisor.md
~~~

In the terminal, confirm preview was non-mutating:

~~~sh
test ! -e "$smoke_dir/.cursor/agents/sol-advisor-routine.md"
test ! -e "$smoke_dir/.cursor/agents/sol-advisor-high.md"
test ! -e "$smoke_dir/.cursor/agents/sol-advisor-advisor.md"
~~~

Repeat the exact `INSTALL <nonce>` token in chat. Do not use a generic “yes.” Confirm
all three files now exist, contain `sol-advisor-managed:v1`, and no other file was
created under `.cursor/agents`:

~~~sh
for name in routine high advisor; do
  test -f "$smoke_dir/.cursor/agents/sol-advisor-$name.md"
done
test "$(find "$smoke_dir/.cursor/agents" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 3
find "$smoke_dir/.cursor/agents" -maxdepth 1 -type f -print -exec grep -H 'sol-advisor-managed:v1' {} \;
~~~

### 4. Verify discovery, routing, and review

Run **Developer: Reload Window** again and start a new Agent chat. Cursor custom
subagents support explicit `/name` invocation. Perform these checks:

1. Invoke `/sol-advisor-routine` to create `cursor-smoke.txt` containing one known
   line. Confirm its subagent details show the configured model/options, or record any
   Cursor fallback warning.
2. Invoke `/sol-advisor-high` to append a second known line while checking the file for
   a deliberately described edge case. Confirm its details show the configured high
   role model/options, or record any fallback warning.
3. Before invoking the advisor, run `advisor_before="$(git -C "$smoke_dir" status --short)"`
   in the same terminal. Invoke `/sol-advisor-advisor` to review the file without
   changing it. Confirm the agent is shown as read-only, then run
   `test "$(git -C "$smoke_dir" status --short)" = "$advisor_before"` to prove the
   advisor created no additional change.
4. Ask: `Use the Sol Advisor orchestration skill to append one line to
   cursor-smoke.txt through the routine role, verify the diff, and obtain the advisor
   verdict.` Confirm setup does not repeat, the parent remains the orchestrator, and
   the configured routine and advisor roles are used.
5. In the same parent chat, ask Sol Advisor to call `get_setup_status` and
   `validate_configuration` for the exact smoke workspace. Both should report a ready,
   valid project profile.

Cursor documents that it may substitute a compatible model when a pin is restricted
or unavailable. Treat any such substitution as an observed host limitation, not as a
successful exact-model routing claim.

### 5. Uninstall and clean up

In the parent chat, say:

~~~text
Use the Sol Advisor setup skill to uninstall this active project adapter. Preview the
managed files first and do not remove anything until I repeat the exact uninstall token.
~~~

Repeat the exact token, then verify the three managed files are gone. Finally remove
only the unchanged local-plugin copy created above and the guarded disposable workspace:

~~~sh
if test -d "$plugin_dir" && ! test -L "$plugin_dir" && diff -qr "$plugin_src" "$plugin_dir" >/dev/null; then
  rm -rf -- "$plugin_dir"
else
  echo "Refusing to remove changed or unexpected plugin path: $plugin_dir" >&2
  exit 1
fi
case "$smoke_dir" in
  "$tmp_base"/sol-advisor-cursor-smoke.*) rm -rf -- "$smoke_dir" ;;
  *) echo "Refusing to remove unexpected workspace: $smoke_dir" >&2; exit 1 ;;
esac
~~~

A passing smoke test requires successful plugin/MCP discovery, lazy parent-chat setup,
non-mutating preview, exact-token installation, all three native subagents, observable
routine/high/advisor routing, unchanged-file advisor review, validated configuration, and
exact managed-file uninstall. Add this evidence to the draft PR before making it ready
for review:

~~~text
Cursor version:
Plugin + MCP discovered (8 tools): pass/fail
Setup stayed in parent chat: pass/fail
Configured routine/high/advisor model values:
Preview paths/content inspected: pass/fail
No files before exact token: pass/fail
Three managed files after token: pass/fail
Observed routine routing/model/fallback:
Observed high routing/model/fallback:
Observed advisor routing/read-only/no-diff:
Orchestration reused saved setup: pass/fail
validate_configuration result:
Exact uninstall + cleanup: pass/fail
Notes/screenshots/log references:
~~~

## Local testing and development

~~~sh
bun install --frozen-lockfile
bun run test
bun run validate
bun run ci
bun run tag:check -- v0.5.0
bun run release:check
git diff --check
~~~

`bun run release:check` builds a flattened archive, extracts it, validates its packaged
manifests/skills/runtime, and starts the extracted MCP server with isolated HOME and
PLUGIN_DATA. Tagged releases remain CI-gated; this repository does not overwrite an
existing release.

## Go deeper

I write [**Attention Heads**](https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) — deep, evidence-backed writing on AI, cognition, and agentic engineering. The **Agentic Engineering Field Notes** series is where I publish practical advice on the craft of using AI. [Subscribe](https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor) to get new posts to your inbox.

## License

MIT. See [LICENSE](https://github.com/DannyMac180/sol-advisor/blob/main/LICENSE).
