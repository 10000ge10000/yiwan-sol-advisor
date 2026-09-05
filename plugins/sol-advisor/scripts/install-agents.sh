#!/bin/sh
# Install Sol Advisor's Sol reviewer custom-agent template without changing Codex config.

set -eu

usage() {
  cat <<'EOF'
Usage: install-agents.sh [--target-dir PATH] [--check] [--check-role ROLE ...]

Install Sol Advisor's Sol reviewer custom-agent template into the target directory.
Normal mode also migrates byte-matching historical templates and safely retires
legacy Luna and Terra implementer roles. It never overwrites a modified, nonregular,
symlinked, or unknown destination.

Without --target-dir, the target is "$CODEX_HOME/agents" when CODEX_HOME is already
set, otherwise "$HOME/.codex/agents".

Options:
  --target-dir PATH  Explicit destination directory (absolute or relative).
  --check            Verify that Sol matches exactly; do not create, replace,
                     or remove anything.
  --check-role ROLE  Verify that ROLE (sol) matches current template exactly and
                     enforce the complete absence of all retired roles (luna, terra).
                     Repeatable and implies --check. Unknown or retired roles fail.
  --help             Show this help text.
EOF
}

created_lock_dir=''
cleanup_lock() {
  if [ -n "$created_lock_dir" ] && [ -d "$created_lock_dir" ]; then
    rmdir "$created_lock_dir" 2>/dev/null || true
  fi
}
trap cleanup_lock 0 HUP INT TERM

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

report_preflight_error() {
  printf '%s\n' "ERROR: $*" >&2
  preflight_failed=1
}

role_selected() {
  role=$1
  if [ -z "$check_roles" ]; then
    return 0
  fi
  case ",$check_roles," in
    *,"$role",*) return 0 ;;
    *) return 1 ;;
  esac
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk 'NF >= 1 && length($1) == 64 { print $1; exit }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk 'NF >= 1 && length($1) == 64 { print $1; exit }'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$1" 2>/dev/null
  elif command -v python >/dev/null 2>&1; then
    python -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$1" 2>/dev/null
  fi
}

matches_digest() {
  file_digest=$1
  shift
  for d in "$@"; do
    if [ -n "$d" ] && [ "$file_digest" = "$d" ]; then
      return 0
    fi
  done
  return 1
}

classify_sol_role() {
  destination=$1
  template=$2
  shift 2

  if ! path_exists "$destination"; then
    printf '%s\n' missing
  elif [ -L "$destination" ] || [ ! -f "$destination" ]; then
    printf '%s\n' unsafe
  elif cmp -s "$template" "$destination"; then
    printf '%s\n' current
  else
    digest=$(sha256_file "$destination")
    if [ -n "$digest" ] && matches_digest "$digest" "$@"; then
      printf '%s\n' legacy
    elif [ -z "$digest" ]; then
      printf '%s\n' unreadable
    else
      printf '%s\n' conflict
    fi
  fi
}

classify_retired_role() {
  destination=$1
  shift

  if ! path_exists "$destination"; then
    printf '%s\n' missing
  elif [ -L "$destination" ] || [ ! -f "$destination" ]; then
    printf '%s\n' unsafe
  else
    digest=$(sha256_file "$destination")
    if [ -n "$digest" ] && matches_digest "$digest" "$@"; then
      printf '%s\n' retired
    elif [ -z "$digest" ]; then
      printf '%s\n' unreadable
    else
      printf '%s\n' conflict
    fi
  fi
}

sol_backup=''
sol_installed_missing=0
luna_retired_backup=''
terra_retired_backup=''

