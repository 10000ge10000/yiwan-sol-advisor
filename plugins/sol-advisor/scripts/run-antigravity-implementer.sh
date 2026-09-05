#!/bin/sh
# Google Antigravity CLI implementation runner for Sol Advisor (POSIX / Linux / WSL).

set -eu

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

workspace=''
spec_file=''
evidence_file=''
print_timeout="25m"
idle_timeout="8m"
generation_preflight_timeout="90s"
heartbeat_interval="30s"
dangerously_skip_permissions=0
skip_generation_preflight=0
test_mode=0
test_agy_exe=''
model="${AGY_MODEL:-gemini-3.8-flash-high}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || fail "--workspace requires a path."
      workspace=$2
      shift 2
      ;;
    --spec-file)
      [ "$#" -ge 2 ] || fail "--spec-file requires a path."
      spec_file=$2
      shift 2
      ;;
    --evidence-file)
      [ "$#" -ge 2 ] || fail "--evidence-file requires a path."
      evidence_file=$2
      shift 2
      ;;
    --print-timeout)
      [ "$#" -ge 2 ] || fail "--print-timeout requires a duration."
      print_timeout=$2
      shift 2
      ;;
    --idle-timeout)
      [ "$#" -ge 2 ] || fail "--idle-timeout requires a duration."
      idle_timeout=$2
      shift 2
      ;;
    --generation-preflight-timeout)
      [ "$#" -ge 2 ] || fail "--generation-preflight-timeout requires a duration."
      generation_preflight_timeout=$2
      shift 2
      ;;
    --heartbeat-interval)
      [ "$#" -ge 2 ] || fail "--heartbeat-interval requires a duration."
      heartbeat_interval=$2
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || fail "--model requires a model name."
      model=$2
      shift 2
      ;;
    --dangerously-skip-permissions)
      dangerously_skip_permissions=1
      shift
      ;;
    --skip-generation-preflight)
      skip_generation_preflight=1
      shift
      ;;
    --test-mode)
      test_mode=1
      shift
      ;;
    --test-agy-exe)
      [ "$#" -ge 2 ] || fail "--test-agy-exe requires a path."
      test_agy_exe=$2
      shift 2
      ;;
    --help|-h)
      printf '%s\n' "Usage: run-antigravity-implementer.sh --workspace PATH --spec-file PATH --evidence-file PATH [--print-timeout DURATION] [--idle-timeout DURATION] [--generation-preflight-timeout DURATION] [--heartbeat-interval DURATION] [--model MODEL] [--dangerously-skip-permissions] [--skip-generation-preflight] [--test-mode] [--test-agy-exe PATH]"
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (run with --help for usage)."
      ;;
  esac
done

[ -n "$workspace" ] || fail "missing required --workspace"
[ -n "$spec_file" ] || fail "missing required --spec-file"
[ -n "$evidence_file" ] || fail "missing required --evidence-file"

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

# Validate dir_fd / openat capability on the current platform
if ! "$py_bin" -c "import os, sys; sys.exit(0 if hasattr(os, 'supports_dir_fd') and os.open in os.supports_dir_fd and os.link in os.supports_dir_fd else 1)" >/dev/null 2>&1; then
  fail "Platform/Python does not support required dir_fd features (os.open, os.link). The POSIX wrapper requires Linux/WSL. On Windows or Git Bash, run the PowerShell 7+ wrapper 'run-antigravity-implementer.ps1' instead."
fi

