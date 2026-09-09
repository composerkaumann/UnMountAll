import Foundation

struct CommandResult: Sendable {
    let output: String
    let error: String
    let status: Int32
}

enum ScriptRunnerError: LocalizedError {
    case scriptNotFound

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            "The bundled unmount-all.sh script could not be found."
        }
    }
}

enum ScriptRunner {
    static func run(arguments: [String]) async throws -> CommandResult {
        let scriptURL = try locateScript()

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            process.waitUntilExit()

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                output: String(decoding: outputData, as: UTF8.self),
                error: String(decoding: errorData, as: UTF8.self),
                status: process.terminationStatus
            )
        }.value
    }

    private static func locateScript() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "unmount-all", withExtension: "sh") {
            return bundled
        }

        let workingCopy = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("unmount-all.sh")
        if FileManager.default.fileExists(atPath: workingCopy.path) {
            return workingCopy
        }
        throw ScriptRunnerError.scriptNotFound
    }
}
