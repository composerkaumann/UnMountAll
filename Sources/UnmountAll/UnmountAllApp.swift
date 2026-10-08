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
            .keyboardShortcut("u", modifiers: [])
            .disabled(model.windowActionsDisabled || (!model.hasNormalTargets && !model.hasActionableFailures))

            Divider()

            ForEach(model.targets) { target in
                targetAction(target)
                if target.failureMessage != nil, !target.isLeftMounted {
                    Button("Leave Mounted: \(target.name)") {
                        model.leaveMounted(target)
                    }
                    .disabled(model.windowActionsDisabled)
                }
            }

            Divider()

            Button("Rescan") {
                Task { await model.scan() }
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(model.windowActionsDisabled)

            Button("Refresh Finder") {
                model.requestFinderRefresh()
            }
            .keyboardShortcut("f", modifiers: [])
            .disabled(model.windowActionsDisabled)
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
            .disabled(model.windowActionsDisabled)
        } else {
            Button(actionTitle(for: target)) {
                performAction(for: target)
            }
            .disabled(model.windowActionsDisabled)
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
