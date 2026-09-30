#!/bin/bash
# Exercise the CLI using fake discovery/actions; never touch real mounts.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(/usr/bin/sed '/^case "${1:-}" in/,$d' "$ROOT_DIR/uma.sh")"

discover() {
    local number
    for ((number=1; number<=FIXTURE_COUNT; number++)); do
        [ ! -f "$FIXTURE_DIR/removed-$number" ] || continue
        emit_target physical "Test $number" "Fixture disk" "disk$number"
    done
}

run_action() {
    local number="${2#disk}"
    /usr/bin/printf '%s:%s\n' "$2" "$3" >>"$FIXTURE_DIR/actions"
    if [ "$number" = 1 ] && [ "$3" = false ]; then
        /usr/bin/printf 'Resource busy\n'
        return 1
    fi
    : >"$FIXTURE_DIR/removed-$number"
    /usr/bin/printf 'Ejected successfully\n'
}

check_menu() {
    local name="$1" input="$2" expected="$3"
    FIXTURE_DIR="$WORK_DIR/$name"
    /bin/mkdir -p "$FIXTURE_DIR"
    : >"$FIXTURE_DIR/actions"
    if ! /usr/bin/printf '%b' "$input" | interactive_menu >"$FIXTURE_DIR/output"; then
        /usr/bin/printf 'FAIL: %s\n' "$name" >&2
        exit 1
    fi
    /usr/bin/printf '%b' "$expected" >"$FIXTURE_DIR/expected"
    /usr/bin/cmp "$FIXTURE_DIR/actions" "$FIXTURE_DIR/expected"
    /usr/bin/printf 'PASS: %s\n' "$name"
}

FIXTURE_COUNT=3
check_menu invalid-and-duplicate '1,99\n2,2\nq\n' 'disk2:false\n'
check_menu all-continues-after-failure '0\nq\n' 'disk1:false\ndisk2:false\ndisk3:false\n'
/usr/bin/grep -Fq '[FORCE]' "$FIXTURE_DIR/output"
check_menu force-cancel-and-confirm '1\nr\n1\nn\n1\ny\nq\n' 'disk1:false\ndisk1:true\n'
check_menu mixed-normal-and-force '1\n1,2\ny\nq\n' 'disk1:false\ndisk1:true\ndisk2:false\n'
check_menu quit 'q\n' ''
check_menu eof '' ''
FIXTURE_COUNT=12
check_menu multiple-digit-choices '12,10\nq\n' 'disk12:false\ndisk10:false\n'
FIXTURE_COUNT=0
check_menu empty-list '0\nr\nq\n' ''
/usr/bin/grep -Fq 'NOTHING MOUNTED' "$FIXTURE_DIR/output"
