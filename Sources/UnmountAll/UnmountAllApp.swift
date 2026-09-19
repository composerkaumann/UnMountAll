import SwiftUI

@main
struct UnmountAllApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("UMA - UnMount All") {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.scan()
                }
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            UMACommands(model: model)
        }
    }
}

@MainActor
private struct UMACommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Actions") {
            Button(model.hasNormalTargets ? "Unmount All" : "Force All") {
                if model.hasNormalTargets {
                    Task { await model.unmountAll() }
                } else {
                    model.requestForceAll()
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.phase.isBusy || (!model.hasNormalTargets && !model.hasActionableFailures))

            Divider()

            ForEach(model.targets) { target in
                targetAction(target)
                if target.failureMessage != nil, !target.isLeftMounted {
                    Button("Leave Mounted: \(target.name)") {
                        model.leaveMounted(target)
                    }
                    .disabled(model.phase.isBusy)
                }
            }

            Divider()

            Button("Rescan") {
                Task { await model.scan() }
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(model.phase.isBusy)

            Button("Refresh Finder") {
                model.requestFinderRefresh()
            }
            .disabled(model.phase.isBusy)
        }
    }

    @ViewBuilder
    private func targetAction(_ target: MountTarget) -> some View {
        if target.isLeftMounted {
            Button("Left Mounted: \(target.name)") {}
                .disabled(true)
        } else if let number = model.shortcutNumber(for: target) {
            Button(actionTitle(for: target)) {
                performAction(for: target)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
            .disabled(model.phase.isBusy)
        } else {
            Button(actionTitle(for: target)) {
                performAction(for: target)
            }
            .disabled(model.phase.isBusy)
        }
    }

    private func actionTitle(for target: MountTarget) -> String {
        target.failureMessage == nil
            ? "Unmount: \(target.name)"
            : "\(target.kind.forceButtonTitle): \(target.name)"
    }

    private func performAction(for target: MountTarget) {
        if target.failureMessage == nil {
            Task { await model.unmount(target) }
        } else {
            model.requestForce(target)
        }
    }
}
