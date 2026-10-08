import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case unmounting
        case forcing(String)
        case forcingAll

        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var targets: [MountTarget] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage = "Scanning mounted items…"
    @Published var forceConfirmation: MountTarget?
    @Published var forceAllConfirmation = false
    @Published var finderRefreshConfirmation = false

    var hasActiveConfirmation: Bool {
        forceConfirmation != nil || forceAllConfirmation || finderRefreshConfirmation
    }

    var windowActionsDisabled: Bool {
        phase.isBusy || hasActiveConfirmation
    }

    var hasNormalTargets: Bool {
        targets.contains { $0.failureMessage == nil }
    }

    var hasActionableFailures: Bool {
        targets.contains { $0.failureMessage != nil && !$0.isLeftMounted }
    }

    func scan() async {
        guard !windowActionsDisabled else { return }
        phase = .scanning
        statusMessage = "Scanning mounted items…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: ["--list-machine"])
            guard command.status == 0 else {
                targets = []
                statusMessage = command.error.nonEmpty ?? "Scanning failed."
                return
            }
            targets = MachineOutputParser.parse(command.output).compactMap {
                if case let .target(target) = $0 { target } else { nil }
            }
            statusMessage = targets.isEmpty
                ? "No supported mounted items found."
                : "Found \(targets.count) mounted \(targets.count == 1 ? "item" : "items")."
        } catch {
            targets = []
            statusMessage = error.localizedDescription
        }
    }

    func unmountAll() async {
        guard !windowActionsDisabled, !targets.isEmpty else { return }
        phase = .unmounting
        statusMessage = "Unmounting all items…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: ["--unmount-all-machine"])
            let results = MachineOutputParser.parse(command.output).compactMap {
                if case let .result(result) = $0 { result } else { nil }
            }
            let failures = results.filter { $0.state == .failure }.map(\.target)
            targets = failures

            if results.isEmpty, command.status != 0 {
                statusMessage = command.error.nonEmpty ?? "The unmount operation failed."
            } else if failures.isEmpty {
                statusMessage = results.isEmpty
                    ? "No supported mounted items found."
                    : "All \(results.count) items were unmounted successfully."
            } else {
                let successCount = results.count - failures.count
                statusMessage = "Unmounted \(successCount) of \(results.count). Choose Force or Leave Mounted for each remaining item."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func unmount(_ target: MountTarget) async {
        guard !windowActionsDisabled, target.failureMessage == nil else { return }
        phase = .unmounting
        statusMessage = "Unmounting \(target.name)…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: [
                "--unmount-machine", target.kind.rawValue, target.target
            ])
            guard let result = firstResult(from: command) else {
                statusMessage = command.error.nonEmpty ?? "The unmount operation failed."
                return
            }

            if result.state == .success {
                targets.removeAll { $0.id == target.id }
                statusMessage = "\(target.name) was unmounted successfully."
            } else {
                updateFailure(for: target.id, message: result.message)
                statusMessage = "Could not unmount \(target.name). Choose Force or Leave Mounted."
            }
        } catch {
            updateFailure(for: target.id, message: error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func requestForce(_ target: MountTarget) {
        guard !windowActionsDisabled else { return }
        forceConfirmation = target
    }

    func requestFinderRefresh() {
        guard !windowActionsDisabled else { return }
        finderRefreshConfirmation = true
    }

    func refreshFinderConfirmed() async {
        guard !phase.isBusy else { return }
        finderRefreshConfirmation = false
        phase = .scanning
        statusMessage = "Refreshing Finder…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: ["--refresh-finder"])
            if command.status == 0 {
                statusMessage = "Finder refreshed. Rescan to update mounted items."
            } else {
                statusMessage = command.error.nonEmpty ?? "Finder could not be refreshed."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func requestForceAll() {
        guard !windowActionsDisabled, hasActionableFailures else { return }
        forceAllConfirmation = true
    }

    func leaveMounted(_ target: MountTarget) {
        guard !windowActionsDisabled,
              let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
        targets[index].isLeftMounted = true
        targets[index].failureMessage = "Left mounted by user."
        statusMessage = "\(target.name) will remain mounted."
    }

    func forceConfirmed() async {
        guard let target = forceConfirmation, !phase.isBusy else { return }
        forceConfirmation = nil
        phase = .forcing(target.id)
        statusMessage = "Forcing \(target.name)…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: ["--force-machine", target.kind.rawValue, target.target])
            let result = firstResult(from: command)

            if result?.state == .success {
                targets.removeAll { $0.id == target.id }
                statusMessage = "\(target.name) was forcibly removed."
            } else {
                let message = result?.message ?? command.error.nonEmpty ?? "Force operation failed."
                if let index = targets.firstIndex(where: { $0.id == target.id }) {
                    targets[index].failureMessage = message
                }
                statusMessage = "Could not remove \(target.name)."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func forceAllConfirmed() async {
        guard !phase.isBusy else { return }
        let failures = targets.filter { $0.failureMessage != nil && !$0.isLeftMounted }
        guard !failures.isEmpty else { return }

        forceAllConfirmation = false
        phase = .forcingAll
        var successCount = 0

        for target in failures {
            statusMessage = "Forcing \(target.name)…"
            do {
                let command = try await ScriptRunner.run(arguments: [
                    "--force-machine", target.kind.rawValue, target.target
                ])
                if let result = firstResult(from: command), result.state == .success {
                    targets.removeAll { $0.id == target.id }
                    successCount += 1
                } else {
                    let message = firstResult(from: command)?.message
                        ?? command.error.nonEmpty
                        ?? "Force operation failed."
                    updateFailure(for: target.id, message: message)
                }
            } catch {
                updateFailure(for: target.id, message: error.localizedDescription)
            }
        }

        phase = .idle
        let failureCount = failures.count - successCount
        statusMessage = failureCount == 0
            ? "All \(successCount) remaining items were forcibly removed."
            : "Forcibly removed \(successCount) of \(failures.count); \(failureCount) still failed."
    }

    func shortcutNumber(for target: MountTarget) -> Int? {
        guard let index = targets.firstIndex(where: { $0.id == target.id }), index < 9 else {
            return nil
        }
        return index + 1
    }

    func targetForShortcut(_ number: Int) -> MountTarget? {
        guard (1...9).contains(number), targets.indices.contains(number - 1) else { return nil }
        let target = targets[number - 1]
        return target.isLeftMounted ? nil : target
    }

    private func firstResult(from command: CommandResult) -> ActionResult? {
        MachineOutputParser.parse(command.output).compactMap {
            if case let .result(result) = $0 { result } else { nil }
        }.first
    }

    private func updateFailure(for id: String, message: String) {
        if let index = targets.firstIndex(where: { $0.id == id }) {
            targets[index].failureMessage = message
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
