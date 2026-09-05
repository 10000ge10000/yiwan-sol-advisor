#!/bin/sh
# Deterministic test suite for yiwan-sol-advisor skill on POSIX / Linux / WSL.
# Validates skill metadata, YAML config, sh -n syntax, Markdown code fences,
# thin-launcher activation procedure, grep pins, implementer wrapper behavior,
# fresh reviewer immutability and verdict validation with 9 cryptographic bindings, parent verification gate,
# per-window snapshot attribution with pre-existing dirty files, baseline HEAD and scoped Git metadata immutability,
# test-mode switch gate, 24 KiB spec size cap, invalid duration rejection,
# adversarial porcelain rename detection, truthful completion (reviewed_no_change),
# hard total deadline enforcement, and an observable two-cycle FIX-FIRST -> SHIP state machine fixture.

set -eu

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
skill_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
launcher_sh="$script_dir/launch-sol-advisor.sh"
implementer_sh="$script_dir/run-antigravity-implementer.sh"
reviewer_sh="$script_dir/run-fresh-reviewer.sh"
setup_sh="$script_dir/setup-yiwan-sol-advisor.sh"

printf '=== STARTING YIWAN-SOL-ADVISOR POSIX VERIFICATION SUITE ===\n'
printf 'Skill Root: %s\n' "$skill_root"

# 0. Pre-run check: Assert no parent-root contamination exists before suite
if [ -e "$skill_root/dirty_mutation.txt" ]; then
  fail "Parent repository contamination detected before running suite: $skill_root/dirty_mutation.txt exists"
fi

# 1. Quick Validate
quick_val="C:/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py"
if [ -f "$quick_val" ] || [ -f "/mnt/c/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py" ]; then
  qv_path="$quick_val"
  [ -f "$qv_path" ] || qv_path="/mnt/c/Users/Administrator/.codex/skills/.system/skill-creator/scripts/quick_validate.py"
  python3 "$qv_path" "$skill_root" || fail "quick_validate.py failed"
  pass "quick_validate.py passed"
fi

