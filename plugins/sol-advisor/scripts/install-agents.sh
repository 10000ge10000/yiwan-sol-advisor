#!/bin/sh
# Install Sol Advisor's shipped custom-agent templates without changing Codex config.

set -eu

usage() {
  cat <<'EOF'
Usage: install-agents.sh [--target-dir <path>] [--check]

Install the three Sol Advisor custom-agent templates into the target directory.
Without --target-dir, the target is "$CODEX_HOME/agents" when CODEX_HOME is already
set, otherwise "$HOME/.codex/agents". The script never overwrites a differing file.

Options:
  --target-dir <path>  Explicit destination directory (absolute or relative).
  --check              Verify that every destination file already matches exactly;
                       do not create or copy anything.
  --help               Show this help text.
EOF
}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
template_dir=$script_dir/../agents

if [ -n "${CODEX_HOME-}" ]; then
  target_dir=$CODEX_HOME/agents
else
  [ -n "${HOME-}" ] || fail "HOME is unset and CODEX_HOME was not supplied; pass --target-dir explicitly."
  target_dir=$HOME/.codex/agents
fi

check_only=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      [ "$#" -ge 2 ] || fail "--target-dir requires a path."
      [ -n "$2" ] || fail "--target-dir requires a non-empty path."
      case "$2" in
        --*) fail "--target-dir path must be explicit; prefix a relative option-like name with ./ or use an absolute path." ;;
      esac
      target_dir=$2
      shift 2
      ;;
    --check)
      check_only=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (run with --help for usage)."
      ;;
  esac
done

# Make explicitly supplied relative paths unambiguous before any file operation.
case "$target_dir" in
  /*) ;;
  *) target_dir=$(pwd -P)/$target_dir ;;
esac

[ "$target_dir" != "/" ] || fail "refusing to use the filesystem root as an agent target directory."

agent_files='sol-advisor-luna-implementer.toml sol-advisor-terra-implementer.toml sol-advisor-sol-reviewer.toml'

# Validate all shipped sources before looking at or mutating the destination.
for agent_file in $agent_files; do
  template=$template_dir/$agent_file
  [ -f "$template" ] && [ ! -L "$template" ] || fail "shipped template is missing or not a regular file: $template"
done

# Preflight every destination before creating a directory or copying a template.
preflight_failed=0
if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
  if [ ! -d "$target_dir" ] || [ -L "$target_dir" ]; then
    printf '%s\n' "ERROR: target directory is not a real directory: $target_dir" >&2
    preflight_failed=1
  fi
fi

for agent_file in $agent_files; do
  template=$template_dir/$agent_file
  destination=$target_dir/$agent_file

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -f "$destination" ] || [ -L "$destination" ]; then
      printf '%s\n' "ERROR: destination is not a regular file and will not be replaced: $destination" >&2
      preflight_failed=1
    elif cmp -s "$template" "$destination"; then
      :
    else
      printf '%s\n' "ERROR: destination differs from the shipped template and will not be overwritten: $destination" >&2
      printf '%s\n' "       Inspect $template and resolve the conflict deliberately, then rerun --check." >&2
      preflight_failed=1
    fi
  elif [ "$check_only" -eq 1 ]; then
    printf '%s\n' "ERROR: required installed agent file is missing: $destination" >&2
    printf '%s\n' "       Run $0 without --check after reviewing the target directory." >&2
    preflight_failed=1
  fi
done

[ "$preflight_failed" -eq 0 ] || exit 1

if [ "$check_only" -eq 1 ]; then
  printf '%s\n' "CHECK PASSED: all Sol Advisor agent files exactly match $template_dir."
  exit 0
fi

# The full conflict preflight passed, so it is now safe to create the target directory
# and add only files that were absent. Existing exact copies are deliberately untouched.
if [ ! -d "$target_dir" ]; then
  mkdir -p "$target_dir" || fail "could not create target directory: $target_dir"
fi

for agent_file in $agent_files; do
  template=$template_dir/$agent_file
  destination=$target_dir/$agent_file

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$template" "$destination"; then
      printf '%s\n' "ALREADY CURRENT: $destination"
      continue
    fi
    fail "destination changed after preflight and will not be overwritten: $destination"
  fi

  # Stage alongside the destination, then hard-link it into place. ln fails if another
  # process created the destination after preflight, so a late conflicting file is
  # never overwritten by cp's normal replacement behavior.
  staged=$(mktemp "$target_dir/.sol-advisor-agent.XXXXXX") || fail "could not stage template for installation: $destination"
  if ! cp "$template" "$staged"; then
    rm -f "$staged"
    fail "could not stage template for installation: $destination"
  fi

  if ln "$staged" "$destination"; then
    rm -f "$staged" || fail "could not remove staged template after installation: $staged"
  else
    rm -f "$staged" || fail "could not remove staged template after conflict: $staged"
    if [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$template" "$destination"; then
      printf '%s\n' "ALREADY CURRENT: $destination"
      continue
    fi
    fail "destination changed after preflight and will not be overwritten: $destination"
  fi

  printf '%s\n' "INSTALLED: $destination"
done

for agent_file in $agent_files; do
  template=$template_dir/$agent_file
  destination=$target_dir/$agent_file
  cmp -s "$template" "$destination" || fail "post-install exactness check failed: $destination"
done

printf '%s\n' "INSTALL PASSED: all Sol Advisor agent files exactly match $template_dir."
