#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-operation-logs.XXXXXX")"
    export HOME
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "$HOME/Library"
    mkdir -p "$HOME/Library/Logs"
}

@test "mo history uses one validated override root for both audit logs" {
    local log_root="$HOME/Library/Logs/mole review"
    mkdir -m 0700 "$log_root"
    cat > "$log_root/operations.log" <<'EOF'
# ========== clean session started at 2026-08-08 10:00:00 ==========
[2026-08-08 10:00:01] [clean] REMOVED /tmp/cache (2KB)
# ========== clean session ended at 2026-08-08 10:00:02, 1 items, 2KB ==========
EOF
    printf '2026-08-08T10:00:01+0000\tpermanent\t2\tok\t/tmp/cache\n' > "$log_root/deletions.log"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$log_root" "$PROJECT_ROOT/mole" history --json
    [ "$status" -eq 0 ]

    printf '%s\n' "$output" | EXPECTED_LOG_ROOT="$log_root" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
root = os.environ["EXPECTED_LOG_ROOT"]
assert data["logs"]["operations"] == root + "/operations.log"
assert data["logs"]["deletions"] == root + "/deletions.log"
assert data["sessions"][0]["command"] == "clean"
assert data["deletions"][0]["path"] == "/tmp/cache"
'
}

@test "operation and deletion writers consume the same override root" {
    local log_root="$HOME/Library/Logs/mole-test"
    local victim="$HOME/victim"
    mkdir -m 0700 "$log_root"
    : > "$victim"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$log_root" PROJECT_ROOT="$PROJECT_ROOT" \
        bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation "clean" "REMOVED" "/tmp/cache" "2KB"
mole_delete "$HOME/victim"
EOF
    [ "$status" -eq 0 ]
    [ ! -e "$victim" ]
    grep -Fq '[clean] REMOVED /tmp/cache (2KB)' "$log_root/operations.log"
    grep -Fq $'\tpermanent\t' "$log_root/deletions.log"
    [ ! -e "$HOME/Library/Logs/mole" ]
}

@test "logging creates only the canonical default root beneath the invoking home" {
    rm -rf "$HOME/Library"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
log_operation "clean" "REMOVED" "/tmp/cache" "2KB"
EOF
    [ "$status" -eq 0 ]
    [ -f "$HOME/Library/Logs/mole/mole.log" ]
    [ -f "$HOME/Library/Logs/mole/operations.log" ]
    [ -z "$(find "$HOME" -type d ! -path "$HOME" ! -path "$HOME/Library" ! -path "$HOME/Library/Logs" ! -path "$HOME/Library/Logs/mole" -print -quit)" ]
}

@test "an outside override is rejected without creating or deleting arbitrary paths" {
    local arbitrary_root="$HOME/Documents/arbitrary/history"
    local victim="$HOME/victim"
    : > "$victim"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$arbitrary_root" PROJECT_ROOT="$PROJECT_ROOT" \
        bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mole_delete "$HOME/victim"
EOF
    [ "$status" -ne 0 ]
    [ -e "$victim" ]
    [ ! -e "$HOME/Documents" ]
    [[ "$output" == *"outside"* ]]
}

@test "independent legacy file overrides are rejected in favor of one root" {
    local legacy_root="$HOME/Library/Logs/legacy"
    mkdir -m 0700 "$legacy_root"

    run env HOME="$HOME" MOLE_DELETE_LOG="$legacy_root/deletions.log" PROJECT_ROOT="$PROJECT_ROOT" \
        bash --noprofile --norc -c 'source "$PROJECT_ROOT/lib/core/common.sh"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"MOLE_OPLOG_PATH"* ]]
    [ ! -e "$legacy_root/deletions.log" ]

    run env HOME="$HOME" MOLE_OPERATIONS_LOG="$legacy_root/operations.log" "$PROJECT_ROOT/mole" history
    [ "$status" -ne 0 ]
    [[ "$output" == *"MOLE_OPLOG_PATH"* ]]
}

@test "history rejects relative JSON-shaped and control-character log roots" {
    local -a invalid_roots=(
        "relative/history"
        "$HOME/Library/Logs/{\"path\":\"mole\"}"
        "$HOME/Library/Logs/mole"$'\n'"forged"
        "$HOME/Library/Logs/mole"$'\t'"forged"
        "$HOME/Library/Logs/mole/"
        "$HOME/Library//Logs/mole"
    )
    local invalid_root

    for invalid_root in "${invalid_roots[@]}"; do
        run env HOME="$HOME" MOLE_OPLOG_PATH="$invalid_root" "$PROJECT_ROOT/mole" history
        [ "$status" -ne 0 ] || {
            printf 'accepted invalid root: %q\n' "$invalid_root" >&2
            return 1
        }
        [[ "$output" == *"Invalid operation log root"* ]] || return 1
    done
}

