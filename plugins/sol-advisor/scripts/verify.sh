#!/bin/sh
# Repository-local verification for Sol Advisor's native three-role architecture.

set -eu

pass() { printf '%s\n' "PASS: $*"; }
fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
plugin_dir=$(CDPATH= cd "$script_dir/.." && pwd) || exit 1
repo_dir=$(CDPATH= cd "$plugin_dir/../.." && pwd) || exit 1
installer=$script_dir/install-agents.sh
runtime_inspector=$script_dir/inspect-agent-runtime.sh
templates=$plugin_dir/agents
manifest=$plugin_dir/.codex-plugin/plugin.json
skill=$plugin_dir/skills/orchestration/SKILL.md
contracts=$plugin_dir/skills/orchestration/references/role-contracts.md
operations=$plugin_dir/skills/orchestration/references/operations.md
readme=$repo_dir/README.md
ui=$plugin_dir/skills/orchestration/agents/openai.yaml
retired_contract=$plugin_dir/skills/orchestration/references/luna-task-lane.md

tmp_base=/tmp
tmp_env=$(printenv TMPDIR 2>/dev/null || true)
if [ -n "$tmp_env" ]; then tmp_base=$tmp_env; fi
case "$tmp_base" in /*) ;; *) tmp_base=/tmp ;; esac
tmp_dir=''
cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    case "$tmp_dir" in
      "$tmp_base"/sol-advisor-verify.*) rm -rf "$tmp_dir" ;;
      *) printf '%s\n' "REFUSING cleanup of unexpected directory: $tmp_dir" >&2 ;;
    esac
  fi
}
trap cleanup 0 HUP INT TERM
tmp_dir=$(mktemp -d "$tmp_base/sol-advisor-verify.XXXXXX") || fail "could not create disposable verification directory"

luna_file=sol-advisor-luna-implementer.toml
terra_file=sol-advisor-terra-implementer.toml
sol_file=sol-advisor-sol-reviewer.toml
legacy_luna_sha256=fba1b42849d93737e83b094a2ab0b1611f87ac37db7438c8bbdf581f0813f8eb
legacy_terra_sha256=4425a8c1f21ce8c6af93f96adc253bbc33ea301f1389b3fa8ce350be08584eca
legacy_luna_v050_sha256=5cfaf77f14757074ca5d3cfecd0b8204c91dc14eff8d6119985c64416ddf4853
legacy_terra_v050_sha256=dc329fe87f6f6610c13157ec16432f91c79cf5a541ee3e7448f6afb165dd18ce

snapshot_files() {
  target=$1
  if [ ! -d "$target" ]; then
    printf '%s\n' MISSING
    return
  fi
  find "$target" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort | while IFS= read -r path; do
    if [ -L "$path" ]; then
      printf 'L %s -> %s\n' "$(basename "$path")" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      shasum -a 256 "$path"
    else
      printf 'O %s\n' "$(basename "$path")"
    fi
  done
}

write_legacy_roles() {
  target=$1
  mkdir -p "$target"
  cat > "$target/$luna_file" <<'LEGACY_LUNA'
name = "sol_advisor_luna_implementer"
description = "Sol Advisor's routine implementation lane for bounded, fully specified work."
model = "gpt-5.6-luna"
model_reasoning_effort = "max"

developer_instructions = """
You are Sol Advisor's routine implementation worker. Execute the supplied five-part
implementation specification exactly when it is bounded and largely determined by
the contract. Preserve stated interfaces and constraints, make only the files you
own, and adapt to concurrent edits instead of reverting work you do not own.

Surface material ambiguity, missing acceptance criteria, scope conflicts, or failed
verification rather than redesigning the architecture. Run the requested checks and
report actual evidence. Do not silently substitute a different role, model, or
reasoning level; this installed custom-agent profile is the required routine lane.
"""
LEGACY_LUNA
  cat > "$target/$terra_file" <<'LEGACY_TERRA'
name = "sol_advisor_terra_implementer"
description = "Sol Advisor's complex implementation lane for context-heavy or higher-risk work."
model = "gpt-5.6-terra"
model_reasoning_effort = "max"

developer_instructions = """
You are Sol Advisor's complex implementation worker. Resolve difficult implementation
details within the settled architecture, including context-heavy, higher-risk, or
wider-blast-radius work. Preserve every stated interface and constraint, stay within
the owned file set, and document material judgment calls.

You are not alone in the codebase: preserve concurrent edits and do not revert
unrelated work. Surface ambiguity, scope conflicts, or verification failures rather
than changing the architecture without direction. Run the requested checks and report
actual evidence. Do not silently substitute a different role, model, or reasoning
level; this installed custom-agent profile is the required complex lane.
"""
LEGACY_TERRA
  cp "$templates/$sol_file" "$target/$sol_file"
  [ "$(shasum -a 256 "$target/$luna_file" | awk '{print $1}')" = "$legacy_luna_sha256" ] || fail "legacy Luna fixture digest drifted"
  [ "$(shasum -a 256 "$target/$terra_file" | awk '{print $1}')" = "$legacy_terra_sha256" ] || fail "legacy Terra fixture digest drifted"
}

write_v050_roles() {
  target=$1
  mkdir -p "$target"
  cat > "$target/$luna_file" <<'V050_LUNA'
name = "sol_advisor_luna_implementer"
description = "Sol Advisor's default routine implementation lane for bounded, fully specified work."
model = "gpt-5.6-luna"
model_reasoning_effort = "max"

developer_instructions = """
You are Sol Advisor's default routine implementation worker. Execute the supplied
five-part implementation specification when the work is bounded and largely
determined by the contract. Preserve every stated interface and constraint, stay
within the owned file set, and document material judgment calls.

You are not alone in the codebase: preserve concurrent edits and do not revert
unrelated work. Surface material ambiguity, scope conflicts, or verification failures
rather than redesigning the architecture. Run the requested checks and report actual
evidence. If one corrected attempt shows that the work is judgment-heavy, high-risk,
or misclassified as routine, stop and return that signal so the parent can escalate
it to Terra / High. Do not silently substitute a different role, model, or reasoning
level; this installed custom-agent profile is the required routine lane.
"""
V050_LUNA
  cat > "$target/$terra_file" <<'V050_TERRA'
name = "sol_advisor_terra_implementer"
description = "Sol Advisor's explicit high-complexity escalation lane for judgment-heavy or high-risk work."
model = "gpt-5.6-terra"
model_reasoning_effort = "high"

developer_instructions = """
You are Sol Advisor's explicit high-complexity escalation worker. Execute the
supplied five-part implementation specification within the settled architecture when
the parent identifies judgment-heavy, high-risk, or wider-blast-radius work, or when
one corrected Luna attempt shows that routine routing was a misclassification.
Preserve every stated interface and constraint, stay within the owned file set, and
document material judgment calls.

You are not alone in the codebase: preserve concurrent edits and do not revert
unrelated work. Surface ambiguity, scope conflicts, or verification failures rather
than redesigning the architecture without direction. Run the requested checks and
report actual evidence. Do not silently substitute a different role, model, or
reasoning level; this installed custom-agent profile is the required escalation lane.
"""
V050_TERRA
  cp "$templates/$sol_file" "$target/$sol_file"
  [ "$(shasum -a 256 "$target/$luna_file" | awk '{print $1}')" = "$legacy_luna_v050_sha256" ] || fail "v0.5.0 Luna fixture digest drifted"
  [ "$(shasum -a 256 "$target/$terra_file" | awk '{print $1}')" = "$legacy_terra_v050_sha256" ] || fail "v0.5.0 Terra fixture digest drifted"
}

for required in "$installer" "$runtime_inspector" "$manifest" "$skill" "$contracts" "$operations" "$readme" "$ui"; do
  test -f "$required" || fail "required file missing: $required"
done
test ! -e "$retired_contract" || fail "retired separate workflow contract remains: $retired_contract"
pass "required files present and retired contract absent"

jq empty "$manifest"
[ "$(jq -r '.version' "$manifest")" = 0.5.1 ] || fail "manifest version is not 0.5.1"
grep -Fq 'default native Luna / Max' "$manifest" || fail "manifest omits default Luna routing"
grep -Fq 'GPT-5.6 Terra / High' "$manifest" || fail "manifest omits Terra escalation"
grep -Fq 'fresh GPT-5.6 Sol / High' "$manifest" || fail "manifest omits fresh Sol review"
grep -Fq 'known up front or revealed by Luna' "$manifest" || fail "manifest omits immediate Terra semantics"
grep -Fq 'one Luna retry is reserved' "$manifest" || fail "manifest omits specification-error retry semantics"
if grep -Fq 'corrected Luna specification when' "$manifest"; then fail "manifest implies corrected Luna work is sent to Terra"; fi
pass "manifest JSON, v0.5.1 release, and routing language"

python3 - "$templates" <<'PY'
from pathlib import Path
import sys
import tomllib

root = Path(sys.argv[1])
expected = {
    "sol-advisor-luna-implementer.toml": {
        "name": "sol_advisor_luna_implementer",
        "model": "gpt-5.6-luna",
        "model_reasoning_effort": "max",
    },
    "sol-advisor-terra-implementer.toml": {
        "name": "sol_advisor_terra_implementer",
        "model": "gpt-5.6-terra",
        "model_reasoning_effort": "high",
    },
    "sol-advisor-sol-reviewer.toml": {
        "name": "sol_advisor_sol_reviewer",
        "model": "gpt-5.6-sol",
        "model_reasoning_effort": "high",
        "sandbox_mode": "read-only",
    },
}
actual = {path.name for path in root.glob("*.toml")}
if actual != set(expected):
    raise SystemExit(f"expected exactly {sorted(expected)}, found {sorted(actual)}")
for filename, pins in expected.items():
    data = tomllib.loads((root / filename).read_text(encoding="utf-8"))
    for field in ("name", "description", "developer_instructions"):
        if not isinstance(data.get(field), str) or not data[field].strip():
            raise SystemExit(f"{filename}: missing {field}")
    for field, value in pins.items():
        if data.get(field) != value:
            raise SystemExit(f"{filename}: {field}={data.get(field)!r}, expected {value!r}")
print("three exact role pins are valid")
PY
pass "exact three-role TOML inventory"

grep -Fq "legacy_luna_sha256=$legacy_luna_sha256" "$installer" || fail "installer legacy Luna digest mismatch"
grep -Fq "legacy_terra_sha256=$legacy_terra_sha256" "$installer" || fail "installer legacy Terra digest mismatch"
grep -Fq "legacy_luna_v050_sha256=$legacy_luna_v050_sha256" "$installer" || fail "installer v0.5.0 Luna digest mismatch"
grep -Fq "legacy_terra_v050_sha256=$legacy_terra_v050_sha256" "$installer" || fail "installer v0.5.0 Terra digest mismatch"
pass "immutable historical migration fingerprints"

clean_target=$tmp_dir/clean
sh "$installer" --target-dir "$clean_target"
for role in "$luna_file" "$terra_file" "$sol_file"; do
  cmp -s "$templates/$role" "$clean_target/$role" || fail "clean install mismatch: $role"
done
sh "$installer" --target-dir "$clean_target" --check
before=$(snapshot_files "$clean_target")
sh "$installer" --target-dir "$clean_target"
after=$(snapshot_files "$clean_target")
[ "$before" = "$after" ] || fail "idempotent install changed current roles"
pass "clean install, exact check, and idempotence"

selective_target=$tmp_dir/selective
sh "$installer" --target-dir "$selective_target"
printf '%s\n' modified >> "$selective_target/$terra_file"
before=$(snapshot_files "$selective_target")
sh "$installer" --target-dir "$selective_target" --check --check-role luna --check-role sol
after=$(snapshot_files "$selective_target")
[ "$before" = "$after" ] || fail "selective Luna/Sol check mutated conflicting Terra target"
if sh "$installer" --target-dir "$selective_target" --check --check-role terra >/dev/null 2>&1; then
  fail "selective Terra check accepted conflicting Terra target"
fi
after=$(snapshot_files "$selective_target")
[ "$before" = "$after" ] || fail "selective Terra refusal mutated target"
if sh "$installer" --target-dir "$selective_target" --check >/dev/null 2>&1; then
  fail "all-role --check accepted conflicting Terra target"
fi
if sh "$installer" --target-dir "$selective_target" --check-role >/dev/null 2>&1; then
  fail "missing --check-role argument was accepted"
fi
if sh "$installer" --target-dir "$selective_target" --check-role unknown >/dev/null 2>&1; then
  fail "unknown --check-role argument was accepted"
fi
after=$(snapshot_files "$selective_target")
[ "$before" = "$after" ] || fail "invalid selective check mutated target"
pass "selective Luna/Sol check, Terra refusal, all-role compatibility, and invalid-role refusal"

upfront_terra_target=$tmp_dir/upfront-terra
sh "$installer" --target-dir "$upfront_terra_target"
printf '%s\n' modified >> "$upfront_terra_target/$luna_file"
before=$(snapshot_files "$upfront_terra_target")
sh "$installer" --target-dir "$upfront_terra_target" --check --check-role terra --check-role sol
after=$(snapshot_files "$upfront_terra_target")
[ "$before" = "$after" ] || fail "selective Terra/Sol check mutated conflicting Luna target"
if sh "$installer" --target-dir "$upfront_terra_target" --check --check-role luna >/dev/null 2>&1; then
  fail "selective Luna check accepted conflicting Luna target"
fi
after=$(snapshot_files "$upfront_terra_target")
[ "$before" = "$after" ] || fail "selective Luna refusal mutated target"
if sh "$installer" --target-dir "$upfront_terra_target" --check >/dev/null 2>&1; then
  fail "all-role --check accepted conflicting Luna target"
fi
after=$(snapshot_files "$upfront_terra_target")
[ "$before" = "$after" ] || fail "all-role Luna refusal mutated target"
pass "selective Terra/Sol up-front path, Luna refusal, and all-role compatibility"

missing_target=$tmp_dir/missing
if sh "$installer" --target-dir "$missing_target" --check; then fail "--check accepted missing target"; fi
test ! -e "$missing_target" || fail "--check mutated missing target"
pass "missing-target check refusal is non-mutating"

codex_home=$tmp_dir/codex-home
CODEX_HOME="$codex_home" sh "$installer"
for role in "$luna_file" "$terra_file" "$sol_file"; do
  cmp -s "$templates/$role" "$codex_home/agents/$role" || fail "CODEX_HOME install mismatch: $role"
done
test ! -e "$codex_home/config.toml" || fail "installer created config.toml"
relative_parent=$tmp_dir/relative-parent
mkdir "$relative_parent"
(cd "$relative_parent" && sh "$installer" --target-dir relative-agents)
cmp -s "$templates/$luna_file" "$relative_parent/relative-agents/$luna_file" || fail "relative target Luna mismatch"
pass "CODEX_HOME and relative target behavior"

migration_target=$tmp_dir/migration
write_legacy_roles "$migration_target"
sh "$installer" --target-dir "$migration_target"
for role in "$luna_file" "$terra_file" "$sol_file"; do
  cmp -s "$templates/$role" "$migration_target/$role" || fail "historical migration mismatch: $role"
done
sh "$installer" --target-dir "$migration_target" --check
pass "exact historical Luna/Terra migration"

v050_migration_target=$tmp_dir/v050-migration
write_v050_roles "$v050_migration_target"
sh "$installer" --target-dir "$v050_migration_target"
for role in "$luna_file" "$terra_file" "$sol_file"; do
  cmp -s "$templates/$role" "$v050_migration_target/$role" || fail "v0.5.0 migration mismatch: $role"
done
sh "$installer" --target-dir "$v050_migration_target" --check
pass "exact v0.5.0 Luna/Terra migration"

modified_v050_luna=$tmp_dir/modified-v050-luna
write_v050_roles "$modified_v050_luna"
printf 'X' >> "$modified_v050_luna/$luna_file"
before=$(snapshot_files "$modified_v050_luna")
if sh "$installer" --target-dir "$modified_v050_luna"; then fail "installer replaced modified v0.5.0 Luna"; fi
after=$(snapshot_files "$modified_v050_luna")
[ "$before" = "$after" ] || fail "modified v0.5.0 Luna refusal partially mutated target"
pass "modified v0.5.0 Luna refusal with zero partial mutation"

modified_v050_terra=$tmp_dir/modified-v050-terra
write_v050_roles "$modified_v050_terra"
printf 'X' >> "$modified_v050_terra/$terra_file"
before=$(snapshot_files "$modified_v050_terra")
if sh "$installer" --target-dir "$modified_v050_terra"; then fail "installer replaced modified v0.5.0 Terra"; fi
after=$(snapshot_files "$modified_v050_terra")
[ "$before" = "$after" ] || fail "modified v0.5.0 Terra refusal partially mutated target"
pass "modified v0.5.0 Terra refusal with zero partial mutation"

modified_luna=$tmp_dir/modified-luna
write_legacy_roles "$modified_luna"
printf '%s\n' modified >> "$modified_luna/$luna_file"
before=$(snapshot_files "$modified_luna")
if sh "$installer" --target-dir "$modified_luna"; then fail "installer replaced modified Luna"; fi
after=$(snapshot_files "$modified_luna")
[ "$before" = "$after" ] || fail "modified-Luna refusal partially mutated target"
pass "modified Luna refusal with zero partial mutation"

modified_terra=$tmp_dir/modified-terra
write_legacy_roles "$modified_terra"
printf '%s\n' modified >> "$modified_terra/$terra_file"
before=$(snapshot_files "$modified_terra")
if sh "$installer" --target-dir "$modified_terra"; then fail "installer replaced modified Terra"; fi
after=$(snapshot_files "$modified_terra")
[ "$before" = "$after" ] || fail "modified-Terra refusal partially mutated target"
pass "differing legacy Terra refusal with zero partial mutation"

modified_current=$tmp_dir/modified-current
sh "$installer" --target-dir "$modified_current"
printf '%s\n' modified >> "$modified_current/$luna_file"
before=$(snapshot_files "$modified_current")
if sh "$installer" --target-dir "$modified_current"; then fail "installer replaced modified current Luna"; fi
after=$(snapshot_files "$modified_current")
[ "$before" = "$after" ] || fail "modified current Luna refusal partially mutated target"
pass "modified current-role refusal with zero partial mutation"

unsafe=$tmp_dir/unsafe
mkdir "$unsafe"
ln -s "$templates/$luna_file" "$unsafe/$luna_file"
before=$(snapshot_files "$unsafe")
if sh "$installer" --target-dir "$unsafe"; then fail "installer accepted symlinked Luna"; fi
after=$(snapshot_files "$unsafe")
[ "$before" = "$after" ] || fail "symlink refusal partially mutated target"
test ! -e "$unsafe/$terra_file" || fail "symlink refusal partially installed Terra"
test ! -e "$unsafe/$sol_file" || fail "symlink refusal partially installed Sol"
pass "unsafe destination refusal with zero partial mutation"

runtime_sessions=$tmp_dir/runtime-sessions
runtime_day=$runtime_sessions/2026/08/15
mkdir -p "$runtime_day"
runtime_id=11111111-1111-7111-8111-111111111111
runtime_rollout=$runtime_day/rollout-2026-08-15T00-00-00-$runtime_id.jsonl
printf '%s\n' \
  '{"type":"response_item","payload":{"prompt":"DO_NOT_LEAK_PROMPT"}}' \
  "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$runtime_id\",\"parent_thread_id\":\"00000000-0000-7000-8000-000000000000\",\"agent_role\":\"sol_advisor_luna_implementer\",\"agent_path\":\"/root/fixture\",\"model_provider\":\"openai\",\"cwd\":\"/fixture\"}}" \
  '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"max","sandbox_policy":{"type":"danger-full-access"},"permission_profile":{"type":"disabled"},"cwd":"/fixture"}}' \
  > "$runtime_rollout"
runtime_output=$(sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$runtime_id")
printf '%s\n' "$runtime_output" | jq -e --arg id "$runtime_id" '
  .thread_id == $id and .agent_role == "sol_advisor_luna_implementer"
  and .model == "gpt-5.6-luna" and .effort == "max"
  and .sandbox_policy_type == "danger-full-access"
  and .permission_profile_type == "disabled"
' >/dev/null || fail "runtime inspector returned wrong Luna/Max evidence"
if printf '%s\n' "$runtime_output" | grep -Fq DO_NOT_LEAK; then fail "runtime inspector leaked payload"; fi
if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" invalid >/dev/null 2>&1; then fail "runtime inspector accepted invalid id"; fi
zero_id=22222222-2222-7222-8222-222222222222
if sh "$runtime_inspector" --sessions-dir "$runtime_sessions" "$zero_id" >/dev/null 2>&1; then fail "runtime inspector accepted zero matches"; fi
pass "runtime inspector Luna/Max routing and safe refusal"

for document in "$contracts" "$operations"; do
  grep -Fq 'agent_type: sol_advisor_luna_implementer' "$document" || fail "missing Luna spawn in $document"
  grep -Fq 'agent_type: sol_advisor_terra_implementer' "$document" || fail "missing Terra spawn in $document"
  grep -Fq 'agent_type: sol_advisor_sol_reviewer' "$document" || fail "missing Sol spawn in $document"
  grep -Fq 'fork_turns: none' "$document" || fail "missing fresh context in $document"
  if grep -Eq 'agent_type:.*terra_max' "$document"; then fail "retired Terra-Max spawn remains in $document"; fi
  if grep -Eq '^[[:space:]]*(model|reasoning_effort):' "$document"; then fail "per-spawn override remains in $document"; fi
done
grep -Fq 'references/operations.md' "$skill" || fail "skill does not link operations reference"
grep -Fq '../../scripts/install-agents.sh' "$operations" || fail "operations does not resolve installer relatively"
grep -Fq '../../scripts/inspect-agent-runtime.sh' "$operations" || fail "operations does not resolve inspector relatively"
grep -Fq 'normal routine path, run the selective Luna+Sol' "$skill" || fail "skill omits routine Luna/Sol starting path"
grep -Fq 'known complexity or high-risk work, run the selective Terra+Sol' "$skill" || fail "skill omits up-front Terra/Sol starting path"
grep -Fq 'Do not require Luna exposure' "$skill" || fail "skill preflights Luna on the up-front Terra path"
grep -Fq 'reuse the task-cached Sol result' "$skill" || fail "skill does not reuse cached Sol on escalation"
grep -Fqi 'public metadata' "$skill" || fail "skill lacks public-metadata evidence rule"
grep -Fqi 'local inspector' "$skill" || fail "skill lacks runtime fallback rule"
grep -Fqi 'parent captures and verifies exact before-and-after' "$contracts" || fail "contracts lack behavioral read-only state check"
grep -Fq 'normal routine path, run the selective Luna+Sol' "$contracts" || fail "contracts omit routine Luna/Sol starting path"
grep -Fq 'known complexity or high-risk work, run the selective Terra+Sol' "$contracts" || fail "contracts omit up-front Terra/Sol starting path"
grep -Fqi 'do not require Luna exposure' "$contracts" || fail "contracts preflight Luna on the up-front Terra path"
grep -Fq 'reuse the task-cached Sol result' "$contracts" || fail "contracts do not reuse cached Sol on escalation"
grep -Fqi 'first Luna result' "$skill" || fail "skill omits immediate Terra escalation"
grep -Fqi 'not a prerequisite' "$skill" || fail "skill makes corrected Luna mandatory"
grep -Fqi 'first result' "$contracts" || fail "contracts omit immediate Terra escalation"
grep -Fqi 'not a prerequisite' "$contracts" || fail "contracts make corrected Luna mandatory"
pass "native role contracts, task-scoped preflight, and escalation checks"

for phrase in \
  'agent_type: sol_advisor_luna_implementer' \
  'agent_type: sol_advisor_terra_implementer' \
  'agent_type: sol_advisor_sol_reviewer' \
  'fork_turns: none' \
  'task-scoped preflight' \
  'normal routine path' \
  'known complexity or high-risk work' \
  'Terra+Sol' \
  'reuse the successful Sol result' \
  'local inspector' \
  'sandbox_mode = read-only' \
  'install-agents.sh --check'; do
  grep -Fqi "$phrase" "$operations" || fail "operations reference omits: $phrase"
done
pass "operations reference preserves native operational detail"

readme_lines=$(wc -l < "$readme" | tr -d ' ')
[ "$readme_lines" -le 110 ] || fail "README remains maintainer-sized ($readme_lines lines)"
grep -Fq 'codex plugin marketplace add' "$readme" || fail "README omits marketplace quick start"
grep -Fq 'codex plugin add' "$readme" || fail "README omits plugin quick start"
grep -Fq 'scripts/install-agents.sh' "$readme" || fail "README omits companion install"
if grep -Eq 'agent_type:|fork_turns:|inspect-agent-runtime|sandbox_policy|sandbox_mode' "$readme"; then
  fail "README exposes maintainer routing/runtime machinery"
fi
if grep -Fq -- '--check' "$readme"; then
  fail "README quick start repeats the post-install --check"
fi
grep -Fq 'advanced native operations' "$readme" || fail "README omits operations link"
if grep -Fq 'or after one corrected Luna attempt' "$readme" ||
   grep -Fq 'corrected Luna attempt shows' "$readme"; then
  fail "README hero retains mandatory-retry Terra language"
fi
grep -Fq 'selected up front, or immediately' "$readme" || fail "README hero omits immediate Terra semantics"
grep -Fq 'You do not need to select or manage' "$readme" || fail "README asks users to manage lanes"
grep -Fq '## When Terra is used' "$readme" || fail "README omits Terra exception guidance"
grep -Fq 'Luna / Max access for the normal routine path' "$readme" || fail "README omits routine Luna access requirement"
grep -Fq 'GPT-5.6 Terra / High access is needed' "$readme" || fail "README omits conditional Terra access requirement"
grep -Fq 'only when escalation is selected.' "$readme" || fail "README implies unconditional Terra access"
grep -Fq 'Terra / High access is conditional' "$readme" || fail "README omits conditional Terra access guidance"
python3 - "$readme" <<'PY'
from pathlib import Path
import sys

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
install_lines = [line for line in lines if line.startswith("plugin_dir=\"") and "scripts/install-agents.sh" in line]
if len(install_lines) != 2:
    raise SystemExit(f"expected two guarded companion install examples, found {len(install_lines)}")
for line in install_lines:
    required = [
        'test -n "$plugin_dir"',
        'test "$plugin_dir" != null',
        'test -d "$plugin_dir"',
        'test -f "$plugin_dir/scripts/install-agents.sh"',
    ]
    if any(check not in line for check in required):
        raise SystemExit(f"unguarded companion install example: {line}")
    if line.index("sh \"") < line.index(required[-1]):
        raise SystemExit(f"installer executes before directory/file guards: {line}")
print("two companion install examples are fail-closed and guarded")
PY
pass "README is concise, user-first, and keeps maintainer machinery out"

python3 - "$readme" "$manifest" "$skill" "$contracts" "$operations" "$ui" "$templates" <<'PY'
from pathlib import Path
import sys

roots = [Path(value) for value in sys.argv[1:]]
terms = [
    "list_" + "projects",
    "list_" + "threads",
    "create_" + "thread",
    "wait_" + "threads",
    "read_" + "thread",
    "send_" + "message_to_thread",
    "client" + "ThreadId",
    "app-" + "task",
    "app " + "task",
    "Luna " + "task",
    "task-" + "lane",
]
paths = []
for root in roots:
    if root.is_file():
        paths.append(root)
    elif root.is_dir():
        paths.extend(path for path in root.rglob("*") if path.is_file())
for path in paths:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for term in terms:
        if term in text:
            raise SystemExit(f"obsolete workflow reference {term!r} remains in {path}")
print("obsolete workflow references are absent")
PY

grep -Fq 'Sol / High plans' "$readme" || fail "README omits plain normal path"
grep -Fq 'Luna / Max' "$readme" || fail "README omits Luna / Max routine path"
grep -Fq 'Terra /' "$readme" || fail "README omits Terra escalation path"
grep -Fq 'one corrected Luna attempt' "$readme" || fail "README omits corrected-attempt escalation"
grep -Fq 'Attention Heads' "$readme" || fail "README lost Attention Heads section"
grep -Fq 'https://attentionheads.substack.com/?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor' "$readme" || fail "README changed Attention Heads link"
grep -Fq 'https://attentionheads.substack.com/subscribe?utm_source=github&utm_medium=readme&utm_campaign=sol-advisor' "$readme" || fail "README changed Subscribe link"
pass "README normal path, escalation, and preserved Go deeper links"

for document in "$readme" "$manifest" "$skill" "$contracts" "$ui"; do
  if grep -Eqi 'Terra / High is the sole implementation producer|one role-pinned .*handles all implementation|route all implementation through.*Terra|delegate all implementation to (the )?(native )?Terra' "$document"; then
    fail "stale single-mode implementation claim remains in $document"
  fi
done
for forbidden in sol_advisor_terra_max sol-advisor-terra-max; do
  if rg -n "$forbidden" "$readme" "$manifest" "$skill" "$contracts" "$ui" "$templates"; then fail "forbidden second Terra role remains"; fi
done
pass "obsolete single-lane claims and second Terra role absent"

sh -n "$installer"
sh -n "$runtime_inspector"
sh -n "$script_dir/verify.sh"
pass "shell syntax"

printf '%s\n' "VERIFY PASSED: Sol Advisor native three-role checks completed in $tmp_dir"
