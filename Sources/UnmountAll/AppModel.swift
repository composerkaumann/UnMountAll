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
    @Published var ghostRemovalConfirmation: MountTarget?
    @Published var finderRefreshConfirmation = false

    var hasNormalTargets: Bool {
        targets.contains { $0.kind != .ghost && $0.failureMessage == nil }
    }

    var hasActionableFailures: Bool {
        targets.contains { $0.kind != .ghost && $0.failureMessage != nil && !$0.isLeftMounted }
    }

    func scan() async {
        guard !phase.isBusy else { return }
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
            let mountedTargets = MachineOutputParser.parse(command.output).compactMap {
                if case let .target(target) = $0 { target } else { nil }
            }
            targets = mountedTargets + FinderRecentGhostStore.discover()
            statusMessage = targets.isEmpty
                ? "No supported mounted items found."
                : "Found \(targets.count) supported \(targets.count == 1 ? "item" : "items")."
        } catch {
            targets = []
            statusMessage = error.localizedDescription
        }
    }

    func unmountAll() async {
        guard !phase.isBusy, !targets.isEmpty else { return }
        phase = .unmounting
        statusMessage = "Unmounting all items…"
        defer { phase = .idle }

        do {
            let command = try await ScriptRunner.run(arguments: ["--unmount-all-machine"])
            let results = MachineOutputParser.parse(command.output).compactMap {
                if case let .result(result) = $0 { result } else { nil }
            }
            let failures = results.filter { $0.state == .failure }.map(\.target)
            let ghosts = targets.filter { $0.kind == .ghost }
            targets = failures + ghosts

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
        guard !phase.isBusy, target.failureMessage == nil else { return }
        phase = .unmounting
        statusMessage = target.kind == .ghost
            ? "Removing empty Finder ghost \(target.name)…"
            : "Unmounting \(target.name)…"
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
                statusMessage = target.kind == .ghost
                    ? "Empty Finder ghost \(target.name) was removed."
                    : "\(target.name) was unmounted successfully."
            } else {
                updateFailure(for: target.id, message: result.message)
                statusMessage = target.kind == .ghost
                    ? "Could not remove empty Finder ghost \(target.name)."
                    : "Could not unmount \(target.name). Choose Force or Leave Mounted."
            }
        } catch {
            updateFailure(for: target.id, message: error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func requestForce(_ target: MountTarget) {
        guard target.kind != .ghost else { return }
        forceConfirmation = target
    }

    func requestGhostRemoval(_ target: MountTarget) {
        guard target.kind == .ghost, !phase.isBusy else { return }
        ghostRemovalConfirmation = target
    }

    func removeGhostConfirmed() async {
        guard let target = ghostRemovalConfirmation else { return }
        ghostRemovalConfirmation = nil
        if FinderRecentGhostStore.isFinderRecentGhost(target) {
            await removeFinderRecentGhost(target)
            return
        }
        await unmount(target)
    }

    private func removeFinderRecentGhost(_ target: MountTarget) async {
        guard !phase.isBusy else { return }
        phase = .unmounting
        statusMessage = "Removing Finder bookmark ghost \(target.name)…"
        defer { phase = .idle }

        do {
            try FinderRecentGhostStore.remove(target)
            let refresh = try await ScriptRunner.run(arguments: ["--refresh-finder"])
            guard refresh.status == 0 else {
                targets.removeAll { $0.id == target.id }
                statusMessage = "The Finder entry was removed, but Finder could not be refreshed."
                return
            }
            targets.removeAll { $0.id == target.id }
            statusMessage = "Finder bookmark ghost \(target.name) was removed."
        } catch {
            updateFailure(for: target.id, message: error.localizedDescription)
            statusMessage = "Could not remove Finder bookmark ghost \(target.name)."
        }
    }

    func requestFinderRefresh() {
        guard !phase.isBusy else { return }
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
                statusMessage = "Finder refreshed. Rescan to check for remaining ghosts."
            } else {
                statusMessage = command.error.nonEmpty ?? "Finder could not be refreshed."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func requestForceAll() {
        guard !phase.isBusy, hasActionableFailures else { return }
        forceAllConfirmation = true
    }

    func leaveMounted(_ target: MountTarget) {
        guard !phase.isBusy,
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
        let failures = targets.filter { $0.kind != .ghost && $0.failureMessage != nil && !$0.isLeftMounted }
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
        guard target.kind != .ghost else { return nil }
        let shortcuts = targets.filter { $0.kind != .ghost }
        guard let index = shortcuts.firstIndex(where: { $0.id == target.id }), index < 9 else {
            return nil
        }
        return index + 1
    }

    func targetForShortcut(_ number: Int) -> MountTarget? {
        let shortcuts = targets.filter { $0.kind != .ghost }
        guard (1...9).contains(number), shortcuts.indices.contains(number - 1) else { return nil }
        let target = shortcuts[number - 1]
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
