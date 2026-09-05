#!/bin/sh
# Machine-enforced orchestration launcher for yiwan-sol-advisor on POSIX / Linux / WSL.
# Executes the autonomous five-stage software delivery state machine:
# 1. Dedicated ephemeral read-only Sol planning/spec authoring with inherited user reasoning effort (plan.json, worker-spec.md <= 24 KiB)
# 2. Antigravity CLI (gemini-3.8-flash-high) implementation window with per-window snapshot attribution
# 3. Parent working-tree machine integrity inspection, scoped Git metadata integrity, and cryptographic binding verification
# 4. Ephemeral read-only fresh Sol review gate with inherited user reasoning effort (SHIP / FIX-FIRST / RETHINK)
# 5. Bounded fix-first correction loop (up to MaxCorrections) or final structured delivery publication.

set -eu

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

workspace=""
task_file=""
result_file=""
timeout="60m"
planner_timeout="6m"
planner_heartbeat_interval="30s"
planner_idle_timeout="2m"
implementer_timeout="15m"
reviewer_timeout="8m"
idle_timeout="4m"
generation_preflight_timeout="60s"
machine_reserve="2m"
max_owned_files=6
max_verification_commands=4
max_corrections=1
dangerously_skip_permissions=1
planner_timeout_specified=0
implementer_timeout_specified=0
reviewer_timeout_specified=0
machine_reserve_specified=0
test_mode=0
test_agy_exe=""
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
    --task-file)
      [ $# -ge 2 ] || fail "Missing value for --task-file"
      task_file="$2"
      shift 2
      ;;
    --result-file)
      [ $# -ge 2 ] || fail "Missing value for --result-file"
      result_file="$2"
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] || fail "Missing value for --timeout"
      timeout="$2"
      shift 2
      ;;
    --planner-timeout) planner_timeout="$2"; planner_timeout_specified=1; shift 2 ;;
    --planner-heartbeat-interval) planner_heartbeat_interval="$2"; shift 2 ;;
    --planner-idle-timeout) planner_idle_timeout="$2"; shift 2 ;;
    --implementer-timeout) implementer_timeout="$2"; implementer_timeout_specified=1; shift 2 ;;
    --reviewer-timeout) reviewer_timeout="$2"; reviewer_timeout_specified=1; shift 2 ;;
    --idle-timeout) idle_timeout="$2"; shift 2 ;;
    --generation-preflight-timeout) generation_preflight_timeout="$2"; shift 2 ;;
    --machine-reserve) machine_reserve="$2"; machine_reserve_specified=1; shift 2 ;;
    --max-owned-files) max_owned_files="$2"; shift 2 ;;
    --max-verification-commands) max_verification_commands="$2"; shift 2 ;;
    --max-corrections)
      [ $# -ge 2 ] || fail "Missing value for --max-corrections"
      max_corrections="$2"
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
    --dangerously-skip-permissions)
      dangerously_skip_permissions=1
      shift 1
      ;;
    --enforce-interactive-permissions)
      dangerously_skip_permissions=0
      shift 1
      ;;
    --test-mode)
      test_mode=1
      shift 1
      ;;
    --test-agy-exe)
      [ $# -ge 2 ] || fail "Missing value for --test-agy-exe"
      test_agy_exe="$2"
      shift 2
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
[ -n "$task_file" ] || fail "task-file is required"
[ -n "$result_file" ] || fail "result-file is required"
case "$max_owned_files" in ''|*[!0-9]*) fail "max-owned-files must be a positive integer" ;; esac
case "$max_verification_commands" in ''|*[!0-9]*) fail "max-verification-commands must be a non-negative integer" ;; esac
[ "$max_owned_files" -ge 1 ] && [ "$max_owned_files" -le 50 ] || fail "max-owned-files must be between 1 and 50"
[ "$max_verification_commands" -le 50 ] || fail "max-verification-commands must be between 0 and 50"

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

