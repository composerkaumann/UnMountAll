import Foundation
import CoreFoundation

enum FinderRecentGhostError: LocalizedError {
    case invalidTarget
    case noLongerPresent
    case noLongerGhost
    case couldNotSave

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
        }
    }
}

enum FinderRecentGhostStore {
    static let targetPrefix = "finder-recent:"

    private static let finderDomain = "com.apple.finder"
    private static let recentFoldersKey = "FXRecentFolders"
    private static let supportedSchemes = [
        "smb", "cifs", "afp", "nfs", "http", "https", "webdav", "dav",
        "davs", "sftp", "ssh", "ftp"
    ]

    static func discover() -> [MountTarget] {
        recentEntries().compactMap { entry in
            guard let info = ghostInfo(for: entry) else { return nil }
            let identity = targetPrefix + info.bookmark.base64EncodedString()
            let protocolName = info.networkURL.scheme?.uppercased() ?? "Network"
            return MountTarget(
                id: identity,
                kind: .ghost,
                name: info.name,
                detail: "Finder recent \(protocolName) bookmark • \(info.networkURL.absoluteString)",
                target: identity
            )
        }
    }

    static func isFinderRecentGhost(_ target: MountTarget) -> Bool {
        target.kind == .ghost && target.target.hasPrefix(targetPrefix)
    }

    static func remove(_ target: MountTarget) throws {
        guard isFinderRecentGhost(target),
              let bookmark = Data(base64Encoded: String(target.target.dropFirst(targetPrefix.count))) else {
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
