import Foundation

enum Shell {
    struct Failure: LocalizedError {
        let executable: String
        let arguments: [String]
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            let command = ([executable] + arguments).joined(separator: " ")
            if stderr.isEmpty {
                return "\(command) exited with status \(status)"
            }
            return "\(command) exited with status \(status): \(stderr)"
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw Failure(
                executable: executable,
                arguments: arguments,
                status: process.terminationStatus,
                stderr: errorOutput
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