@test "history rejects non-directory and symlink log roots" {
    local real_root="$HOME/Library/Logs/real-mole"
    local link_root="$HOME/Library/Logs/link-mole"
    local file_root="$HOME/Library/Logs/file-mole"
    mkdir -m 0700 "$real_root"
    ln -s "$real_root" "$link_root"
    : > "$file_root"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$link_root" "$PROJECT_ROOT/mole" history
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a real directory"* ]]

    run env HOME="$HOME" MOLE_OPLOG_PATH="$file_root" "$PROJECT_ROOT/mole" history
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a real directory"* ]]
}

@test "support inventory reports malformed roots over NUL-delimited records without deleting them" {
    local approved_root="$HOME/Library/Logs/mole"
    local newline_root="$HOME/Library/Logs/"$'mole\nforged'
    local json_root="$HOME/Library/Logs/{\"root\":\"forged\"}"
    local link_root="$HOME/Library/Logs/mole-link"
    local outside="$HOME/outside"
    local inventory="$HOME/inventory.bin"

    mkdir -m 0700 "$approved_root" "$newline_root" "$json_root" "$outside"
    ln -s "$outside" "$link_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" INVENTORY="$inventory" \
        bash --noprofile --norc -c '"$PROJECT_ROOT/scripts/audit_operation_log_roots.sh" --null > "$INVENTORY"'
    [ "$status" -eq 0 ]

    APPROVED_ROOT="$approved_root" NEWLINE_ROOT="$newline_root" JSON_ROOT="$json_root" \
        LINK_ROOT="$link_root" INVENTORY="$inventory" python3 - <<'PY'
import os

with open(os.environ["INVENTORY"], "rb") as handle:
    fields = handle.read().split(b"\0")
assert fields[-1] == b""
records = [tuple(part.decode("utf-8") for part in fields[i:i + 3]) for i in range(0, len(fields) - 1, 3)]
by_path = {path: (status, reason) for status, reason, path in records}
assert by_path[os.environ["APPROVED_ROOT"]][0] == "approved"
assert by_path[os.environ["NEWLINE_ROOT"]][0] == "invalid"
assert by_path[os.environ["JSON_ROOT"]][0] == "invalid"
assert by_path[os.environ["LINK_ROOT"]][0] == "invalid"
PY

    [ -d "$newline_root" ]
    [ -d "$json_root" ]
    [ -L "$link_root" ]
    [ -d "$outside" ]
}

@test "writers refuse a log-root symlink replacement without creating files at its target" {
    local log_root="$HOME/Library/Logs/mole-test"
    local redirected="$HOME/redirected"
    mkdir -m 0700 "$log_root" "$redirected"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$log_root" PROJECT_ROOT="$PROJECT_ROOT" \
        REDIRECTED="$redirected" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rm -f "$MOLE_OPLOG_PATH/mole.log" "$MOLE_OPLOG_PATH/operations.log"
rmdir "$MOLE_OPLOG_PATH"
ln -s "$REDIRECTED" "$MOLE_OPLOG_PATH"
log_operation "clean" "REMOVED" "/tmp/cache" "2KB"
_mole_delete_log "permanent" "2" "ok" "/tmp/cache"
EOF
    [ "$status" -eq 0 ]
    [ -L "$log_root" ]
    [ -z "$(find "$redirected" -mindepth 1 -print -quit)" ]
    [[ "$output" == *"Invalid operation log root"* ]]
}

@test "resolver rejects roots with unexpected ownership or volume identity" {
    local log_root="$HOME/Library/Logs/mole-test"
    mkdir -m 0700 "$log_root"

    run env HOME="$HOME" MOLE_OPLOG_PATH="$log_root" PROJECT_ROOT="$PROJECT_ROOT" \
        TEST_ROOT="$log_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/log_paths.sh"
_mole_log_stat_uid() {
    [[ "$1" == "$TEST_ROOT" ]] && { printf '0\n'; return; }
    /usr/bin/stat -f '%u' "$1"
}
mole_operation_log_root_for_read
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected owner"* ]]

    run env HOME="$HOME" MOLE_OPLOG_PATH="$log_root" PROJECT_ROOT="$PROJECT_ROOT" \
        TEST_ROOT="$log_root" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/log_paths.sh"
_mole_log_stat_device() {
    [[ "$1" == "$TEST_ROOT" ]] && { printf '999999\n'; return; }
    /usr/bin/stat -f '%d' "$1"
}
mole_operation_log_root_for_read
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected volume"* ]]
}
