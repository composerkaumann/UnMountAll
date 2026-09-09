import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460)
        .confirmationDialog(
            model.forceConfirmation?.kind.forceButtonTitle ?? "Force",
            isPresented: Binding(
                get: { model.forceConfirmation != nil },
                set: { if !$0 { model.forceConfirmation = nil } }
            ),
            presenting: model.forceConfirmation
        ) { target in
            Button(target.kind.forceButtonTitle, role: .destructive) {
                Task { await model.forceConfirmed() }
            }
            Button("Cancel", role: .cancel) {
                model.forceConfirmation = nil
            }
        } message: { target in
            Text("Forcing \(target.name) may cause data loss if files are still open.")
        }
        .confirmationDialog(
            "Force All Remaining Items?",
            isPresented: $model.forceAllConfirmation
        ) {
            Button("Force All", role: .destructive) {
                Task { await model.forceAllConfirmed() }
            }
            Button("Cancel", role: .cancel) {
                model.forceAllConfirmation = false
            }
        } message: {
            Text("Forcing mounted items may cause data loss if files are still open.")
        }
        .confirmationDialog(
            ghostConfirmationTitle,
            isPresented: Binding(
                get: { model.ghostRemovalConfirmation != nil },
                set: { if !$0 { model.ghostRemovalConfirmation = nil } }
            ),
            presenting: model.ghostRemovalConfirmation
        ) { target in
            Button(ghostConfirmationButtonTitle, role: .destructive) {
                Task { await model.removeGhostConfirmed() }
            }
            Button("Cancel", role: .cancel) {
                model.ghostRemovalConfirmation = nil
            }
        } message: { target in
            if FinderRecentGhostStore.isFinderRecentGhost(target) {
                Text("UMA will remove only this stale network bookmark from Finder's Recent Folders and then refresh Finder. It will not connect to the server, unmount anything, or delete files.")
            } else {
                Text("UMA will remove only the empty, unmounted directory at \(target.target). It will not unmount or delete mounted data.")
            }
        }
        .confirmationDialog(
            "Refresh Finder?",
            isPresented: $model.finderRefreshConfirmation
        ) {
            Button("Refresh Finder") {
                Task { await model.refreshFinderConfirmed() }
            }
            Button("Cancel", role: .cancel) {
                model.finderRefreshConfirmation = false
            }
        } message: {
            Text("Finder will briefly quit and relaunch. No files or mounts will be changed.")
        }
        .background(
            KeyboardShortcutMonitor(
                onNumber: handleNumberShortcut,
                onReturn: handleReturnShortcut,
                onRescan: handleRescanShortcut
            )
            .frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "eject.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("UMA")
                    .font(.title2.bold())
                Text("External disks, disk images, and network shares")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.scan() }
            } label: {
                HStack(spacing: 7) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                    KeyCap(title: "R")
                }
            }
            .disabled(model.phase.isBusy)
            Button {
                model.requestFinderRefresh()
            } label: {
                Label("Refresh Finder", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.phase.isBusy)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .scanning && model.targets.isEmpty {
            progressView("Scanning…")
        } else if model.targets.isEmpty {
            ContentUnavailableView(
                "Nothing Mounted",
                systemImage: "checkmark.circle",
                description: Text(model.statusMessage)
            )
        } else {
            List {
                ForEach(groupedKinds, id: \.self) { kind in
                    Section(kind.title + "s") {
                        ForEach(model.targets.filter { $0.kind == kind }) { target in
                            TargetRow(target: target)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.phase.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: primaryAction) {
                HStack(spacing: 9) {
                    Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                    KeyCap(title: "↩")
                }
                .frame(minWidth: 122)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.hasNormalTargets ? .accentColor : .red)
            .controlSize(.large)
            .disabled(model.phase.isBusy || !hasPrimaryAction)
        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var groupedKinds: [MountKind] {
        [.physical, .image, .network, .ghost].filter { kind in
            model.targets.contains { $0.kind == kind }
        }
    }

    private var ghostConfirmationTitle: String {
        guard let target = model.ghostRemovalConfirmation,
              FinderRecentGhostStore.isFinderRecentGhost(target) else {
            return "Remove Empty Finder Ghost?"
        }
        return "Remove Finder Network Ghost?"
    }

    private var ghostConfirmationButtonTitle: String {
        guard let target = model.ghostRemovalConfirmation,
              FinderRecentGhostStore.isFinderRecentGhost(target) else {
            return "Remove Empty Ghost"
        }
        return "Remove Finder Entry"
    }

    private var hasPrimaryAction: Bool {
        model.hasNormalTargets || model.hasActionableFailures
    }

    private var primaryButtonTitle: String {
        model.hasNormalTargets ? "Unmount All" : "Force All"
    }

    private var primaryButtonSymbol: String {
        model.hasNormalTargets ? "eject.fill" : "exclamationmark.triangle.fill"
    }

    private func primaryAction() {
        guard !model.phase.isBusy else { return }
        if model.hasNormalTargets {
            Task { await model.unmountAll() }
        } else {
            model.requestForceAll()
        }
    }

    private func handleNumberShortcut(_ number: Int) -> Bool {
        guard !model.phase.isBusy,
              model.forceConfirmation == nil,
              !model.forceAllConfirmation,
              let target = model.targetForShortcut(number) else { return false }

        if target.failureMessage == nil {
            Task { await model.unmount(target) }
        } else {
            model.requestForce(target)
        }
        return true
    }

    private func handleReturnShortcut() -> Bool {
        guard !model.phase.isBusy,
              model.forceConfirmation == nil,
              !model.forceAllConfirmation,
              hasPrimaryAction else { return false }
        primaryAction()
        return true
    }

    private func handleRescanShortcut() -> Bool {
        guard !model.phase.isBusy,
              model.forceConfirmation == nil,
              !model.forceAllConfirmation else { return false }
        Task { await model.scan() }
        return true
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TargetRow: View {
    @EnvironmentObject private var model: AppModel
    let target: MountTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: target.kind.symbol)
                .font(.title3)
                .foregroundStyle(target.failureMessage == nil ? Color.accentColor : .red)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.name)
                    .fontWeight(.medium)
                Text(target.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let failure = target.failureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 16)
            if target.kind == .ghost {
                ghostAction
            } else if target.isLeftMounted {
                Label("Left Mounted", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if target.failureMessage != nil {
                HStack(spacing: 8) {
                    Button(target.kind.forceButtonTitle) {
                        model.requestForce(target)
                    }
                    .buttonStyle(.borderedProminent)

                    if let number = model.shortcutNumber(for: target) {
                        KeyCap(title: "\(number)")
                    }

                    Button("Leave Mounted") {
                        model.leaveMounted(target)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(model.phase.isBusy)
            } else {
                HStack(spacing: 8) {
                    Button("Unmount") {
                        Task { await model.unmount(target) }
                    }
                    .buttonStyle(.bordered)

                    if let number = model.shortcutNumber(for: target) {
                        KeyCap(title: "\(number)")
                    }
                }
                .disabled(model.phase.isBusy)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var ghostAction: some View {
        if target.failureMessage == nil {
            Button(FinderRecentGhostStore.isFinderRecentGhost(target) ? "Remove Finder Entry" : "Remove Empty Ghost") {
                model.requestGhostRemoval(target)
            }
            .buttonStyle(.bordered)
            .disabled(model.phase.isBusy)
        } else {
            Label("Could not remove", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

private struct KeyCap: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 22, minHeight: 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.tertiary, lineWidth: 0.5)
            }
            .accessibilityLabel("Keyboard shortcut \(title)")
    }
}

private struct KeyboardShortcutMonitor: NSViewRepresentable {
    let onNumber: (Int) -> Bool
    let onReturn: () -> Bool
    let onRescan: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onNumber: onNumber, onReturn: onReturn, onRescan: onRescan)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNumber = onNumber
        context.coordinator.onReturn = onReturn
        context.coordinator.onRescan = onRescan
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        var onNumber: (Int) -> Bool
        var onReturn: () -> Bool
        var onRescan: () -> Bool
        private var monitor: Any?

        init(
            onNumber: @escaping (Int) -> Bool,
            onReturn: @escaping () -> Bool,
            onRescan: @escaping () -> Bool
        ) {
            self.onNumber = onNumber
            self.onReturn = onReturn
            self.onRescan = onRescan
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }

                if let number = Self.number(for: event.keyCode), self.onNumber(number) {
                    return nil
                }
                if (event.keyCode == 36 || event.keyCode == 76), self.onReturn() {
                    return nil
                }
                if event.keyCode == 15, self.onRescan() {
                    return nil
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func number(for keyCode: UInt16) -> Int? {
            [
                18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9
            ][keyCode]
        }
    }
}