rollback_all() {
  err_msg=$1

  # Test hook for race before rollback restoration
  if [ -n "${_SOL_ADVISOR_TEST_ACTION_BEFORE_ROLLBACK_RESTORE+x}" ]; then
    if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
      fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
    fi
    case "$_SOL_ADVISOR_TEST_ACTION_BEFORE_ROLLBACK_RESTORE" in
      race_sol_restore)
        printf 'COMPETING_SOL_BEFORE_RESTORE' > "$sol_destination"
        ;;
      race_luna_restore)
        printf 'COMPETING_LUNA_BEFORE_RESTORE' > "$luna_destination"
        ;;
      race_terra_restore)
        printf 'COMPETING_TERRA_BEFORE_RESTORE' > "$terra_destination"
        ;;
      *)
        fail "unknown test action before rollback restore: $_SOL_ADVISOR_TEST_ACTION_BEFORE_ROLLBACK_RESTORE"
        ;;
    esac
  fi

  if [ -n "$sol_backup" ] && [ -f "$sol_backup" ]; then
    restored=0
    if ln "$sol_backup" "$sol_destination" 2>/dev/null; then
      restored=1
      rm -f "$sol_backup" 2>/dev/null || true
      sol_backup=''
    fi
    if [ "$restored" -eq 0 ]; then
      err_msg="$err_msg; Sol destination exists or cannot be restored without clobbering; original legacy Sol preserved at $sol_backup (manual recovery: copy $sol_backup to $sol_destination)"
    fi
  fi

  if [ -n "$luna_retired_backup" ] && [ -f "$luna_retired_backup" ]; then
    restored=0
    if ln "$luna_retired_backup" "$luna_destination" 2>/dev/null; then
      restored=1
      rm -f "$luna_retired_backup" 2>/dev/null || true
      luna_retired_backup=''
    fi
    if [ "$restored" -eq 0 ]; then
      err_msg="$err_msg; Luna destination exists or cannot be restored without clobbering; original Luna preserved at $luna_retired_backup (manual recovery: copy $luna_retired_backup to $luna_destination)"
    fi
  fi

  if [ -n "$terra_retired_backup" ] && [ -f "$terra_retired_backup" ]; then
    restored=0
    if ln "$terra_retired_backup" "$terra_destination" 2>/dev/null; then
      restored=1
      rm -f "$terra_retired_backup" 2>/dev/null || true
      terra_retired_backup=''
    fi
    if [ "$restored" -eq 0 ]; then
      err_msg="$err_msg; Terra destination exists or cannot be restored without clobbering; original Terra preserved at $terra_retired_backup (manual recovery: copy $terra_retired_backup to $terra_destination)"
    fi
  fi

  fail "$err_msg"
}

install_missing() {
  template=$1
  destination=$2
  shift 2
  staged=''

  curr_state=$(classify_sol_role "$destination" "$template" "$@")
  if [ "$curr_state" != "missing" ]; then
    rollback_all "destination changed after preflight (now $curr_state) and will not be overwritten: $destination"
  fi

  staged=$(mktemp "$target_dir/.sol-advisor-agent.XXXXXX") || rollback_all "could not stage template for installation: $destination"
  if ! cp "$template" "$staged"; then
    rm -f "$staged"
    rollback_all "could not stage template for installation: $destination"
  fi

  # Deterministic test hook: test action before link publication
  if [ -n "${_SOL_ADVISOR_TEST_ACTION_BEFORE_PUBLISH+x}" ]; then
    if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
      fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
    fi
    case "$_SOL_ADVISOR_TEST_ACTION_BEFORE_PUBLISH" in
      race_install_missing)
        printf 'RACE_COMPETING_SOL_BYTES' > "$destination"
        ;;
      *)
        fail "unknown test action before publish: $_SOL_ADVISOR_TEST_ACTION_BEFORE_PUBLISH"
        ;;
    esac
  fi

  published=0
  if ln "$staged" "$destination" 2>/dev/null; then
    published=1
  fi
  rm -f "$staged" || true

  if [ "$published" -ne 1 ]; then
    rollback_all "destination appeared or changed after preflight and will not be overwritten: $destination"
  fi

  if ! cmp -s "$template" "$destination"; then
    rollback_all "installed file does not match template: $destination"
  fi

  sol_installed_missing=1
  printf '%s\n' "INSTALLED: $destination"
}

