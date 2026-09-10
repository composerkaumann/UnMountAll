#!/bin/bash

# Safely eject mounted external disks, detach mounted disk images, and
# unmount supported network shares on macOS.

set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

readonly DISKUTIL="/usr/sbin/diskutil"
readonly HDIUTIL="/usr/bin/hdiutil"
readonly PLUTIL="/usr/bin/plutil"
readonly MOUNT="/sbin/mount"
readonly BASE64="/usr/bin/base64"
readonly KILLALL="/usr/bin/killall"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/unmount-all.XXXXXX")" || exit 1
trap '/bin/rm -rf "$WORK_DIR"' EXIT HUP INT TERM

encode() {
    /usr/bin/printf '%s' "$1" | "$BASE64" | /usr/bin/tr -d '\n'
}

decode() {
    /usr/bin/printf '%s' "$1" | "$BASE64" -D
}

plist_value() {
    local plist="$1"
    local key_path="$2"
    "$PLUTIL" -extract "$key_path" raw -o - "$plist" 2>/dev/null
}

target_id() {
    local kind="$1"
    local target="$2"
    /usr/bin/printf '%s:%s' "$kind" "$(encode "$target")"
}

emit_target() {
    local kind="$1"
    local name="$2"
    local detail="$3"
    local target="$4"
    /usr/bin/printf 'target\t%s\t%s\t%s\t%s\t%s\n' \
        "$(target_id "$kind" "$target")" \
        "$kind" \
        "$(encode "$name")" \
        "$(encode "$detail")" \
        "$(encode "$target")"
}

emit_result() {
    local id="$1"
    local kind="$2"
    local state="$3"
    local name="$4"
    local detail="$5"
    local message="$6"
    local target="$7"
    /usr/bin/printf 'result\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" \
        "$kind" \
        "$state" \
        "$(encode "$name")" \
        "$(encode "$detail")" \
        "$(encode "$message")" \
        "$(encode "$target")"
}

split_mount_line() {
    local line="$1"
    MOUNT_OPTIONS="${line##* (}"
    MOUNT_OPTIONS="${MOUNT_OPTIONS%)}"
    MOUNT_TYPE="${MOUNT_OPTIONS%%,*}"
    local prefix="${line% (*}"
    MOUNT_SOURCE="${prefix%% on *}"
    MOUNT_POINT="${prefix#* on }"
}

append_unique() {
    local current="$1"
    local addition="$2"
    if [ -z "$current" ]; then
        /usr/bin/printf '%s' "$addition"
    elif ! /usr/bin/printf '%s\n' "$current" | /usr/bin/grep -Fqx "$addition"; then
        /usr/bin/printf '%s, %s' "$current" "$addition"
    else
        /usr/bin/printf '%s' "$current"
    fi
}

format_size() {
    local bytes="$1"
    /usr/bin/awk -v bytes="$bytes" 'BEGIN {
        if (bytes >= 1000000000000) printf "%.1f TB", bytes / 1000000000000;
        else if (bytes >= 1000000000) printf "%.1f GB", bytes / 1000000000;
        else if (bytes >= 1000000) printf "%.1f MB", bytes / 1000000;
        else printf "%d bytes", bytes;
    }'
}

