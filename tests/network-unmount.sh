#!/bin/bash
# Exercise actual network dispatch with simulated macOS commands only.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(/usr/bin/sed \
    -e '/^case "${1:-}" in/,$d' \
    -e 's@^readonly DISKUTIL=.*@readonly DISKUTIL="mock_diskutil"@' \
    -e 's@^readonly MOUNT=.*@readonly MOUNT="mock_mount"@' \
    -e 's@^readonly UMOUNT=.*@readonly UMOUNT="mock_umount"@' \
    "$ROOT_DIR/uma.sh")"

mock_mount() {
    /bin/cat "$WORK_DIR/mount-state"
}

mock_diskutil() {
    /usr/bin/printf 'diskutil %s\n' "$*" >>"$WORK_DIR/calls"
    case "$MODE" in
        diskutil-success|diskutil-error-removed) : >"$WORK_DIR/mount-state" ;;
        changed) /usr/bin/printf '//user@server/different on /Volumes/Test Share (smbfs, nodev)\n' >"$WORK_DIR/mount-state" ;;
    esac
    case "$MODE" in
        diskutil-success|diskutil-false-success) return 0 ;;
        *) /usr/bin/printf 'Could not find disk\n' >&2; return 1 ;;
    esac
}

mock_umount() {
    /usr/bin/printf 'umount %s\n' "$*" >>"$WORK_DIR/calls"
    case "$MODE" in
        busy) /usr/bin/printf 'Resource busy\n' >&2; return 1 ;;
        still-mounted) return 0 ;;
        *) : >"$WORK_DIR/mount-state"; return 0 ;;
    esac
}

check() {
    MODE="$1"
    local force="$2" expected_status="$3" expected_calls="$4" actual_status=0
    /usr/bin/printf '//user@server/share on /Volumes/Test Share (smbfs, nodev)\n' >"$WORK_DIR/mount-state"
    : >"$WORK_DIR/calls"
    run_action network '/Volumes/Test Share' "$force" >"$WORK_DIR/output" 2>&1 || actual_status=$?
    [ "$actual_status" -eq "$expected_status" ]
    /usr/bin/printf '%b' "$expected_calls" >"$WORK_DIR/expected"
    /usr/bin/cmp "$WORK_DIR/calls" "$WORK_DIR/expected"
    /usr/bin/printf 'PASS: %s (force=%s)\n' "$MODE" "$force"
}

check fallback false 0 'diskutil unmount /Volumes/Test Share\numount /Volumes/Test Share\n'
check fallback true 0 'diskutil unmount force /Volumes/Test Share\numount -f /Volumes/Test Share\n'
check diskutil-success false 0 'diskutil unmount /Volumes/Test Share\n'
check diskutil-error-removed false 0 'diskutil unmount /Volumes/Test Share\n'
check diskutil-false-success false 0 'diskutil unmount /Volumes/Test Share\numount /Volumes/Test Share\n'
check busy true 1 'diskutil unmount force /Volumes/Test Share\numount -f /Volumes/Test Share\n'
/usr/bin/grep -Fq 'Resource busy' "$WORK_DIR/output"
check busy false 1 'diskutil unmount /Volumes/Test Share\numount /Volumes/Test Share\n'
check still-mounted true 1 'diskutil unmount force /Volumes/Test Share\numount -f /Volumes/Test Share\n'
check changed true 1 'diskutil unmount force /Volumes/Test Share\n'

discover() {
    emit_target network 'Test Share' 'SMB fixture' '/Volumes/Test Share'
}
MODE=busy
: >"$WORK_DIR/calls"
auto_unmount >"$WORK_DIR/output" 2>&1
[ ! -s "$WORK_DIR/output" ]
/usr/bin/printf 'diskutil unmount /Volumes/Test Share\numount /Volumes/Test Share\n' >"$WORK_DIR/expected"
/usr/bin/cmp "$WORK_DIR/calls" "$WORK_DIR/expected"
/usr/bin/printf 'PASS: auto mode keeps network fallback silent and non-force\n'
