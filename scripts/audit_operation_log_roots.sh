#!/bin/bash
# Inventory Mole-like operation log roots without modifying them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/core/base.sh
source "$PROJECT_ROOT/lib/core/base.sh"
# shellcheck source=lib/core/log_paths.sh
source "$PROJECT_ROOT/lib/core/log_paths.sh"

output_mode="text"
case "${1:-}" in
    "") ;;
    --null) output_mode="null" ;;
    --help | -h)
        printf 'Usage: %s [--null]\n' "${0##*/}"
        printf 'Inventory approved and malformed Mole operation-log roots. This command never deletes files.\n'
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        exit 2
        ;;
esac
[[ $# -le 1 ]] || {
    printf 'Unexpected argument: %s\n' "$2" >&2
    exit 2
}

emit_record() {
    local status="$1"
    local reason="$2"
    local path="$3"

    if [[ "$output_mode" == "null" ]]; then
        printf '%s\0%s\0%s\0' "$status" "$reason" "$path"
    else
        printf '%-8s %-24s %q\n' "$status" "$reason" "$path"
    fi
}

home=$(get_invoking_home)
[[ -n "$home" && "$home" == /* && "$home" != *[[:cntrl:]]* ]] || {
    printf 'Cannot inventory operation logs: invalid invoking home.\n' >&2
    exit 2
}
canonical_home=$(_mole_log_physical_dir "$home") || {
    printf 'Cannot inventory operation logs: invoking home is not a real directory.\n' >&2
    exit 2
}
[[ "$canonical_home" == "$home" ]] || {
    printf 'Cannot inventory operation logs: invoking home is not canonical.\n' >&2
    exit 2
}

logs_parent="$canonical_home/Library/Logs"
if [[ ! -e "$logs_parent" && ! -L "$logs_parent" ]]; then
    exit 0
fi
[[ -d "$logs_parent" && ! -L "$logs_parent" ]] || {
    emit_record "invalid" "untrusted-parent" "$logs_parent"
    exit 1
}
canonical_parent=$(_mole_log_physical_dir "$logs_parent") || {
    emit_record "invalid" "untrusted-parent" "$logs_parent"
    exit 1
}
[[ "$canonical_parent" == "$logs_parent" ]] || {
    emit_record "invalid" "untrusted-parent" "$logs_parent"
    exit 1
}

expected_uid=$(get_invoking_uid)
expected_device=$(_mole_log_stat_device "$canonical_home") || exit 2
parent_uid=$(_mole_log_stat_uid "$canonical_parent") || exit 2
parent_device=$(_mole_log_stat_device "$canonical_parent") || exit 2
if [[ "$parent_uid" != "$expected_uid" || "$parent_device" != "$expected_device" ]]; then
    emit_record "invalid" "untrusted-parent" "$logs_parent"
    exit 1
fi

approved_root=""
approved_root=$(mole_operation_log_root 2> /dev/null || true)

while IFS= read -r -d '' candidate; do
    name=${candidate##*/}
    is_candidate=false
    case "$name" in
        mole* | Mole* | \{* | \[* ) is_candidate=true ;;
    esac
    if [[ "$is_candidate" == "false" && -d "$candidate" ]] && \
        { [[ -e "$candidate/operations.log" || -L "$candidate/operations.log" ]] || \
            [[ -e "$candidate/deletions.log" || -L "$candidate/deletions.log" ]]; }; then
        is_candidate=true
    fi
    [[ "$is_candidate" == "true" ]] || continue

    if [[ -n "$approved_root" && "$candidate" == "$approved_root" ]]; then
        emit_record "approved" "configured-root" "$candidate"
        continue
    fi
    if [[ -L "$candidate" ]]; then
        emit_record "invalid" "symlink" "$candidate"
        continue
    fi
    if [[ ! -d "$candidate" ]]; then
        emit_record "invalid" "wrong-type" "$candidate"
        continue
    fi
    if [[ "$name" == *[[:cntrl:]]* ]]; then
        emit_record "invalid" "control-character" "$candidate"
        continue
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]]; then
        emit_record "invalid" "unsupported-characters" "$candidate"
        continue
    fi

    candidate_uid=$(_mole_log_stat_uid "$candidate" 2> /dev/null || true)
    if [[ "$candidate_uid" != "$expected_uid" ]]; then
        emit_record "invalid" "unexpected-owner" "$candidate"
        continue
    fi
    candidate_device=$(_mole_log_stat_device "$candidate" 2> /dev/null || true)
    if [[ "$candidate_device" != "$expected_device" ]]; then
        emit_record "invalid" "unexpected-volume" "$candidate"
        continue
    fi
    emit_record "invalid" "unapproved-root" "$candidate"
done < <(find -P "$canonical_parent" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
