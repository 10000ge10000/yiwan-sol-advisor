#!/bin/sh
# Configure Yiwan Sol Advisor dependencies on Linux, macOS, or WSL.

set -eu

official_installer_url='https://antigravity.google/cli/install.sh'
required_model='gemini-3.8-flash-high'
offline_package=''
offline_sha256=''
skip_login=0
check_only=0
skip_headless_smoke_test=0

usage() {
  cat <<'EOF'
Usage: setup-yiwan-sol-advisor.sh [options]
  --agy-offline-package PATH   Official agy_cli_* tar.gz used only if online install fails
  --agy-offline-sha256 SHA256  Expected SHA-256 for the offline package
  --skip-login                 Do not launch interactive agy authentication
  --check-only                 Verify prerequisites without installing or launching login
  --skip-headless-smoke-test   Configure sandbox automation without running the live command test
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agy-offline-package)
      [ "$#" -ge 2 ] || { printf 'ERROR: --agy-offline-package requires a value\n' >&2; exit 2; }
      offline_package=$2
      shift 2
      ;;
    --agy-offline-sha256)
      [ "$#" -ge 2 ] || { printf 'ERROR: --agy-offline-sha256 requires a value\n' >&2; exit 2; }
      offline_sha256=$2
      shift 2
      ;;
    --skip-login) skip_login=1; shift ;;
    --check-only) check_only=1; shift ;;
    --skip-headless-smoke-test) skip_headless_smoke_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found in PATH."
  printf 'FOUND: %s -> %s\n' "$1" "$(command -v "$1")"
}

find_agy() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
    return 0
  fi
  if [ -x "$HOME/.local/bin/agy" ]; then
    printf '%s\n' "$HOME/.local/bin/agy"
    return 0
  fi
  return 1
}

install_agy_online() {
  require_command curl
  installer_file=$(mktemp "${TMPDIR:-/tmp}/yiwan-agy-install.XXXXXX")
  trap 'rm -f "$installer_file"' EXIT HUP INT TERM
  if ! curl -fsSL "$official_installer_url" -o "$installer_file"; then
    rm -f "$installer_file"
    trap - EXIT HUP INT TERM
    return 1
  fi
  if ! sh "$installer_file"; then
    rm -f "$installer_file"
    trap - EXIT HUP INT TERM
    return 1
  fi
  rm -f "$installer_file"
  trap - EXIT HUP INT TERM
}

install_agy_offline() {
  package_path=$1
  expected_sha=$2
  [ -f "$package_path" ] || fail "Offline package not found: $package_path"
  case "$package_path" in
    *.tar.gz|*.tgz) ;;
    *) fail "POSIX offline package must be an official agy_cli_* tar.gz archive." ;;
  esac
  printf '%s' "$expected_sha" | grep -Eq '^[0-9a-fA-F]{64}$' || \
    fail "--agy-offline-sha256 must be the 64-character SHA-256 recorded when the official package was downloaded."

  actual_sha=$(python3 - "$package_path" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        h.update(chunk)
print(h.hexdigest())
PY
)
  [ "$actual_sha" = "$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')" ] || \
    fail "Offline package SHA-256 mismatch. Expected $expected_sha, observed $actual_sha."

  install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir"
  python3 - "$package_path" "$install_dir/agy" <<'PY'
import os, pathlib, sys, tarfile, tempfile

archive_path, destination = sys.argv[1:3]
with tarfile.open(archive_path, 'r:gz') as archive:
    members = archive.getmembers()
    for member in members:
        pure = pathlib.PurePosixPath(member.name)
        if pure.is_absolute() or '..' in pure.parts:
            raise SystemExit(f"Unsafe archive path: {member.name}")
    candidates = [m for m in members if m.isfile() and pathlib.PurePosixPath(m.name).name == 'agy']
    if len(candidates) != 1:
        raise SystemExit(f"Offline archive must contain exactly one agy executable; observed {len(candidates)}")
    source = archive.extractfile(candidates[0])
    if source is None:
        raise SystemExit('Could not read agy executable from archive')
    directory = os.path.dirname(destination)
    fd, temporary = tempfile.mkstemp(prefix='.agy.', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as output:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        os.chmod(temporary, 0o755)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY
  PATH="$install_dir:$PATH"
  export PATH
  step "Installed verified offline package to $install_dir/agy"
}

test_required_model() {
  agy_path=$1
  model_output=$("$agy_path" models 2>/dev/null) || return 1
  printf '%s\n' "$model_output" | grep -E "^${required_model}([[:space:]]|$)" >/dev/null 2>&1
}

agy_settings_path() {
  printf '%s\n' "$HOME/.gemini/antigravity-cli/settings.json"
}

