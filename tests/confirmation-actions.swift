import Foundation

struct CommandResult: Sendable {
    let output: String
    let error: String
    let status: Int32
}

@MainActor
enum ScriptRunner {
    static var calls: [[String]] = []

    static func run(arguments: [String]) async throws -> CommandResult {
        calls.append(arguments)
        let encoded = ["Fixture", "Test disk", "/dev/disk999"].map {
            Data($0.utf8).base64EncodedString()
        }
        return CommandResult(
            output: "target\tfixture-id\timage\t\(encoded.joined(separator: "\t"))\n",
            error: "", status: 0
        )
    }
}

@main
struct ConfirmationActionsTest {
    @MainActor
    static func main() async throws {
        let model = AppModel()
        await model.scan()
        let target = model.targets[0]

        for confirmation in ["Finder", "Force", "Force All"] {
            model.finderRefreshConfirmation = confirmation == "Finder"
            model.forceConfirmation = confirmation == "Force" ? target : nil
            model.forceAllConfirmation = confirmation == "Force All"
            ScriptRunner.calls = []

            precondition(model.windowActionsDisabled)
            await model.scan()
            await model.unmountAll()
            await model.unmount(target)
            model.requestFinderRefresh()
            model.requestForce(target)
            model.requestForceAll()
            model.leaveMounted(target)

            precondition(ScriptRunner.calls.isEmpty, "Background action ran during \(confirmation)")
            precondition(model.finderRefreshConfirmation == (confirmation == "Finder"))
            precondition((model.forceConfirmation != nil) == (confirmation == "Force"))
            precondition(model.forceAllConfirmation == (confirmation == "Force All"))
            precondition(!model.targets[0].isLeftMounted)
            print("PASS: background actions blocked during \(confirmation) confirmation")
        }

        model.forceAllConfirmation = false
        model.finderRefreshConfirmation = true
        ScriptRunner.calls = []
        await model.refreshFinderConfirmed()
        precondition(ScriptRunner.calls == [["--refresh-finder"]])
        precondition(!model.windowActionsDisabled)
        print("PASS: Finder confirmation invokes only Refresh Finder")
    }
}