replace_legacy_sol() {
  template=$1
  destination=$2
  shift 2
  staged=''

  curr_state=$(classify_sol_role "$destination" "$template" "$@")
  if [ "$curr_state" != "legacy" ]; then
    rollback_all "destination changed after preflight (now $curr_state) and will not be replaced: $destination"
  fi

  curr_digest=$(sha256_file "$destination")
  if ! matches_digest "$curr_digest" "$@"; then
    rollback_all "destination digest changed after preflight and will not be replaced: $destination"
  fi

  staged=$(mktemp "$target_dir/.sol-advisor-agent.XXXXXX") || rollback_all "could not stage migrated Sol template: $destination"
  if ! cp "$template" "$staged"; then
    rm -f "$staged"
    rollback_all "could not stage migrated Sol template: $destination"
  fi

  final_digest=$(sha256_file "$destination")
  if [ "$final_digest" != "$curr_digest" ]; then
    rm -f "$staged"
    rollback_all "destination digest changed immediately before replacement: $destination"
  fi

  sol_backup=$(mktemp "$target_dir/.sol-advisor-sol-backup.XXXXXX") || { rm -f "$staged"; rollback_all "could not stage backup for Sol migration: $destination"; }
  if ! mv -f "$destination" "$sol_backup"; then
    rm -f "$staged" "$sol_backup"
    sol_backup=''
    rollback_all "could not back up legacy Sol before replacement: $destination"
  fi

  # Deterministic test hook for race between backup and publish
  if [ -n "${_SOL_ADVISOR_TEST_ACTION_AFTER_SOL_BACKUP+x}" ]; then
    if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
      fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
    fi
    case "$_SOL_ADVISOR_TEST_ACTION_AFTER_SOL_BACKUP" in
      tamper_sol_publish|race_sol_publish)
        printf 'RACE_COMPETING_SOL_BYTES' > "$destination"
        ;;
      *)
        fail "unknown test action after sol backup: $_SOL_ADVISOR_TEST_ACTION_AFTER_SOL_BACKUP"
        ;;
    esac
  fi

  published=0
  if ln "$staged" "$destination" 2>/dev/null; then
    published=1
  fi
  rm -f "$staged" || true

  if [ "$published" -eq 1 ] && cmp -s "$template" "$destination"; then
    printf '%s\n' "MIGRATED: $destination"
  else
    restored=0
    if [ -f "$sol_backup" ]; then
      if ln "$sol_backup" "$destination" 2>/dev/null; then
        restored=1
        rm -f "$sol_backup"
        sol_backup=''
      fi
    fi
    if [ "$restored" -eq 1 ]; then
      rollback_all "destination publish failed; original legacy Sol was restored: $destination"
    else
      rollback_all "destination appeared or changed during replacement and will not be overwritten: $destination; original legacy Sol preserved at $sol_backup (manual recovery: copy $sol_backup to $destination)"
    fi
  fi
}

retire_role() {
  label=$1
  destination=$2
  shift 2

  curr_state=$(classify_retired_role "$destination" "$@")
  if [ "$curr_state" != "retired" ]; then
    rollback_all "$label destination changed after preflight (now $curr_state) and will not be removed: $destination"
  fi

  curr_digest=$(sha256_file "$destination")
  if ! matches_digest "$curr_digest" "$@"; then
    rollback_all "$label destination digest changed after preflight and will not be removed: $destination"
  fi

  quarantine=$(mktemp "$target_dir/.sol-advisor-quarantine.XXXXXX") || rollback_all "could not create quarantine path for $label: $destination"
  if ! mv -f "$destination" "$quarantine"; then
    rm -f "$quarantine" 2>/dev/null || true
    rollback_all "could not move $label to quarantine: $destination"
  fi

  # Deterministic test hook: tamper quarantine file to simulate digest mismatch in quarantine
  if [ -n "${_SOL_ADVISOR_TEST_ACTION_AFTER_QUARANTINE_MOVE+x}" ]; then
    if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
      fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
    fi
    case "$_SOL_ADVISOR_TEST_ACTION_AFTER_QUARANTINE_MOVE" in
      tamper_quarantine)
        printf 'TAMPERED_QUARANTINE_BYTES' > "$quarantine"
        ;;
      *)
        fail "unknown test action after quarantine move: $_SOL_ADVISOR_TEST_ACTION_AFTER_QUARANTINE_MOVE"
        ;;
    esac
  fi

  if [ ! -f "$quarantine" ] || [ -L "$quarantine" ]; then
    rollback_all "quarantined $label is not a regular file: $quarantine"
  fi

  quarantine_digest=$(sha256_file "$quarantine")
  if [ -z "$quarantine_digest" ] || ! matches_digest "$quarantine_digest" "$@"; then
    if [ -n "${_SOL_ADVISOR_TEST_ACTION_BEFORE_QUARANTINE_RESTORE+x}" ]; then
      if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
        fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
      fi
      case "$_SOL_ADVISOR_TEST_ACTION_BEFORE_QUARANTINE_RESTORE" in
        race_quarantine_restore)
          printf 'COMPETING_QUARANTINE_DEST_BYTES' > "$destination"
          ;;
        *)
          fail "unknown test action before quarantine restore: $_SOL_ADVISOR_TEST_ACTION_BEFORE_QUARANTINE_RESTORE"
          ;;
      esac
    fi
    restored=0
    if ln "$quarantine" "$destination" 2>/dev/null; then
      restored=1
      rm -f "$quarantine" 2>/dev/null || true
    fi
    if [ "$restored" -eq 1 ]; then
      rollback_all "$label destination digest changed immediately before quarantine and will not be removed: $destination"
    else
      rollback_all "$label destination digest in quarantine did not match recognized digest; destination appeared or cannot be restored without clobbering; original preserved at $quarantine (manual recovery: inspect $quarantine and copy to $destination)"
    fi
  fi

  if [ "$label" = "Luna" ]; then
    luna_retired_backup=$quarantine
  elif [ "$label" = "Terra" ]; then
    terra_retired_backup=$quarantine
  else
    rm -f "$quarantine" 2>/dev/null || true
  fi

  if path_exists "$destination"; then
    rollback_all "retired $label template still exists after removal: $destination"
  fi

  printf '%s\n' "RETIRED: $destination"
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
check_roles=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      [ "$#" -ge 2 ] || fail "--target-dir requires a path."
      [ -n "$2" ] || fail "--target-dir requires a non-empty path."
      case "$2" in
        --*) fail "--target-dir path must be explicit; prefix an option-like relative name with ./ or use an absolute path." ;;
      esac
      target_dir=$2
      shift 2
      ;;
    --check)
      check_only=1
      shift
      ;;
    --check-role)
      [ "$#" -ge 2 ] || fail "--check-role requires a role: sol."
      case "$2" in
        sol) ;;
        *) fail "unknown --check-role '$2'; expected sol." ;;
      esac
      check_only=1
      check_roles=$check_roles$2,
      shift 2
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

