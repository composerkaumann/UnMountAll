import Foundation
import CoreFoundation
@preconcurrency import CoreServices

enum FinderRecentGhostError: LocalizedError {
    case invalidTarget
    case noLongerPresent
    case noLongerGhost
    case couldNotSave
    case couldNotRemoveRecentServer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "This Finder ghost identifier is invalid."
        case .noLongerPresent:
            "This Finder entry is no longer present. Rescan to refresh the list."
        case .noLongerGhost:
            "This Finder entry is no longer a ghost and was not removed."
        case .couldNotSave:
            "Finder's recent-folder list could not be updated."
        case let .couldNotRemoveRecentServer(status):
            "Finder's recent-server ghost could not be removed (error \(status))."
        }
    }
}

enum FinderRecentGhostStore {
    static let targetPrefix = "finder-recent:"
    static let recentServerTargetPrefix = "finder-server:"

    private static let finderDomain = "com.apple.finder"
    private static let recentFoldersKey = "FXRecentFolders"
    private static let supportedSchemes = [
        "smb", "cifs", "afp", "nfs", "http", "https", "webdav", "dav",
        "davs", "sftp", "ssh", "ftp"
    ]

    static func discover(excludingMountedNames mountedNames: Set<String> = []) -> [MountTarget] {
        let excluded = Set(mountedNames.map { $0.lowercased() })
        var targets: [MountTarget] = []

        for server in staleRecentServers() where !excluded.contains(server.name.lowercased()) {
            let identity = recentServerTargetPrefix + String(server.id)
            targets.append(MountTarget(
                id: identity,
                kind: .ghost,
                name: server.name,
                detail: "LEFTOVER / GHOST — Finder Recent Servers record; not mounted; Unmount has no effect",
                target: identity
            ))
        }

        for entry in recentEntries() {
            guard let info = ghostInfo(for: entry) else { continue }
            guard !excluded.contains(info.name.lowercased()) else { continue }
            let identity = targetPrefix + info.bookmark.base64EncodedString()
            let protocolName = info.networkURL.scheme?.uppercased() ?? "Network"
            targets.removeAll { $0.name.caseInsensitiveCompare(info.name) == .orderedSame }
            targets.append(MountTarget(
                id: identity,
                kind: .ghost,
                name: info.name,
                detail: "LEFTOVER / GHOST — not mounted; Unmount has no effect • \(protocolName) • \(info.networkURL.absoluteString)",
                target: identity
            ))
        }
        return targets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func isFinderRecentGhost(_ target: MountTarget) -> Bool {
        target.kind == .ghost && (
            target.target.hasPrefix(targetPrefix) ||
            target.target.hasPrefix(recentServerTargetPrefix)
        )
    }

    static func remove(_ target: MountTarget) throws {
        guard isFinderRecentGhost(target) else {
            throw FinderRecentGhostError.invalidTarget
        }

        if target.target.hasPrefix(recentServerTargetPrefix) {
            guard let itemID = UInt32(target.target.dropFirst(recentServerTargetPrefix.count)) else {
                throw FinderRecentGhostError.invalidTarget
            }
            try removeStaleRecentServer(id: itemID, expectedName: target.name)
            removeRecentFolderGhosts(named: target.name)
            return
        }

        guard let bookmark = Data(base64Encoded: String(target.target.dropFirst(targetPrefix.count))) else {
            throw FinderRecentGhostError.invalidTarget
        }

        var entries = recentEntries()
        guard let index = entries.firstIndex(where: { entry in
            (entry["file-bookmark"] as? Data) == bookmark
        }) else {
            throw FinderRecentGhostError.noLongerPresent
        }
        guard ghostInfo(for: entries[index]) != nil else {
            throw FinderRecentGhostError.noLongerGhost
        }

        try removeStaleRecentServers(named: target.name)

        entries.remove(at: index)
        CFPreferencesSetValue(
            recentFoldersKey as CFString,
            entries as CFArray,
            finderDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            finderDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw FinderRecentGhostError.couldNotSave
        }

        let stillPresent = recentEntries().contains { entry in
            (entry["file-bookmark"] as? Data) == bookmark
        }
        if stillPresent {
            throw FinderRecentGhostError.couldNotSave
        }
    }

    private static func staleRecentServers() -> [(id: UInt32, name: String)] {
        guard let (list, snapshot) = recentServerSnapshot() else { return [] }
        _ = list
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        var result: [(UInt32, String)] = []

        for rawItem in snapshot {
            let item = rawItem as! LSSharedFileListItem
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            var resolutionError: Unmanaged<CFError>?
            if let resolved = LSSharedFileListItemCopyResolvedURL(item, flags, &resolutionError) {
                let url = resolved.takeRetainedValue() as URL
                if FileManager.default.fileExists(atPath: url.path) { continue }
            }
            if let resolutionError { _ = resolutionError.takeRetainedValue() }
            result.append((LSSharedFileListItemGetID(item), name))
        }
        return result
    }

    private static func removeStaleRecentServers(named name: String) throws {
        guard let (list, snapshot) = recentServerSnapshot() else {
            throw FinderRecentGhostError.couldNotSave
        }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

        for rawItem in snapshot {
            let item = rawItem as! LSSharedFileListItem
            let displayName = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            guard displayName == name, isUnresolved(item, flags: flags) else { continue }
            let status = LSSharedFileListItemRemove(list, item)
            guard status == noErr else {
                throw FinderRecentGhostError.couldNotRemoveRecentServer(status)
            }
        }
    }

    private static func removeStaleRecentServer(id: UInt32, expectedName: String) throws {
        guard let (list, snapshot) = recentServerSnapshot() else {
            throw FinderRecentGhostError.couldNotSave
        }
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

        for rawItem in snapshot {
            let item = rawItem as! LSSharedFileListItem
            guard LSSharedFileListItemGetID(item) == id else { continue }
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            guard name == expectedName, isUnresolved(item, flags: flags) else {
                throw FinderRecentGhostError.noLongerGhost
            }
            let status = LSSharedFileListItemRemove(list, item)
            guard status == noErr else {
                throw FinderRecentGhostError.couldNotRemoveRecentServer(status)
            }
            return
        }
        throw FinderRecentGhostError.noLongerPresent
    }

    private static func recentServerSnapshot() -> (LSSharedFileList, [AnyObject])? {
        let listType = kLSSharedFileListRecentServerItems.takeUnretainedValue()
        guard let unmanagedList = LSSharedFileListCreate(nil, listType, nil) else { return nil }
        let list = unmanagedList.takeRetainedValue()
        guard let unmanagedSnapshot = LSSharedFileListCopySnapshot(list, nil) else { return nil }
        let snapshot = unmanagedSnapshot.takeRetainedValue() as [AnyObject]
        return (list, snapshot)
    }

    private static func isUnresolved(
        _ item: LSSharedFileListItem,
        flags: UInt32
    ) -> Bool {
        var resolutionError: Unmanaged<CFError>?
        if let resolved = LSSharedFileListItemCopyResolvedURL(item, flags, &resolutionError) {
            _ = resolved.takeRetainedValue()
            return false
        }
        if let resolutionError { _ = resolutionError.takeRetainedValue() }
        return true
    }

    private static func removeRecentFolderGhosts(named name: String) {
        let filtered = recentEntries().filter { entry in
            guard let info = ghostInfo(for: entry) else { return true }
            return info.name != name
        }
        CFPreferencesSetValue(
            recentFoldersKey as CFString,
            filtered as CFArray,
            finderDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            finderDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private static func recentEntries() -> [[String: Any]] {
        CFPreferencesCopyValue(
            recentFoldersKey as CFString,
            finderDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [[String: Any]] ?? []
    }

    private static func ghostInfo(for entry: [String: Any]) -> GhostInfo? {
        guard let name = entry["name"] as? String,
              !name.isEmpty,
              let bookmark = entry["file-bookmark"] as? Data else { return nil }

        let urls = printableStrings(in: bookmark).compactMap(URL.init(string:))
        guard let networkURL = urls.first(where: { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return supportedSchemes.contains(scheme)
        }),
        let volumeURL = urls.first(where: { url in
            url.isFileURL && url.path.hasPrefix("/Volumes/")
        }),
        !FileManager.default.fileExists(atPath: volumeURL.path) else { return nil }

        return GhostInfo(name: name, bookmark: bookmark, networkURL: networkURL)
    }

    private static func printableStrings(in data: Data) -> [String] {
        var strings: [String] = []
        var current: [UInt8] = []

        func finishCurrent() {
            if current.count >= 4, let string = String(bytes: current, encoding: .utf8) {
                strings.append(string)
            }
            current.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if (32...126).contains(byte) {
                current.append(byte)
            } else {
                finishCurrent()
            }
        }
        finishCurrent()
        return strings
    }

    private struct GhostInfo {
        let name: String
        let bookmark: Data
        let networkURL: URL
    }
}