# 2. Validate TaskFile
case "$task_file" in
  /*) ;;
  *) fail "task-file must be an absolute path: $task_file" ;;
esac
[ -f "$task_file" ] || fail "task-file does not exist or is not a file: $task_file"
[ ! -L "$task_file" ] || fail "task-file is a symbolic link: $task_file"

# Check task file size <= 1MB
"$py_bin" - "$task_file" <<'PY'
import sys, os
if os.path.getsize(sys.argv[1]) > 1048576:
    sys.stderr.write(f"ERROR: Task file exceeds maximum allowed size of 1MB ({os.path.getsize(sys.argv[1])} bytes).\n")
    sys.exit(1)
PY

task_parent=$(dirname "$task_file")
[ -d "$task_parent" ] || fail "task-file parent directory does not exist: $task_parent"
[ ! -L "$task_parent" ] || fail "task-file parent directory is a symbolic link: $task_parent"

curr=$task_parent
while [ "$curr" != "/" ] && [ -n "$curr" ] && [ "$curr" != "." ]; do
  if [ -L "$curr" ]; then
    fail "task-file parent ancestor is a symbolic link: $curr"
  fi
  p=$(dirname "$curr")
  if [ "$p" = "$curr" ]; then break; fi
  curr=$p
done

task_parent_real=$(CDPATH= cd "$task_parent" && pwd -P) || fail "Cannot resolve task-file parent directory: $task_parent"
case "$task_parent_real" in
  "$ws_real"|"$ws_real"/*)
    fail "task-file is inside target workspace: $task_parent_real"
    ;;
esac

task_file_real="$task_parent_real/$(basename "$task_file")"

# 3. Validate ResultFile
case "$result_file" in
  /*) ;;
  *) fail "result-file must be an absolute path: $result_file" ;;
esac

[ ! -e "$result_file" ] || fail "Result output destination already exists (no-clobber): $result_file"

res_parent=$(dirname "$result_file")
[ -d "$res_parent" ] || fail "result-file parent directory does not exist: $res_parent"
[ ! -L "$res_parent" ] || fail "result-file parent directory is a symbolic link: $res_parent"

curr=$res_parent
while [ "$curr" != "/" ] && [ -n "$curr" ] && [ "$curr" != "." ]; do
  if [ -L "$curr" ]; then
    fail "result-file parent ancestor is a symbolic link: $curr"
  fi
  p=$(dirname "$curr")
  if [ "$p" = "$curr" ]; then break; fi
  curr=$p
done

res_parent_real=$(CDPATH= cd "$res_parent" && pwd -P) || fail "Cannot resolve result-file parent directory: $res_parent"
case "$res_parent_real" in
  "$ws_real"|"$ws_real"/*)
    fail "result-file is inside target workspace: $res_parent_real"
    ;;
esac

# 4. Locate Bundled Scripts
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
impl_script="$script_dir/run-antigravity-implementer.sh"
reviewer_script="$script_dir/run-fresh-reviewer.sh"

[ -f "$impl_script" ] || fail "Bundled implementer script not found at: $impl_script"
[ -f "$reviewer_script" ] || fail "Bundled reviewer script not found at: $reviewer_script"

# 5. Determine Codex Executable & Test Mode
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

# 6. Execute Python Orchestrator
any_explicit_phase_budget=0
if [ "$planner_timeout_specified" -eq 1 ] || [ "$implementer_timeout_specified" -eq 1 ] || [ "$reviewer_timeout_specified" -eq 1 ] || [ "$machine_reserve_specified" -eq 1 ]; then
  any_explicit_phase_budget=1
fi

"$py_bin" - \
  "$ws_real" \
  "$task_file_real" \
  "$result_file" \
  "$res_parent_real" \
  "$impl_script" \
  "$reviewer_script" \
  "$codex_bin" \
  "$timeout" \
  "$planner_timeout" \
  "$planner_heartbeat_interval" \
  "$planner_idle_timeout" \
  "$implementer_timeout" \
  "$reviewer_timeout" \
  "$idle_timeout" \
  "$generation_preflight_timeout" \
  "$machine_reserve" \
  "$max_owned_files" \
  "$max_verification_commands" \
  "$max_corrections" \
  "$dangerously_skip_permissions" \
  "$effective_test_mode" \
  "$test_agy_exe" \
  "$test_codex_bin" \
  "$py_bin" \
  "$model" \
  "$reasoning_effort" \
  "$any_explicit_phase_budget" <<'PY'
import sys, os, subprocess, json, time, re, hashlib, secrets, stat, signal, threading

(ws_real, task_file_real, result_file, res_parent_real,
 impl_script, reviewer_script, codex_bin, timeout_str,
 planner_timeout_str, planner_heartbeat_interval_str, planner_idle_timeout_str,
 implementer_timeout_str, reviewer_timeout_str,
 idle_timeout_str, generation_preflight_timeout_str, machine_reserve_str,
 max_owned_files_str, max_verification_commands_str,
 max_corrections_str, danger_perm_str, effective_test_mode_str,
 test_agy_exe, test_codex_bin, py_bin, model_arg, effort_arg, any_explicit_budget_str) = sys.argv[1:28]

max_corrections = int(max_corrections_str)
danger_perm = danger_perm_str == "1"
test_mode = effective_test_mode_str == "1"

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
effective_codex_model = model_arg.strip() if model_arg.strip() else (os.environ.get("SOL_ADVISOR_MODEL") or os.environ.get("CODEX_MODEL") or inherited_codex_cfg.get("model"))
effective_reasoning_effort = effort_arg.strip() if effort_arg.strip() else inherited_codex_cfg.get("effort")

def parse_duration(d):
    d = d.strip()
    m = re.match(r'^(\d+)h(?:(\d+)m)?$', d)
    if m: return int(m.group(1)) * 3600 + int(m.group(2) or 0) * 60
    m = re.match(r'^(\d+)m(?:(\d+)s)?$', d)
    if m: return int(m.group(1)) * 60 + int(m.group(2) or 0)
    m = re.match(r'^(\d+)s$', d)
    if m: return int(m.group(1))
    m = re.match(r'^(\d+)$', d)
    if m: return int(m.group(1))
    sys.stderr.write(f"ERROR: Invalid duration format '{d}'.\n")
    sys.exit(1)

total_timeout_sec = parse_duration(timeout_str)
planner_timeout_sec = parse_duration(planner_timeout_str)
planner_heartbeat_interval_sec = parse_duration(planner_heartbeat_interval_str)
planner_idle_timeout_sec = parse_duration(planner_idle_timeout_str)
if planner_idle_timeout_sec > planner_timeout_sec:
    planner_idle_timeout_sec = planner_timeout_sec
if planner_heartbeat_interval_sec > planner_timeout_sec:
    planner_heartbeat_interval_sec = planner_timeout_sec
implementer_timeout_sec = parse_duration(implementer_timeout_str)
reviewer_timeout_sec = parse_duration(reviewer_timeout_str)
idle_timeout_sec = parse_duration(idle_timeout_str)
generation_preflight_timeout_sec = parse_duration(generation_preflight_timeout_str)
machine_reserve_sec = parse_duration(machine_reserve_str)
max_owned_files = int(max_owned_files_str)
max_verification_commands = int(max_verification_commands_str)
minimum_iteration_budget_sec = planner_timeout_sec + implementer_timeout_sec + reviewer_timeout_sec + machine_reserve_sec

any_explicit_phase_budget = any_explicit_budget_str == "1"
is_dynamically_scaled = False
if any_explicit_phase_budget:
    if total_timeout_sec < minimum_iteration_budget_sec:
        raise SystemExit(f"ERROR: total timeout {timeout_str} is too short for one safe iteration; at least {minimum_iteration_budget_sec}s are required")
else:
    if total_timeout_sec < minimum_iteration_budget_sec:
        min_safe_total_sec = 180
        if total_timeout_sec < min_safe_total_sec:
            raise SystemExit(f"ERROR: total timeout {timeout_str} is too short for one safe iteration; at least {min_safe_total_sec}s are required")
        is_dynamically_scaled = True
        planner_timeout_sec = max(45, int(total_timeout_sec * 0.20))
        implementer_timeout_sec = max(90, int(total_timeout_sec * 0.50))
        reviewer_timeout_sec = max(45, int(total_timeout_sec * 0.25))
        machine_reserve_sec = max(10, total_timeout_sec - (planner_timeout_sec + implementer_timeout_sec + reviewer_timeout_sec))
        minimum_iteration_budget_sec = 190

        if idle_timeout_sec > implementer_timeout_sec:
            idle_timeout_sec = implementer_timeout_sec
        if generation_preflight_timeout_sec >= implementer_timeout_sec:
            generation_preflight_timeout_sec = max(10, int(implementer_timeout_sec * 0.2))
        if planner_heartbeat_interval_sec > planner_timeout_sec:
            planner_heartbeat_interval_sec = max(10, int(planner_timeout_sec * 0.25))
        if planner_idle_timeout_sec > planner_timeout_sec:
            planner_idle_timeout_sec = planner_timeout_sec
        sys.stderr.write(f"INFO: Total timeout ({total_timeout_sec}s) is smaller than default phase budget sum. Dynamically scaled phase budgets: Planner={planner_timeout_sec}s, Implementer={implementer_timeout_sec}s, Reviewer={reviewer_timeout_sec}s, MachineReserve={machine_reserve_sec}s\n")

if idle_timeout_sec > implementer_timeout_sec:
    raise SystemExit("ERROR: idle timeout must not exceed implementer timeout")
if generation_preflight_timeout_sec >= implementer_timeout_sec:
    raise SystemExit("ERROR: generation preflight timeout must be shorter than implementer timeout")
start_time = time.time()

active_child_procs = []

def terminate_tree(p):
    if not p: return
    if hasattr(os, 'killpg') and hasattr(os, 'getpgid'):
        try: os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception: pass
    try: p.kill()
    except Exception: pass

def register_process(p):
    if p and p not in active_child_procs:
        active_child_procs.append(p)

def unregister_process(p):
    if p:
        try: active_child_procs.remove(p)
        except ValueError: pass

def process_tree_cpu(pid):
    visited = set()
    def read_one(current):
        if current in visited:
            return 0
        visited.add(current)
        total = 0
        try:
            with open(f"/proc/{current}/stat", "r", encoding="ascii") as stream:
                fields = stream.read().split()
            total += int(fields[13]) + int(fields[14])
        except Exception:
            pass
        try:
            children = set()
            for task in os.listdir(f"/proc/{current}/task"):
                try:
                    with open(f"/proc/{current}/task/{task}/children", "r", encoding="ascii") as stream:
                        children.update(int(value) for value in stream.read().split())
                except Exception:
                    pass
            for child in children:
                total += read_one(child)
        except Exception:
            pass
        return total
    try:
        return read_one(pid)
    except Exception:
        return 0

def get_remaining_timeout(max_step=60):
    rem = total_timeout_sec - (time.time() - start_time)
    if rem <= 0:
        sys.stderr.write(f"ERROR: Sol Advisor orchestration exceeded total timeout of {timeout_str} ({total_timeout_sec}s).\n")
        sys.exit(1)
    return min(max_step, rem)

with open(task_file_real, 'rb') as f:
    raw_task_bytes = f.read()

task_content = raw_task_bytes.decode('utf-8', errors='replace')
if not task_content.strip():
    sys.stderr.write(f"ERROR: Task file is empty: {task_file_real}\n")
    sys.exit(1)

task_sha256 = hashlib.sha256(raw_task_bytes).hexdigest()

def run_git(args, timeout=30):
    r = subprocess.run(["git", "-C", ws_real] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=get_remaining_timeout(timeout))
    if r.returncode != 0:
        sys.stderr.write(f"ERROR: Git command failed: git {' '.join(args)}\n{r.stderr.decode('utf-8', errors='replace')}\n")
        sys.exit(1)
    return r.stdout

def run_git_allow_fail(args, timeout=30):
    r = subprocess.run(["git", "-C", ws_real] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=get_remaining_timeout(timeout))
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

baseline_head_sha = run_git(["rev-parse", "HEAD"]).strip().decode('utf-8')
ref_res = run_git_allow_fail(["symbolic-ref", "-q", "HEAD"])
baseline_head_ref = ref_res.strip().decode('utf-8') if ref_res else "DETACHED"

def assert_head_unchanged(phase_label):
    curr_head = run_git(["rev-parse", "HEAD"]).strip().decode('utf-8')
    if curr_head != baseline_head_sha:
        sys.stderr.write(f"ERROR: Baseline HEAD immutability violated during {phase_label}: HEAD commit changed from '{baseline_head_sha}' to '{curr_head}'. Antigravity must not commit or advance HEAD.\n")
        sys.exit(1)

def get_scoped_git_metadata_digest(include_index=True):
    h = hashlib.sha256()
    git_dir_rel = run_git(["rev-parse", "--git-dir"]).strip().decode('utf-8')
    git_dir_full = os.path.normpath(os.path.join(ws_real, git_dir_rel))

    head_file = os.path.join(git_dir_full, "HEAD")
    if os.path.isfile(head_file):
        with open(head_file, 'rb') as f: h.update(b"HEAD_FILE:" + hashlib.sha256(f.read()).hexdigest().encode('utf-8') + b"\n")
    else:
        h.update(b"HEAD_FILE:MISSING\n")

    h.update(b"HEAD_SHA:" + run_git(["rev-parse", "HEAD"]).strip() + b"\n")
    ref_res_val = run_git_allow_fail(["symbolic-ref", "-q", "HEAD"])
    ref_val = ref_res_val.strip() if ref_res_val else b"DETACHED"
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

def is_ignored_runtime_cache_path(p):
    if isinstance(p, bytes):
        try:
            p_str = p.decode('utf-8')
        except Exception:
            return False
    else:
        p_str = str(p)
    norm = p_str.replace('\\', '/').strip('/')
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

def get_repo_fingerprint():
    h = hashlib.sha256()
    h.update(b"HEAD:" + run_git(["rev-parse", "HEAD"]).strip() + b"\n")
    ref_res_val = run_git_allow_fail(["symbolic-ref", "-q", "HEAD"])
    h.update(b"REF:" + (ref_res_val.strip() if ref_res_val else b"DETACHED") + b"\n")
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
        if is_ignored_runtime_cache_path(uf):
            continue
        fp = os.path.join(ws_real.encode('utf-8'), uf)
        if os.path.isfile(fp):
            f_len, f_hash = get_file_sha256_and_len(fp)
            h.update(uf + b":" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8') + b"\n")

    dirty_raw = run_git(["diff", "--name-only", "HEAD", "-z"])
    dirty_files = [p for p in dirty_raw.split(b'\0') if p]
    dirty_files.sort()
    h.update(b"DIRTY_TRACKED_FILES:\n")
    for df in dirty_files:
        fp = os.path.join(ws_real.encode('utf-8'), df)
        if os.path.isfile(fp):
            f_len, f_hash = get_file_sha256_and_len(fp)
            h.update(df + b":" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8') + b"\n")
        else:
            h.update(df + b":DELETED\n")
    return h.hexdigest()

def capture_repository_snapshot():
    file_map = {}

    # 1. Tracked index entries via git ls-files --stage -z (raw bytes)
    stage_raw = run_git(["ls-files", "--stage", "-z"])
    for entry in [t for t in stage_raw.split(b'\0') if t]:
        tab_idx = entry.find(b'\t')
        if tab_idx > 0:
            meta = entry[:tab_idx]
            raw_path = entry[tab_idx+1:].lstrip(b'/')
            full_p = os.path.join(ws_real.encode('utf-8'), raw_path)
            f_len, f_hash = get_file_sha256_and_len(full_p)
            record = b"INDEX_RECORD:" + meta
            if raw_path in file_map:
                file_map[raw_path] += b"|" + record
            else:
                file_map[raw_path] = record + b"|WT:" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8')

    # 2. Augment with porcelain v1 -z output for rename/copy detection & status
    status_raw = run_git(["status", "--porcelain=v1", "-z"])
    tokens = [t for t in status_raw.split(b'\0') if t]
    idx = 0
    while idx < len(tokens):
        token = tokens[idx]
        if len(token) >= 4:
            st = token[:2]
            p = token[3:].lstrip(b'/')
            if b'R' in st or b'C' in st:
                dest_path = p
                src_path = b""
                idx += 1
                if idx < len(tokens):
                    src_path = tokens[idx].lstrip(b'/')
                full_dest = os.path.join(ws_real.encode('utf-8'), dest_path)
                d_len, d_hash = get_file_sha256_and_len(full_dest)
                dest_base = file_map.get(dest_path, b"WT:" + str(d_len).encode('utf-8') + b":" + d_hash.encode('utf-8'))
                file_map[dest_path] = dest_base + b"|STATUS:" + st + b":DEST"
                if src_path:
                    full_src = os.path.join(ws_real.encode('utf-8'), src_path)
                    s_len, s_hash = get_file_sha256_and_len(full_src)
                    src_base = file_map.get(src_path, b"WT:" + str(s_len).encode('utf-8') + b":" + s_hash.encode('utf-8'))
                    file_map[src_path] = src_base + b"|STATUS:" + st + b":SRC"
            else:
                full_p = os.path.join(ws_real.encode('utf-8'), p)
                f_len, f_hash = get_file_sha256_and_len(full_p)
                p_base = file_map.get(p, b"WT:" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8'))
                file_map[p] = p_base + b"|STATUS:" + st
        idx += 1

    # 3. Add untracked files
    untracked_raw = run_git(["ls-files", "--others", "--exclude-standard", "-z"])
    for uf in [t for t in untracked_raw.split(b'\0') if t]:
        norm_uf = uf.lstrip(b'/')
        if is_ignored_runtime_cache_path(norm_uf):
            continue
        full_uf = os.path.join(ws_real.encode('utf-8'), norm_uf)
        f_len, f_hash = get_file_sha256_and_len(full_uf)
        file_map[norm_uf] = b"UNTRACKED:" + str(f_len).encode('utf-8') + b":" + f_hash.encode('utf-8')

    return {
        "head_sha": run_git(["rev-parse", "HEAD"]).strip().decode('utf-8'),
        "file_map": file_map
    }

def get_window_delta(pre_snap, post_snap):
    changed_raw = set()
    for k, v in post_snap["file_map"].items():
        if is_ignored_runtime_cache_path(k):
            continue
        if k not in pre_snap["file_map"] or pre_snap["file_map"][k] != v:
            changed_raw.add(k)
    for k in pre_snap["file_map"].keys():
        if is_ignored_runtime_cache_path(k):
            continue
        if k not in post_snap["file_map"]:
            changed_raw.add(k)

    # Losslessly decode raw path bytes to UTF-8; fail closed if invalid
    changed_str = []
    for p_bytes in changed_raw:
        try:
            p_str = p_bytes.decode('utf-8')
        except UnicodeDecodeError:
            sys.stderr.write(f"ERROR: Changed repository path cannot be losslessly decoded to UTF-8: {p_bytes!r}\n")
            sys.exit(1)
        changed_str.append(p_str)
    changed_str.sort()
    return changed_str

initial_snapshot = capture_repository_snapshot()

# Create private run directory
run_dir_name = f".sol-advisor-run.{os.getpid()}.{secrets.token_hex(8)}"
run_dir = os.path.join(res_parent_real, run_dir_name)
os.makedirs(run_dir, exist_ok=True)

iteration = 1
last_plan = None
last_impl_evidence_raw = ""
last_parent_verification_raw = ""
last_review_raw = ""
last_implementer_evidence = None
last_parent_verification = None
last_review_findings = ""
last_review_reason = ""
reviewed_no_change_accepted = False
final_report_text = None
stage_telemetry = []

try:
    while iteration <= (max_corrections + 1):
        elapsed = time.time() - start_time
        if elapsed >= total_timeout_sec:
            sys.stderr.write(f"ERROR: Sol Advisor orchestration exceeded total timeout of {timeout_str} ({total_timeout_sec}s).\n")
            sys.exit(1)
        remaining_iteration = int(total_timeout_sec - elapsed)
        if remaining_iteration < minimum_iteration_budget_sec:
            sys.stderr.write(f"ERROR: Insufficient remaining budget for a safe complete iteration: {remaining_iteration}s remain, {minimum_iteration_budget_sec}s are reserved. No new writer window was started.\n")
            sys.exit(1)

        if not any_explicit_phase_budget and is_dynamically_scaled:
            current_iter_budget = min(total_timeout_sec, remaining_iteration)
            planner_timeout_sec = max(45, int(current_iter_budget * 0.20))
            implementer_timeout_sec = max(90, int(current_iter_budget * 0.50))
            reviewer_timeout_sec = max(45, int(current_iter_budget * 0.25))
            machine_reserve_sec = max(10, current_iter_budget - (planner_timeout_sec + implementer_timeout_sec + reviewer_timeout_sec))

        iter_dir = os.path.join(run_dir, f"iteration-{iteration}")
        os.makedirs(iter_dir, exist_ok=True)
        print(f"=== [Sol Advisor Iteration {iteration} / {max_corrections + 1}] ===")

        # STAGE 1: Architecture & Specification Planning (read-only Sol, inherited effort)
        sw_stage1 = time.monotonic()
        assert_head_unchanged("before planning stage")
        fp_before_plan = get_repo_fingerprint()

        planner_model_desc = f"model: {effective_codex_model}" if effective_codex_model else "inherited Codex model"
        if iteration == 1:
            planner_prompt = f"""ROLE CONTRACT:
You are the dedicated Sol planner and architect for workspace: {ws_real} ({planner_model_desc}). Use the reasoning effort inherited from the user's current Codex configuration; do not require or claim a fixed effort tier.
You MUST NOT implement code directly. All code edits are performed exclusively by Google Antigravity CLI.
Your sandbox is strictly read-only.
Analyze requirements, inspect workspace conventions, and author an implementation plan.
Bound this iteration to at most {max_owned_files} exact owned file paths and at most {max_verification_commands} verification commands. Prefer one independently verifiable phase.

USER TASK:
{task_content}

OUTPUT REQUIREMENTS:
You must output ONLY a valid JSON object matching the following schema (no markdown fences or conversational text):
{{
  "objective": "<concrete observable outcome>",
  "owned_files": [
    "<exact relative file or directory path 1>",
    "<exact relative file or directory path 2>"
  ],
  "interfaces": "<signatures, types, schemas, commands, or protocol behaviors to preserve>",
  "constraints": "<repository conventions, safety boundaries, excluded scope>",
  "verification_commands": [
    "<suggested test/verification command 1>",
    "<suggested test/verification command 2>"
  ]
}}"""
        else:
            prior_review_summary = last_review_raw if last_review_raw else "None"
            prior_impl_summary = last_impl_evidence_raw if last_impl_evidence_raw else "None"
            prior_pv_summary = last_parent_verification_raw if last_parent_verification_raw else "None"
            prior_review_hash = hashlib.sha256(last_review_raw.encode('utf-8')).hexdigest()
            prior_impl_hash = hashlib.sha256(last_impl_evidence_raw.encode('utf-8')).hexdigest()
            prior_pv_hash = hashlib.sha256(last_parent_verification_raw.encode('utf-8')).hexdigest()

            planner_prompt = f"""ROLE CONTRACT:
You are the dedicated Sol correction planner and architect for workspace: {ws_real} ({planner_model_desc}). Use the reasoning effort inherited from the user's current Codex configuration; do not require or claim a fixed effort tier.
You MUST NOT implement code directly. All code edits are performed exclusively by Google Antigravity CLI.
Your sandbox is strictly read-only.
The previous iteration received a FIX-FIRST verdict during review.
Analyze the complete prior review envelope, parent verification results, and prior implementer evidence, and author a targeted correction plan.
Focus strictly on the delta and the specific verification failures reported in the prior review. DO NOT re-scan or traverse the entire repository.
Bound this correction to at most {max_owned_files} exact owned file paths and at most {max_verification_commands} verification commands.

USER TASK:
{task_content}

PREVIOUS PLAN OBJECTIVE:
{last_plan.get('objective')}

PREVIOUS REVIEW ENVELOPE (SHA-256: {prior_review_hash}):
{prior_review_summary}

PREVIOUS IMPLEMENTER EVIDENCE (SHA-256: {prior_impl_hash}):
{prior_impl_summary}

PREVIOUS PARENT VERIFICATION EVIDENCE (SHA-256: {prior_pv_hash}):
{prior_pv_summary}

OUTPUT REQUIREMENTS:
You must output ONLY a valid JSON object matching the following schema (no markdown fences or conversational text):
{{
  "objective": "<concrete observable outcome for this correction>",
  "owned_files": [
    "<exact relative file or directory path 1>",
    "<exact relative file or directory path 2>"
  ],
  "interfaces": "<signatures, types, schemas, commands, or protocol behaviors to preserve>",
  "constraints": "<repository conventions, safety boundaries, excluded scope>",
  "verification_commands": [
    "<suggested test/verification command 1>",
    "<suggested test/verification command 2>"
  ]
}}"""

        # Bound planner prompt (3 MiB cap)
        prompt_bytes = planner_prompt.encode('utf-8')
        if len(prompt_bytes) > 3145728:
            sys.stderr.write(f"ERROR: Assembled planner prompt exceeds finite cap of 3 MiB ({len(prompt_bytes)} bytes).\n")
            sys.exit(1)

        plan_msg_file = os.path.join(iter_dir, ".plan-msg.tmp")
        plan_cmd = [
            codex_bin,
            "exec"
        ]
        if effective_codex_model:
            plan_cmd.extend(["-m", effective_codex_model])
        plan_cmd.extend([
            "-s", "read-only",
            "--ephemeral",
            "--ignore-user-config"
        ])
        if effective_reasoning_effort:
            plan_cmd.extend(["-c", f'model_reasoning_effort="{effective_reasoning_effort}"'])
        for feat in ("apps", "plugins", "remote_plugin", "recommended_plugins", "browser_use", "browser_use_external", "computer_use", "in_app_browser", "memories", "image_generation", "workspace_dependencies", "skill_search"):
            plan_cmd.extend(["--disable", feat])
        plan_cmd.extend([
            "-C", ws_real,
            "--color", "never",
            "-o", plan_msg_file
        ])

        rem_plan_sec = min(planner_timeout_sec, int(total_timeout_sec - (time.time() - start_time)))
        if rem_plan_sec <= 0:
            sys.stderr.write("ERROR: Sol planning stage exceeded remaining timeout.\n")
            sys.exit(1)

        plan_started = time.monotonic()
        plan_state = {
            "last_activity": plan_started,
            "kind": "startup",
            "out": 0,
            "err": 0,
            "plan_bytes": 0,
            "cpu": 0,
            "stdout_chunks": [],
            "stderr_chunks": []
        }
        plan_lock = threading.Lock()

        def read_pipe(pipe, kind):
            while True:
                chunk = pipe.read(4096)
                if not chunk:
                    break
                with plan_lock:
                    plan_state[kind] += len(chunk)
                    plan_state[f"{kind}_chunks"].append(chunk)
                    plan_state["last_activity"] = time.monotonic()
                    plan_state["kind"] = "stdout" if kind == "out" else "stderr"

        p = None
        try:
            p = subprocess.Popen(
                plan_cmd,
                cwd=ws_real,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid if hasattr(os, 'setsid') else None
            )
            register_process(p)
            if prompt_bytes:
                p.stdin.write(prompt_bytes)
                p.stdin.flush()
            p.stdin.close()

            t_out = threading.Thread(target=read_pipe, args=(p.stdout, "out"), daemon=True)
            t_err = threading.Thread(target=read_pipe, args=(p.stderr, "err"), daemon=True)
            t_out.start()
            t_err.start()

            last_cpu = process_tree_cpu(p.pid)
            last_probe = -2
            last_heartbeat = -planner_heartbeat_interval_sec
            last_plan_size = 0
            planner_timed_out = False
            planner_idle_timed_out = False

            while p.poll() is None:
                time.sleep(0.1)
                now = time.monotonic()
                elapsed = int(now - plan_started)

                with plan_lock:
                    idle = int(now - plan_state["last_activity"])
                    out_bytes = plan_state["out"]
                    err_bytes = plan_state["err"]
                    last_kind = plan_state["kind"]

                if out_bytes > 4 * 1024 * 1024 or err_bytes > 4 * 1024 * 1024:
                    terminate_tree(p)
                    sys.stderr.write("ERROR: Sol planner output exceeded the 4 MiB diagnostic limit.\n")
                    sys.exit(1)

                if elapsed >= rem_plan_sec:
                    planner_timed_out = True
                    break

                if elapsed - last_probe >= 1:
                    last_probe = elapsed
                    cpu = process_tree_cpu(p.pid)
                    plan_size = 0
                    if os.path.isfile(plan_msg_file):
                        try: plan_size = os.path.getsize(plan_msg_file)
                        except Exception: pass
                    iter_plan = os.path.join(iter_dir, "plan.json")
                    if os.path.isfile(iter_plan):
                        try: plan_size += os.path.getsize(iter_plan)
                        except Exception: pass

                    with plan_lock:
                        if plan_size > last_plan_size:
                            last_plan_size = plan_size
                            plan_state["last_activity"] = now
                            plan_state["kind"] = "file-growth"
                            plan_state["plan_bytes"] = plan_size
                        if cpu >= last_cpu + 10:
                            last_cpu = cpu
                            plan_state["last_activity"] = now
                            plan_state["kind"] = "process-cpu"
                            plan_state["cpu"] = cpu
                        idle = int(now - plan_state["last_activity"])
                        last_kind = plan_state["kind"]

                if idle >= planner_idle_timeout_sec:
                    planner_idle_timed_out = True
                    break

                if elapsed - last_heartbeat >= planner_heartbeat_interval_sec:
                    last_heartbeat = elapsed
                    state_label = "analyzing"
                    if last_kind == "file-growth":
                        state_label = "file-growth"
                    elif last_kind in ("stdout", "stderr"):
                        state_label = "tool-execution"
                    elif idle >= 5:
                        state_label = "waiting-model"

                    hb = {
                        "event": "SOL_ADVISOR_HEARTBEAT",
                        "stage": "sol-planner",
                        "elapsed_seconds": elapsed,
                        "hard_timeout_seconds": planner_timeout_sec,
                        "idle_timeout_seconds": planner_idle_timeout_sec,
                        "idle_seconds": idle,
                        "last_activity_kind": last_kind,
                        "stdout_bytes": out_bytes,
                        "stderr_bytes": err_bytes,
                        "plan_bytes": last_plan_size,
                        "cpu_ms": last_cpu,
                        "state": state_label
                    }
                    sys.stderr.write(json.dumps(hb) + "\n")
                    sys.stderr.flush()

            t_out.join(timeout=1)
            t_err.join(timeout=1)

            if planner_timed_out or planner_idle_timed_out:
                terminate_tree(p)
                diag_dir = os.path.join(res_parent_real, f"planner-diagnostics-iter-{iteration}")
                os.makedirs(diag_dir, exist_ok=True)
                with plan_lock:
                    out_all = b"".join(plan_state["stdout_chunks"]).decode('utf-8', errors='replace')
                    err_all = b"".join(plan_state["stderr_chunks"]).decode('utf-8', errors='replace')
                    diag_data = {
                        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "stage": "sol-planner",
                        "iteration": iteration,
                        "timeout_kind": "idle_timeout" if planner_idle_timed_out else "hard_timeout",
                        "failure_reason": f"Sol planner idle timeout of {planner_idle_timeout_sec}s exceeded" if planner_idle_timed_out else f"Sol planning stage exceeded timeout of {planner_timeout_sec}s",
                        "elapsed_seconds": elapsed,
                        "idle_seconds": idle,
                        "last_activity_kind": last_kind,
                        "stdout_bytes": out_bytes,
                        "stderr_bytes": err_bytes,
                        "plan_bytes": last_plan_size,
                        "cpu_ms": last_cpu
                    }
                with open(os.path.join(diag_dir, "planner-stdout.log"), "w", encoding="utf-8") as f:
                    f.write(out_all)
                with open(os.path.join(diag_dir, "planner-stderr.log"), "w", encoding="utf-8") as f:
                    f.write(err_all)
                with open(os.path.join(diag_dir, "diagnostics.json"), "w", encoding="utf-8") as f:
                    json.dump(diag_data, f, indent=2)
                if os.path.isfile(plan_msg_file):
                    try:
                        import shutil
                        shutil.copyfile(plan_msg_file, os.path.join(diag_dir, "plan-msg-partial.tmp"))
                    except Exception: pass

                if planner_idle_timed_out:
                    sys.stderr.write(f"ERROR: Sol planner idle timeout of {planner_idle_timeout_sec}s exceeded; no stdout, stderr, plan file growth, or process CPU progress was observed. Diagnostics preserved at: {diag_dir}\n")
                else:
                    sys.stderr.write(f"ERROR: Sol planning stage exceeded timeout. Diagnostics preserved at: {diag_dir}\n")
                sys.exit(1)

            with plan_lock:
                raw_out_bytes = b"".join(plan_state["stdout_chunks"])
                raw_err_bytes = b"".join(plan_state["stderr_chunks"])
            stdout = raw_out_bytes
            stderr = raw_err_bytes

            if p.returncode != 0:
                diag_dir = os.path.join(res_parent_real, f"planner-diagnostics-iter-{iteration}")
                try:
                    os.makedirs(diag_dir, exist_ok=True)
                    with open(os.path.join(diag_dir, "planner-stdout.log"), "w", encoding="utf-8") as f:
                        f.write(stdout.decode('utf-8', errors='replace'))
                    with open(os.path.join(diag_dir, "planner-stderr.log"), "w", encoding="utf-8") as f:
                        f.write(stderr.decode('utf-8', errors='replace'))
                except Exception: pass
                sys.stderr.write(f"ERROR: Sol planner failed with code {p.returncode}: {stderr.decode('utf-8', errors='replace')}\n")
                sys.exit(1)
        finally:
            unregister_process(p)
            if p and p.poll() is None:
                terminate_tree(p)

        assert_head_unchanged("after planning stage")
        fp_after_plan = get_repo_fingerprint()
        if fp_before_plan != fp_after_plan:
            sys.stderr.write("ERROR: Repository attribution violation: repository was modified during read-only Sol planning stage!\n")
            sys.exit(1)

        plan_raw = ""
        if os.path.exists(plan_msg_file):
            with open(plan_msg_file, 'r', encoding='utf-8') as f: plan_raw = f.read()
            try: os.unlink(plan_msg_file)
            except Exception: pass
        else:
            plan_raw = stdout.decode('utf-8', errors='replace')

        if len(plan_raw) > 2097152:
            sys.stderr.write("ERROR: Sol planner output exceeds 2 MiB limit.\n")
            sys.exit(1)

        clean_plan_json = plan_raw.strip()
        if clean_plan_json.startswith('```'):
            lines = [l for l in clean_plan_json.splitlines() if not l.strip().startswith('```')]
            clean_plan_json = "\n".join(lines).strip()

        try:
            plan_obj = json.loads(clean_plan_json)
        except Exception as e:
            sys.stderr.write(f"ERROR: Sol planner output is not valid JSON: {plan_raw}\n")
            sys.exit(1)

        if not isinstance(plan_obj, dict):
            sys.stderr.write("ERROR: Sol plan must be a JSON object.\n")
            sys.exit(1)

        allowed_keys = {"objective", "owned_files", "interfaces", "constraints", "verification_commands", "suggested_verification_commands"}
        for k in plan_obj.keys():
            if k not in allowed_keys:
                sys.stderr.write(f"ERROR: Unknown key '{k}' in plan.json (strict schema validation).\n")
                sys.exit(1)

        if not plan_obj.get("objective"): sys.stderr.write("ERROR: Sol plan missing objective.\n"); sys.exit(1)
        if not plan_obj.get("owned_files") or not isinstance(plan_obj["owned_files"], list):
            sys.stderr.write("ERROR: Sol plan missing owned_files list.\n"); sys.exit(1)
        if len(plan_obj["owned_files"]) > max_owned_files:
            sys.stderr.write(f"ERROR: Sol plan owned_files exceeds the bounded maximum of {max_owned_files} items.\n"); sys.exit(1)

        for of in plan_obj["owned_files"]:
            if not isinstance(of, str) or not of.strip() or of.startswith('/') or '..' in of or ':' in of:
                sys.stderr.write(f"ERROR: Invalid owned_files entry in plan: {of!r}\n")
                sys.exit(1)

        ver_cmds = plan_obj.get("verification_commands") or plan_obj.get("suggested_verification_commands") or []
        if len(ver_cmds) > max_verification_commands:
            sys.stderr.write(f"ERROR: Sol plan verification_commands exceeds the bounded maximum of {max_verification_commands} items.\n")
            sys.exit(1)

        plan_json_path = os.path.join(iter_dir, "plan.json")
        plan_json_str = json.dumps(plan_obj, indent=2)
        with open(plan_json_path, 'w', encoding='utf-8') as f:
            f.write(plan_json_str)

        last_plan = plan_obj

        # Render five-part worker-spec.md (capped at 24 KiB)
        owned_files_md = "\n".join([f"- {of}" for of in plan_obj["owned_files"]])
        interfaces_val = plan_obj.get("interfaces", "")
        interfaces_md = "\n".join([f"- {i}" for i in interfaces_val]) if isinstance(interfaces_val, list) else str(interfaces_val)
        constraints_val = plan_obj.get("constraints", "")
        constraints_md = "\n".join([f"- {c}" for c in constraints_val]) if isinstance(constraints_val, list) else str(constraints_val)
        ver_cmds_md = "\n".join([f"- Run: {vc}\n  Success: exit code 0" for vc in ver_cmds]) if ver_cmds else "- Run: true\n  Success: exit code 0"

        worker_spec = f"""OBJECTIVE
{plan_obj['objective']}

FILES AND OWNERSHIP
You own only:
{owned_files_md}

You are not alone in the codebase. Other agents or the user may be editing concurrently.
Preserve their edits, do not revert unrelated work, and adapt to changes already present.
Do not modify files outside your ownership.

INTERFACES
{interfaces_md}

CONSTRAINTS
{constraints_md}
- Do not redesign or redo architecture; follow the specification strictly.
- No fallback models or alternate execution providers.
- Focus strictly on owned files and incremental fixes; do not crawl or re-index the broader repository.
- Micro-verification only: do not run entire test suites or full regression suites; test only the specific changes or leaf tests relevant to owned files.
- In your final response under 'VERIFIED:', explicitly record each verification command run and its numeric exit code (e.g., "(exit code 0)").

VERIFICATION
{ver_cmds_md}
"""
        spec_bytes = worker_spec.encode('utf-8')
        if len(spec_bytes) > 24576:
            sys.stderr.write(f"ERROR: Rendered worker-spec.md exceeds conservative maximum size of 24 KiB ({len(spec_bytes)} bytes).\n")
            sys.exit(1)

        worker_spec_path = os.path.join(iter_dir, "worker-spec.md")
        with open(worker_spec_path, 'wb') as f:
            f.write(spec_bytes)
        stage1_sec = round(time.monotonic() - sw_stage1, 2)

        # STAGE 2: Antigravity Code Implementation Window
        sw_stage2 = time.monotonic()
        assert_head_unchanged("before Antigravity implementation window")
        pre_impl_snapshot = capture_repository_snapshot()
        pre_impl_manifest_hash = get_repo_fingerprint()
        pre_impl_meta_hash = get_scoped_git_metadata_digest(include_index=False)

        impl_evidence_path = os.path.join(iter_dir, "implementer-evidence.json")
        rem_impl_sec = min(implementer_timeout_sec, int(total_timeout_sec - (time.time() - start_time)))
        if rem_impl_sec <= 0:
            sys.stderr.write("ERROR: Sol Advisor orchestration exceeded total timeout before implementer window.\n")
            sys.exit(1)

        impl_cmd = [
            "sh", impl_script,
            "--workspace", ws_real,
            "--spec-file", worker_spec_path,
            "--evidence-file", impl_evidence_path,
            "--print-timeout", f"{rem_impl_sec}s",
            "--idle-timeout", idle_timeout_str,
            "--generation-preflight-timeout", generation_preflight_timeout_str
        ]
        if iteration > 1:
            impl_cmd.append("--skip-generation-preflight")
        if danger_perm:
            impl_cmd.append("--dangerously-skip-permissions")
        if test_mode:
            impl_cmd.append("--test-mode")
            if test_agy_exe:
                impl_cmd.extend(["--test-agy-exe", test_agy_exe])

        p_impl = None
        try:
            p_impl = subprocess.Popen(impl_cmd, preexec_fn=os.setsid if hasattr(os, 'setsid') else None)
            register_process(p_impl)
            impl_outer_sec = min(rem_impl_sec + 5, max(1, int(total_timeout_sec - (time.time() - start_time))))
            impl_exit_code = p_impl.wait(timeout=impl_outer_sec)
            if impl_exit_code != 0:
                post_failure_snapshot = capture_repository_snapshot()
                partial_files = get_window_delta(pre_impl_snapshot, post_failure_snapshot)
                sys.stderr.write(json.dumps({
                    "event": "SOL_ADVISOR_FAILURE",
                    "stage": "implementation-window",
                    "reason": f"Implementer wrapper exited with code {impl_exit_code}",
                    "completed": False,
                    "reviewed": False,
                    "partial_worktree_trusted": False,
                    "worktree_preserved": True,
                    "window_modified_files": partial_files,
                }) + "\n")
                sys.exit(impl_exit_code)
        except subprocess.TimeoutExpired:
            terminate_tree(p_impl)
            post_failure_snapshot = capture_repository_snapshot()
            partial_files = get_window_delta(pre_impl_snapshot, post_failure_snapshot)
            sys.stderr.write(json.dumps({
                "event": "SOL_ADVISOR_FAILURE",
                "stage": "implementation-window",
                "reason": f"Implementer wrapper exceeded bounded stage timeout of {implementer_timeout_str}",
                "completed": False,
                "reviewed": False,
                "partial_worktree_trusted": False,
                "worktree_preserved": True,
                "window_modified_files": partial_files,
            }) + "\n")
            sys.exit(124)
        finally:
            unregister_process(p_impl)
            if p_impl and p_impl.poll() is None:
                terminate_tree(p_impl)

        if not os.path.isfile(impl_evidence_path):
            sys.stderr.write(f"ERROR: Antigravity evidence file missing: {impl_evidence_path}\n")
            sys.exit(1)

        with open(impl_evidence_path, 'rb') as f:
            raw_impl_ev_bytes = f.read()
        impl_evidence_text = raw_impl_ev_bytes.decode('utf-8', errors='replace')
        impl_evidence_obj = json.loads(impl_evidence_text)
        last_impl_evidence_raw = impl_evidence_text
        last_implementer_evidence = impl_evidence_obj

        assert_head_unchanged("after Antigravity implementation window")
        post_impl_snapshot = capture_repository_snapshot()
        post_impl_manifest_hash = get_repo_fingerprint()
        post_impl_meta_hash = get_scoped_git_metadata_digest(include_index=False)

        # Verify Scoped Git Metadata Integrity
        scoped_git_meta_unchanged = (pre_impl_meta_hash == post_impl_meta_hash)
        if not scoped_git_meta_unchanged:
            sys.stderr.write(f"ERROR: Scoped Git metadata integrity violated during Antigravity implementation window: metadata hash changed from '{pre_impl_meta_hash}' to '{post_impl_meta_hash}'.\n")
            sys.exit(1)

        # Detect In-Progress Git Operations
        in_progress_ops = []
        git_dir_rel = run_git(["rev-parse", "--git-dir"]).strip().decode('utf-8')
        git_dir_full = os.path.normpath(os.path.join(ws_real, git_dir_rel))
        for marker in ("MERGE_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE"):
            if os.path.exists(os.path.join(git_dir_full, marker)):
                in_progress_ops.append(marker)
        if in_progress_ops:
            sys.stderr.write(f"ERROR: In-progress Git operations detected after Antigravity implementation window: {', '.join(in_progress_ops)}\n")
            sys.exit(1)

        # Compute Window Delta
        window_delta_files = get_window_delta(pre_impl_snapshot, post_impl_snapshot)

        # Validate Ownership strictly on Window Delta (including rename destinations)
        unowned_mods = []
        for cf in window_delta_files:
            norm_cf = cf.strip('/')
            if is_ignored_runtime_cache_path(norm_cf):
                continue
            is_owned = False
            for of in plan_obj["owned_files"]:
                norm_of = of.strip('/')
                if norm_cf == norm_of or norm_cf.startswith(norm_of + '/'):
                    is_owned = True
                    break
            if not is_owned:
                unowned_mods.append(cf)

        if unowned_mods:
            sys.stderr.write(f"ERROR: Ownership violation: Antigravity modified file(s) outside declared owned_files: {', '.join(unowned_mods)}\n")
            sys.exit(1)
        stage2_sec = round(time.monotonic() - sw_stage2, 2)

        # STAGE 3: Parent Working-Tree Inspection & Verification
        sw_stage3 = time.monotonic()
        assert_head_unchanged("before parent verification stage")
        fp_before_parent = get_repo_fingerprint()

        head_unchanged_verified = (post_impl_snapshot["head_sha"] == baseline_head_sha)
        ownership_check_passed = (len(unowned_mods) == 0)
        integrity_passed = head_unchanged_verified and scoped_git_meta_unchanged and len(in_progress_ops) == 0
        all_checks_passed = head_unchanged_verified and ownership_check_passed and integrity_passed and (impl_evidence_obj.get("invocation", {}).get("exit_code_observed") == 0)

        fp_after_parent = get_repo_fingerprint()
        if fp_before_parent != fp_after_parent:
            sys.stderr.write("ERROR: Repository mutation detected during parent verification stage!\n")
            sys.exit(1)

        spec_hash = hashlib.sha256(spec_bytes).hexdigest()
        plan_hash = hashlib.sha256(plan_json_str.encode('utf-8')).hexdigest()
        impl_ev_hash = hashlib.sha256(raw_impl_ev_bytes).hexdigest()

        agg_delta_files = get_window_delta(initial_snapshot, post_impl_snapshot)

        # Build aggregate delta manifest lines
        agg_lines = []
        for af in agg_delta_files:
            pre_val = initial_snapshot["file_map"].get(af.encode('utf-8'), b"MISSING").decode('utf-8', errors='replace')
            post_val = post_impl_snapshot["file_map"].get(af.encode('utf-8'), b"MISSING").decode('utf-8', errors='replace')
            agg_lines.append(f"PATH:{af}\nPRE:{pre_val}\nPOST:{post_val}\n")
        agg_delta_str = "".join(agg_lines)
        agg_delta_hash = hashlib.sha256(agg_delta_str.encode('utf-8')).hexdigest()

        parent_ver_envelope = {
            "schema_version": 1,
            "iteration": iteration,
            "verified_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ownership_check": {
                "passed": ownership_check_passed,
                "declared_owned_files": plan_obj["owned_files"],
                "window_modified_files": window_delta_files,
                "unowned_modifications": unowned_mods
            },
            "integrity_check": {
                "passed": integrity_passed,
                "head_unchanged": head_unchanged_verified,
                "baseline_head_sha": baseline_head_sha,
                "current_head_sha": post_impl_snapshot["head_sha"],
                "scoped_git_metadata_unchanged": scoped_git_meta_unchanged,
                "in_progress_git_operations": in_progress_ops
            },
            "implementer_evidence_assessment": {
                "passed": impl_evidence_obj.get("invocation", {}).get("exit_code_observed") == 0,
                "implementer_status": str(impl_evidence_obj.get("agy_result", {}).get("status")),
                "implementer_reported_tests_untrusted": True,
                "implementer_reported_test_summary": f"Implementer reported tests (untrusted): {impl_evidence_obj.get('agy_result', {}).get('response', '')}"
            },
            "suggested_commands_unexecuted": ver_cmds,
            "all_checks_passed": all_checks_passed,
            "bindings": {
                "task_sha256": task_sha256,
                "plan_sha256": plan_hash,
                "spec_sha256": spec_hash,
                "implementer_evidence_sha256": impl_ev_hash,
                "pre_window_manifest_sha256": pre_impl_manifest_hash,
                "post_window_manifest_sha256": post_impl_manifest_hash,
                "repository_manifest_sha256": fp_after_parent,
                "aggregate_delta_manifest_sha256": agg_delta_hash
            }
        }

        parent_ver_path = os.path.join(iter_dir, "parent-verification.json")
        parent_ver_text = json.dumps(parent_ver_envelope, indent=2)
        with open(parent_ver_path, 'w', encoding='utf-8') as f:
            f.write(parent_ver_text)

        last_parent_verification_raw = parent_ver_text
        last_parent_verification = parent_ver_envelope
        parent_ver_hash = hashlib.sha256(parent_ver_text.encode('utf-8')).hexdigest()
        stage3_sec = round(time.monotonic() - sw_stage3, 2)

        # STAGE 4: Fresh Read-Only Sol Review Gate
        sw_stage4 = time.monotonic()
        assert_head_unchanged("before fresh review stage")
        fp_before_review = get_repo_fingerprint()
        review_out_path = os.path.join(iter_dir, "review-evidence.json")
        rem_rev_sec = min(reviewer_timeout_sec, int(total_timeout_sec - (time.time() - start_time)))
        if rem_rev_sec <= 0:
            sys.stderr.write("ERROR: Sol Advisor orchestration exceeded total timeout before fresh review.\n")
            sys.exit(1)

        rev_cmd = [
            "sh", reviewer_script,
            "--workspace", ws_real,
            "--goal-file", task_file_real,
            "--evidence-file", impl_evidence_path,
            "--parent-verification-file", parent_ver_path,
            "--review-output-file", review_out_path,
            "--timeout", f"{rem_rev_sec}s"
        ]
        if effective_codex_model:
            rev_cmd.extend(["--model", effective_codex_model])
        if effective_reasoning_effort:
            rev_cmd.extend(["--reasoning-effort", effective_reasoning_effort])
        if test_mode:
            rev_cmd.append("--test-mode")
            if test_codex_bin:
                rev_cmd.extend(["--test-codex-bin", test_codex_bin])

        p_rev = None
        try:
            p_rev = subprocess.Popen(rev_cmd, preexec_fn=os.setsid if hasattr(os, 'setsid') else None)
            register_process(p_rev)
            rev_outer_sec = min(rem_rev_sec + 5, max(1, int(total_timeout_sec - (time.time() - start_time))))
            rev_exit_code = p_rev.wait(timeout=rev_outer_sec)
            if rev_exit_code != 0:
                sys.stderr.write(f"ERROR: Fresh reviewer wrapper failed with code {rev_exit_code}.\n")
                sys.exit(rev_exit_code)
        except subprocess.TimeoutExpired:
            terminate_tree(p_rev)
            sys.stderr.write("ERROR: Fresh reviewer wrapper exceeded outer timeout deadline.\n")
            sys.exit(124)
        finally:
            unregister_process(p_rev)
            if p_rev and p_rev.poll() is None:
                terminate_tree(p_rev)

        if not os.path.isfile(review_out_path):
            sys.stderr.write(f"ERROR: Fresh reviewer evidence missing: {review_out_path}\n")
            sys.exit(1)

        with open(review_out_path, 'r', encoding='utf-8') as f:
            last_review_raw = f.read()

        try:
            review_data = json.loads(last_review_raw)
        except Exception as e:
            sys.stderr.write(f"ERROR: review-evidence.json is not valid JSON: {e}\n")
            sys.exit(1)

        if not isinstance(review_data, dict):
            sys.stderr.write("ERROR: review-evidence.json must be a JSON object.\n")
            sys.exit(1)

        assert_head_unchanged("after fresh review stage")
        fp_after_review = get_repo_fingerprint()
        if fp_before_review != fp_after_review:
            sys.stderr.write("ERROR: Repository immutability violated during fresh review stage!\n")
            sys.exit(1)

        # Validate Reviewer Output Schema & Bindings strictly
        allowed_rev_top_keys = {"schema_version", "reviewer", "review", "reviewed_bindings"}
        for k in review_data.keys():
            if k not in allowed_rev_top_keys:
                sys.stderr.write(f"ERROR: Unknown key '{k}' in review-evidence.json (strict schema validation).\n")
                sys.exit(1)

        if type(review_data.get("schema_version")) is not int or review_data.get("schema_version") != 1:
            sys.stderr.write("ERROR: review-evidence.json schema_version must be integer 1.\n")
            sys.exit(1)

        rev_reviewer = review_data.get("reviewer")
        if not isinstance(rev_reviewer, dict):
            sys.stderr.write("ERROR: review-evidence.json reviewer missing or not an object.\n")
            sys.exit(1)
        allowed_reviewer_keys = {"model_requested", "effort_requested", "sandbox_mode_requested", "ephemeral", "exit_code_observed", "repository_unchanged_verified"}
        for k in rev_reviewer.keys():
            if k not in allowed_reviewer_keys:
                sys.stderr.write(f"ERROR: Unknown key '{k}' in reviewer object (strict schema validation).\n")
                sys.exit(1)
        expected_reviewer_model = effective_codex_model if effective_codex_model else "inherited"
        if rev_reviewer.get("model_requested") != expected_reviewer_model or rev_reviewer.get("effort_requested") != "inherited" or rev_reviewer.get("sandbox_mode_requested") != "read-only":
            sys.stderr.write(f"ERROR: review-evidence.json reviewer pins mismatch (expected model '{expected_reviewer_model}', got '{rev_reviewer.get('model_requested')}').\n")
            sys.exit(1)
        if type(rev_reviewer.get("ephemeral")) is not bool or rev_reviewer.get("ephemeral") is not True or type(rev_reviewer.get("repository_unchanged_verified")) is not bool or rev_reviewer.get("repository_unchanged_verified") is not True:
            sys.stderr.write("ERROR: review-evidence.json reviewer booleans must be true.\n")
            sys.exit(1)
        if type(rev_reviewer.get("exit_code_observed")) is not int or rev_reviewer["exit_code_observed"] != 0:
            sys.stderr.write("ERROR: review-evidence.json reviewer.exit_code_observed must be integer 0.\n")
            sys.exit(1)

        rev_review = review_data.get("review")
        if not isinstance(rev_review, dict):
            sys.stderr.write("ERROR: review-evidence.json review missing or not an object.\n")
            sys.exit(1)
        allowed_review_keys = {"verdict", "reason", "findings", "residual_risk", "reviewed_no_change"}
        for k in rev_review.keys():
            if k not in allowed_review_keys:
                sys.stderr.write(f"ERROR: Unknown key '{k}' in review object (strict schema validation).\n")
                sys.exit(1)
        if any(not isinstance(rev_review.get(k), str) for k in ("verdict", "reason", "findings", "residual_risk")) or type(rev_review.get("reviewed_no_change")) is not bool:
            sys.stderr.write("ERROR: review-evidence.json review field types are invalid.\n")
            sys.exit(1)

        echoed_b = review_data.get("reviewed_bindings", {})
        if not isinstance(echoed_b, dict):
            sys.stderr.write("ERROR: Fresh reviewer output missing 'reviewed_bindings' object.\n")
            sys.exit(1)

        expected_map = {
            "task_sha256": task_sha256,
            "plan_sha256": plan_hash,
            "spec_sha256": spec_hash,
            "implementer_evidence_sha256": impl_ev_hash,
            "parent_verification_sha256": parent_ver_hash,
            "pre_window_manifest_sha256": pre_impl_manifest_hash,
            "post_window_manifest_sha256": post_impl_manifest_hash,
            "repository_manifest_sha256": fp_after_parent,
            "aggregate_delta_manifest_sha256": agg_delta_hash
        }

        required_keys = [
            "task_sha256", "plan_sha256", "spec_sha256", "implementer_evidence_sha256",
            "parent_verification_sha256", "pre_window_manifest_sha256",
            "post_window_manifest_sha256", "repository_manifest_sha256",
            "aggregate_delta_manifest_sha256"
        ]

        for k in echoed_b.keys():
            if k not in required_keys:
                sys.stderr.write(f"ERROR: Unknown key '{k}' in reviewer reviewed_bindings (closed set validation).\n")
                sys.exit(1)

        for bk in required_keys:
            if bk not in echoed_b or not isinstance(echoed_b[bk], str) or len(echoed_b[bk]) != 64:
                sys.stderr.write(f"ERROR: Reviewer reviewed_bindings missing or invalid key '{bk}'.\n")
                sys.exit(1)
            if echoed_b[bk] != expected_map[bk]:
                sys.stderr.write(f"ERROR: Reviewer binding mismatch for '{bk}': '{echoed_b[bk]}' != '{expected_map[bk]}'.\n")
                sys.exit(1)

        verdict = str(rev_review.get("verdict", "")).strip().upper()
        reason = str(rev_review.get("reason", "")).strip()
        findings = str(rev_review.get("findings", "")).strip()
        residual_risk = str(rev_review.get("residual_risk", "")).strip()

        raw_rnc = rev_review.get("reviewed_no_change")
        if raw_rnc is not None:
            if type(raw_rnc) is not bool:
                sys.stderr.write("ERROR: review-evidence.json reviewed_no_change must be an actual JSON boolean, not string or number.\n")
                sys.exit(1)
            reviewed_no_change_accepted = raw_rnc
        else:
            reviewed_no_change_accepted = False

        print(f"Review Verdict: {verdict}")
        print(f"Review Reason: {reason}")

        stage4_sec = round(time.monotonic() - sw_stage4, 2)
        iter_total_sec = round(stage1_sec + stage2_sec + stage3_sec + stage4_sec, 2)
        stage_telemetry.append({
            "iteration": iteration,
            "planner_seconds": stage1_sec,
            "implementer_seconds": stage2_sec,
            "parent_verify_seconds": stage3_sec,
            "reviewer_seconds": stage4_sec,
            "total_seconds": iter_total_sec,
        })

        # STAGE 5: Decision & State Transition
        if verdict == "SHIP":
            if not all_checks_passed:
                sys.stderr.write("ERROR: Reviewer issued SHIP but parent verification checks failed.\n")
                sys.exit(1)

            aggregate_changed_files = get_window_delta(initial_snapshot, post_impl_snapshot)

            rep_status = "complete"
            rep_obj = plan_obj["objective"]
            if len(aggregate_changed_files) == 0:
                if not reviewed_no_change_accepted:
                    sys.stderr.write("ERROR: Aggregate task delta is empty, but reviewer did not explicitly confirm reviewed_no_change: true.\n")
                    sys.exit(1)
                rep_status = "reviewed_no_change"
                rep_changes = "None (no changes required; verified existing codebase)."
            else:
                rep_changes = "\n".join([f"- {cf}" for cf in aggregate_changed_files])

            rep_verified = f"Machine repository integrity, scoped Git metadata, and ownership verified (exit code 0); implementer reported tests: {str(impl_evidence_obj.get('agy_result', {}).get('response', '')).strip()} [untrusted]"
            rep_judgment = "none"
            rep_gaps = residual_risk if residual_risk and residual_risk.lower() != "none" else "none"

            final_report_text = f"""STATUS: {rep_status}
OBJECTIVE: {rep_obj}
CHANGES:
{rep_changes}
VERIFIED:
{rep_verified}
JUDGMENT CALLS: {rep_judgment}
GAPS: {rep_gaps}
"""
            break
        elif verdict == "FIX-FIRST":
            if iteration > max_corrections:
                sys.stderr.write(f"ERROR: Reviewer issued FIX-FIRST but maximum correction count ({max_corrections}) has been exhausted.\n")
                sys.exit(1)
            last_review_findings = findings
            last_review_reason = reason
            iteration += 1
            continue
        elif verdict == "RETHINK":
            sys.stderr.write(f"ERROR: Reviewer issued RETHINK verdict: {reason}\n")
            sys.exit(1)
        else:
            sys.stderr.write(f"ERROR: Unknown review verdict '{verdict}'.\n")
            sys.exit(1)

    if not final_report_text:
        sys.stderr.write("ERROR: Orchestration terminated without producing final report.\n")
        sys.exit(1)

    if stage_telemetry:
        tot_sec = round(time.time() - start_time, 2)
        telemetry_doc = {
            "event": "SOL_ADVISOR_TELEMETRY",
            "total_seconds": tot_sec,
            "iterations": stage_telemetry,
        }
        sys.stderr.write(json.dumps(telemetry_doc) + "\n")
        sys.stderr.flush()

        try:
            with open(os.path.join(run_dir, "telemetry.json"), "w", encoding="utf-8") as tf:
                json.dump(telemetry_doc, tf, indent=2)
        except Exception:
            pass

        print("")
        print("========================== Sol Advisor Stage Telemetry ==========================")
        print(f"{'Iter':<6} | {'Planner (s)':<13} | {'Implementer (s)':<17} | {'Parent Verify (s)':<19} | {'Reviewer (s)':<14} | {'Total (s)':<10}")
        print("-------+---------------+-------------------+---------------------+----------------+-----------")
        for row in stage_telemetry:
            print(f"{row['iteration']:>6} | {row['planner_seconds']:>13.2f} | {row['implementer_seconds']:>17.2f} | {row['parent_verify_seconds']:>19.2f} | {row['reviewer_seconds']:>14.2f} | {row['total_seconds']:>10.2f}")
        print("-------+---------------+-------------------+---------------------+----------------+-----------")
        print(f"Total Orchestration Time: {tot_sec:.2f}s (Iterations: {len(stage_telemetry)})")
        print("=================================================================================")
        print("")

    # Atomic Two-Phase Publication
    content_bytes = (final_report_text + '\n').encode('utf-8')
    parent_fd = os.open(res_parent_real, os.O_RDONLY | (os.O_DIRECTORY if hasattr(os, 'O_DIRECTORY') else 0) | (os.O_NOFOLLOW if hasattr(os, 'O_NOFOLLOW') else 0))
    try:
        target_filename = os.path.basename(result_file)
        tmp_filename = f".result-tmp.{os.getpid()}.{secrets.token_hex(8)}"
        create_flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, 'O_NOFOLLOW'): create_flags |= os.O_NOFOLLOW
        if hasattr(os, 'O_CLOEXEC'): create_flags |= os.O_CLOEXEC

        tmp_fd = os.open(tmp_filename, create_flags, 0o600, dir_fd=parent_fd)
        with open(tmp_fd, 'wb', closefd=False) as f:
            f.write(content_bytes)
            f.flush()
            os.fsync(f.fileno())
        os.close(tmp_fd)

        try:
            os.link(tmp_filename, target_filename, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
        except FileExistsError:
            sys.stderr.write(f"ERROR: Result destination already exists (no-clobber): {result_file}\n")
            sys.exit(1)
        finally:
            try: os.unlink(tmp_filename, dir_fd=parent_fd)
            except Exception: pass

        try: os.fsync(parent_fd)
        except Exception: pass
    finally:
        try: os.close(parent_fd)
        except Exception: pass

    print(f"Sol Advisor orchestration completed. Result published to: {result_file}")
    sys.exit(0)

finally:
    for proc in list(active_child_procs):
        if proc and proc.poll() is None:
            terminate_tree(proc)
    try:
        if os.path.isdir(run_dir):
            import shutil
            shutil.rmtree(run_dir, ignore_errors=True)
    except Exception:
        pass
PY

exit 0