# 1. Validate and resolve workspace
case "$workspace" in
  /*) ;;
  *) fail "workspace path must be absolute: $workspace" ;;
esac

[ -d "$workspace" ] || fail "workspace does not exist or is not a directory: $workspace"
resolved_workspace=$(CDPATH= cd "$workspace" && pwd -P) || fail "could not resolve workspace: $workspace"

git_root=$(git -C "$resolved_workspace" rev-parse --show-toplevel 2>/dev/null) || fail "workspace is not a git repository: $resolved_workspace"
canonical_git_root=$(CDPATH= cd "$git_root" && pwd -P) || fail "could not resolve git root"

[ "$resolved_workspace" = "$canonical_git_root" ] || fail "workspace must be the Git top-level directory: expected $canonical_git_root, got $resolved_workspace"

# 2. Validate and resolve spec file (must be absolute, regular file, outside workspace, no symlinks in ancestors)
case "$spec_file" in
  /*) ;;
  *) fail "spec-file path must be absolute: $spec_file" ;;
esac

[ -f "$spec_file" ] || fail "spec file is missing or not a regular file: $spec_file"
[ ! -L "$spec_file" ] || fail "spec file is a symbolic link: $spec_file"

spec_parent=$(dirname "$spec_file")
[ -d "$spec_parent" ] || fail "spec file parent directory does not exist: $spec_parent"
[ ! -L "$spec_parent" ] || fail "spec file parent directory is a symbolic link: $spec_parent"

curr_dir=$spec_parent
while [ "$curr_dir" != "/" ] && [ -n "$curr_dir" ] && [ "$curr_dir" != "." ]; do
  if [ -L "$curr_dir" ]; then
    fail "spec file directory ancestor is a symbolic link: $curr_dir"
  fi
  parent=$(dirname "$curr_dir")
  if [ "$parent" = "$curr_dir" ]; then break; fi
  curr_dir=$parent
done

resolved_spec_dir=$(CDPATH= cd "$spec_parent" && pwd -P) || fail "could not resolve spec file directory"
case "$resolved_spec_dir" in
  "$resolved_workspace"/*|"$resolved_workspace")
    fail "spec file parent directory is inside target workspace ($resolved_spec_dir is inside $resolved_workspace)."
    ;;
esac

resolved_spec_file="$resolved_spec_dir/$(basename "$spec_file")"
case "$resolved_spec_file" in
  "$resolved_workspace"/*|"$resolved_workspace")
    fail "spec file cannot be inside target workspace ($resolved_spec_file is inside $resolved_workspace)."
    ;;
esac

[ -r "$resolved_spec_file" ] || fail "spec file is not readable: $resolved_spec_file"

spec_content=$(cat "$resolved_spec_file") || fail "could not read spec file: $resolved_spec_file"
[ -n "$spec_content" ] || fail "spec file is empty: $resolved_spec_file"

# Validate five-part specification structure (OBJECTIVE, FILES AND OWNERSHIP, INTERFACES, CONSTRAINTS, VERIFICATION) and size
"$py_bin" - "$resolved_spec_file" <<'PY'
import sys, re, os

spec_file = sys.argv[1]
try:
    if os.path.getsize(spec_file) > 24576:
        sys.stderr.write(f"ERROR: Spec file exceeds maximum allowed size of 24 KiB ({os.path.getsize(spec_file)} bytes).\n")
        sys.exit(1)
    with open(spec_file, 'r', encoding='utf-8') as f:
        content = f.read()
except Exception as e:
    sys.stderr.write(f"ERROR: Could not read spec file: {e}\n")
    sys.exit(1)

if not content.strip():
    sys.stderr.write(f"ERROR: Spec file is empty: {spec_file}\n")
    sys.exit(1)

sections = [
    "OBJECTIVE",
    "FILES AND OWNERSHIP",
    "INTERFACES",
    "CONSTRAINTS",
    "VERIFICATION"
]

lines = content.splitlines()
heading_pattern = re.compile(r'^(?:#{1,6}\s+)?(OBJECTIVE|FILES AND OWNERSHIP|INTERFACES|CONSTRAINTS|VERIFICATION)\s*$', re.IGNORECASE)

found_headings = []
section_contents = {s: [] for s in sections}
current_section = None

for line in lines:
    m = heading_pattern.match(line.strip())
    if m:
        heading_raw = m.group(1).upper()
        canonical = None
        for s in sections:
            if heading_raw == s:
                canonical = s
                break
        if canonical:
            found_headings.append(canonical)
            current_section = canonical
    elif current_section:
        section_contents[current_section].append(line)

if found_headings != sections:
    missing = [s for s in sections if s not in found_headings]
    duplicates = [s for s in sections if found_headings.count(s) > 1]
    if duplicates:
        sys.stderr.write(f"ERROR: Spec file contains duplicate section heading(s): {', '.join(duplicates)}\n")
        sys.exit(1)
    if missing:
        sys.stderr.write(f"ERROR: Spec file is missing mandatory five-part section(s): {', '.join(missing)}\n")
        sys.exit(1)
    sys.stderr.write(f"ERROR: Spec file sections are out of order. Expected: {', '.join(sections)}; Found: {', '.join(found_headings)}\n")
    sys.exit(1)

for s in sections:
    text = "\n".join(section_contents[s]).strip()
    if not text:
        sys.stderr.write(f"ERROR: Spec file section '{s}' is empty.\n")
        sys.exit(1)
PY

# 3. Validate and resolve evidence file (strictly absolute, does not exist, parent exists, outside workspace, no symlinks)
case "$evidence_file" in
  /*) ;;
  *) fail "evidence file path must be absolute: $evidence_file" ;;
esac

if [ -e "$evidence_file" ] || [ -L "$evidence_file" ]; then
  fail "evidence destination already exists: $evidence_file. Evidence destination must not exist before execution."
fi

evidence_parent=$(dirname "$evidence_file")
if [ ! -d "$evidence_parent" ] || [ -L "$evidence_parent" ]; then
  fail "evidence parent directory does not exist or is a symlink: $evidence_parent. Evidence parent directory must already exist."
fi

curr_dir=$evidence_parent
while [ "$curr_dir" != "/" ] && [ -n "$curr_dir" ] && [ "$curr_dir" != "." ]; do
  if [ -L "$curr_dir" ]; then
    fail "evidence directory ancestor is a symbolic link: $curr_dir"
  fi
  parent=$(dirname "$curr_dir")
  if [ "$parent" = "$curr_dir" ]; then break; fi
  curr_dir=$parent
done

resolved_evidence_dir=$(CDPATH= cd "$evidence_parent" && pwd -P) || fail "could not resolve evidence directory"

case "$resolved_evidence_dir" in
  "$resolved_workspace"/*|"$resolved_workspace")
    fail "evidence file parent directory is inside the target workspace ($resolved_evidence_dir is inside $resolved_workspace)."
    ;;
esac

resolved_evidence_file="$resolved_evidence_dir/$(basename "$evidence_file")"

case "$resolved_evidence_file" in
  "$resolved_workspace"/*|"$resolved_workspace")
    fail "evidence file cannot be inside the target workspace ($resolved_evidence_file is inside $resolved_workspace). Do not contaminate the target diff with evidence."
    ;;
esac

# 4. Resolve agy executable from PATH or test hook
agy_bin=''
if [ "${test_mode:-0}" -eq 1 ] || [ "${_SOL_ADVISOR_TEST_MODE:-}" = "1" ] || [ "${_MY_SOL_ADVISOR_TEST_MODE:-}" = "1" ]; then
  effective_test_mode=1
else
  effective_test_mode=0
fi

if [ -n "$test_agy_exe" ]; then
  if [ "$effective_test_mode" -ne 1 ]; then
    fail "test executable argument (--test-agy-exe) specified without --test-mode"
  fi
  if [ ! -f "$test_agy_exe" ]; then
    fail "test executable specified in --test-agy-exe does not exist: $test_agy_exe"
  fi
  agy_bin="$test_agy_exe"
else
  override_var_present=0
  override_candidate=""
  for var in _MY_SOL_ADVISOR_TEST_AGY_BIN _MY_SOL_ADVISOR_TEST_AGY_EXE _SOL_ADVISOR_TEST_AGY_BIN _SOL_ADVISOR_TEST_AGY_EXE; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
      override_var_present=1
      override_candidate="$val"
      break
    fi
  done

  if [ "$override_var_present" -eq 1 ]; then
    if [ "$effective_test_mode" -ne 1 ]; then
      fail "test executable override variable specified without explicit test mode (--test-mode / _MY_SOL_ADVISOR_TEST_MODE=1)"
    fi
    if [ ! -f "$override_candidate" ]; then
      fail "test executable override does not exist or is not a file: $override_candidate"
    fi
    agy_bin="$override_candidate"
  fi
fi

if [ -z "$agy_bin" ]; then
  if command -v agy >/dev/null 2>&1; then
    agy_bin=$(command -v agy)
  elif command -v agy.exe >/dev/null 2>&1; then
    agy_bin=$(command -v agy.exe)
  else
    fail "Antigravity CLI executable ('agy' or 'agy.exe') not found in PATH."
  fi
fi

if [ "$effective_test_mode" -ne 1 ]; then
  agy_settings="$HOME/.gemini/antigravity-cli/settings.json"
  [ -f "$agy_settings" ] || fail "Antigravity sandbox automation is not configured. Run setup-yiwan-sol-advisor.sh first."
  "$py_bin" - "$agy_settings" <<'PY' || fail "Antigravity must use toolPermission=proceed-in-sandbox and enableTerminalSandbox=true. Run setup-yiwan-sol-advisor.sh."
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as stream:
        settings = json.load(stream)
except Exception as exc:
    sys.stderr.write(f"Invalid Antigravity settings JSON: {exc}\n")
    raise SystemExit(1)
raise SystemExit(0 if settings.get('toolPermission') == 'proceed-in-sandbox' and settings.get('enableTerminalSandbox') is True else 1)
PY
fi

# 5. Parse all watchdog budgets before any generation request.
eval "$("$py_bin" - "$print_timeout" "$idle_timeout" "$generation_preflight_timeout" "$heartbeat_interval" <<'PY'
import re, shlex, sys

def parse(value, label):
    match = re.fullmatch(r'(\d+)h(?:(\d+)m)?', value)
    if match:
        result = int(match.group(1)) * 3600 + int(match.group(2) or 0) * 60
    else:
        match = re.fullmatch(r'(\d+)m(?:(\d+)s)?', value)
        if match:
            result = int(match.group(1)) * 60 + int(match.group(2) or 0)
        else:
            match = re.fullmatch(r'(\d+)s', value)
            result = int(match.group(1)) if match else (int(value) if value.isdigit() else 0)
    if result <= 0:
        raise SystemExit(f'ERROR: Invalid or non-positive {label} duration: {value!r}.')
    return result

values = {
    'timeout_sec': parse(sys.argv[1].strip(), 'print timeout'),
    'idle_timeout_sec': parse(sys.argv[2].strip(), 'idle timeout'),
    'preflight_timeout_sec': parse(sys.argv[3].strip(), 'generation preflight timeout'),
    'heartbeat_interval_sec': parse(sys.argv[4].strip(), 'heartbeat interval'),
}
if values['idle_timeout_sec'] > values['timeout_sec']:
    values['idle_timeout_sec'] = values['timeout_sec']
if values['preflight_timeout_sec'] >= values['timeout_sec']:
    values['preflight_timeout_sec'] = max(1, values['timeout_sec'] - 1)
for key, value in values.items():
    print(f'{key}={shlex.quote(str(value))}')
PY
)"

prompt_header="ROLE CONTRACT:
You are the sole implementation provider (Google Antigravity CLI).
Sol (using the active Codex model and reasoning effort) is the architect and planner.
Do not redesign or redo architecture; stay within the owned files and follow the five-part specification below.
Execute the implementation, perform verification, and return a structured report including: status, files changed, commands, verification outputs, warnings, and blockers.
Never run git config --global or git config --system. The wrapper supplies repository trust only to this subprocess.

STRUCTURED IMPLEMENTATION REPORT CONTRACT:
Your final response must provide a structured implementation report with the following fields:
STATUS: complete | partial | blocked
OBJECTIVE: <restatement of objective>
CHANGES: <file-by-file summary of changes made>
VERIFIED: <exact verification commands run, exit codes, and output evidence>
JUDGMENT CALLS: <material decisions made or none>
GAPS: <remaining gaps or none>

SPECIFICATION:
"
full_prompt="${prompt_header}${spec_content}"

if [ "$dangerously_skip_permissions" -eq 1 ]; then
  perm_mode="dangerously-skip-permissions"
  printf '%s\n' "PERMISSION MODE: sandboxed-dangerously-skip-permissions enabled for workspace $resolved_workspace" >&2
else
  perm_mode="standard"
fi

tmp_stdout=$(mktemp) || fail "could not create temporary file for stdout"
tmp_stderr=$(mktemp) || fail "could not create temporary file for stderr"
tmp_prompt=$(mktemp) || fail "could not create temporary file for prompt"
printf '%s' "$full_prompt" > "$tmp_prompt"

cleanup() {
  rm -f "$tmp_stdout" "$tmp_stderr" "$tmp_prompt"
}
trap cleanup 0 HUP INT TERM

started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
start_seconds=$(date +%s 2>/dev/null || printf '0')

tmp_ver_file=$(mktemp) || fail "could not create temporary file for version"

set +e
"$py_bin" - "$agy_bin" "$resolved_workspace" "$print_timeout" "$tmp_prompt" "$dangerously_skip_permissions" "$tmp_stdout" "$tmp_stderr" "$timeout_sec" "$idle_timeout_sec" "$preflight_timeout_sec" "$heartbeat_interval_sec" "$tmp_ver_file" "$resolved_spec_file" "$skip_generation_preflight" "$model" <<'PY'
import datetime
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

agy_bin, workspace, print_timeout, prompt_file = sys.argv[1:5]
danger_flag = sys.argv[5] == "1"
stdout_file, stderr_file = sys.argv[6:8]
timeout_sec = int(sys.argv[8])
idle_timeout_sec = int(sys.argv[9])
preflight_timeout_sec = int(sys.argv[10])
heartbeat_interval_sec = int(sys.argv[11])
version_file, spec_file = sys.argv[12:14]
skip_generation_preflight = sys.argv[14] == "1"
model_requested = sys.argv[15].strip() if len(sys.argv) > 15 and sys.argv[15].strip() else "gemini-3.8-flash-high"
started = time.monotonic()

def remaining(label):
    value = timeout_sec - (time.monotonic() - started)
    if value <= 0:
        raise RuntimeError(f"hard timeout of {timeout_sec}s expired before {label}")
    return value

def terminate(proc):
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=2)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

def emit_failure(reason):
    sys.stderr.write(json.dumps({
        "event": "SOL_ADVISOR_FAILURE",
        "stage": "antigravity-implementer",
        "reason": reason,
        "completed": False,
        "reviewed": False,
        "partial_worktree_trusted": False,
        "worktree_preserved": True,
    }) + "\n")
    sys.stderr.flush()

def emit_heartbeat(elapsed, idle, kind):
    sys.stderr.write(json.dumps({
        "event": "SOL_ADVISOR_HEARTBEAT",
        "stage": "antigravity-implementer",
        "elapsed_seconds": elapsed,
        "hard_timeout_seconds": timeout_sec,
        "idle_timeout_seconds": idle_timeout_sec,
        "idle_seconds": idle,
        "last_activity_kind": kind,
    }) + "\n")
    sys.stderr.flush()

child_env = os.environ.copy()
try:
    config_count = int(child_env.get("GIT_CONFIG_COUNT", "0"))
except ValueError:
    raise SystemExit("ERROR: inherited GIT_CONFIG_COUNT is invalid")
if not 0 <= config_count <= 100:
    raise SystemExit("ERROR: inherited GIT_CONFIG_COUNT is invalid or unreasonably large")
child_env["GIT_CONFIG_COUNT"] = str(config_count + 1)
child_env[f"GIT_CONFIG_KEY_{config_count}"] = "safe.directory"
child_env[f"GIT_CONFIG_VALUE_{config_count}"] = workspace

def bounded_run(args, cwd, timeout, label):
    proc = subprocess.Popen(args, cwd=cwd, env=child_env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=min(timeout, remaining(label)))
    except subprocess.TimeoutExpired:
        terminate(proc)
        raise RuntimeError(f"{label} timed out after {timeout}s")
    if proc.returncode != 0:
        raise RuntimeError(f"{label} exited with code {proc.returncode}: {err.decode('utf-8', errors='replace')}")
    return out.decode("utf-8", errors="strict"), err.decode("utf-8", errors="replace")

try:
    models_out, _ = bounded_run([agy_bin, "models"], workspace, 30, "agy models")
    models = [line.split()[0] for line in models_out.splitlines() if line.strip()]
    if model_requested not in models:
        raise RuntimeError(f"required model '{model_requested}' is absent from agy models")
    version_out, _ = bounded_run([agy_bin, "--version"], workspace, 30, "agy --version")
    version_out = version_out.strip()
    if not version_out:
        raise RuntimeError("agy --version returned empty output")
    with open(version_file, "w", encoding="utf-8") as stream:
        stream.write(version_out)

    nonce = "sol-advisor-generation-preflight-" + uuid.uuid4().hex
    if skip_generation_preflight:
        sys.stderr.write("[run-antigravity-implementer] Skipping disposable generation preflight as requested (already verified or subsequent iteration).\n")
        sys.stderr.flush()
    else:
        with tempfile.TemporaryDirectory(prefix="sol-advisor-preflight-") as preflight_dir:
            preflight_prompt = f"Return only one JSON object with status=ok and nonce={nonce}. Do not create or modify files."
            preflight_args = [
                agy_bin, "--sandbox", "--model", model_requested,
                "--effort", "high", "--mode", "accept-edits", "--output-format", "json",
                "--print-timeout", f"{preflight_timeout_sec}s", "--dangerously-skip-permissions",
                "--print", preflight_prompt,
            ]
            preflight_out, _ = bounded_run(preflight_args, preflight_dir,
                                           preflight_timeout_sec, "generation preflight")
            try:
                parsed_preflight = json.loads(preflight_out)
            except Exception as exc:
                raise RuntimeError(f"generation preflight returned invalid JSON: {exc}")
            if not isinstance(parsed_preflight, dict) or nonce not in preflight_out:
                raise RuntimeError("generation preflight did not echo its nonce")
except Exception as exc:
    reason = str(exc)
    emit_failure(reason)
    sys.stderr.write(f"ERROR: {reason}. Refusing to enter the implementation window.\n")
    raise SystemExit(1)

with open(prompt_file, "r", encoding="utf-8") as stream:
    prompt = stream.read()

owned_files = []
in_owned = False
with open(spec_file, "r", encoding="utf-8") as stream:
    for raw_line in stream:
        line = raw_line.strip()
        upper = line.lstrip("# ").upper()
        if upper == "FILES AND OWNERSHIP":
            in_owned = True
            continue
        if in_owned and upper in {"INTERFACES", "CONSTRAINTS", "VERIFICATION", "OBJECTIVE"}:
            break
        if in_owned and (line.startswith("- ") or line.startswith("* ")):
            candidate = line[2:].strip().strip("`'\"").replace("\\", "/")
            if candidate and not candidate.startswith("You own") and ".." not in candidate and ":" not in candidate:
                owned_files.append(candidate)
if not owned_files or len(owned_files) > 12:
    raise SystemExit("ERROR: specification must declare between 1 and 12 valid owned paths")

def worktree_fingerprint():
    result = []
    for owned in owned_files:
        target = os.path.join(workspace, owned)
        try:
            stat = os.stat(target)
            result.append((owned, stat.st_size, stat.st_mtime_ns))
        except FileNotFoundError:
            result.append((owned, None, None))
        except OSError:
            result.append((owned, "error", "error"))
    return tuple(result)

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
    return read_one(pid)

cmd = [
    agy_bin, "--new-project", "--add-dir", workspace, "--sandbox", "--model", model_requested,
    "--effort", "high", "--mode", "accept-edits", "--output-format", "json",
    "--print-timeout", print_timeout,
]
if danger_flag:
    cmd.append("--dangerously-skip-permissions")
cmd.extend(["--print", prompt])

state = {"last_activity": time.monotonic(), "kind": "startup", "out": 0, "err": 0}
state_lock = threading.Lock()
proc = None

def consume(pipe, path, relay, kind):
    with open(path, "wb") as destination:
        while True:
            chunk = pipe.read(4096)
            if not chunk:
                break
            destination.write(chunk)
            destination.flush()
            if relay:
                sys.stderr.buffer.write(chunk)
                sys.stderr.buffer.flush()
            with state_lock:
                state[kind] += len(chunk)
                state["last_activity"] = time.monotonic()
                state["kind"] = "stdout" if kind == "out" else "stderr"

try:
    proc = subprocess.Popen(cmd, cwd=workspace, env=child_env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    threads = [
        threading.Thread(target=consume, args=(proc.stdout, stdout_file, False, "out"), daemon=True),
        threading.Thread(target=consume, args=(proc.stderr, stderr_file, True, "err"), daemon=True),
    ]
    for thread in threads:
        thread.start()
    last_fingerprint = worktree_fingerprint()
    last_cpu = process_tree_cpu(proc.pid)
    last_probe = -2
    last_heartbeat = -heartbeat_interval_sec
    failure = ""
    while proc.poll() is None:
        time.sleep(0.2)
        now = time.monotonic()
        elapsed = int(now - started)
        with state_lock:
            idle = int(now - state["last_activity"])
            output_size = state["out"] + state["err"]
            activity_kind = state["kind"]
        if output_size > 8 * 1024 * 1024:
            failure = "Antigravity CLI output exceeded the 4 MiB per-stream safety limit"
            break
        if elapsed >= timeout_sec:
            failure = f"Antigravity implementation hard timeout of {timeout_sec}s exceeded"
            break
        if elapsed - last_probe >= 2:
            last_probe = elapsed
            fingerprint = worktree_fingerprint()
            cpu = process_tree_cpu(proc.pid)
            with state_lock:
                if fingerprint != last_fingerprint:
                    state["last_activity"] = now
                    state["kind"] = "owned-worktree"
                    last_fingerprint = fingerprint
                if cpu >= last_cpu + 10:
                    state["last_activity"] = now
                    state["kind"] = "process-cpu"
                    last_cpu = cpu
                idle = int(now - state["last_activity"])
                activity_kind = state["kind"]
        if idle >= idle_timeout_sec:
            failure = f"Antigravity implementation idle timeout of {idle_timeout_sec}s exceeded; no stdout, stderr, owned-worktree, or process CPU progress was observed"
            break
        if elapsed - last_heartbeat >= heartbeat_interval_sec:
            last_heartbeat = elapsed
            emit_heartbeat(elapsed, idle, activity_kind)
    if failure:
        terminate(proc)
        emit_failure(failure)
        sys.stderr.write(f"ERROR: {failure}.\n")
        raise SystemExit(124)
    return_code = proc.wait()
    for thread in threads:
        thread.join(timeout=3)
    raise SystemExit(return_code)
except SystemExit:
    raise
except Exception as exc:
    terminate(proc)
    reason = f"failed to run Antigravity CLI: {exc}"
    emit_failure(reason)
    sys.stderr.write(f"ERROR: {reason}\n")
    raise SystemExit(1)
finally:
    terminate(proc)
PY
exit_code=$?
set -e

if [ -f "$tmp_ver_file" ]; then
  cli_version=$(cat "$tmp_ver_file" | tr -d '\r\n')
  rm -f "$tmp_ver_file"
else
  cli_version="unknown"
fi

ended_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
end_seconds=$(date +%s 2>/dev/null || printf '0')
duration_ms=$(( (end_seconds - start_seconds) * 1000 ))
if [ "$duration_ms" -lt 0 ]; then duration_ms=0; fi

if [ "$exit_code" -ne 0 ]; then
  "$py_bin" - "$tmp_stdout" "$exit_code" <<'PY'
import json, sys
path, code = sys.argv[1], int(sys.argv[2])
detail = f"exit code {code}"
try:
    with open(path, "r", encoding="utf-8") as stream:
        payload = json.load(stream)
    if isinstance(payload, dict):
        status = str(payload.get("status", "unknown"))
        error = str(payload.get("error", "")).replace("\r", " ").replace("\n", " ").replace("\t", " ")[:512]
        detail = f"exit code {code}, status={status}" + (f", error={error}" if error else "")
except Exception:
    pass
reason = f"Antigravity CLI failed before a valid implementation report was produced ({detail})."
print(json.dumps({"event":"SOL_ADVISOR_FAILURE","stage":"antigravity-implementer","reason":reason,"completed":False,"reviewed":False,"partial_worktree_trusted":False,"worktree_preserved":True}), file=sys.stderr)
print(f"ERROR: {reason}", file=sys.stderr)
PY
  exit "$exit_code"
fi

# 8. Build, validate response contract, and atomically publish evidence envelope
build_envelope_python() {
  py_runner=$1
  "$py_runner" - "$tmp_stdout" "$resolved_evidence_file" "$cli_version" "$resolved_workspace" "$perm_mode" "$started_at_utc" "$ended_at_utc" "$duration_ms" "$exit_code" "$effective_test_mode" "$model" <<'PY'
import json, sys, os, stat, re, secrets

raw_file = sys.argv[1]
target_file = sys.argv[2]
cli_ver = sys.argv[3]
cwd_obs = sys.argv[4]
perm_mode = sys.argv[5]
start_utc = sys.argv[6]
end_utc = sys.argv[7]
dur_ms = int(sys.argv[8])
exit_code = int(sys.argv[9])
test_mode_flag = sys.argv[10] == "1"
model_requested = sys.argv[11].strip() if len(sys.argv) > 11 and sys.argv[11].strip() else "gemini-3.8-flash-high"

target_parent = os.path.dirname(target_file)
target_filename = os.path.basename(target_file)

if not target_filename or target_filename in ('.', '..'):
    sys.stderr.write(f"ERROR: Invalid evidence filename: {target_filename}\n")
    sys.exit(1)

# Validate target parent directory non-symlink status
if not os.path.isdir(target_parent) or os.path.islink(target_parent):
    sys.stderr.write(f"ERROR: Evidence parent directory does not exist or is a symlink: {target_parent}\n")
    sys.exit(1)

# Validate all ancestor directories for symlinks
curr_dir = target_parent
while curr_dir and curr_dir != '/' and curr_dir != '.':
    if os.path.islink(curr_dir):
        sys.stderr.write(f"ERROR: Evidence directory ancestor is a symbolic link: {curr_dir}\n")
        sys.exit(1)
    parent = os.path.dirname(curr_dir)
    if parent == curr_dir:
        break
    curr_dir = parent

# Validate target directory exteriority from workspace
resolved_parent = os.path.realpath(target_parent)
resolved_ws = os.path.realpath(cwd_obs)
if resolved_parent == resolved_ws or resolved_parent.startswith(resolved_ws + os.sep):
    sys.stderr.write(f"ERROR: Evidence directory is inside target workspace: {target_parent}\n")
    sys.exit(1)

# Securely open parent directory with O_DIRECTORY and O_NOFOLLOW
open_dir_flags = os.O_RDONLY
if hasattr(os, 'O_DIRECTORY'):
    open_dir_flags |= os.O_DIRECTORY
if hasattr(os, 'O_NOFOLLOW'):
    open_dir_flags |= os.O_NOFOLLOW

try:
    parent_fd = os.open(target_parent, open_dir_flags)
except Exception as e:
    sys.stderr.write(f"ERROR: Could not securely open evidence parent directory: {e}\n")
    sys.exit(1)

try:
    # Verify identity of opened parent fd against validated path
    st_fd = os.fstat(parent_fd)
    if not stat.S_ISDIR(st_fd.st_mode):
        sys.stderr.write(f"ERROR: Opened parent file descriptor is not a directory: {target_parent}\n")
        sys.exit(1)

    st_path = os.stat(target_parent, follow_symlinks=False)
    if (st_fd.st_dev, st_fd.st_ino) != (st_path.st_dev, st_path.st_ino):
        sys.stderr.write(f"ERROR: Evidence parent directory identity changed between validation and opening: {target_parent}\n")
        sys.exit(1)

    with open(raw_file, 'r', encoding='utf-8') as f:
        raw_text = f.read().strip()

    if not raw_text:
        sys.stderr.write("ERROR: Antigravity CLI produced empty output.\n")
        sys.exit(1)

    try:
        decoder = json.JSONDecoder()
        agy_res, idx = decoder.raw_decode(raw_text)
        if raw_text[idx:].strip():
            sys.stderr.write("ERROR: Antigravity stdout contains multiple JSON documents or trailing data.\n")
            sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"ERROR: Antigravity stdout is not valid JSON evidence: {e}\n")
        sys.exit(1)

    if not isinstance(agy_res, dict):
        sys.stderr.write("ERROR: Antigravity stdout JSON must be an object.\n")
        sys.exit(1)

    model_obs = "model" in agy_res
    effort_obs = "effort" in agy_res or "model_reasoning_effort" in agy_res
    mode_obs = "mode" in agy_res
    cwd_obs_field = "cwd" in agy_res or "working_directory" in agy_res

    if model_obs and agy_res["model"] != model_requested:
        sys.stderr.write(f"ERROR: Observed agy_result model {agy_res['model']!r} does not match requested pin {model_requested!r}\n")
        sys.exit(1)

    if "effort" in agy_res and agy_res["effort"] != "high":
        sys.stderr.write(f"ERROR: Observed agy_result effort {agy_res['effort']!r} does not match requested pin 'high'\n")
        sys.exit(1)

    if "model_reasoning_effort" in agy_res and agy_res["model_reasoning_effort"] != "high":
        sys.stderr.write(f"ERROR: Observed agy_result model_reasoning_effort {agy_res['model_reasoning_effort']!r} does not match requested pin 'high'\n")
        sys.exit(1)

    if mode_obs and agy_res["mode"] != "accept-edits":
        sys.stderr.write(f"ERROR: Observed agy_result mode {agy_res['mode']!r} does not match requested pin 'accept-edits'\n")
        sys.exit(1)

    if "cwd" in agy_res and os.path.realpath(agy_res["cwd"]) != os.path.realpath(cwd_obs):
        sys.stderr.write(f"ERROR: Observed agy_result cwd {agy_res['cwd']!r} does not match expected {cwd_obs!r}\n")
        sys.exit(1)

    if "working_directory" in agy_res and os.path.realpath(agy_res["working_directory"]) != os.path.realpath(cwd_obs):
        sys.stderr.write(f"ERROR: Observed agy_result working_directory {agy_res['working_directory']!r} does not match expected {cwd_obs!r}\n")
        sys.exit(1)

    # Validate agy_result response contract (STATUS, OBJECTIVE, CHANGES, VERIFIED, JUDGMENT CALLS, GAPS)
    report_status = None
    report_objective = None
    report_changes = None
    report_verified = None
    report_judgment = None
    report_gaps = None

    if isinstance(agy_res.get("report"), dict):
        rep = agy_res["report"]
        if rep.get("status") is not None: report_status = rep.get("status")
        if rep.get("report_status") is not None: report_status = rep.get("report_status")
        if rep.get("objective") is not None: report_objective = rep.get("objective")
        if rep.get("report_objective") is not None: report_objective = rep.get("report_objective")
        if rep.get("changes") is not None: report_changes = rep.get("changes")
        elif rep.get("changes_made") is not None: report_changes = rep.get("changes_made")
        if rep.get("verified") is not None: report_verified = rep.get("verified")
        if rep.get("judgment_calls") is not None: report_judgment = rep.get("judgment_calls")
        elif rep.get("judgment") is not None: report_judgment = rep.get("judgment")
        if rep.get("gaps") is not None: report_gaps = rep.get("gaps")

    if agy_res.get("report_status") is not None: report_status = agy_res.get("report_status")
    if agy_res.get("report_objective") is not None: report_objective = agy_res.get("report_objective")

    resp_text = ""
    for field in ("response", "content", "text", "output", "result", "message"):
        if isinstance(agy_res.get(field), str) and agy_res[field].strip():
            resp_text = agy_res[field]
            break

    if resp_text:
        key_pattern = r'(?im)^[ \t]*(?:(?:[-*+]|\d+\.)[ \t]+)?(?:#{1,6}[ \t]*)?(?:\*\*|__)?(STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|JUDGMENT_CALLS|JUDGMENT|GAPS)(?:\*\*|__)?(?:\s*:\s*(?:\*\*|__)?|\s*(?:\*\*|__)?(?:\n|$))'
        def _norm_key(m):
            k = re.sub(r'\s+', ' ', m.group(1).upper())
            if k == 'JUDGMENT_CALLS': k = 'JUDGMENT CALLS'
            return f'{k}: '
        resp_text = re.sub(key_pattern, _norm_key, resp_text)

        status_m = re.search(r'(?im)(?:^|\n)\s*STATUS\s*:\s*(?:[^\S\r\n]*\r?\n\s*)?(?!(?:OBJECTIVE|CHANGES|VERIFIED|JUDGMENT|GAPS)\s*:)([^\r\n]+)', resp_text)
        if status_m:
            report_status = status_m.group(1).strip()
        obj_m = re.search(r'(?is)(?:^|\n)\s*OBJECTIVE\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)', resp_text)
        if obj_m and obj_m.group(1).strip():
            report_objective = obj_m.group(1).strip()
        changes_m = re.search(r'(?is)(?:^|\n)\s*CHANGES\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)', resp_text)
        if changes_m and changes_m.group(1).strip():
            report_changes = changes_m.group(1).strip()
        verified_m = re.search(r'(?is)(?:^|\n)\s*VERIFIED\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)', resp_text)
        if verified_m and verified_m.group(1).strip():
            report_verified = verified_m.group(1).strip()
        judgment_m = re.search(r'(?is)(?:^|\n)\s*JUDGMENT(?:\s*CALLS)?\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)', resp_text)
        if judgment_m and judgment_m.group(1).strip():
            report_judgment = judgment_m.group(1).strip()
        gaps_m = re.search(r'(?is)(?:^|\n)\s*GAPS\s*:\s*([\s\S]*?)(?=(?:^|\n)\s*(?:STATUS|OBJECTIVE|CHANGES|VERIFIED|JUDGMENT\s*CALLS|GAPS)\s*:|\Z)', resp_text)
        if gaps_m and gaps_m.group(1).strip():
            report_gaps = gaps_m.group(1).strip()

    missing_fields = []
    if report_status is None or not str(report_status).strip(): missing_fields.append("STATUS")
    if report_objective is None or not str(report_objective).strip(): missing_fields.append("OBJECTIVE")
    if report_changes is None or not str(report_changes).strip(): missing_fields.append("CHANGES")
    if report_verified is None or not str(report_verified).strip(): missing_fields.append("VERIFIED")
    if report_judgment is None or not str(report_judgment).strip(): missing_fields.append("JUDGMENT CALLS")
    if report_gaps is None or not str(report_gaps).strip(): missing_fields.append("GAPS")

    if missing_fields:
        sys.stderr.write(f"ERROR: agy_result does not satisfy response contract: missing or empty report field(s): {', '.join(missing_fields)}\n")
        sys.exit(1)

    norm_status = str(report_status).strip().lower()
    if norm_status not in ("complete", "completed", "success"):
        sys.stderr.write(f"ERROR: agy_result report status '{report_status}' does not indicate successful completion (expected complete/completed/success).\n")
        sys.exit(1)

    verified_str = str(report_verified).strip()
    verified_lower = verified_str.lower()
    forbidden_tokens = [
        "not tested", "untested", "not verified", "no tests", "no test", "unverified",
        "bypass", "bypassed",
        "exit pending", "pending exit", "test pending", "verification pending",
        "not run", "to be tested", "will test", "skipped"
    ]
    for bad in forbidden_tokens:
        if bad in verified_lower:
            sys.stderr.write(f"ERROR: agy_result VERIFIED section contains forbidden/unverified token '{bad}'.\n")
            sys.exit(1)

    has_exit_code = bool(
        re.search(r'(?i)\b(?:exit(?:ed)?(?:\s+with)?(?:[_\s]*(?:code|status))?|return[_\s]*code|status[_\s]*code|code|status|rc)\s*[:=]?\s*\d+\b', verified_str) or
        re.search(r'(?:退出码|返回码|退出代码|返回代码)\s*[:：=]?\s*`?\d+`?', verified_str) or
        re.search(r'(?i)\bexit\s+\d+\b', verified_str) or
        re.search(r'(?i)[\(\[]exit\s*(?:code)?\s*[:=]?\s*\d+[\]\)]', verified_str)
    )

    has_cmd = False
    cmd_indicators = [
        "git", "sh", "bash", "pwsh", "powershell", "python", "python3", "pytest",
        "npm", "cargo", "go", "make", "node", "verify", "install", "diff",
        "command", "executed", "run", "passed"
    ]
    for ind in cmd_indicators:
        if re.search(r'(?i)\b' + re.escape(ind) + r'\b', verified_str) or f"`{ind}" in verified_lower:
            has_cmd = True
            break
    if not has_cmd and ('`' in verified_str or '$ ' in verified_str):
        has_cmd = True

    if not has_exit_code or not has_cmd:
        sys.stderr.write("ERROR: agy_result VERIFIED section does not contain explicit command and numeric observed exit code evidence.\n")
        sys.exit(1)

    envelope = {
        "schema_version": 1,
        "invocation": {
            "provider": "google-antigravity-cli",
            "cli_version_observed": cli_ver,
            "model_requested": model_requested,
            "model_catalog_exact_match_observed": True,
            "effort_requested": "high",
            "mode_requested": "accept-edits",
            "output_format_requested": "json",
            "cwd_observed": cwd_obs,
            "permission_mode_requested": perm_mode,
            "started_at_utc": start_utc,
            "ended_at_utc": end_utc,
            "duration_ms_observed": dur_ms,
            "exit_code_observed": exit_code
        },
        "runtime_observability": {
            "model_field_observed": model_obs,
            "effort_field_observed": effort_obs,
            "mode_field_observed": mode_obs,
            "cwd_field_observed": cwd_obs_field,
            "note": "Requested invocation pins, exact catalog lookup, and nonce-bound generation preflight are configuration/process evidence; absent agy result fields are not dynamic runtime observations."
        },
        "agy_result": {
            **({"conversation_id": str(agy_res["conversation_id"])} if "conversation_id" in agy_res else {}),
            "status": str(agy_res.get("status") or report_status).strip(),
            "objective": str(report_objective).strip(),
            "changes": str(report_changes).strip(),
            "verified": str(report_verified).strip(),
            "judgment_calls": str(report_judgment).strip(),
            "gaps": str(report_gaps).strip(),
            "response": resp_text.strip()
        }
    }

    envelope_bytes = (json.dumps(envelope, indent=2, ensure_ascii=False) + '\n').encode('utf-8')

    if test_mode_flag:
        action = os.environ.get("_MY_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH") or os.environ.get("_SOL_ADVISOR_TEST_ACTION_BEFORE_EVIDENCE_PUBLISH")
        if action in ("simulate_write_crash", "simulate_interruption"):
            sys.stderr.write("TEST ERROR: Simulated crash before evidence publication.\n")
            sys.exit(1)

    # Secure two-phase publication: write full content to private temp file, then atomically link
    tmp_filename = f".evidence-tmp.{os.getpid()}.{secrets.token_hex(8)}"
    create_flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, 'O_NOFOLLOW'):
        create_flags |= os.O_NOFOLLOW
    if hasattr(os, 'O_CLOEXEC'):
        create_flags |= os.O_CLOEXEC

    tmp_fd = None
    try:
        tmp_fd = os.open(tmp_filename, create_flags, 0o600, dir_fd=parent_fd)
        with open(tmp_fd, 'wb', closefd=False) as f:
            f.write(envelope_bytes)
            f.flush()
            os.fsync(f.fileno())
        os.close(tmp_fd)
        tmp_fd = None

        try:
            os.link(tmp_filename, target_filename, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
        except FileExistsError:
            sys.stderr.write(f"ERROR: Evidence destination already exists or appeared during publishing (no-clobber): {target_file}\n")
            sys.exit(1)

        try:
            os.unlink(tmp_filename, dir_fd=parent_fd)
        except Exception:
            pass

        try:
            os.fsync(parent_fd)
        except Exception:
            pass

    except Exception as e:
        if tmp_fd is not None:
            try:
                os.close(tmp_fd)
            except Exception:
                pass
        try:
            os.unlink(tmp_filename, dir_fd=parent_fd)
        except Exception:
            pass
        sys.stderr.write(f"ERROR: Evidence publication failed: {e}\n")
        sys.exit(1)

finally:
    try:
        os.close(parent_fd)
    except Exception:
        pass
PY
}

build_envelope_python "$py_bin"

[ "$exit_code" -eq 0 ] || exit "$exit_code"
