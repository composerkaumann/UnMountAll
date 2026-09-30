# UMA

`UMA` safely handles these mounted items on Apple silicon Macs running
macOS 26 or later:

- external physical disks, including USB, Thunderbolt, and memory cards;
- mounted disk images;
- AFP, SMB/CIFS, NFS/NFS4, WebDAV, SFTP, and FTP network shares;
- Mountain Duck cloud mounts, regardless of their underlying protocol;
- FUSE/macFUSE/osxfuse mounts;
- virtual-machine host shares using 9P, VirtioFS, Parallels, VMware, or
  VirtualBox filesystem types.

UMA intentionally lists only real, currently mounted filesystems. It does not
classify Finder history, bookmarks, sidebar entries, or empty `/Volumes`
directories as mounts and never offers to delete them. **Refresh Finder**
restarts Finder to clear stale display entries without altering files or mounts.

The first pass always uses a normal eject or unmount and continues
even when an individual operation fails. Only failed items remain in one list.
Each failed item gets its own **Force Eject** or **Force Unmount** button and a
**Leave Mounted** button. Force actions include a confirmation warning.

Each mounted item also has its own **Unmount** button. The first nine visible
rows use keyboard shortcuts **1–9** from either the number row or numeric
keypad. **Return** and numeric-keypad **Enter** activate **Unmount All**. After
a bulk unmount leaves only failures, the same keys activate each row's force
action and **Return/Enter** activates **Force All**.
Press **R** to rescan at any time when no unmount operation or confirmation is
in progress.

All window actions are mirrored in the native macOS **Actions** menu. The menu
uses the same enabled states, confirmation dialogs, Return/R/1–9 shortcuts, and
per-item Unmount, Force, and Leave Mounted actions as the window.

## Shell script

Make the scripts executable once:

```sh
chmod +x "uma.sh" "package_app.sh"
```

Safe inspection commands:

```sh
./uma.sh --list
./uma.sh --dry-run
```

Unmount everything supported:

```sh
./uma.sh --unmount-all
```

Force is intentionally limited to a target that the script can rediscover as
an allowed, currently mounted item:

```sh
./uma.sh --force physical disk4
./uma.sh --force image /dev/disk6
./uma.sh --force network "/Volumes/Share Name"
```

Install the standalone script for the current user (no administrator access
required):

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 uma.sh "$HOME/.local/bin/uma.sh"
```

With `$HOME/.local/bin` on your shell's `PATH`, run `uma.sh --help`,
`uma.sh --list`, or `uma.sh --unmount-all` from any directory. Running
`uma.sh` without arguments shows help. Repeat the install command after
updating the project to update the installed copy. The app uses its own
bundled `uma.sh` and does not depend on the command-line installation.

## SwiftUI app

Open `UMA.xcodeproj` in Xcode to build and run the same native app from the
shared Swift sources. The project includes the shell helper and app icon as
bundle resources, targets Apple silicon, and uses `Config/Version.xcconfig` for
the same version and build numbers as the packaging script.

Build the native arm64 app:

```sh
./package_app.sh
```

The result is `dist/UMA.app`. It is ad-hoc signed for local use and has
a minimum system version of macOS 26.0. The app is not sandboxed because it
must inspect and unmount system volumes through Apple's command-line tools.
Each successful packaging run increments the existing app's patch version:
`1.0.1`, `1.0.2`, and so on. The app uses the project artwork in
`Assets/AppIconSource.png` to generate a complete macOS `.icns` icon.
The last successful version and build number are persisted in `VERSION` and
`BUILD_NUMBER`, so removing or moving the previous app cannot reset the count.

## Safety model

- Internal disks and the startup volume are never targets.
- Physical devices must be reported by `diskutil` as external and physical.
- Only physical devices with at least one mounted descendant are shown.
- Disk images must have a mounted system entity reported by `hdiutil`.
- CoreSimulator runtime disk images are excluded from discovery.
- Internal local filesystems, Time Machine snapshots, and automount entries
  are ignored.
- Force actions are never automatic.
