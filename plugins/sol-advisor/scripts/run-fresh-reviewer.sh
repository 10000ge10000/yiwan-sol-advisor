#!/bin/sh
# Deterministic fresh-review mechanism for yiwan-sol-advisor (POSIX / Linux / WSL).
# Starts a separate ephemeral read-only gpt-5.6-sol Codex process using inherited user reasoning effort,
# supplies staged diff (git diff --cached --binary) and unstaged diff (git diff --binary) separately,
# untracked file contents (with streaming SHA-256 and binary detection), implementer evidence,
# and parent verification evidence within fail-closed presentation limits.
# Validates that the reviewed repository remains unmodified via comprehensive content fingerprinting,
# enforces mandatory closed-set 9 cryptographic evidence bindings (SHA-256), strictly validates schemas,
# and returns only SHIP, FIX-FIRST, or RETHINK in a structured JSON envelope.

set -eu

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

workspace=""
goal_file=""
evidence_file=""
parent_verification_file=""
review_output_file=""
timeout="15m"
test_mode=0
test_codex_bin=""
model=""
reasoning_effort=""

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace)
      [ $# -ge 2 ] || fail "Missing value for --workspace"
      workspace="$2"
      shift 2
      ;;
    --goal-file)
      [ $# -ge 2 ] || fail "Missing value for --goal-file"
      goal_file="$2"
      shift 2
      ;;
    --evidence-file)
      [ $# -ge 2 ] || fail "Missing value for --evidence-file"
      evidence_file="$2"
      shift 2
      ;;
    --parent-verification-file)
      [ $# -ge 2 ] || fail "Missing value for --parent-verification-file"
      parent_verification_file="$2"
      shift 2
      ;;
    --review-output-file)
      [ $# -ge 2 ] || fail "Missing value for --review-output-file"
      review_output_file="$2"
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || fail "Missing value for --timeout"
      timeout="$2"
      shift 2
      ;;
    --model)
      [ $# -ge 2 ] || fail "Missing value for --model"
      model="$2"
      shift 2
      ;;
    --reasoning-effort)
      [ $# -ge 2 ] || fail "Missing value for --reasoning-effort"
      reasoning_effort="$2"
      shift 2
      ;;
    --test-mode)
      test_mode=1
      shift 1
      ;;
    --test-codex-bin)
      [ $# -ge 2 ] || fail "Missing value for --test-codex-bin"
      test_codex_bin="$2"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[ -n "$workspace" ] || fail "workspace is required"
[ -n "$goal_file" ] || fail "goal-file is required"
[ -n "$evidence_file" ] || fail "evidence-file is required"
[ -n "$parent_verification_file" ] || fail "parent-verification-file is required"
[ -n "$review_output_file" ] || fail "review-output-file is required"

# 0. Preflight Python 3 validation
py_bin=''
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)" >/dev/null 2>&1; then
    py_bin=python3
  fi
fi
if [ -z "$py_bin" ] && command -v python >/dev/null 2>&1; then
  if python -c "import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)" >/dev/null 2>&1; then
    py_bin=python
  fi
fi
[ -n "$py_bin" ] || fail "Python 3 (version 3.6+) is required but was not found in PATH."