test_agy_sandbox_settings() {
  settings_path=$(agy_settings_path)
  [ -f "$settings_path" ] || return 1
  python3 - "$settings_path" <<'PY'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as stream:
        settings = json.load(stream)
except Exception as exc:
    sys.stderr.write(f"ERROR: Antigravity settings are not valid JSON: {exc}\n")
    raise SystemExit(2)
raise SystemExit(0 if settings.get('toolPermission') == 'proceed-in-sandbox' and settings.get('enableTerminalSandbox') is True else 1)
PY
}

enable_agy_sandbox_automation() {
  settings_path=$(agy_settings_path)
  settings_dir=$(dirname "$settings_path")
  mkdir -p "$settings_dir"
  python3 - "$settings_path" <<'PY'
import datetime, json, os, shutil, sys, tempfile

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path, 'r', encoding='utf-8') as stream:
            settings = json.load(stream)
    except Exception as exc:
        raise SystemExit(f"ERROR: Antigravity settings are not valid JSON: {path}: {exc}. No changes were made.")
else:
    settings = {}

if settings.get('toolPermission') == 'proceed-in-sandbox' and settings.get('enableTerminalSandbox') is True:
    print('UNCHANGED')
    raise SystemExit(0)

if os.path.exists(path):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = f"{path}.yiwan-sol-advisor-backup-{stamp}"
    shutil.copy2(path, backup)
    print(f"BACKUP={backup}")

settings['toolPermission'] = 'proceed-in-sandbox'
settings['enableTerminalSandbox'] = True
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix='.settings.', suffix='.tmp', dir=directory)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as stream:
        json.dump(settings, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print('CONFIGURED')
PY
}

test_agy_headless_sandbox() {
  agy_path=$1
  smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/yiwan-agy-smoke.XXXXXX") || fail 'Could not create Antigravity smoke-test workspace.'
  trap 'rm -rf "$smoke_dir"' EXIT HUP INT TERM
  prompt="Installation self-test in a disposable directory. Use the command tool to run exactly: printf true '>' yiwan-command-ok.txt. Do not run Git and do not modify any other file."
  smoke_output=$(cd "$smoke_dir" && "$agy_path" --new-project --sandbox --dangerously-skip-permissions --model "$required_model" --effort high --mode accept-edits --output-format json --print-timeout 2m --print "$prompt" 2>&1) || {
    status=$?
    fail "Sandboxed Antigravity headless smoke test failed with exit code $status: $smoke_output"
  }
  [ -f "$smoke_dir/yiwan-command-ok.txt" ] || fail 'Sandboxed Antigravity headless smoke test did not execute its command in the target workspace.'
  [ "$(tr -d '\r\n[:space:]' < "$smoke_dir/yiwan-command-ok.txt")" = 'true' ] || fail 'Sandboxed Antigravity headless smoke test produced unexpected command evidence.'
  rm -rf "$smoke_dir"
  trap - EXIT HUP INT TERM
  step 'Sandboxed Antigravity headless command test passed'
}

step 'Checking Yiwan Sol Advisor prerequisites'
require_command codex
require_command git
require_command python3

agy_path=$(find_agy || true)
if [ -z "$agy_path" ]; then
  [ "$check_only" -eq 0 ] || fail 'agy is not installed. Re-run without --check-only to install it.'

  online_error=0
  install_agy_online || online_error=$?
  if [ "$online_error" -ne 0 ]; then
    printf 'WARNING: Official online installation failed with exit code %s.\n' "$online_error" >&2
  fi

  agy_path=$(find_agy || true)
  if [ -z "$agy_path" ] && [ -n "$offline_package" ]; then
    install_agy_offline "$offline_package" "$offline_sha256"
    agy_path=$(find_agy || true)
  fi
  [ -n "$agy_path" ] || fail 'agy installation did not complete. If Google is unreachable, provide --agy-offline-package and --agy-offline-sha256 for an official archive.'
fi

step 'Verifying Antigravity CLI'
"$agy_path" --version

model_ready=0
if test_required_model "$agy_path"; then model_ready=1; fi
if [ "$model_ready" -eq 0 ] && [ "$skip_login" -eq 0 ] && [ "$check_only" -eq 0 ]; then
  step 'Antigravity authentication or model access is required. Complete the interactive Google sign-in, then exit agy.'
  "$agy_path"
  if test_required_model "$agy_path"; then model_ready=1; fi
fi

[ "$model_ready" -eq 1 ] || fail "Required model '$required_model' is not currently available. Run 'agy', complete sign-in, then run this setup again."

if [ "$check_only" -eq 1 ]; then
  test_agy_sandbox_settings || fail 'Antigravity sandbox automation is not configured. Re-run setup without --check-only.'
else
  enable_agy_sandbox_automation
fi

if [ "$check_only" -eq 0 ] && [ "$skip_headless_smoke_test" -eq 0 ]; then
  test_agy_headless_sandbox "$agy_path"
fi

printf 'READY: Yiwan Sol Advisor prerequisites, %s, and sandboxed headless automation are available.\n' "$required_model"