case "$target_dir" in
  /*) ;;
  *) target_dir=$(pwd -P)/$target_dir ;;
esac

case "$target_dir" in
  /|//) fail "refusing to use the filesystem root as an agent target directory." ;;
esac

terra_file=sol-advisor-terra-implementer.toml
luna_file=sol-advisor-luna-implementer.toml
sol_file=sol-advisor-sol-reviewer.toml
sol_template=$template_dir/$sol_file
terra_destination=$target_dir/$terra_file
luna_destination=$target_dir/$luna_file
sol_destination=$target_dir/$sol_file

# Historical Luna digests (v0.2.0, v0.4.0 custom, v0.5.0, v0.6.0; LF and CRLF)
legacy_luna_v020_lf=fba1b42849d93737e83b094a2ab0b1611f87ac37db7438c8bbdf581f0813f8eb
legacy_luna_v020_crlf=d823f5c616a34e837e11e63ad01dfe7626e84b6ea0ba1a9c992fef6c2fdbc701
legacy_luna_v040_lf=3b49d9fecf329dd6636f9494cd6038f69eb4f3cd689b550e4c546f4ab6d464bb
legacy_luna_v040_crlf=a219c78acb07f719aeb637ea6be466101b359a1a098303a65d89d242eab78db0
legacy_luna_v050_lf=5cfaf77f14757074ca5d3cfecd0b8204c91dc14eff8d6119985c64416ddf4853
legacy_luna_v050_crlf=4150331e87602b59a9dddd517a78c1520692c49e8286bd7b855646a91db9f894
legacy_luna_v060_lf=12fa9180a292876e6731bc325779123bcd931c3caa902fbf90d676a31833be84
legacy_luna_v060_crlf=000ff8bed7f94f77a460fb81424d51233eb6146db5b21a346068aceb6a9abe27

# Historical Terra digests (v0.2.0, v0.5.0, v0.6.0; LF and CRLF)
legacy_terra_v020_lf=4425a8c1f21ce8c6af93f96adc253bbc33ea301f1389b3fa8ce350be08584eca
legacy_terra_v020_crlf=71d89684ac48d8a08791373db97d7a466c89d4009fa7d9c220bfc7adf009052a
legacy_terra_v050_lf=dc329fe87f6f6610c13157ec16432f91c79cf5a541ee3e7448f6afb165dd18ce
legacy_terra_v050_crlf=c6988a4b094835cd144427d7d0ce0e20d0a93587736288f65f906e9f73157bb6
legacy_terra_v060_lf=77ed2f36bb149da5d9032230c3d6f5e5cd56b059b3fa5f59085249bba06e1f3a
legacy_terra_v060_crlf=7c9497c46207007565f72ac9bac6ce4954a1491914e4d64b44e27e4c27e8cd43

# Historical Sol digests (v0.4.0 custom, v0.6.0 high effort; LF, CRLF, and mixed LF/CRLF)
legacy_sol_v040_lf=8e998e0e08a2dcad4c18d896cc19bbf97d869d89855a466322c6ec4f6d969997
legacy_sol_v040_crlf=f6e206252abe8012e43718ea1cd81a6aa52a0aa736bb88fdbd1deaf5524771a9
legacy_sol_v040_mixed=65223c5a3a6b8f2d08148fcf4ebc66fc170213e73a7c27a4780f8fd3579f5b47
legacy_sol_v060_lf=0333acf0ef562bcfebd06009ac09bd1dd8cbc04c4cf28e08e9e049bd8bf202d2
legacy_sol_v060_crlf=6ac63677bcc8677a9a743522cf06696c8edb1b005a61430e0fc8fa62e18dc355
legacy_sol_v070_max_lf=1d475b27638098331eae86d6383812ec14d833a04f58ed4503c7c7c06373bac6
legacy_sol_v070_max_crlf=30537dff1f8c255dade1072705001206b15513fd45c74a115643ab7bca6d9fe7

[ -f "$sol_template" ] && [ ! -L "$sol_template" ] ||
  fail "shipped template is missing or not a regular file: $sol_template"

preflight_failed=0
if path_exists "$target_dir"; then
  if [ -L "$target_dir" ] || [ ! -d "$target_dir" ]; then
    report_preflight_error "target directory is not a real directory: $target_dir"
  fi
fi

sol_state=$(classify_sol_role "$sol_destination" "$sol_template" "$legacy_sol_v040_lf" "$legacy_sol_v040_crlf" "$legacy_sol_v040_mixed" "$legacy_sol_v060_lf" "$legacy_sol_v060_crlf" "$legacy_sol_v070_max_lf" "$legacy_sol_v070_max_crlf")
luna_state=$(classify_retired_role "$luna_destination" "$legacy_luna_v020_lf" "$legacy_luna_v020_crlf" "$legacy_luna_v040_lf" "$legacy_luna_v040_crlf" "$legacy_luna_v050_lf" "$legacy_luna_v050_crlf" "$legacy_luna_v060_lf" "$legacy_luna_v060_crlf")
terra_state=$(classify_retired_role "$terra_destination" "$legacy_terra_v020_lf" "$legacy_terra_v020_crlf" "$legacy_terra_v050_lf" "$legacy_terra_v050_crlf" "$legacy_terra_v060_lf" "$legacy_terra_v060_crlf")

if [ "$check_only" -eq 1 ]; then
  if role_selected sol; then
    [ "$sol_state" = current ] ||
      report_preflight_error "Sol template is $sol_state, not the current exact file: $sol_destination"
  fi
  if path_exists "$luna_destination"; then
    report_preflight_error "retired Luna role remains: $luna_destination ($luna_state)"
  fi
  if path_exists "$terra_destination"; then
    report_preflight_error "retired Terra role remains: $terra_destination ($terra_state)"
  fi
else
  case "$sol_state" in
    current|legacy|missing) ;;
    *) report_preflight_error "Sol destination is $sol_state and will not be replaced: $sol_destination" ;;
  esac
  case "$luna_state" in
    missing|retired) ;;
    *) report_preflight_error "Luna destination is $luna_state and will not be removed/replaced: $luna_destination" ;;
  esac
  case "$terra_state" in
    missing|retired) ;;
    *) report_preflight_error "Terra destination is $terra_state and will not be removed/replaced: $terra_destination" ;;
  esac
fi

[ "$preflight_failed" -eq 0 ] || exit 1

if [ "$check_only" -eq 1 ]; then
  printf '%s\n' "CHECK PASSED: Sol exactly matches $template_dir."
  exit 0
fi

if [ ! -d "$target_dir" ]; then
  mkdir -p "$target_dir" || fail "could not create target directory: $target_dir"
fi
[ -d "$target_dir" ] && [ ! -L "$target_dir" ] ||
  fail "target directory changed after preflight: $target_dir"

installer_lock_dir="$target_dir/.sol-advisor-install.lock"
if ! mkdir "$installer_lock_dir" 2>/dev/null; then
  fail "could not acquire exclusive installer lock in $target_dir: another installation is in progress or stale lock exists ($installer_lock_dir)"
fi
created_lock_dir="$installer_lock_dir"

if [ -n "${_SOL_ADVISOR_TEST_ACTION_AFTER_PREFLIGHT+x}" ] || [ -n "${_SOL_ADVISOR_TEST_HOOK_AFTER_PREFLIGHT+x}" ]; then
  if [ "${_SOL_ADVISOR_TEST_MODE-}" != "1" ]; then
    fail "test action hook variable specified without _SOL_ADVISOR_TEST_MODE=1"
  fi
  test_action="${_SOL_ADVISOR_TEST_ACTION_AFTER_PREFLIGHT-${_SOL_ADVISOR_TEST_HOOK_AFTER_PREFLIGHT-}}"
  case "$test_action" in
    tamper_sol_missing|race_missing)
      printf 'UNKNOWN_RACE_BYTES' > "$target_dir/$sol_file"
      ;;
    tamper_sol_legacy|race_legacy)
      printf 'TAMPERED_LEGACY_BYTES' > "$target_dir/$sol_file"
      ;;
    tamper_luna_retired|race_luna)
      printf 'TAMPERED_LUNA_BYTES' > "$target_dir/$luna_file"
      ;;
    tamper_terra_retired|race_terra)
      printf 'TAMPERED_TERRA_BYTES' > "$target_dir/$terra_file"
      ;;
    *)
      fail "unknown test action: $test_action"
      ;;
  esac
fi

case "$luna_state" in
  retired) retire_role Luna "$luna_destination" "$legacy_luna_v020_lf" "$legacy_luna_v020_crlf" "$legacy_luna_v040_lf" "$legacy_luna_v040_crlf" "$legacy_luna_v050_lf" "$legacy_luna_v050_crlf" "$legacy_luna_v060_lf" "$legacy_luna_v060_crlf" ;;
  missing) ;;
esac

case "$terra_state" in
  retired) retire_role Terra "$terra_destination" "$legacy_terra_v020_lf" "$legacy_terra_v020_crlf" "$legacy_terra_v050_lf" "$legacy_terra_v050_crlf" "$legacy_terra_v060_lf" "$legacy_terra_v060_crlf" ;;
  missing) ;;
esac

case "$sol_state" in
  missing) install_missing "$sol_template" "$sol_destination" "$legacy_sol_v040_lf" "$legacy_sol_v040_crlf" "$legacy_sol_v040_mixed" "$legacy_sol_v060_lf" "$legacy_sol_v060_crlf" "$legacy_sol_v070_max_lf" "$legacy_sol_v070_max_crlf" ;;
  legacy) replace_legacy_sol "$sol_template" "$sol_destination" "$legacy_sol_v040_lf" "$legacy_sol_v040_crlf" "$legacy_sol_v040_mixed" "$legacy_sol_v060_lf" "$legacy_sol_v060_crlf" "$legacy_sol_v070_max_lf" "$legacy_sol_v070_max_crlf" ;;
  current) printf '%s\n' "ALREADY CURRENT: $sol_destination" ;;
esac

# Cleanup backup on complete transaction success
if [ -n "$sol_backup" ] && [ -f "$sol_backup" ]; then
  rm -f "$sol_backup" 2>/dev/null || true
  sol_backup=''
fi
if [ -n "$luna_retired_backup" ] && [ -f "$luna_retired_backup" ]; then
  rm -f "$luna_retired_backup" 2>/dev/null || true
  luna_retired_backup=''
fi
if [ -n "$terra_retired_backup" ] && [ -f "$terra_retired_backup" ]; then
  rm -f "$terra_retired_backup" 2>/dev/null || true
  terra_retired_backup=''
fi

[ "$(classify_sol_role "$sol_destination" "$sol_template" "$legacy_sol_v040_lf" "$legacy_sol_v040_crlf" "$legacy_sol_v040_mixed" "$legacy_sol_v060_lf" "$legacy_sol_v060_crlf" "$legacy_sol_v070_max_lf" "$legacy_sol_v070_max_crlf")" = current ] ||
  fail "post-install exactness check failed: $sol_destination"

if path_exists "$luna_destination"; then
  fail "post-install cleanup failed: $luna_destination still exists"
fi
if path_exists "$terra_destination"; then
  fail "post-install cleanup failed: $terra_destination still exists"
fi

printf '%s\n' "INSTALL PASSED: Sol exactly matches $template_dir."