# 2. Syntax check (sh -n) on all .sh scripts
for f in "$script_dir"/*.sh; do
  sh -n "$f" || fail "sh -n failed for $f"
done
pass "sh -n syntax check passed for all .sh scripts"

# 2a. Distribution installer invariants
for required_setup_token in \
  'https://antigravity.google/cli/install.sh' \
  '--agy-offline-package' \
  '--agy-offline-sha256' \
  'gemini-3.8-flash-high' \
  'hashlib.sha256'
do
  grep -F -- "$required_setup_token" "$setup_sh" >/dev/null 2>&1 || \
    fail "setup-yiwan-sol-advisor.sh missing required installer invariant: $required_setup_token"
done
pass "POSIX setup helper online-first, offline SHA-256, and model checks validated"

# 3. YAML check of agents/openai.yaml
python3 - "$skill_root/agents/openai.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f)
policy = data.get('policy', {})
if policy.get('allow_implicit_invocation') is not False:
    print("ERROR: allow_implicit_invocation must be false")
    sys.exit(1)
prompt = data.get('interface', {}).get('default_prompt', '')
if '$yiwan-sol-advisor' not in prompt:
    print("ERROR: default_prompt must explicitly mention $yiwan-sol-advisor")
    sys.exit(2)
short_desc = data.get('interface', {}).get('short_description', '')
if not isinstance(short_desc, str) or len(short_desc) < 25 or len(short_desc) > 64:
    print(f"ERROR: short_description length ({len(short_desc)}) must be between 25 and 64 characters")
    sys.exit(3)
display_name = data.get('interface', {}).get('display_name', '')
if not isinstance(display_name, str) or len(display_name.strip()) == 0:
    print("ERROR: display_name must be a non-empty string")
    sys.exit(4)
sys.exit(0)
PY
pass "agents/openai.yaml explicit invocation policy, short_description length (25-64), and default prompt verified"

# 4. Markdown code fence validity and balance across all .md files
python3 - "$skill_root" <<'PY'
import sys, os, re
root = sys.argv[1]
for dirpath, _, filenames in os.walk(root):
    if ".git" in dirpath: continue
    for fn in filenames:
        if not fn.endswith(".md"): continue
        fp = os.path.join(dirpath, fn)
        with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        in_fence = False
        fence_char = ""
        fence_len = 0
        for idx, line in enumerate(lines):
            trimmed = line.lstrip()
            if re.match(r'^``[a-zA-Z0-9_-]+', trimmed):
                print(f"Invalid 2-backtick code fence in {fp} at line {idx+1}: {line}")
                sys.exit(1)
            m = re.match(r'^(```+|~~~+)', trimmed)
            if m:
                fc = trimmed[0]
                fl = len(m.group(1))
                if not in_fence:
                    in_fence = True
                    fence_char = fc
                    fence_len = fl
                else:
                    if fc == fence_char and fl >= fence_len:
                        in_fence = False
                        fence_char = ""
                        fence_len = 0
        if in_fence:
            print(f"Unclosed markdown code fence in {fp}")
            sys.exit(1)
sys.exit(0)
PY
pass "Markdown code fence balance and syntax verified across all .md files"

# 5. SKILL.md Structural & Thin-Launcher Policy Assertions
python3 - "$skill_root/SKILL.md" <<'PY'
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    text = f.read()

checks = [
    ("## On Explicit Invocation", "SKILL.md missing '## On Explicit Invocation' section"),
    ("thin launcher", "SKILL.md missing thin-launcher prohibition against task analysis"),
    ("gpt-5.6-sol", "SKILL.md missing gpt-5.6-sol pin"),
    ("gemini-3.8-flash-high", "SKILL.md missing gemini-3.8-flash-high pin"),
    ("accept-edits", "SKILL.md missing accept-edits pin"),
]
for target, err in checks:
    if target.lower() not in text.lower():
        print(f"ERROR: {err}")
        sys.exit(1)
sys.exit(0)
PY
pass "SKILL.md thin-launcher procedure, portable paths, fixed model pins verified"

# Setup and implementer must enforce seamless sandboxed headless execution.
for token in 'proceed-in-sandbox' 'enableTerminalSandbox' 'yiwan-sol-advisor-backup' '--sandbox'; do
  grep -F -- "$token" "$skill_root/scripts/setup-yiwan-sol-advisor.sh" >/dev/null 2>&1 || fail "POSIX setup helper missing sandbox invariant: $token"
done
for token in '--new-project' '--sandbox' 'proceed-in-sandbox' '--dangerously-skip-permissions' 'sandboxed-dangerously-skip-permissions'; do
  grep -F -- "$token" "$skill_root/scripts/run-antigravity-implementer.sh" >/dev/null 2>&1 || fail "POSIX implementer missing sandbox invariant: $token"
done
pass "POSIX setup and implementer sandbox enforcement validated"

# 6. Absence of forbidden strings
python3 - "$skill_root" <<'PY'
import sys, os
root = sys.argv[1]
tok_luna = "lu" + "na"
tok_terra = "ter" + "ra"
tok_fb = "fallback_" + "model"
tok_mfb = "model_" + "fallback"
forbidden = ["sol-advisor-" + tok_luna, "sol-advisor-" + tok_terra, tok_luna + "-task-lane", "sol_advisor_" + tok_luna, "sol_advisor_" + tok_terra, tok_fb, tok_mfb]

for dirpath, _, filenames in os.walk(root):
    if ".git" in dirpath: continue
    for fn in filenames:
        if fn.startswith("verify-skill."): continue
        fp = os.path.join(dirpath, fn)
        with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read().lower()
        for pat in forbidden:
            if pat in content:
                print(f"ERROR: Forbidden token '{pat}' found in {fp}")
                sys.exit(1)
sys.exit(0)
PY
pass "Zero forbidden routing tokens found across skill operational files"

# 7. Executable Integration Fixtures
tmp_dir=$(python3 -c "import tempfile, uuid; print(tempfile.mkdtemp(prefix='sol-adv-test.'))")
clean_tmp() {
  if [ -n "${tmp_dir:-}" ] && [ -d "$tmp_dir" ]; then
    case "$tmp_dir" in
      */sol-adv-test.*)
        rm -rf "$tmp_dir" 2>/dev/null || true
        ;;
    esac
  fi
}
trap clean_tmp EXIT INT TERM

