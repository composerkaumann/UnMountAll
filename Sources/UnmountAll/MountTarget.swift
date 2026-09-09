import Foundation

enum MountKind: String, Sendable {
    case physical
    case image
    case network
    case ghost

    var title: String {
        switch self {
        case .physical: "External Disk"
        case .image: "Disk Image"
        case .network: "Network Share"
        case .ghost: "Finder Ghost"
        }
    }

    var symbol: String {
        switch self {
        case .physical: "externaldrive.fill"
        case .image: "opticaldiscdrive.fill"
        case .network: "network"
        case .ghost: "eye.slash"
        }
    }

    var forceButtonTitle: String {
        switch self {
        case .physical, .image: "Force Eject"
        case .network: "Force Unmount"
        case .ghost: "Remove Empty Ghost"
        }
    }
}

struct MountTarget: Identifiable, Sendable, Equatable {
    let id: String
    let kind: MountKind
    let name: String
    let detail: String
    let target: String
    var failureMessage: String?
    var isLeftMounted = false
}

enum ActionState: String, Sendable {
    case success
    case failure
    case dryRun = "dry-run"
}

struct ActionResult: Sendable {
    let target: MountTarget
    let state: ActionState
    let message: String
}

enum MachineRecord {
    case target(MountTarget)
    case result(ActionResult)
}

enum MachineOutputParser {
    static func parse(_ text: String) -> [MachineRecord] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let recordType = fields.first else { return nil }

            if recordType == "target", fields.count == 6,
               let kind = MountKind(rawValue: fields[2]),
               let name = decode(fields[3]),
               let detail = decode(fields[4]),
               let target = decode(fields[5]) {
                return .target(MountTarget(
                    id: fields[1],
                    kind: kind,
                    name: name,
                    detail: detail,
                    target: target
                ))
            }

            if recordType == "result", fields.count == 8,
               let kind = MountKind(rawValue: fields[2]),
               let state = ActionState(rawValue: fields[3]),
               let name = decode(fields[4]),
               let detail = decode(fields[5]),
               let message = decode(fields[6]),
               let target = decode(fields[7]) {
                return .result(ActionResult(
                    target: MountTarget(
                        id: fields[1],
                        kind: kind,
                        name: name,
                        detail: detail,
                        target: target,
                        failureMessage: state == .failure ? message : nil
                    ),
                    state: state,
                    message: message
                ))
            }
            return nil
        }
    }

    private static func decode(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