discover_physical_disks() {
    local physical_list="$WORK_DIR/physical-list.txt"
    local mounts_file="$1"

    if ! "$DISKUTIL" list external physical >"$physical_list" 2>/dev/null; then
        return
    fi

    /usr/bin/awk '/^\/dev\/disk[0-9]+ \(external, physical\):$/ {
        sub("^/dev/", "", $1); print $1
    }' "$physical_list" | while IFS= read -r disk; do
        [ -n "$disk" ] || continue

        local disk_info="$WORK_DIR/${disk}.plist"
        "$DISKUTIL" info -plist "$disk" >"$disk_info" 2>/dev/null || continue

        local disk_tree media_name bus size mounted_names line
        disk_tree="$(plist_value "$disk_info" DeviceTreePath || true)"
        media_name="$(plist_value "$disk_info" MediaName || true)"
        bus="$(plist_value "$disk_info" BusProtocol || true)"
        size="$(plist_value "$disk_info" TotalSize || true)"
        mounted_names=""

        while IFS= read -r line; do
            split_mount_line "$line"
            case "$MOUNT_SOURCE" in
                /dev/disk*) ;;
                *) continue ;;
            esac

            local volume_device volume_info volume_tree volume_name
            volume_device="${MOUNT_SOURCE#/dev/}"
            volume_info="$WORK_DIR/${disk}-${volume_device}.plist"
            "$DISKUTIL" info -plist "$MOUNT_SOURCE" >"$volume_info" 2>/dev/null || continue
            volume_tree="$(plist_value "$volume_info" DeviceTreePath || true)"

            if [[ "$volume_device" == "$disk"s* ]] || \
               { [ -n "$disk_tree" ] && [ "$disk_tree" = "$volume_tree" ]; }; then
                volume_name="$(plist_value "$volume_info" VolumeName || true)"
                [ -n "$volume_name" ] || volume_name="${MOUNT_POINT##*/}"
                mounted_names="$(append_unique "$mounted_names" "$volume_name")"
            fi
        done <"$mounts_file"

        [ -n "$mounted_names" ] || continue
        [ -n "$media_name" ] || media_name="$mounted_names"
        [ -n "$bus" ] || bus="External"

        local detail="$bus"
        if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
            detail="$detail • $(format_size "$size")"
        fi
        detail="$detail • $mounted_names"
        emit_target physical "$media_name" "$detail" "$disk"
    done
}

discover_disk_images() {
    local image_info="$WORK_DIR/images.plist"
    "$HDIUTIL" info -plist >"$image_info" 2>/dev/null || return

    local image_index=0
    while :; do
        local image_path
        image_path="$(plist_value "$image_info" "images.${image_index}.image-path" || true)"

        # An image can exist without image-path (for example a RAM image), so
        # use the first entity as the end-of-array check as well.
        local first_device
        first_device="$(plist_value "$image_info" "images.${image_index}.system-entities.0.dev-entry" || true)"
        if [ -z "$image_path" ] && [ -z "$first_device" ]; then
            break
        fi

        local entity_index=0
        local target_device=""
        local mount_points=""
        while :; do
            local device mount_point
            device="$(plist_value "$image_info" "images.${image_index}.system-entities.${entity_index}.dev-entry" || true)"
            mount_point="$(plist_value "$image_info" "images.${image_index}.system-entities.${entity_index}.mount-point" || true)"
            if [ -z "$device" ] && [ -z "$mount_point" ]; then
                break
            fi
            [ -n "$target_device" ] || target_device="$device"
            if [ -n "$mount_point" ]; then
                mount_points="$(append_unique "$mount_points" "$mount_point")"
            fi
            entity_index=$((entity_index + 1))
        done

        if [ -n "$mount_points" ] && [ -n "$target_device" ]; then
            local name
            if [ -n "$image_path" ]; then
                name="${image_path##*/}"
            else
                name="${mount_points##*/}"
            fi
            emit_target image "$name" "Disk image • $mount_points" "$target_device"
        fi
        image_index=$((image_index + 1))
    done
}