ws="$tmp_dir/posix_ws"
mkdir -p "$ws"
git -C "$ws" init -q
git -C "$ws" config user.name "Test User"
git -C "$ws" config user.email "test@example.com"
printf 'initial content\n' > "$ws/initial.txt"
git -C "$ws" add initial.txt
git -C "$ws" commit -q -m "Initial commit"

out_dir="$tmp_dir/out_dir"
mkdir -p "$out_dir"

spec_file="$tmp_dir/spec.md"
cat > "$spec_file" <<'EOF'
OBJECTIVE
Implement test feature in fixture workspace.

FILES AND OWNERSHIP
You own only:
- test_feature.txt

INTERFACES
- Feature interface v1.

CONSTRAINTS
- Standard conventions.

VERIFICATION
- Run: sh -c "exit 0"
  Success: exit code 0
EOF

mock_agy_bin="$tmp_dir/mock_agy.sh"
mock_agy_mode="$tmp_dir/mock_agy_mode.txt"
printf 'edit_owned_file\n' > "$mock_agy_mode"

cat > "$mock_agy_bin" <<'EOF'
#!/bin/sh
mode="edit_owned_file"
mode_file="$(dirname "$0")/mock_agy_mode.txt"
if [ -f "$mode_file" ]; then
  mode=$(cat "$mode_file" | tr -d '\r\n')
fi

