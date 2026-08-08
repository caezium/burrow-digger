#!/bin/bash
# Mole - Canonical operation-history log root policy.

set -euo pipefail

if [[ -n "${MOLE_LOG_PATHS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_LOG_PATHS_LOADED=1

if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    _MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi

readonly MOLE_OPLOG_DIRECTORY_NAME="mole"

_mole_log_root_error() {
    printf 'Invalid operation log root: %s\n' "$1" >&2
    return 1
}

_mole_reject_independent_log_overrides() {
    if [[ -n "${MOLE_DELETE_LOG+x}" || -n "${MOLE_OPERATIONS_LOG+x}" ]]; then
        _mole_log_root_error "use MOLE_OPLOG_PATH for the shared log directory"
        return 1
    fi
}

_mole_log_physical_dir() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || return 1
    (cd -P "$path" 2> /dev/null && pwd -P)
}

_mole_log_stat_uid() {
    /usr/bin/stat -f '%u' "$1" 2> /dev/null
}

_mole_log_stat_device() {
    /usr/bin/stat -f '%d' "$1" 2> /dev/null
}

_mole_validate_owned_log_dir() {
    local path="$1"
    local expected_uid="$2"
    local expected_device="$3"
    local actual_uid actual_device

    [[ -d "$path" && ! -L "$path" ]] || {
        _mole_log_root_error "not a real directory: $path"
        return 1
    }
    actual_uid=$(_mole_log_stat_uid "$path") || {
        _mole_log_root_error "cannot inspect ownership: $path"
        return 1
    }
    [[ "$actual_uid" == "$expected_uid" ]] || {
        _mole_log_root_error "unexpected owner: $path"
        return 1
    }
    actual_device=$(_mole_log_stat_device "$path") || {
        _mole_log_root_error "cannot inspect volume: $path"
        return 1
    }
    [[ "$actual_device" == "$expected_device" ]] || {
        _mole_log_root_error "unexpected volume: $path"
        return 1
    }
}

_mole_create_owned_log_dir() {
    local path="$1"
    local expected_uid="$2"
    local expected_gid="$3"
    local expected_device="$4"

    if [[ -e "$path" || -L "$path" ]]; then
        _mole_validate_owned_log_dir "$path" "$expected_uid" "$expected_device"
        return $?
    fi

    if ! mkdir -m 0700 "$path" 2> /dev/null; then
        _mole_log_root_error "cannot create approved directory: $path"
        return 1
    fi
    if [[ "$(id -u)" == "0" ]] && ! chown "$expected_uid:$expected_gid" "$path" 2> /dev/null; then
        rmdir "$path" 2> /dev/null || true
        _mole_log_root_error "cannot assign invoking-user ownership: $path"
        return 1
    fi
    _mole_validate_owned_log_dir "$path" "$expected_uid" "$expected_device"
}

mole_prepare_operation_log_root() {
    local home canonical_home library_dir logs_parent raw_root root_name
    local expected_uid expected_gid expected_device

    _mole_reject_independent_log_overrides || return 1

    home=$(get_invoking_home)
    [[ -n "$home" && "$home" == /* ]] || {
        _mole_log_root_error "invoking home is unavailable or relative"
        return 1
    }
    [[ "$home" != *[[:cntrl:]]* ]] || {
        _mole_log_root_error "invoking home contains control characters"
        return 1
    }
    canonical_home=$(_mole_log_physical_dir "$home") || {
        _mole_log_root_error "invoking home is not a real directory"
        return 1
    }
    [[ "$canonical_home" == "$home" ]] || {
        _mole_log_root_error "invoking home is not canonical"
        return 1
    }

    expected_uid=$(get_invoking_uid)
    expected_gid=$(get_invoking_gid)
    [[ "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] || {
        _mole_log_root_error "invoking identity is unavailable"
        return 1
    }
    expected_device=$(_mole_log_stat_device "$canonical_home") || {
        _mole_log_root_error "cannot inspect invoking home"
        return 1
    }
    _mole_validate_owned_log_dir "$canonical_home" "$expected_uid" "$expected_device" || return 1

    library_dir="$canonical_home/Library"
    logs_parent="$library_dir/Logs"
    _mole_create_owned_log_dir "$library_dir" "$expected_uid" "$expected_gid" "$expected_device" || return 1
    _mole_create_owned_log_dir "$logs_parent" "$expected_uid" "$expected_gid" "$expected_device" || return 1

    raw_root="${MOLE_OPLOG_PATH:-$logs_parent/$MOLE_OPLOG_DIRECTORY_NAME}"
    [[ -n "$raw_root" && "$raw_root" == /* ]] || {
        _mole_log_root_error "override must be absolute"
        return 1
    }
    [[ "$raw_root" != *[[:cntrl:]]* ]] || {
        _mole_log_root_error "override contains control characters"
        return 1
    }
    [[ "$raw_root" != */ && "$raw_root" != *//* ]] || {
        _mole_log_root_error "override is not canonical"
        return 1
    }
    [[ "$(dirname "$raw_root")" == "$logs_parent" ]] || {
        _mole_log_root_error "override is outside $logs_parent"
        return 1
    }
    root_name=$(basename "$raw_root")
    [[ "$root_name" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || {
        _mole_log_root_error "override has unsupported characters"
        return 1
    }
    [[ "$root_name" != "." && "$root_name" != ".." ]] || {
        _mole_log_root_error "override has an invalid directory name"
        return 1
    }

    _mole_create_owned_log_dir "$raw_root" "$expected_uid" "$expected_gid" "$expected_device" || return 1
    mole_operation_log_root
}

mole_operation_log_root() {
    local home raw_root logs_parent canonical_home canonical_parent canonical_root
    local expected_uid expected_device root_name

    _mole_reject_independent_log_overrides || return 1

    home=$(get_invoking_home)
    [[ -n "$home" && "$home" == /* ]] || {
        _mole_log_root_error "invoking home is unavailable or relative"
        return 1
    }
    [[ "$home" != *[[:cntrl:]]* ]] || {
        _mole_log_root_error "invoking home contains control characters"
        return 1
    }
    canonical_home=$(_mole_log_physical_dir "$home") || {
        _mole_log_root_error "invoking home is not a real directory"
        return 1
    }
    [[ "$canonical_home" == "$home" ]] || {
        _mole_log_root_error "invoking home is not canonical"
        return 1
    }

    expected_uid=$(get_invoking_uid)
    [[ "$expected_uid" =~ ^[0-9]+$ ]] || {
        _mole_log_root_error "invoking uid is unavailable"
        return 1
    }
    expected_device=$(_mole_log_stat_device "$canonical_home") || {
        _mole_log_root_error "cannot inspect invoking home"
        return 1
    }
    _mole_validate_owned_log_dir "$canonical_home" "$expected_uid" "$expected_device" || return 1

    logs_parent="$canonical_home/Library/Logs"
    canonical_parent=$(_mole_log_physical_dir "$logs_parent") || {
        _mole_log_root_error "approved parent is not a real directory: $logs_parent"
        return 1
    }
    [[ "$canonical_parent" == "$logs_parent" ]] || {
        _mole_log_root_error "approved parent is not canonical: $logs_parent"
        return 1
    }
    _mole_validate_owned_log_dir "$canonical_parent" "$expected_uid" "$expected_device" || return 1

    raw_root="${MOLE_OPLOG_PATH:-$canonical_parent/$MOLE_OPLOG_DIRECTORY_NAME}"
    [[ -n "$raw_root" && "$raw_root" == /* ]] || {
        _mole_log_root_error "override must be absolute"
        return 1
    }
    [[ "$raw_root" != *[[:cntrl:]]* ]] || {
        _mole_log_root_error "override contains control characters"
        return 1
    }
    [[ "$raw_root" != */ && "$raw_root" != *//* ]] || {
        _mole_log_root_error "override is not canonical"
        return 1
    }
    [[ "$(dirname "$raw_root")" == "$canonical_parent" ]] || {
        _mole_log_root_error "override is outside $canonical_parent"
        return 1
    }

    root_name=$(basename "$raw_root")
    [[ "$root_name" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || {
        _mole_log_root_error "override has unsupported characters"
        return 1
    }
    [[ "$root_name" != "." && "$root_name" != ".." ]] || {
        _mole_log_root_error "override has an invalid directory name"
        return 1
    }

    canonical_root=$(_mole_log_physical_dir "$raw_root") || {
        _mole_log_root_error "not a real directory: $raw_root"
        return 1
    }
    [[ "$canonical_root" == "$raw_root" ]] || {
        _mole_log_root_error "override is not canonical: $raw_root"
        return 1
    }
    _mole_validate_owned_log_dir "$canonical_root" "$expected_uid" "$expected_device" || return 1

    printf '%s\n' "$canonical_root"
}

mole_operation_log_root_for_read() {
    local home canonical_home library_dir logs_parent raw_root root_name canonical_root
    local expected_uid expected_device existing_dir

    _mole_reject_independent_log_overrides || return 1
    home=$(get_invoking_home)
    [[ -n "$home" && "$home" == /* && "$home" != *[[:cntrl:]]* ]] || {
        _mole_log_root_error "invoking home is unavailable, relative, or contains controls"
        return 1
    }
    canonical_home=$(_mole_log_physical_dir "$home") || {
        _mole_log_root_error "invoking home is not a real directory"
        return 1
    }
    [[ "$canonical_home" == "$home" ]] || {
        _mole_log_root_error "invoking home is not canonical"
        return 1
    }
    expected_uid=$(get_invoking_uid)
    expected_device=$(_mole_log_stat_device "$canonical_home") || return 1
    _mole_validate_owned_log_dir "$canonical_home" "$expected_uid" "$expected_device" || return 1

    library_dir="$canonical_home/Library"
    logs_parent="$library_dir/Logs"
    for existing_dir in "$library_dir" "$logs_parent"; do
        if [[ -e "$existing_dir" || -L "$existing_dir" ]]; then
            _mole_validate_owned_log_dir "$existing_dir" "$expected_uid" "$expected_device" || return 1
        fi
    done

    raw_root="${MOLE_OPLOG_PATH:-$logs_parent/$MOLE_OPLOG_DIRECTORY_NAME}"
    [[ -n "$raw_root" && "$raw_root" == /* ]] || {
        _mole_log_root_error "override must be absolute"
        return 1
    }
    [[ "$raw_root" != *[[:cntrl:]]* && "$raw_root" != */ && "$raw_root" != *//* ]] || {
        _mole_log_root_error "override contains controls or is not canonical"
        return 1
    }
    [[ "$(dirname "$raw_root")" == "$logs_parent" ]] || {
        _mole_log_root_error "override is outside $logs_parent"
        return 1
    }
    root_name=$(basename "$raw_root")
    [[ "$root_name" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || {
        _mole_log_root_error "override has unsupported characters"
        return 1
    }

    if [[ -e "$raw_root" || -L "$raw_root" ]]; then
        _mole_validate_owned_log_dir "$raw_root" "$expected_uid" "$expected_device" || return 1
        canonical_root=$(_mole_log_physical_dir "$raw_root") || return 1
        [[ "$canonical_root" == "$raw_root" ]] || {
            _mole_log_root_error "override is not canonical: $raw_root"
            return 1
        }
    fi
    printf '%s\n' "$raw_root"
}

mole_operation_log_file() {
    local filename="$1"
    local root

    case "$filename" in
        operations.log | deletions.log | mole.log | mole_debug_session.log) ;;
        *)
            _mole_log_root_error "unsupported log filename: $filename"
            return 1
            ;;
    esac

    root=$(mole_operation_log_root_for_read) || return 1
    printf '%s/%s\n' "$root" "$filename"
}
