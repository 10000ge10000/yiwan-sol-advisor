#!/bin/sh
# Repository-local verification for Sol Advisor's custom-agent companion installer.

set -eu

pass() {
  printf '%s\n' "PASS: $*"
}

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

hash_agents() {
  shasum -a 256 "$1/sol-advisor-luna-implementer.toml" "$1/sol-advisor-terra-implementer.toml" "$1/sol-advisor-sol-reviewer.toml" | shasum -a 256 | awk '{print $1}'
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
plugin_dir=$(CDPATH= cd "$script_dir/.." && pwd) || exit 1
installer=$script_dir/install-agents.sh
runtime_inspector=$script_dir/inspect-agent-runtime.sh
templates=$plugin_dir/agents
manifest=$plugin_dir/.codex-plugin/plugin.json
skill=$plugin_dir/skills/orchestration/SKILL.md
contracts=$plugin_dir/skills/orchestration/references/role-contracts.md

tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in
  /*) ;;
  *) tmp_base=/tmp ;;
esac
tmp_dir=''

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    case "$tmp_dir" in
      "$tmp_base"/sol-advisor-verify.*)
        rm -rf "$tmp_dir"
        ;;
      *)
        printf '%s\n' "REFUSING cleanup of unexpected directory: $tmp_dir" >&2
        ;;
    esac
  fi
}

trap cleanup 0 HUP INT TERM

tmp_dir=$(mktemp -d "$tmp_base/sol-advisor-verify.XXXXXX") || fail "could not create disposable verification directory"
case "$tmp_dir" in
  "$tmp_base"/sol-advisor-verify.*) ;;
  *) fail "mktemp returned an unexpected directory: $tmp_dir" ;;
esac

test -f "$installer" || fail "installer missing: $installer"
test -f "$runtime_inspector" || fail "runtime inspector missing: $runtime_inspector"
test -f "$manifest" || fail "plugin manifest missing: $manifest"
test -f "$skill" || fail "skill missing: $skill"
test -f "$contracts" || fail "role contracts missing: $contracts"

jq empty "$manifest"
pass "plugin manifest JSON is valid"

python3 - "$templates" <<'PY'
from pathlib import Path
import sys

try:
    import tomllib
except ModuleNotFoundError as exc:
    raise SystemExit("Python 3.11+ with tomllib is required for TOML validation") from exc

templates = Path(sys.argv[1])
expected = {
    "sol-advisor-luna-implementer.toml": {
        "name": "sol_advisor_luna_implementer",
        "model": "gpt-5.6-luna",
        "model_reasoning_effort": "max",
    },
    "sol-advisor-terra-implementer.toml": {
        "name": "sol_advisor_terra_implementer",
        "model": "gpt-5.6-terra",
        "model_reasoning_effort": "max",
    },
    "sol-advisor-sol-reviewer.toml": {
        "name": "sol_advisor_sol_reviewer",
        "model": "gpt-5.6-sol",
        "model_reasoning_effort": "high",
        "sandbox_mode": "read-only",
    },
}

for filename, pins in expected.items():
    path = templates / filename
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    for field in ("name", "description", "developer_instructions"):
        value = data.get(field)
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f"{path}: missing or empty required {field!r}")
    for field, expected_value in pins.items():
        if data.get(field) != expected_value:
            raise SystemExit(
                f"{path}: {field}={data.get(field)!r}, expected {expected_value!r}"
            )

print("TOML templates and exact role pins are valid")
PY
pass "custom-agent TOML validity and exact role pins"

clean_target=$tmp_dir/clean-install
sh "$installer" --target-dir "$clean_target"
for agent_file in sol-advisor-luna-implementer.toml sol-advisor-terra-implementer.toml sol-advisor-sol-reviewer.toml; do
  cmp -s "$templates/$agent_file" "$clean_target/$agent_file" || fail "clean install is not byte-for-byte exact: $agent_file"
done
pass "installer clean install and byte-for-byte final copies"

missing_check_target=$tmp_dir/missing-check
if sh "$installer" --target-dir "$missing_check_target" --check; then
  fail "--check accepted a missing target"
fi
test ! -e "$missing_check_target" || fail "--check created a missing target directory"
pass "installer --check refuses missing files without mutation"

codex_home_target=$tmp_dir/codex-home
CODEX_HOME="$codex_home_target" sh "$installer"
for agent_file in sol-advisor-luna-implementer.toml sol-advisor-terra-implementer.toml sol-advisor-sol-reviewer.toml; do
  cmp -s "$templates/$agent_file" "$codex_home_target/agents/$agent_file" || fail "CODEX_HOME target is not byte-for-byte exact: $agent_file"
done
test ! -e "$codex_home_target/config.toml" || fail "installer unexpectedly created config.toml"
pass "installer honors a pre-existing CODEX_HOME without editing config"

relative_parent=$tmp_dir/relative-parent
mkdir "$relative_parent"
(
  cd "$relative_parent"
  sh "$installer" --target-dir explicit-agents
)
for agent_file in sol-advisor-luna-implementer.toml sol-advisor-terra-implementer.toml sol-advisor-sol-reviewer.toml; do
  cmp -s "$templates/$agent_file" "$relative_parent/explicit-agents/$agent_file" || fail "explicit relative target is not byte-for-byte exact: $agent_file"
done
pass "installer accepts an explicit relative target directory"

before_repeat=$(hash_agents "$clean_target")
sh "$installer" --target-dir "$clean_target"
after_repeat=$(hash_agents "$clean_target")
[ "$before_repeat" = "$after_repeat" ] || fail "idempotent repeat changed an installed template"
pass "installer idempotent repeat"

before_check=$(hash_agents "$clean_target")
sh "$installer" --target-dir "$clean_target" --check
after_check=$(hash_agents "$clean_target")
[ "$before_check" = "$after_check" ] || fail "--check altered an installed template"
pass "installer --check"

conflict_target=$tmp_dir/conflict
mkdir "$conflict_target"
printf '%s\n' 'intentionally conflicting custom-agent template' > "$conflict_target/sol-advisor-luna-implementer.toml"
if sh "$installer" --target-dir "$conflict_target"; then
  fail "installer accepted a differing destination file"
fi
test ! -e "$conflict_target/sol-advisor-terra-implementer.toml" || fail "conflict refusal partially installed the Terra template"
test ! -e "$conflict_target/sol-advisor-sol-reviewer.toml" || fail "conflict refusal partially installed the Sol template"
pass "installer conflict refusal without partial mutation"

runtime_sessions=$tmp_dir/runtime-sessions
runtime_day=$runtime_sessions/2026/08/01
mkdir -p "$runtime_day"
runtime_success_id=11111111-1111-7111-8111-111111111111
runtime_success_rollout=$runtime_day/rollout-2026-08-01T00-00-00-$runtime_success_id.jsonl
printf '%s\n' \
  '{"type":"response_item","payload":{"prompt":"DO_NOT_LEAK_PROMPT","token":"DO_NOT_LEAK_TOKEN"}}' \
  '{"type":"event_msg","payload":{"environment":{"SECRET_ENV":"DO_NOT_LEAK_ENV"},"config":{"api_key":"DO_NOT_LEAK_CONFIG"}}}' \
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_success_id\",\"parent_thread_id\":\"00000000-0000-7000-8000-000000000000\",\"agent_role\":\"sol_advisor_luna_implementer\",\"agent_path\":\"/root/fixture\",\"model_provider\":\"openai\",\"cwd\":\"/fixture/cwd\",\"base_instructions\":\"DO_NOT_LEAK_INSTRUCTIONS\"}}" \
  '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"max","sandbox_policy":{"type":"danger-full-access","hidden":"DO_NOT_LEAK_SANDBOX"},"permission_profile":{"type":"disabled","hidden":"DO_NOT_LEAK_PERMISSION"},"cwd":"/fixture/cwd","summary":"DO_NOT_LEAK_SUMMARY"}}' \
  > "$runtime_success_rollout"
runtime_output=$(sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$runtime_success_id")
if ! printf '%s\n' "$runtime_output" | jq -e --arg id "$runtime_success_id" '
  type == "object"
  and (keys | sort) == ["agent_path", "agent_role", "cwd", "effort", "model", "model_provider", "parent_thread_id", "permission_profile_type", "sandbox_policy_type", "thread_id"]
  and .thread_id == $id
  and .agent_role == "sol_advisor_luna_implementer"
  and .model == "gpt-5.6-luna"
  and .effort == "max"
  and .sandbox_policy_type == "danger-full-access"
  and .permission_profile_type == "disabled"
' >/dev/null; then
  fail "runtime inspector did not return the expected safe routing object"
fi
if printf '%s\n' "$runtime_output" | grep -Fq 'DO_NOT_LEAK'; then
  fail "runtime inspector leaked fixture prompt or secret content"
fi
pass "runtime inspector safe allowlisted extraction"

if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" not-a-thread-id >/dev/null 2>&1; then
  fail "runtime inspector accepted an invalid thread id"
fi
pass "runtime inspector invalid-id refusal"

runtime_zero_id=22222222-2222-7222-8222-222222222222
if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$runtime_zero_id" >/dev/null 2>&1; then
  fail "runtime inspector accepted a thread id with no rollout"
fi
pass "runtime inspector zero-match refusal"

runtime_missing_turn_id=33333333-3333-7333-8333-333333333333
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_missing_turn_id\",\"agent_role\":\"sol_advisor_luna_implementer\"}}" > "$runtime_day/rollout-2026-08-01T00-00-01-$runtime_missing_turn_id.jsonl"
runtime_missing_session_id=44444444-4444-7444-8444-444444444444
printf '%s\n' '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"max"}}' > "$runtime_day/rollout-2026-08-01T00-00-02-$runtime_missing_session_id.jsonl"
runtime_missing_role_id=55555555-5555-7555-8555-555555555555
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_missing_role_id\"}}" '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"max"}}' > "$runtime_day/rollout-2026-08-01T00-00-03-$runtime_missing_role_id.jsonl"
runtime_missing_model_id=66666666-6666-7666-8666-666666666666
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_missing_model_id\",\"agent_role\":\"sol_advisor_luna_implementer\"}}" '{"type":"turn_context","payload":{"effort":"max"}}' > "$runtime_day/rollout-2026-08-01T00-00-04-$runtime_missing_model_id.jsonl"
runtime_missing_effort_id=77777777-7777-7777-8777-777777777777
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_missing_effort_id\",\"agent_role\":\"sol_advisor_luna_implementer\"}}" '{"type":"turn_context","payload":{"model":"gpt-5.6-luna"}}' > "$runtime_day/rollout-2026-08-01T00-00-05-$runtime_missing_effort_id.jsonl"
for rejected_runtime_id in "$runtime_missing_turn_id" "$runtime_missing_session_id" "$runtime_missing_role_id" "$runtime_missing_model_id" "$runtime_missing_effort_id"; do
  if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$rejected_runtime_id" >/dev/null 2>&1; then
    fail "runtime inspector accepted missing required routing metadata"
  fi
done
pass "runtime inspector required-metadata refusal"

runtime_duplicate_id=88888888-8888-7888-8888-888888888888
printf '%s\n' '{"type":"session_meta","payload":{}}' > "$runtime_day/rollout-2026-08-01T00-00-06-$runtime_duplicate_id.jsonl"
mkdir -p "$runtime_sessions/2026/08/02"
printf '%s\n' '{"type":"session_meta","payload":{}}' > "$runtime_sessions/2026/08/02/rollout-2026-08-02T00-00-06-$runtime_duplicate_id.jsonl"
if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$runtime_duplicate_id" >/dev/null 2>&1; then
  fail "runtime inspector accepted multiple matching rollouts"
fi
pass "runtime inspector multiple-match refusal"

for document in "$skill" "$contracts"; do
  grep -Fq 'agent_type: sol_advisor_luna_implementer' "$document" || fail "missing Luna custom agent reference: $document"
  grep -Fq 'agent_type: sol_advisor_terra_implementer' "$document" || fail "missing Terra custom agent reference: $document"
  grep -Fq 'agent_type: sol_advisor_sol_reviewer' "$document" || fail "missing Sol custom agent reference: $document"
  grep -Fq 'fork_turns: none' "$document" || fail "missing fresh-context spawn requirement: $document"
  if grep -Eq '^[[:space:]]*(model|reasoning_effort):' "$document"; then
    fail "per-spawn model or reasoning override remains in: $document"
  fi
done
grep -Fq '../../scripts/install-agents.sh' "$skill" || fail "skill does not resolve the companion installer relative to SKILL.md"
grep -Fq '../../scripts/inspect-agent-runtime.sh' "$skill" || fail "skill does not resolve the runtime inspector relative to SKILL.md"
grep -Fqi 'public native spawn/details metadata first' "$skill" || fail "skill does not require public runtime metadata first"
grep -Fqi 'host broadens it' "$skill" || fail "skill does not describe broadened reviewer sandbox behavior"
grep -Fqi 'parent captures and verifies exact before-and-after repository' "$contracts" || fail "role contracts do not require behavioral-read-only state verification"
grep -Fqi 'never silently fall back' "$skill" || fail "skill does not state the no-fallback guarantee"
pass "custom-agent contract references, runtime fallback, and no per-spawn overrides"

sh -n "$installer"
sh -n "$runtime_inspector"
sh -n "$script_dir/verify.sh"
pass "shell syntax"

printf '%s\n' "VERIFY PASSED: Sol Advisor companion-agent checks completed in $tmp_dir"