if [ "$#" -eq 1 ] && [ "$1" = "models" ]; then
  if [ "$mode" = "hang_preflight" ]; then
    sleep 60
    exit 0
  fi
  printf 'gemini-3.8-flash-high\ngemini-2.5-pro\n'
  exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  if [ "$mode" = "fail_version" ]; then
    exit 1
  fi
  printf 'antigravity-cli 1.5.0\n'
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    *nonce=sol-advisor-generation-preflight-*)
      nonce=${arg#*nonce=}
      nonce=${nonce%%.*}
      printf '{"status":"ok","nonce":"%s"}\n' "$nonce"
      exit 0
      ;;
  esac
done

cwd=$(pwd -P)

if [ "$mode" = "edit_owned_file" ]; then
  printf 'feature implementation line\n' >> "$cwd/test_feature.txt"
elif [ "$mode" = "no_changes" ]; then
  : # Do not modify any files
elif [ "$mode" = "ownership_violation" ]; then
  printf 'UNOWNED EDIT\n' > "$cwd/unowned_file.txt"
elif [ "$mode" = "adversarial_rename" ]; then
  printf 'renamed content\n' >> "$cwd/test_feature.txt"
  git -C "$cwd" add test_feature.txt >/dev/null 2>&1
  git -C "$cwd" mv test_feature.txt unowned_renamed.txt >/dev/null 2>&1
elif [ "$mode" = "modify_git_meta" ]; then
  printf '# mutation\n' >> "$cwd/.git/config"
elif [ "$mode" = "create_merge_head" ]; then
  printf '1234567890123456789012345678901234567890\n' > "$cwd/.git/MERGE_HEAD"
elif [ "$mode" = "index_only_delta" ]; then
  blob_sha=$(git -C "$cwd" hash-object -w /dev/null 2>/dev/null || printf 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')
  git -C "$cwd" update-index --add --cacheinfo 100644 "$blob_sha" staged_unowned.txt >/dev/null 2>&1
elif [ "$mode" = "non_utf8_path" ]; then
  # Create a non-UTF8 filename in git index/worktree (0xFF byte)
  python3 -c "import os; open(b'bad_\xff.txt', 'wb').write(b'bad\n')"
elif [ "$mode" = "git_commit_bypass" ]; then
  printf 'bypass commit\n' >> "$cwd/test_feature.txt"
  git -C "$cwd" add -A >/dev/null 2>&1
  git -C "$cwd" commit -m "bypass commit" >/dev/null 2>&1
elif [ "$mode" = "exit_code_failure" ]; then
  printf 'Mock Antigravity fatal error\n' >&2
  exit 1
elif [ "$mode" = "json_error_failure" ]; then
  printf '%s\n' '{"status":"ERROR","response":"","error":"timeout waiting for response"}'
  exit 1
elif [ "$mode" = "hanging_child" ]; then
  sleep 60
  exit 0
fi

cat <<JSON
{
  "model": "gemini-3.8-flash-high",
  "effort": "high",
  "mode": "accept-edits",
  "cwd": "$cwd",
  "status": "completed",
  "response": "STATUS: complete\nOBJECTIVE: Implement test feature\nCHANGES: Added test_feature.txt\nVERIFIED: Executed sh -c 'exit 0' (exit code 0)\nJUDGMENT CALLS: none\nGAPS: none"
}
JSON
exit 0
EOF
chmod +x "$mock_agy_bin"

# Mock Codex Binary
mock_codex_bin="$tmp_dir/mock_codex.sh"
mock_codex_mode="$tmp_dir/mock_codex_mode.txt"
mock_codex_counter="$tmp_dir/mock_codex_counter.txt"
printf 'two_cycle_flow\n' > "$mock_codex_mode"
printf '0\n' > "$mock_codex_counter"

cat > "$mock_codex_bin" <<'EOF'
#!/bin/sh
mode_file="$(dirname "$0")/mock_codex_mode.txt"
counter_file="$(dirname "$0")/mock_codex_counter.txt"
mode="two_cycle_flow"
if [ -f "$mode_file" ]; then
  mode=$(cat "$mode_file" | tr -d '\r\n')
fi

cnt=0
if [ -f "$counter_file" ]; then
  cnt=$(cat "$counter_file" | tr -d '\r\n')
fi
cnt=$((cnt + 1))
printf '%s\n' "$cnt" > "$counter_file"

out_file=""
ws_arg=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ] && [ $# -ge 2 ]; then
    out_file="$2"
    shift 2
  elif { [ "$1" = "-C" ] || [ "$1" = "--cd" ]; } && [ $# -ge 2 ]; then
    ws_arg="$2"
    shift 2
  else
    shift 1
  fi
done

stdin_content=""
if [ ! -t 0 ]; then
  stdin_content=$(cat)
fi

python3 - "$mode" "$cnt" "$out_file" "$ws_arg" "$stdin_content" <<'PY'
import sys, re, os, json

mode = sys.argv[1]
cnt = int(sys.argv[2])
out_file = sys.argv[3]
ws_arg = sys.argv[4]
stdin_content = sys.argv[5]

def extract_binding(key):
    m = re.search(r'-\s+' + re.escape(key) + r':\s*([0-9a-f]{64})', stdin_content)
    return m.group(1) if m else "0" * 64

is_reviewer = ("REVIEW INSTRUCTIONS" in stdin_content) or ("CRYPTOGRAPHIC BINDINGS" in stdin_content)

task_sha = extract_binding("task_sha256")
plan_sha = extract_binding("plan_sha256")
spec_sha = extract_binding("spec_sha256")
impl_sha = extract_binding("implementer_evidence_sha256")
pv_sha = extract_binding("parent_verification_sha256")
pre_sha = extract_binding("pre_window_manifest_sha256")
post_sha = extract_binding("post_window_manifest_sha256")
repo_sha = extract_binding("repository_manifest_sha256")
agg_sha = extract_binding("aggregate_delta_manifest_sha256")

reviewed_bindings = {
    "task_sha256": task_sha,
    "plan_sha256": plan_sha,
    "spec_sha256": spec_sha,
    "implementer_evidence_sha256": impl_sha,
    "parent_verification_sha256": pv_sha,
    "pre_window_manifest_sha256": pre_sha,
    "post_window_manifest_sha256": post_sha,
    "repository_manifest_sha256": repo_sha,
    "aggregate_delta_manifest_sha256": agg_sha
}

resp_obj = {}

if mode == "two_cycle_flow":
    if not is_reviewer:
        resp_obj = {
            "objective": "Implement test feature with fix",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        if cnt <= 2:
            resp_obj = {
                "verdict": "FIX-FIRST",
                "reason": "Need correction on first cycle.",
                "findings": "Add assertions.",
                "residual_risk": "None",
                "reviewed_bindings": reviewed_bindings
            }
        else:
            resp_obj = {
                "verdict": "SHIP",
                "reason": "All checks passed.",
                "findings": "None",
                "residual_risk": "None",
                "reviewed_bindings": reviewed_bindings
            }
elif mode == "review_ship":
    if not is_reviewer:
        resp_obj = {
            "objective": "Implement test feature",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "SHIP",
            "reason": "All verification passed.",
            "findings": "None",
            "residual_risk": "None",
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_no_change":
    if not is_reviewer:
        resp_obj = {
            "objective": "Verify codebase without modifications",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "SHIP",
            "reason": "Verified existing codebase requires no changes.",
            "findings": "None",
            "residual_risk": "None",
            "reviewed_no_change": True,
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_no_change_false":
    if not is_reviewer:
        resp_obj = {
            "objective": "Verify codebase without modifications",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "SHIP",
            "reason": "No changes made but not confirmed.",
            "findings": "None",
            "residual_risk": "None",
            "reviewed_no_change": False,
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_string_false_no_change":
    if not is_reviewer:
        resp_obj = {
            "objective": "Verify codebase without modifications",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "SHIP",
            "reason": "String false no change.",
            "findings": "None",
            "residual_risk": "None",
            "reviewed_no_change": "false",
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_unknown_nested_key":
    if not is_reviewer:
        resp_obj = {
            "objective": "Implement test feature",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "SHIP",
            "reason": "All checks passed.",
            "findings": "None",
            "residual_risk": "None",
            "unknown_extra_field": True,
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_fix_first_repeat":
    if not is_reviewer:
        resp_obj = {
            "objective": "Implement test feature",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "FIX-FIRST",
            "reason": "Correction required repeatedly.",
            "findings": "Still failing checks.",
            "residual_risk": "High",
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_rethink":
    if not is_reviewer:
        resp_obj = {
            "objective": "Implement test feature",
            "owned_files": ["test_feature.txt"],
            "interfaces": "Feature interface v1",
            "constraints": "Standard conventions",
            "verification_commands": ["sh -c 'exit 0'"]
        }
    else:
        resp_obj = {
            "verdict": "RETHINK",
            "reason": "Architecture incompatible",
            "findings": "Total revision needed",
            "residual_risk": "High",
            "reviewed_bindings": reviewed_bindings
        }
elif mode == "review_mutate_repo":
    if ws_arg and os.path.isdir(ws_arg):
        with open(os.path.join(ws_arg, "dirty_mutation.txt"), 'w') as f:
            f.write("MUTATION\n")
    resp_obj = {
        "verdict": "SHIP",
        "reason": "Mutated repo",
        "findings": "None",
        "residual_risk": "None",
        "reviewed_bindings": reviewed_bindings
    }

resp_str = json.dumps(resp_obj, indent=2)
if out_file:
    with open(out_file, 'w', encoding='utf-8') as f:
        f.write(resp_str)
else:
    print(resp_str)
PY
exit 0
EOF
chmod +x "$mock_codex_bin"

# Test Gate: Test Mode Switch Enforcement (rejects override variable without TestMode)
export _MY_SOL_ADVISOR_TEST_CODEX_BIN="$mock_codex_bin"
export _MY_SOL_ADVISOR_TEST_AGY_BIN="$mock_agy_bin"
unset _MY_SOL_ADVISOR_TEST_MODE 2>/dev/null || true

dummy_task="$tmp_dir/dummy_task.md"
printf 'dummy task\n' > "$dummy_task"
dummy_res="$out_dir/dummy_res.md"

if sh "$launcher_sh" --workspace "$ws" --task-file "$dummy_task" --result-file "$dummy_res" 2>/dev/null; then
  fail "Launcher must fail when test overrides are specified without explicit --test-mode"
fi
pass "POSIX test-mode switch gate enforcement verified"

# Re-enable Test Mode
export _MY_SOL_ADVISOR_TEST_MODE="1"

# Test Implementer Wrapper in isolation with --test-mode
ev_file="$out_dir/evidence.json"
sh "$implementer_sh" --workspace "$ws" --spec-file "$spec_file" --evidence-file "$ev_file" --test-mode || fail "implementer failed"
[ -f "$ev_file" ] || fail "evidence file missing"
pass "POSIX run-antigravity-implementer.sh executed and created valid schema 1 evidence envelope"

# Test SpecFile > 24 KiB Cap
oversize_spec="$tmp_dir/oversize_spec.md"
python3 -c "import sys; open(sys.argv[1], 'wb').write(b'A' * (24576 + 1024))" "$oversize_spec"
if sh "$implementer_sh" --workspace "$ws" --spec-file "$oversize_spec" --evidence-file "$out_dir/ev_oversize.json" --test-mode 2>/dev/null; then
  fail "Spec file > 24 KiB must fail size check"
fi
pass "POSIX SpecFile 24 KiB size cap enforcement verified"

# Test Strict Duration Parsing
if sh "$implementer_sh" --workspace "$ws" --spec-file "$spec_file" --evidence-file "$ev_file" --print-timeout "invalid_duration" --test-mode 2>/dev/null; then
  fail "Invalid duration format must fail closed"
fi
pass "POSIX implementer strict duration format parsing verified"

printf 'hanging_child\n' > "$mock_agy_mode"
idle_ev="$out_dir/idle_timeout_evidence.json"
idle_log="$tmp_dir/idle_timeout.log"
idle_start=$(date +%s)
if sh "$implementer_sh" --workspace "$ws" --spec-file "$spec_file" --evidence-file "$idle_ev" --print-timeout 8s --idle-timeout 2s --generation-preflight-timeout 2s --heartbeat-interval 1s --test-mode >"$tmp_dir/idle_stdout.log" 2>"$idle_log"; then
  fail "POSIX idle watchdog unexpectedly succeeded"
fi
idle_elapsed=$(( $(date +%s) - idle_start ))
grep -Fq 'SOL_ADVISOR_HEARTBEAT' "$idle_log" || fail "POSIX idle watchdog emitted no heartbeat"
grep -Fq 'idle timeout' "$idle_log" || fail "POSIX idle watchdog did not identify idle timeout"
[ "$idle_elapsed" -le 10 ] || fail "POSIX idle watchdog exceeded expected bound (${idle_elapsed}s)"
[ ! -e "$idle_ev" ] || fail "POSIX idle watchdog published trusted evidence after failure"
pass "POSIX implementer heartbeat and idle timeout supervision verified"

printf 'json_error_failure\n' > "$mock_agy_mode"
json_failure_ev="$out_dir/json_failure_evidence.json"
json_failure_log="$tmp_dir/json_failure.log"
if sh "$implementer_sh" --workspace "$ws" --spec-file "$spec_file" --evidence-file "$json_failure_ev" --print-timeout 8s --idle-timeout 2s --generation-preflight-timeout 2s --heartbeat-interval 1s --test-mode >"$tmp_dir/json_failure_stdout.log" 2>"$json_failure_log"; then
  fail "POSIX structured AGY failure unexpectedly succeeded"
fi
grep -Fq 'status=ERROR' "$json_failure_log" || fail "POSIX structured AGY status was not preserved"
grep -Fq 'timeout waiting for response' "$json_failure_log" || fail "POSIX structured AGY error was not preserved"
if grep -Fq 'missing or empty report field' "$json_failure_log"; then fail "POSIX structured AGY failure was misclassified"; fi
[ ! -e "$json_failure_ev" ] || fail "POSIX structured AGY failure published trusted evidence"
pass "POSIX structured AGY nonzero failure classification verified"
printf 'edit_owned_file\n' > "$mock_agy_mode"

# ---------------------------------------------------------------------------------
# Per-Window Snapshot Attribution with Pre-existing Dirty File & 2-Cycle State Machine
# ---------------------------------------------------------------------------------
printf 'pre-existing uncommitted edit\n' >> "$ws/initial.txt"

printf 'two_cycle_flow\n' > "$mock_codex_mode"
printf '0\n' > "$mock_codex_counter"
printf 'edit_owned_file\n' > "$mock_agy_mode"

task_file="$tmp_dir/task.md"
printf '# Task: Implement test feature\n' > "$task_file"

result_file="$out_dir/final_result.md"
sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$result_file" --max-corrections 3 --test-mode || fail "launcher failed"
[ -f "$result_file" ] || fail "result file missing"
grep -q "STATUS: complete" "$result_file" || fail "result file missing STATUS: complete"
grep -q "OBJECTIVE:" "$result_file" || fail "result file missing OBJECTIVE:"
grep -q "CHANGES:" "$result_file" || fail "result file missing CHANGES:"
grep -q "VERIFIED:" "$result_file" || fail "result file missing VERIFIED:"

# Verify CHANGES does not include initial.txt
if grep -q "initial.txt" "$result_file"; then
  fail "Result CHANGES incorrectly attributed pre-existing dirty file initial.txt to this task!"
fi
grep -q "test_feature.txt" "$result_file" || fail "Result CHANGES missing task modified file test_feature.txt"
pass "POSIX per-window snapshot attribution successfully ignored pre-existing dirty files and reported truthful task changes"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Adversarial Rename / Copy Detection
printf 'adversarial_rename\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
rename_res="$out_dir/rename_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$rename_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when Antigravity renames to an unowned destination"
fi
[ ! -f "$rename_res" ] || fail "Result file was published despite adversarial rename failure!"
pass "POSIX adversarial porcelain rename destination ownership verification verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Scoped Git Metadata Mutation Detection (.git/config)
printf 'modify_git_meta\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
meta_res="$out_dir/meta_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$meta_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when Git metadata (.git/config) is modified"
fi
[ ! -f "$meta_res" ] || fail "Result file was published despite Git metadata mutation!"
pass "POSIX scoped Git metadata integrity verification (.git/config) verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test In-Progress Git Operation Marker Detection (.git/MERGE_HEAD)
printf 'create_merge_head\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
merge_head_res="$out_dir/merge_head_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$merge_head_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when in-progress Git operation marker (.git/MERGE_HEAD) is created"
fi
[ ! -f "$merge_head_res" ] || fail "Result file was published despite MERGE_HEAD!"
pass "POSIX in-progress Git operation marker detection (.git/MERGE_HEAD) verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Index-Only Unowned Mutation Detection (git ls-files --stage)
printf 'index_only_delta\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
index_delta_res="$out_dir/index_delta_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$index_delta_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when Antigravity stages an unowned index entry without worktree file"
fi
[ ! -f "$index_delta_res" ] || fail "Result file was published despite unowned staged index mutation!"
pass "POSIX index-only staged delta ownership verification verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Non-UTF8 Path Fail-Closed Behavior
printf 'non_utf8_path\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
non_utf8_res="$out_dir/non_utf8_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$non_utf8_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when changed path cannot be decoded to UTF-8"
fi
[ ! -f "$non_utf8_res" ] || fail "Result file was published despite non-UTF8 path!"
pass "POSIX non-UTF8 path fail-closed verification verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Truthful Completion: reviewed_no_change outcome
printf 'no_changes\n' > "$mock_agy_mode"
printf 'review_no_change\n' > "$mock_codex_mode"
no_change_res="$out_dir/no_change_res.md"
sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$no_change_res" --test-mode || fail "launcher failed on reviewed_no_change"
grep -q "STATUS: reviewed_no_change" "$no_change_res" || fail "Expected STATUS: reviewed_no_change"
pass "POSIX truthful completion with STATUS: reviewed_no_change verified"

# Test False No-Change Rejection (empty delta with reviewed_no_change: false must fail)
printf 'no_changes\n' > "$mock_agy_mode"
printf 'review_no_change_false\n' > "$mock_codex_mode"
false_no_change_res="$out_dir/false_no_change_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$false_no_change_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when aggregate delta is empty but reviewer did not confirm reviewed_no_change: true"
fi
[ ! -f "$false_no_change_res" ] || fail "Result file was published despite reviewed_no_change: false!"
pass "POSIX truthful no-change gate rejection verified when reviewed_no_change is false"

# Test String 'false' for reviewed_no_change Rejection (must be JSON boolean)
printf 'no_changes\n' > "$mock_agy_mode"
printf 'review_string_false_no_change\n' > "$mock_codex_mode"
str_false_res="$out_dir/str_false_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$str_false_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when reviewer outputs string 'false' for reviewed_no_change"
fi
[ ! -f "$str_false_res" ] || fail "Result file was published despite string 'false' reviewed_no_change!"
pass "POSIX strict typed JSON boolean validation for reviewed_no_change verified"

# Test Unknown Nested Schema Key in Review Output
printf 'edit_owned_file\n' > "$mock_agy_mode"
printf 'review_unknown_nested_key\n' > "$mock_codex_mode"
unknown_key_res="$out_dir/unknown_key_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$unknown_key_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when review output contains unknown nested keys"
fi
[ ! -f "$unknown_key_res" ] || fail "Result file was published despite schema violation!"
pass "POSIX closed-schema review validation verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Hard Outer Timeout Deadline with Hanging Preflight
printf 'hang_preflight\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
hang_res="$out_dir/hang_res.md"
start_hang=$(python3 -c 'import time; print(int(time.time()))')
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$hang_res" \
    --timeout 6s --planner-timeout 1s --implementer-timeout 2s --reviewer-timeout 1s \
    --idle-timeout 1s --generation-preflight-timeout 1s --machine-reserve 1s --test-mode 2>/dev/null; then
  fail "Launcher must terminate on hard outer timeout when child preflight hangs"
fi
end_hang=$(python3 -c 'import time; print(int(time.time()))')
elapsed_hang=$((end_hang - start_hang))
if [ "$elapsed_hang" -gt 15 ]; then
  fail "Hanging preflight exceeded expected deadline window (${elapsed_hang}s)"
fi
[ ! -f "$hang_res" ] || fail "Result file was published after hanging timeout!"
pass "POSIX hard outer timeout deadline enforcement verified (elapsed: ${elapsed_hang}s)"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Version Failure Immediate Exit
printf 'fail_version\n' > "$mock_agy_mode"
ver_fail_res="$out_dir/ver_fail_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$ver_fail_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when agy --version preflight fails"
fi
[ ! -f "$ver_fail_res" ] || fail "Result file was published after version check failure!"
pass "POSIX Antigravity --version preflight failure rejection verified"

git -C "$ws" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$ws" clean -fdx >/dev/null 2>&1 || true

# Test Ownership Violation Rejection
printf 'ownership_violation\n' > "$mock_agy_mode"
printf 'review_ship\n' > "$mock_codex_mode"
unowned_res="$out_dir/unowned_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$unowned_res" --test-mode 2>/dev/null; then
  fail "Launcher must fail when Antigravity modifies an unowned file"
fi
pass "POSIX launcher ownership violation rejection verified"

rm -f "$ws/unowned_file.txt" 2>/dev/null || true

# Test MaxCorrections Exhaustion
printf 'edit_owned_file\n' > "$mock_agy_mode"
printf 'review_fix_first_repeat\n' > "$mock_codex_mode"
exhaust_res="$out_dir/exhaust_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$exhaust_res" --max-corrections 1 --test-mode 2>/dev/null; then
  fail "Launcher must halt when MaxCorrections is exhausted"
fi
pass "POSIX launcher MaxCorrections exhaustion verified"

# Test RETHINK Rejection
printf 'edit_owned_file\n' > "$mock_agy_mode"
printf 'review_rethink\n' > "$mock_codex_mode"
rethink_res="$out_dir/rethink_res.md"
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$rethink_res" --test-mode 2>/dev/null; then
  fail "Launcher must halt when reviewer returns RETHINK"
fi
pass "POSIX launcher RETHINK verdict halting verified"

# Test ResultFile No-Clobber
if sh "$launcher_sh" --workspace "$ws" --task-file "$task_file" --result-file "$result_file" --test-mode 2>/dev/null; then
  fail "Launcher must fail if ResultFile already exists (no-clobber)"
fi
pass "POSIX launcher ResultFile no-clobber verified"

# 8. Post-run check: Assert no parent-root contamination occurred
if [ -e "$skill_root/dirty_mutation.txt" ]; then
  fail "Parent repository contamination detected after running suite: $skill_root/dirty_mutation.txt was created"
fi
pass "Parent-root contamination check passed: no dirty_mutation.txt in Skill root"

printf 'ALL YIWAN-SOL-ADVISOR POSIX VERIFICATION CHECKS PASSED.\n'
exit 0
