import SwiftUI

@main
struct UnmountAllApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.scan()
                }
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rescan") {
                    Task { await model.scan() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}