network_protocol() {
    local fs_type
    fs_type="$(/usr/bin/printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    local source
    source="$(/usr/bin/printf '%s' "$2" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    case "$fs_type" in
        smbfs|cifs) /usr/bin/printf 'SMB/CIFS'; return 0 ;;
        afpfs) /usr/bin/printf 'AFP'; return 0 ;;
        nfs|nfs4) /usr/bin/printf 'NFS'; return 0 ;;
        webdav|webdavfs) /usr/bin/printf 'WebDAV'; return 0 ;;
        9p|virtiofs|prl_fs|prlfs|hgfs|vboxsf) /usr/bin/printf 'VM Host Share'; return 0 ;;
        sshfs|sftpfs) /usr/bin/printf 'SFTP'; return 0 ;;
        ftpfs|curlftpfs) /usr/bin/printf 'FTP'; return 0 ;;
    esac

    case "$source" in
        http://*|https://*) /usr/bin/printf 'WebDAV'; return 0 ;;
        sftp://*|sshfs\#*|sftp\#*) /usr/bin/printf 'SFTP'; return 0 ;;
        ftp://*) /usr/bin/printf 'FTP'; return 0 ;;
    esac

    case "$fs_type" in
        macfuse|osxfuse|fusefs|fuse)
            case "$source" in
                *sshfs*|*sftp*|*@*:*) /usr/bin/printf 'SFTP'; return 0 ;;
                *ftp*) /usr/bin/printf 'FTP'; return 0 ;;
            esac
            /usr/bin/printf 'FUSE'
            return 0
            ;;
        fuse*) /usr/bin/printf 'FUSE'; return 0 ;;
    esac
    return 1
}

discover_network_mounts() {
    local mounts_file="$1"
    local line
    while IFS= read -r line; do
        split_mount_line "$line"
        local protocol
        case "$MOUNT_POINT" in
            *"/Library/Application Support/Mountain Duck/Volumes.noindex/"*)
                local underlying_protocol
                underlying_protocol="$(network_protocol "$MOUNT_TYPE" "$MOUNT_SOURCE" || true)"
                [ -n "$underlying_protocol" ] || underlying_protocol="$MOUNT_TYPE"
                protocol="Mountain Duck / $underlying_protocol"
                ;;
            *)
                protocol="$(network_protocol "$MOUNT_TYPE" "$MOUNT_SOURCE" || true)"
                ;;
        esac
        [ -n "$protocol" ] || continue

        local name="${MOUNT_POINT##*/}"
        name="${name%.localized}"
        [ -n "$name" ] || name="$MOUNT_POINT"
        emit_target network "$name" "$protocol • $MOUNT_SOURCE" "$MOUNT_POINT"
    done <"$mounts_file"
}

discover() {
    local mounts_file="$WORK_DIR/mounts.txt"
    "$MOUNT" >"$mounts_file" 2>/dev/null || return 1
    discover_physical_disks "$mounts_file"
    discover_disk_images
    discover_network_mounts "$mounts_file"
}

action_description() {
    local kind="$1"
    local target="$2"
    local force="$3"
    case "$kind:$force" in
        physical:false) /usr/bin/printf 'diskutil eject %s' "$target" ;;
        physical:true) /usr/bin/printf 'diskutil eject force %s' "$target" ;;
        image:false) /usr/bin/printf 'hdiutil detach %s' "$target" ;;
        image:true) /usr/bin/printf 'hdiutil detach %s -force' "$target" ;;
        network:false) /usr/bin/printf 'diskutil unmount %s' "$target" ;;
        network:true) /usr/bin/printf 'diskutil unmount force %s' "$target" ;;
        *) /usr/bin/printf 'unsupported action' ;;
    esac
}

run_action() {
    local kind="$1"
    local target="$2"
    local force="$3"
    case "$kind:$force" in
        physical:false) "$DISKUTIL" eject "$target" ;;
        physical:true) "$DISKUTIL" eject force "$target" ;;
        image:false) "$HDIUTIL" detach "$target" ;;
        image:true) "$HDIUTIL" detach "$target" -force ;;
        network:false) "$DISKUTIL" unmount "$target" ;;
        network:true) "$DISKUTIL" unmount force "$target" ;;
        *) /usr/bin/printf 'Unsupported target type: %s\n' "$kind" >&2; return 64 ;;
    esac
}

perform_one() {
    local id="$1"
    local kind="$2"
    local name="$3"
    local detail="$4"
    local target="$5"
    local force="$6"
    local dry_run="$7"

    if [ "$dry_run" = true ]; then
        emit_result "$id" "$kind" dry-run "$name" "$detail" \
            "Would run: $(action_description "$kind" "$target" "$force")" "$target"
        return
    fi

    local output status
    output="$(run_action "$kind" "$target" "$force" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
        [ -n "$output" ] || output="Unmounted successfully."
        emit_result "$id" "$kind" success "$name" "$detail" "$output" "$target"
    else
        [ -n "$output" ] || output="The unmount command failed with status $status."
        emit_result "$id" "$kind" failure "$name" "$detail" "$output" "$target"
    fi
}