# 1. Validate Workspace
case "$workspace" in
  /*) ;;
  *) fail "workspace must be an absolute path: $workspace" ;;
esac

[ -d "$workspace" ] || fail "Target workspace does not exist or is not a directory: $workspace"
ws_real=$(CDPATH= cd "$workspace" && pwd -P) || fail "Cannot resolve workspace path: $workspace"

git_top=$(git -C "$ws_real" rev-parse --show-toplevel 2>/dev/null) || fail "Target workspace is not a Git repository: $workspace"
git_top_real=$(CDPATH= cd "$git_top" && pwd -P) || fail "Cannot resolve Git top-level path: $git_top"
[ "$ws_real" = "$git_top_real" ] || fail "Target workspace is not the top-level root of the Git repository ($ws_real vs $git_top_real)"

# 2. Validate input files (GoalFile, EvidenceFile, ParentVerificationFile)
validate_input_file() {
  f_path=$1
  label=$2
  case "$f_path" in
    /*) ;;
    *) fail "$label must be an absolute path: $f_path" ;;
  esac
  [ -f "$f_path" ] || fail "$label does not exist or is not a file: $f_path"
  [ ! -L "$f_path" ] || fail "$label is a symbolic link: $f_path"

  # File size validation (<= 1MB)
  "$py_bin" - "$f_path" "$label" <<'PY'
import sys, os
f_path, label = sys.argv[1], sys.argv[2]
if os.path.getsize(f_path) > 1048576:
    sys.stderr.write(f"ERROR: {label} exceeds maximum allowed size of 1MB ({os.path.getsize(f_path)} bytes).\n")
    sys.exit(1)
PY

  f_parent=$(dirname "$f_path")
  [ -d "$f_parent" ] || fail "$label parent directory does not exist: $f_parent"
  [ ! -L "$f_parent" ] || fail "$label parent directory is a symbolic link: $f_parent"

  curr=$f_parent
  while [ "$curr" != "/" ] && [ -n "$curr" ] && [ "$curr" != "." ]; do
    if [ -L "$curr" ]; then
      fail "$label ancestor directory is a symbolic link: $curr"
    fi
    p=$(dirname "$curr")
    if [ "$p" = "$curr" ]; then break; fi
    curr=$p
  done

  resolved_dir=$(CDPATH= cd "$f_parent" && pwd -P) || fail "Cannot resolve $label parent directory"
  case "$resolved_dir" in
    "$ws_real"/*|"$ws_real")
      fail "$label is inside target workspace ($resolved_dir is inside $ws_real)."
      ;;
  esac
}

validate_input_file "$goal_file" "GoalFile"
validate_input_file "$evidence_file" "EvidenceFile"
validate_input_file "$parent_verification_file" "ParentVerificationFile"

goal_file_real=$(CDPATH= cd "$(dirname "$goal_file")" && pwd -P)/$(basename "$goal_file")
evidence_file_real=$(CDPATH= cd "$(dirname "$evidence_file")" && pwd -P)/$(basename "$evidence_file")
parent_ver_file_real=$(CDPATH= cd "$(dirname "$parent_verification_file")" && pwd -P)/$(basename "$parent_verification_file")

# 3. Validate ReviewOutputFile
case "$review_output_file" in
  /*) ;;
  *) fail "ReviewOutputFile must be an absolute path: $review_output_file" ;;
esac

[ ! -e "$review_output_file" ] || fail "Review output destination already exists (no-clobber): $review_output_file"

out_parent=$(dirname "$review_output_file")
[ -d "$out_parent" ] || fail "Review output parent directory does not exist: $out_parent"
[ ! -L "$out_parent" ] || fail "Review output parent directory is a symbolic link: $out_parent"

curr=$out_parent
while [ "$curr" != "/" ] && [ -n "$curr" ] && [ "$curr" != "." ]; do
  if [ -L "$curr" ]; then
    fail "Review output parent ancestor is a symbolic link: $curr"
  fi
  p=$(dirname "$curr")
  if [ "$p" = "$curr" ]; then break; fi
  curr=$p
done

out_parent_real=$(CDPATH= cd "$out_parent" && pwd -P) || fail "Cannot resolve review output parent directory: $out_parent"

case "$out_parent_real" in
  "$ws_real"|"$ws_real"/*)
    fail "Review output destination is inside target workspace: $out_parent_real"
    ;;
esac

# 4. Determine Codex Executable & Test Mode
codex_bin="codex"
effective_test_mode=$test_mode

if [ -n "$test_codex_bin" ]; then
  if [ "$effective_test_mode" -ne 1 ]; then
    fail "test executable argument (--test-codex-bin) specified without --test-mode"
  fi
  if [ ! -f "$test_codex_bin" ]; then
    fail "test executable specified in --test-codex-bin does not exist: $test_codex_bin"
  fi
  codex_bin="$test_codex_bin"
else
  override_codex_var=0
  codex_candidate=""
  for var in _MY_SOL_ADVISOR_TEST_CODEX_BIN _SOL_ADVISOR_TEST_CODEX_BIN; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
      override_codex_var=1
      codex_candidate="$val"
      break
    fi
  done

  if [ "$override_codex_var" -eq 1 ]; then
    if [ "$effective_test_mode" -ne 1 ]; then
      fail "test executable override variable specified without explicit test mode (--test-mode / _MY_SOL_ADVISOR_TEST_MODE=1)"
    fi
    if [ ! -f "$codex_candidate" ]; then
      fail "test executable override does not exist or is not a file: $codex_candidate"
    fi
    codex_bin="$codex_candidate"
  fi
fi

timeout_sec=$("$py_bin" -c "
import sys, re
d = sys.argv[1].strip()
m = re.match(r'^(\d+)h(?:(\d+)m)?$', d)
if m:
    h, mins = int(m.group(1)), int(m.group(2) or 0)
    print(h * 3600 + mins * 60)
    sys.exit(0)
m = re.match(r'^(\d+)m(?:(\d+)s)?$', d)
if m:
    mins, s = int(m.group(1)), int(m.group(2) or 0)
    print(mins * 60 + s)
    sys.exit(0)
m = re.match(r'^(\d+)s$', d)
if m:
    print(int(m.group(1)))
    sys.exit(0)
m = re.match(r'^(\d+)$', d)
if m:
    print(int(m.group(1)))
    sys.exit(0)
sys.stderr.write(f'ERROR: Invalid duration format \'{d}\'.\n')
sys.exit(1)
" "$timeout")

temp_msg_file="$out_parent_real/.codex-review-msg.$$.tmp"
temp_prompt_file="$out_parent_real/.codex-review-prompt.$$.tmp"

clean_temp() {
  rm -f "$temp_msg_file" "$temp_prompt_file" 2>/dev/null || true
}
trap clean_temp EXIT INT TERM

# 5. Execute Full Reviewer Workflow via Python Engine
"$py_bin" - \
  "$ws_real" \
  "$goal_file_real" \
  "$evidence_file_real" \
  "$parent_ver_file_real" \
  "$review_output_file" \
  "$out_parent_real" \
  "$codex_bin" \
  "$temp_prompt_file" \
  "$temp_msg_file" \
  "$timeout_sec" \
  "$timeout" \
  "$model" \
  "$reasoning_effort" <<'PY'
import sys, os, subprocess, json, hashlib, signal, secrets, stat, time, re

(ws, goal_file, evidence_file, parent_ver_file, review_output_file,
 out_parent, codex_bin, temp_prompt_file, temp_msg_file,
 timeout_sec_str, timeout_str, model_arg, effort_arg) = sys.argv[1:14]

def get_current_codex_config():
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    cfg_path = os.path.join(codex_home, "config.toml")
    res = {"model": None, "effort": None}
    if not os.path.isfile(cfg_path):
        return res
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            text = f.read()
        m_model = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', text)
        if m_model:
            res["model"] = m_model.group(1).strip()
        m_effort = re.search(r'(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"', text)
        if m_effort:
            res["effort"] = m_effort.group(1).strip()
    except Exception:
        pass
    return res

inherited_codex_cfg = get_current_codex_config()
effective_model = model_arg.strip() if model_arg.strip() else (os.environ.get("SOL_ADVISOR_MODEL") or os.environ.get("CODEX_MODEL") or inherited_codex_cfg.get("model"))
effective_reasoning_effort = effort_arg.strip() if effort_arg.strip() else inherited_codex_cfg.get("effort")

timeout_sec = int(timeout_sec_str)
start_time = time.time()

def get_remaining_timeout(max_step=60):
    rem = timeout_sec - (time.time() - start_time)
    if rem <= 0:
        sys.stderr.write(f"ERROR: Fresh reviewer exceeded timeout of {timeout_str} ({timeout_sec}s).\n")
        sys.exit(1)
    return min(max_step, rem)

def run_git(args, timeout=30):
    r = subprocess.run(["git", "-C", ws] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=get_remaining_timeout(timeout))
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: Git command failed: git {' '.join(args)}\n{r.stderr.decode('utf-8', errors='replace')}\n")
        sys.exit(1)
    return r.stdout

def run_git_allow_fail(args, timeout=30):
    r = subprocess.run(["git", "-C", ws] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=get_remaining_timeout(timeout))
    return r.stdout if r.returncode == 0 else b""

def get_file_sha256_and_len(file_path):
    if not os.path.isfile(file_path):
        return 0, "MISSING"
    h = hashlib.sha256()
    total_len = 0
    with open(file_path, 'rb') as f:
        while True:
            chunk = f.read(65536)
            if not chunk: break
            h.update(chunk)
            total_len += len(chunk)
    return total_len, h.hexdigest()

# 5.1 Read raw input bytes and compute independent hashes
with open(goal_file, 'rb') as f: raw_goal = f.read()
task_hash = hashlib.sha256(raw_goal).hexdigest()
goal_text = raw_goal.decode('utf-8', errors='replace')

with open(evidence_file, 'rb') as f: raw_evidence = f.read()
impl_ev_hash = hashlib.sha256(raw_evidence).hexdigest()
evidence_text = raw_evidence.decode('utf-8', errors='replace')

with open(parent_ver_file, 'rb') as f: raw_pv = f.read()
pv_hash = hashlib.sha256(raw_pv).hexdigest()
pv_text = raw_pv.decode('utf-8', errors='replace')

# Strict validation of ParentVerificationFile schema
try:
    pv_obj = json.loads(pv_text)
except Exception as e:
    sys.stderr.write(f"ERROR: ParentVerificationFile is not valid JSON: {e}\n")
    sys.exit(1)

if not isinstance(pv_obj, dict):
    sys.stderr.write("ERROR: ParentVerificationFile must be a JSON object.\n")
    sys.exit(1)

allowed_pv_keys = {"schema_version", "iteration", "verified_at_utc", "ownership_check", "integrity_check", "implementer_evidence_assessment", "suggested_commands_unexecuted", "all_checks_passed", "bindings"}
for k in pv_obj.keys():
    if k not in allowed_pv_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in parent-verification.json (strict schema validation).\n")
        sys.exit(1)

if type(pv_obj.get("schema_version")) is not int or pv_obj.get("schema_version") != 1:
    sys.stderr.write("ERROR: ParentVerificationFile schema_version must be integer 1.\n")
    sys.exit(1)
if type(pv_obj.get("iteration")) is not int or pv_obj["iteration"] < 1 or not isinstance(pv_obj.get("verified_at_utc"), str) or not pv_obj["verified_at_utc"].strip():
    sys.stderr.write("ERROR: ParentVerificationFile iteration/timestamp types are invalid.\n")
    sys.exit(1)
if not isinstance(pv_obj.get("suggested_commands_unexecuted"), list) or any(not isinstance(v, str) for v in pv_obj["suggested_commands_unexecuted"]):
    sys.stderr.write("ERROR: ParentVerificationFile suggested_commands_unexecuted must be an array of strings.\n")
    sys.exit(1)

if type(pv_obj.get("all_checks_passed")) is not bool or pv_obj.get("all_checks_passed") is not True:
    sys.stderr.write("ERROR: ParentVerificationFile does not report all_checks_passed = true.\n")
    sys.exit(1)

oc = pv_obj.get("ownership_check")
if not isinstance(oc, dict):
    sys.stderr.write("ERROR: ParentVerificationFile ownership_check missing or not a JSON object.\n")
    sys.exit(1)
allowed_oc_keys = {"passed", "declared_owned_files", "window_modified_files", "unowned_modifications"}
for k in oc.keys():
    if k not in allowed_oc_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in parent-verification ownership_check (strict schema validation).\n")
        sys.exit(1)
if type(oc.get("passed")) is not bool or oc.get("passed") is not True:
    sys.stderr.write("ERROR: ParentVerificationFile ownership_check.passed must be boolean true.\n")
    sys.exit(1)
for name in ("declared_owned_files", "window_modified_files", "unowned_modifications"):
    if not isinstance(oc.get(name), list) or any(not isinstance(v, str) for v in oc[name]):
        sys.stderr.write(f"ERROR: ParentVerificationFile ownership_check.{name} must be an array of strings.\n")
        sys.exit(1)
if not isinstance(oc.get("declared_owned_files"), list) or not isinstance(oc.get("window_modified_files"), list) or not isinstance(oc.get("unowned_modifications"), list):
    sys.stderr.write("ERROR: ParentVerificationFile ownership_check fields must be JSON arrays.\n")
    sys.exit(1)
if len(oc["unowned_modifications"]) != 0:
    sys.stderr.write("ERROR: ParentVerificationFile reports unowned modifications.\n")
    sys.exit(1)

ic = pv_obj.get("integrity_check")
if not isinstance(ic, dict):
    sys.stderr.write("ERROR: ParentVerificationFile integrity_check missing or not a JSON object.\n")
    sys.exit(1)
allowed_ic_keys = {"passed", "head_unchanged", "baseline_head_sha", "current_head_sha", "scoped_git_metadata_unchanged", "in_progress_git_operations"}
for k in ic.keys():
    if k not in allowed_ic_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in parent-verification integrity_check (strict schema validation).\n")
        sys.exit(1)
if type(ic.get("passed")) is not bool or ic.get("passed") is not True or type(ic.get("head_unchanged")) is not bool or ic.get("head_unchanged") is not True or type(ic.get("scoped_git_metadata_unchanged")) is not bool or ic.get("scoped_git_metadata_unchanged") is not True:
    sys.stderr.write("ERROR: ParentVerificationFile integrity_check booleans must be true.\n")
    sys.exit(1)
b_head = ic.get("baseline_head_sha", "")
c_head = ic.get("current_head_sha", "")
if not isinstance(b_head, str) or not isinstance(c_head, str) or len(b_head) != 40 or len(c_head) != 40 or b_head != c_head:
    sys.stderr.write("ERROR: ParentVerificationFile integrity_check HEAD SHAs invalid or mismatched.\n")
    sys.exit(1)
if not isinstance(ic.get("in_progress_git_operations"), list) or len(ic["in_progress_git_operations"]) != 0:
    sys.stderr.write("ERROR: ParentVerificationFile in_progress_git_operations must be empty array.\n")
    sys.exit(1)

iea = pv_obj.get("implementer_evidence_assessment")
if not isinstance(iea, dict):
    sys.stderr.write("ERROR: ParentVerificationFile implementer_evidence_assessment missing or not a JSON object.\n")
    sys.exit(1)
allowed_iea_keys = {"passed", "implementer_status", "implementer_reported_tests_untrusted", "implementer_reported_test_summary"}
for k in iea.keys():
    if k not in allowed_iea_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in implementer_evidence_assessment (strict schema validation).\n")
        sys.exit(1)
if type(iea.get("passed")) is not bool or iea.get("passed") is not True or type(iea.get("implementer_reported_tests_untrusted")) is not bool or iea.get("implementer_reported_tests_untrusted") is not True:
    sys.stderr.write("ERROR: ParentVerificationFile implementer_evidence_assessment booleans must be true.\n")
    sys.exit(1)
if not isinstance(iea.get("implementer_status"), str) or not isinstance(iea.get("implementer_reported_test_summary"), str):
    sys.stderr.write("ERROR: ParentVerificationFile implementer assessment status/summary must be strings.\n")
    sys.exit(1)

pv_bindings = pv_obj.get("bindings")
if not isinstance(pv_bindings, dict):
    sys.stderr.write("ERROR: ParentVerificationFile missing 'bindings' object.\n")
    sys.exit(1)

required_pv_bindings = [
    "task_sha256", "plan_sha256", "spec_sha256", "implementer_evidence_sha256",
    "pre_window_manifest_sha256", "post_window_manifest_sha256",
    "repository_manifest_sha256", "aggregate_delta_manifest_sha256"
]

for k in pv_bindings.keys():
    if k not in required_pv_bindings:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in parent-verification bindings (strict schema validation).\n")
        sys.exit(1)

for bk in required_pv_bindings:
    if bk not in pv_bindings or not isinstance(pv_bindings[bk], str) or len(pv_bindings[bk]) != 64:
        sys.stderr.write(f"ERROR: ParentVerificationFile bindings missing or invalid key '{bk}'.\n")
        sys.exit(1)

if pv_bindings["task_sha256"] != task_hash:
    sys.stderr.write(f"ERROR: ParentVerificationFile task_sha256 '{pv_bindings['task_sha256']}' != actual task hash '{task_hash}'.\n")
    sys.exit(1)

if pv_bindings["implementer_evidence_sha256"] != impl_ev_hash:
    sys.stderr.write(f"ERROR: ParentVerificationFile implementer_evidence_sha256 '{pv_bindings['implementer_evidence_sha256']}' != actual evidence hash '{impl_ev_hash}'.\n")
    sys.exit(1)

# Strict validation of ImplementerEvidence
try:
    impl_obj = json.loads(evidence_text)
except Exception as e:
    sys.stderr.write(f"ERROR: EvidenceFile is not valid JSON: {e}\n")
    sys.exit(1)

if not isinstance(impl_obj, dict):
    sys.stderr.write("ERROR: EvidenceFile must be a JSON object.\n")
    sys.exit(1)

allowed_impl_keys = {"schema_version", "invocation", "runtime_observability", "agy_result"}
for k in impl_obj.keys():
    if k not in allowed_impl_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in EvidenceFile (strict schema validation).\n")
        sys.exit(1)

if type(impl_obj.get("schema_version")) is not int or impl_obj.get("schema_version") != 1:
    sys.stderr.write("ERROR: EvidenceFile schema_version must be integer 1.\n")
    sys.exit(1)

inv = impl_obj.get("invocation")
if not isinstance(inv, dict):
    sys.stderr.write("ERROR: EvidenceFile invocation missing or not an object.\n")
    sys.exit(1)
allowed_inv_keys = {"provider", "cli_version_observed", "model_requested", "model_catalog_exact_match_observed", "effort_requested", "mode_requested", "output_format_requested", "cwd_observed", "permission_mode_requested", "started_at_utc", "ended_at_utc", "duration_ms_observed", "exit_code_observed"}
for k in inv.keys():
    if k not in allowed_inv_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in EvidenceFile invocation (strict schema validation).\n")
        sys.exit(1)

if inv.get("provider") != "google-antigravity-cli":
    sys.stderr.write("ERROR: EvidenceFile invocation.provider must be 'google-antigravity-cli'.\n")
    sys.exit(1)
for name in ("provider", "cli_version_observed", "model_requested", "effort_requested", "mode_requested", "output_format_requested", "cwd_observed", "permission_mode_requested", "started_at_utc", "ended_at_utc"):
    if not isinstance(inv.get(name), str):
        sys.stderr.write(f"ERROR: EvidenceFile invocation.{name} must be a string.\n")
        sys.exit(1)

if inv.get("model_requested") != "gemini-3.8-flash-high":
    sys.stderr.write("ERROR: EvidenceFile model_requested must be 'gemini-3.8-flash-high'.\n")
    sys.exit(1)

if inv.get("effort_requested") != "high" or inv.get("mode_requested") != "accept-edits" or inv.get("output_format_requested") != "json":
    sys.stderr.write("ERROR: EvidenceFile invocation pins mismatch.\n")
    sys.exit(1)

if type(inv.get("model_catalog_exact_match_observed")) is not bool or inv.get("model_catalog_exact_match_observed") is not True:
    sys.stderr.write("ERROR: EvidenceFile model_catalog_exact_match_observed must be boolean true.\n")
    sys.exit(1)

if type(inv.get("duration_ms_observed")) not in (int, float) or type(inv.get("exit_code_observed")) is not int:
    sys.stderr.write("ERROR: EvidenceFile duration and exit code must be numeric.\n")
    sys.exit(1)

ro = impl_obj.get("runtime_observability")
required_ro = {"model_field_observed", "effort_field_observed", "mode_field_observed", "cwd_field_observed", "note"}
if not isinstance(ro, dict) or set(ro) != required_ro:
    sys.stderr.write("ERROR: EvidenceFile runtime_observability must match its closed schema.\n")
    sys.exit(1)
if any(type(ro[k]) is not bool for k in required_ro - {"note"}) or not isinstance(ro["note"], str):
    sys.stderr.write("ERROR: EvidenceFile runtime_observability field types are invalid.\n")
    sys.exit(1)

agy = impl_obj.get("agy_result")
required_agy = {"status", "objective", "changes", "verified", "judgment_calls", "gaps", "response"}
allowed_agy = {"status", "objective", "changes", "verified", "judgment_calls", "gaps", "response", "conversation_id"}
if not isinstance(agy, dict) or not required_agy.issubset(agy) or not set(agy).issubset(allowed_agy) or any(not isinstance(agy[k], str) for k in agy):
    sys.stderr.write("ERROR: EvidenceFile agy_result must match its normalized closed string schema.\n")
    sys.exit(1)

# 5.2 Scoped Git Metadata Digest Function
def get_scoped_git_metadata_digest(include_index=True):
    h = hashlib.sha256()
    git_dir_rel = run_git(["rev-parse", "--git-dir"]).strip().decode('utf-8')
    git_dir_full = os.path.normpath(os.path.join(ws, git_dir_rel))

    head_file = os.path.join(git_dir_full, "HEAD")
    if os.path.isfile(head_file):
        with open(head_file, 'rb') as f: h.update(b"HEAD_FILE:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
    else:
        h.update(b"HEAD_FILE:MISSING\n")

    h.update(b"HEAD_SHA:" + run_git(["rev-parse", "HEAD"]).strip() + b"\n")
    ref_res = run_git_allow_fail(["symbolic-ref", "-q", "HEAD"])
    ref_val = ref_res.strip() if ref_res else b"DETACHED"
    h.update(b"HEAD_REF:" + ref_val + b"\n")

    config_file = os.path.join(git_dir_full, "config")
    if os.path.isfile(config_file):
        with open(config_file, 'rb') as f: h.update(b"CONFIG:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
    else:
        h.update(b"CONFIG:MISSING\n")

    packed_refs = os.path.join(git_dir_full, "packed-refs")
    if os.path.isfile(packed_refs):
        with open(packed_refs, 'rb') as f: h.update(b"PACKED_REFS:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
    else:
        h.update(b"PACKED_REFS:MISSING\n")

    refs_dir = os.path.join(git_dir_full, "refs")
    h.update(b"REFS_ENTRIES:\n")
    if os.path.isdir(refs_dir):
        ref_files = []
        for root_d, _, files in os.walk(refs_dir):
            for fn in files:
                p = os.path.join(root_d, fn)
                rel = os.path.relpath(p, refs_dir).replace("\\", "/")
                ref_files.append((rel, p))
        ref_files.sort()
        for rel, p in ref_files:
            with open(p, 'rb') as f: h.update(f"REF:{rel}:".encode('utf-8') + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")

    hooks_dir = os.path.join(git_dir_full, "hooks")
    h.update(b"HOOKS_ENTRIES:\n")
    if os.path.isdir(hooks_dir):
        hook_files = []
        for root_d, _, files in os.walk(hooks_dir):
            for fn in files:
                p = os.path.join(root_d, fn)
                rel = os.path.relpath(p, hooks_dir).replace("\\", "/")
                hook_files.append((rel, p))
        hook_files.sort()
        for rel, p in hook_files:
            with open(p, 'rb') as f: h.update(f"HOOK:{rel}:".encode('utf-8') + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")

    info_dir = os.path.join(git_dir_full, "info")
    h.update(b"INFO_ENTRIES:\n")
    if os.path.isdir(info_dir):
        info_files = []
        for root_d, _, files in os.walk(info_dir):
            for fn in files:
                p = os.path.join(root_d, fn)
                rel = os.path.relpath(p, info_dir).replace("\\", "/")
                info_files.append((rel, p))
        info_files.sort()
        for rel, p in info_files:
            with open(p, 'rb') as f: h.update(f"INFO:{rel}:".encode('utf-8') + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")

    shallow_file = os.path.join(git_dir_full, "shallow")
    if os.path.isfile(shallow_file):
        with open(shallow_file, 'rb') as f: h.update(b"SHALLOW:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
    else:
        h.update(b"SHALLOW:MISSING\n")

    h.update(b"IN_PROGRESS_MARKERS:\n")
    for marker in ("MERGE_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE", "ORIG_HEAD", "FETCH_HEAD"):
        if os.path.exists(os.path.join(git_dir_full, marker)):
            h.update(f"OP_MARKER:{marker}:PRESENT\n".encode('utf-8'))

    if include_index:
        index_file = os.path.join(git_dir_full, "index")
        if os.path.isfile(index_file):
            with open(index_file, 'rb') as f: h.update(b"INDEX:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
        else:
            h.update(b"INDEX:MISSING\n")

    return h.hexdigest()

# Universal runtime cache and compilation artifact filter
def is_ignored_runtime_cache_path(path_str):
    if not path_str:
        return False
    norm = path_str.replace('\\', '/').strip('/')
    if re.search(r'(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.coverage|\.tox|\.nox)(/|$)', norm):
        return True
    if re.search(r'\.(pyc|pyo|pyd)$', norm):
        return True
    if re.search(r'(^|/)(node_modules/\.cache|\.npm|\.yarn/cache)(/|$)', norm):
        return True
    if re.search(r'(^|/)(\.DS_Store|Thumbs\.db|\.directory)$', norm):
        return True
    if re.search(r'\.(tmp|swp|bak)$', norm) or re.search(r'(^|/)\.~', norm):
        return True
    return False

# 5.3 Deterministic Repository Manifest Function
def get_deterministic_repo_manifest():
    h = hashlib.sha256()
    h.update(b"HEAD:" + run_git(["rev-parse", "HEAD"]).strip() + b"\n")
    ref_res = run_git_allow_fail(["symbolic-ref", "-q", "HEAD"])
    h.update(b"REF:" + (ref_res.strip() if ref_res else b"DETACHED") + b"\n")

    scoped_meta = get_scoped_git_metadata_digest(include_index=True)
    h.update(b"SCOPED_GIT_METADATA:" + scoped_meta.encode('utf-8') + b"\n")

    h.update(b"STATUS_Z:" + run_git(["status", "--porcelain=v1", "-z"]) + b"\n")

    diff_cached = run_git(["diff", "--cached", "--binary"])
    h.update(b"DIFF_CACHED_BYTES:" + str(len(diff_cached)).encode('utf-8') + b":" + hashlib.sha256(diff_cached).hexdigest().encode('utf-8') + b"\n")

    diff_unstaged = run_git(["diff", "--binary"])
    h.update(b"DIFF_UNSTAGED_BYTES:" + str(len(diff_unstaged)).encode('utf-8') + b":" + hashlib.sha256(diff_unstaged).hexdigest().encode('utf-8') + b"\n")

    diff_head = run_git(["diff", "HEAD", "--binary"])
    h.update(b"DIFF_HEAD_BYTES:" + str(len(diff_head)).encode('utf-8') + b":" + hashlib.sha256(diff_head).hexdigest().encode('utf-8') + b"\n")

    untracked_raw = run_git(["ls-files", "--others", "--exclude-standard", "-z"])
    untracked_files = [p for p in untracked_raw.split(b'\0') if p]
    untracked_files.sort()
    h.update(b"UNTRACKED_FILES:\n")
    for uf in untracked_files:
        uf_str = uf.decode('utf-8', errors='replace').replace('\\', '/').lstrip('/')
        if is_ignored_runtime_cache_path(uf_str):
            continue
        fp = os.path.join(ws.encode('utf-8'), uf)
        if os.path.isfile(fp):
            f_len, f_hash = get_file_sha256_and_len(fp.decode('utf-8', errors='replace'))
            h.update(uf + b":" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8') + b"\n")

    dirty_raw = run_git(["diff", "--name-only", "HEAD", "-z"])
    dirty_files = [p for p in dirty_raw.split(b'\0') if p]
    dirty_files.sort()
    h.update(b"DIRTY_TRACKED_FILES:\n")
    for df in dirty_files:
        fp = os.path.join(ws.encode('utf-8'), df)
        if os.path.isfile(fp):
            f_len, f_hash = get_file_sha256_and_len(fp.decode('utf-8', errors='replace'))
            h.update(df + b":" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8') + b"\n")
        else:
            h.update(df + b":DELETED\n")

    return h.hexdigest()

pre_review_fingerprint = get_deterministic_repo_manifest()

if pv_bindings["repository_manifest_sha256"] != pre_review_fingerprint:
    sys.stderr.write(f"ERROR: ParentVerificationFile repository_manifest_sha256 '{pv_bindings['repository_manifest_sha256']}' does not match current repository manifest '{pre_review_fingerprint}'.\n")
    sys.exit(1)

# 5.4 Gather staged & unstaged diffs with fail-closed resource caps
staged_diff_bytes = run_git(["diff", "--cached", "--binary"])
unstaged_diff_bytes = run_git(["diff", "--binary"])
total_diff_bytes = len(staged_diff_bytes) + len(unstaged_diff_bytes)

if total_diff_bytes > 2097152:
    sys.stderr.write(f"ERROR: Total review diff presentation exceeds 2MB limit ({total_diff_bytes} bytes). Bounded review limits fail closed.\n")
    sys.exit(1)

staged_diff_str = staged_diff_bytes.decode('utf-8', errors='replace') if staged_diff_bytes else "None"
unstaged_diff_str = unstaged_diff_bytes.decode('utf-8', errors='replace') if unstaged_diff_bytes else "None"

# Untracked files presentation
untracked_raw = run_git(["ls-files", "--others", "--exclude-standard", "-z"])
untracked_list = [p for p in untracked_raw.split(b'\0') if p]
untracked_lines = []
total_untracked_text_bytes = 0

for uf_bytes in untracked_list:
    try:
        uf = uf_bytes.decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        sys.stderr.write("ERROR: Non-UTF-8 Git path rejected fail-closed during fresh review.\n")
        sys.exit(1)
    if is_ignored_runtime_cache_path(uf.replace('\\', '/').lstrip('/')):
        continue
    full_path = os.path.join(ws, uf)
    if os.path.isfile(full_path):
        f_len, f_hash = get_file_sha256_and_len(full_path)
        is_binary = False
        with open(full_path, 'rb') as f:
            head_bytes = f.read(min(8192, f_len))
            if b'\0' in head_bytes:
                is_binary = True

        untracked_lines.append(f"--- UNTRACKED FILE: {uf} ---")
        if is_binary:
            untracked_lines.append(f"[BINARY FILE: {uf}, Size: {f_len} bytes, SHA256: {f_hash}]")
        else:
            if f_len > 262144:
                sys.stderr.write(f"ERROR: Untracked text file '{uf}' exceeds 256KB individual presentation limit ({f_len} bytes).\n")
                sys.exit(1)
            total_untracked_text_bytes += f_len
            if total_untracked_text_bytes > 1048576:
                sys.stderr.write(f"ERROR: Total untracked text presentation exceeds 1MB limit ({total_untracked_text_bytes} bytes).\n")
                sys.exit(1)
            try:
                with open(full_path, 'r', encoding='utf-8') as f:
                    txt = f.read()
                untracked_lines.append(txt)
            except Exception:
                untracked_lines.append(f"[NON-UTF8 FILE: {uf}, Size: {f_len} bytes, SHA256: {f_hash}]")

untracked_text = "\n".join(untracked_lines) if untracked_lines else "None"

plan_hash = pv_bindings["plan_sha256"]
spec_hash = pv_bindings["spec_sha256"]
pre_win_hash = pv_bindings["pre_window_manifest_sha256"]
post_win_hash = pv_bindings["post_window_manifest_sha256"]
agg_delta_hash = pv_bindings["aggregate_delta_manifest_sha256"]

bindings_summary = f"""- task_sha256: {task_hash}
- plan_sha256: {plan_hash}
- spec_sha256: {spec_hash}
- implementer_evidence_sha256: {impl_ev_hash}
- parent_verification_sha256: {pv_hash}
- pre_window_manifest_sha256: {pre_win_hash}
- post_window_manifest_sha256: {post_win_hash}
- repository_manifest_sha256: {pre_review_fingerprint}
- aggregate_delta_manifest_sha256: {agg_delta_hash}"""

# 5.5 Review Prompt
reviewer_model_desc = f"model: {effective_model}" if effective_model else "inherited Codex model"
reviewer_effort_desc = effective_reasoning_effort if effective_reasoning_effort else "inherited"
review_prompt = f"""ROLE
You are a fresh, ephemeral, read-only final reviewer ({reviewer_model_desc} with reasoning effort: {reviewer_effort_desc}).
You MUST remain strictly read-only: do not create, modify, delete, format, or implement files.
Inspect the stated goal, staged & unstaged diffs relative to HEAD, untracked files, implementer evidence, and parent verification evidence in a fresh context.
Note: Ignored files (.gitignore) are excluded from integrity scope; tracked and non-ignored files are strictly verified.
Implementer-reported test commands are untrusted implementer self-reports.

STATED GOAL
{goal_text}

STAGED CHANGES (vs HEAD)
{staged_diff_str}

UNSTAGED WORKING TREE CHANGES (vs INDEX)
{unstaged_diff_str}

UNTRACKED FILES AND CONTENTS
{untracked_text}

IMPLEMENTER EVIDENCE
{evidence_text}

PARENT VERIFICATION EVIDENCE
{pv_text}

CRYPTOGRAPHIC BINDINGS
{bindings_summary}

REVIEW INSTRUCTIONS
Judge correctness, completeness, regressions, scope discipline, interface preservation, and test adequacy.
When parent verification reports all_checks_passed: true and no dedicated parent verification script was supplied, evaluate code correctness, logic, and test coverage through rigorous inspection of the diffs, untracked files, and test suites. Do not reject with FIX-FIRST solely because implementer-reported execution is marked untrusted or because suggested commands were left unexecuted by the parent machine, unless you identify concrete code bugs, test defects, or unmet requirements.
If no changes were needed or made to satisfy the goal, indicate reviewed_no_change: true.
You MUST echo all 9 reviewed_bindings exactly as provided above.
Return ONLY a structured JSON object with the following schema:
{{
  "verdict": "SHIP" | "FIX-FIRST" | "RETHINK",
  "reason": "<evidence-based decisive reason>",
  "findings": "<precise file references and required fixes, or none>",
  "residual_risk": "<most important remaining risk, or none>",
  "reviewed_no_change": false,
  "reviewed_bindings": {{
    "task_sha256": "{task_hash}",
    "plan_sha256": "{plan_hash}",
    "spec_sha256": "{spec_hash}",
    "implementer_evidence_sha256": "{impl_ev_hash}",
    "parent_verification_sha256": "{pv_hash}",
    "pre_window_manifest_sha256": "{pre_win_hash}",
    "post_window_manifest_sha256": "{post_win_hash}",
    "repository_manifest_sha256": "{pre_review_fingerprint}",
    "aggregate_delta_manifest_sha256": "{agg_delta_hash}"
  }}
}}
Do not wrap in markdown fences or include any conversational text outside the JSON object."""

prompt_bytes = review_prompt.encode('utf-8')
if len(prompt_bytes) > 4194304:
    sys.stderr.write(f"ERROR: Total reviewer prompt size exceeds 4MB limit ({len(prompt_bytes)} bytes).\n")
    sys.exit(1)

with open(temp_prompt_file, 'wb') as f:
    f.write(prompt_bytes)

# 5.6 Execute Codex Subprocess
codex_cmd = [
    codex_bin, "exec"
]
if effective_model:
    codex_cmd.extend(["-m", effective_model])
codex_cmd.extend([
    "-s", "read-only",
    "--ephemeral",
    "--ignore-user-config"
])
if effective_reasoning_effort:
    codex_cmd.extend(["-c", f'model_reasoning_effort="{effective_reasoning_effort}"'])
for feat in ("apps", "plugins", "remote_plugin", "recommended_plugins", "browser_use", "browser_use_external", "computer_use", "in_app_browser", "memories", "image_generation", "workspace_dependencies", "skill_search"):
    codex_cmd.extend(["--disable", feat])
codex_cmd.extend([
    "-C", ws,
    "--skip-git-repo-check",
    "--color", "never",
    "-o", temp_msg_file
])

rem_codex_sec = int(timeout_sec - (time.time() - start_time))
if rem_codex_sec <= 0:
    sys.stderr.write(f"ERROR: Fresh reviewer exceeded timeout of {timeout_str} ({timeout_sec}s) before executing Codex.\n")
    sys.exit(1)
p = None
try:
    p = subprocess.Popen(codex_cmd, cwd=ws, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=os.setsid if hasattr(os, 'setsid') else None)
    stdout, stderr = p.communicate(input=prompt_bytes, timeout=rem_codex_sec)
    if p.returncode != 0:
        sys.stderr.write(f"ERROR: Fresh review Codex process exited with code {p.returncode}: {stderr.decode('utf-8', errors='replace')}\n")
        sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    if hasattr(os, 'killpg') and hasattr(os, 'getpgid'):
        try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception: pass
    else:
        try: p.kill()
        except Exception: pass
    sys.stderr.write(f"ERROR: Fresh review Codex process exceeded timeout of {timeout_str} ({timeout_sec}s).\n")
    sys.exit(124)
finally:
    if p and p.poll() is None:
        if hasattr(os, 'killpg') and hasattr(os, 'getpgid'):
            try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception: pass
        else:
            try: p.kill()
            except Exception: pass

# 5.7 Post-Review Fingerprint Immutability Check
post_review_fingerprint = get_deterministic_repo_manifest()
if pre_review_fingerprint != post_review_fingerprint:
    sys.stderr.write(f"ERROR: Repository immutability violated: repository state was modified during fresh read-only review! (pre: {pre_review_fingerprint}, post: {post_review_fingerprint})\n")
    sys.exit(1)

# 5.8 Read and Validate Reviewer Output (via file, not argv)
raw_output = ""
if os.path.isfile(temp_msg_file):
    with open(temp_msg_file, 'r', encoding='utf-8') as f:
        raw_output = f.read()

if not raw_output.strip():
    raw_output = stdout.decode('utf-8', errors='replace')

if not raw_output.strip():
    sys.stderr.write("ERROR: Fresh reviewer produced empty output.\n")
    sys.exit(1)

if len(raw_output) > 2097152:
    sys.stderr.write(f"ERROR: Fresh reviewer output exceeds 2MB limit ({len(raw_output)} chars).\n")
    sys.exit(1)

clean_json = raw_output.strip()
if clean_json.startswith("```"):
    lines = [l for l in clean_json.splitlines() if not l.strip().startswith("```")]
    clean_json = "\n".join(lines).strip()

try:
    review_parsed = json.loads(clean_json)
except Exception as e:
    sys.stderr.write(f"ERROR: Fresh reviewer output is not valid JSON: {raw_output}\n")
    sys.exit(1)

if not isinstance(review_parsed, dict):
    sys.stderr.write("ERROR: Fresh reviewer output must be a JSON object.\n")
    sys.exit(1)

allowed_reviewer_keys = {"verdict", "reason", "findings", "residual_risk", "reviewed_no_change", "reviewed_bindings"}
for k in review_parsed.keys():
    if k not in allowed_reviewer_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in reviewer JSON output (strict schema validation).\n")
        sys.exit(1)

verdict = str(review_parsed.get("verdict", "")).strip().upper()
for name in ("verdict", "reason", "findings", "residual_risk"):
    if not isinstance(review_parsed.get(name), str):
        sys.stderr.write(f"ERROR: Fresh reviewer field '{name}' must be a string.\n")
        sys.exit(1)
if verdict not in ("SHIP", "FIX-FIRST", "RETHINK"):
    sys.stderr.write(f"ERROR: Invalid review verdict '{verdict}'. Must be one of SHIP, FIX-FIRST, RETHINK.\n")
    sys.exit(1)

reason = str(review_parsed.get("reason", "")).strip()
if not reason:
    sys.stderr.write("ERROR: Fresh review JSON missing or empty 'reason' field.\n")
    sys.exit(1)

findings = str(review_parsed.get("findings", "")).strip()
residual_risk = str(review_parsed.get("residual_risk", "")).strip()

raw_rnc = review_parsed.get("reviewed_no_change")
if raw_rnc is not None:
    if type(raw_rnc) is not bool:
        sys.stderr.write("ERROR: Fresh reviewer 'reviewed_no_change' field must be an actual JSON boolean (true/false), not string or number.\n")
        sys.exit(1)
    reviewed_no_change = raw_rnc
else:
    reviewed_no_change = False

echoed_bindings = review_parsed.get("reviewed_bindings")
if not isinstance(echoed_bindings, dict):
    sys.stderr.write("ERROR: Fresh review JSON missing mandatory 'reviewed_bindings' object.\n")
    sys.exit(1)

required_binding_keys = [
    "task_sha256", "plan_sha256", "spec_sha256", "implementer_evidence_sha256",
    "parent_verification_sha256", "pre_window_manifest_sha256",
    "post_window_manifest_sha256", "repository_manifest_sha256",
    "aggregate_delta_manifest_sha256"
]

for k in echoed_bindings.keys():
    if k not in required_binding_keys:
        sys.stderr.write(f"ERROR: Unknown key '{k}' in reviewer reviewed_bindings (closed set validation).\n")
        sys.exit(1)

expected_map = {
    "task_sha256": task_hash,
    "plan_sha256": plan_hash,
    "spec_sha256": spec_hash,
    "implementer_evidence_sha256": impl_ev_hash,
    "parent_verification_sha256": pv_hash,
    "pre_window_manifest_sha256": pre_win_hash,
    "post_window_manifest_sha256": post_win_hash,
    "repository_manifest_sha256": pre_review_fingerprint,
    "aggregate_delta_manifest_sha256": agg_delta_hash
}

for bk in required_binding_keys:
    if bk not in echoed_bindings or not isinstance(echoed_bindings[bk], str) or not echoed_bindings[bk].strip():
        sys.stderr.write(f"ERROR: Reviewer reviewed_bindings missing mandatory key '{bk}'.\n")
        sys.exit(1)
    echoed_val = echoed_bindings[bk].strip()
    if len(echoed_val) != 64 or not all(c in '0123456789abcdef' for c in echoed_val):
        sys.stderr.write(f"ERROR: Reviewer binding '{bk}' value '{echoed_val}' is not a 64-lowercase-hex string.\n")
        sys.exit(1)
    exp_val = expected_map[bk]
    if echoed_val != exp_val:
        sys.stderr.write(f"ERROR: Reviewer binding mismatch for '{bk}': '{echoed_val}' != '{exp_val}'.\n")
        sys.exit(1)

# 5.9 Build and Publish Review Envelope Atomically
envelope = {
    "schema_version": 1,
    "reviewer": {
        "model_requested": effective_model if effective_model else "inherited",
        "effort_requested": "inherited",
        "sandbox_mode_requested": "read-only",
        "ephemeral": True,
        "exit_code_observed": 0,
        "repository_unchanged_verified": True
    },
    "review": {
        "verdict": verdict,
        "reason": reason,
        "findings": findings,
        "residual_risk": residual_risk,
        "reviewed_no_change": reviewed_no_change
    },
    "reviewed_bindings": echoed_bindings
}

envelope_bytes = (json.dumps(envelope, indent=2, ensure_ascii=False) + '\n').encode('utf-8')

open_flags = os.O_RDONLY
if hasattr(os, 'O_DIRECTORY'): open_flags |= os.O_DIRECTORY
if hasattr(os, 'O_NOFOLLOW'): open_flags |= os.O_NOFOLLOW

parent_fd = os.open(out_parent, open_flags)
try:
    target_filename = os.path.basename(review_output_file)
    tmp_filename = f".review-tmp.{os.getpid()}.{secrets.token_hex(8)}"
    create_flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, 'O_NOFOLLOW'): create_flags |= os.O_NOFOLLOW
    if hasattr(os, 'O_CLOEXEC'): create_flags |= os.O_CLOEXEC

    tmp_fd = os.open(tmp_filename, create_flags, 0o600, dir_fd=parent_fd)
    with open(tmp_fd, 'wb', closefd=False) as f:
        f.write(envelope_bytes)
        f.flush()
        os.fsync(f.fileno())
    os.close(tmp_fd)

    try:
        os.link(tmp_filename, target_filename, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
    except FileExistsError:
        sys.stderr.write(f"ERROR: Review output file already exists (no-clobber): {review_output_file}\n")
        sys.exit(1)
    finally:
        try: os.unlink(tmp_filename, dir_fd=parent_fd)
        except Exception: pass

    try: os.fsync(parent_fd)
    except Exception: pass
finally:
    try: os.close(parent_fd)
    except Exception: pass

print(f"Fresh review completed successfully: verdict = {verdict}")
sys.exit(0)
PY

exit 0