perform_all() {
    local force="$1"
    local dry_run="$2"
    local targets_file="$WORK_DIR/targets.tsv"
    discover >"$targets_file" || return 1

    local record id kind name64 detail64 target64
    while IFS=$'\t' read -r record id kind name64 detail64 target64; do
        [ "$record" = target ] || continue
        perform_one "$id" "$kind" "$(decode "$name64")" "$(decode "$detail64")" \
            "$(decode "$target64")" "$force" "$dry_run"
    done <"$targets_file"
}

perform_target() {
    local kind="$1"
    local target="$2"
    local force="$3"
    local targets_file="$WORK_DIR/force-targets.tsv"
    discover >"$targets_file" || return 1

    local record id found_kind name64 detail64 target64 decoded_target
    while IFS=$'\t' read -r record id found_kind name64 detail64 target64; do
        [ "$record" = target ] || continue
        decoded_target="$(decode "$target64")"
        if [ "$found_kind" = "$kind" ] && [ "$decoded_target" = "$target" ]; then
            perform_one "$id" "$found_kind" "$(decode "$name64")" "$(decode "$detail64")" \
                "$decoded_target" "$force" false
            return
        fi
    done <"$targets_file"

    emit_result "$(target_id "$kind" "$target")" "$kind" failure "$target" "" \
        "The target is no longer mounted or is not an allowed target." "$target"
}

print_human() {
    local record id kind state_or_name name_or_detail detail_or_target message64 target64
    while IFS=$'\t' read -r record id kind state_or_name name_or_detail detail_or_target message64 target64; do
        if [ "$record" = target ]; then
            /usr/bin/printf '%-9s  %s\n           %s\n' \
                "$kind" "$(decode "$state_or_name")" "$(decode "$name_or_detail")"
        elif [ "$record" = result ]; then
            /usr/bin/printf '%-9s  %-8s  %s\n           %s\n' \
                "$kind" "$state_or_name" "$(decode "$name_or_detail")" "$(decode "$message64")"
        fi
    done
}

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  unmount-all.sh --list' \
        '  unmount-all.sh --dry-run' \
        '  unmount-all.sh --unmount-all' \
        '  unmount-all.sh --unmount TYPE TARGET' \
        '  unmount-all.sh --force TYPE TARGET' \
        '  unmount-all.sh --refresh-finder' \
        '' \
        'TYPE is physical, image, or network.'
}

refresh_finder() {
    if "$KILLALL" Finder; then
        /usr/bin/printf 'Finder is refreshing.\n'
    else
        /usr/bin/printf 'Finder could not be refreshed.\n' >&2
        return 1
    fi
}

case "${1:-}" in
    --list)
        discover | print_human
        ;;
    --list-machine)
        discover
        ;;
    --dry-run)
        perform_all false true | print_human
        ;;
    --unmount-all)
        perform_all false false | print_human
        ;;
    --unmount-all-machine)
        perform_all false false
        ;;
    --unmount)
        [ "$#" -eq 3 ] || { usage >&2; exit 64; }
        perform_target "$2" "$3" false | print_human
        ;;
    --unmount-machine)
        [ "$#" -eq 3 ] || { usage >&2; exit 64; }
        perform_target "$2" "$3" false
        ;;
    --force)
        [ "$#" -eq 3 ] || { usage >&2; exit 64; }
        perform_target "$2" "$3" true | print_human
        ;;
    --force-machine)
        [ "$#" -eq 3 ] || { usage >&2; exit 64; }
        perform_target "$2" "$3" true
        ;;
    --refresh-finder)
        refresh_finder
        ;;
    --help|-h|'')
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
