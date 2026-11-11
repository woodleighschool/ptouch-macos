import Foundation
import OSLog

enum PrinterQueue {
    static func ensure(_ printer: PrinterDescriptor) async throws {
        let existing = try await run("/usr/bin/lpstat", ["-v", printer.queue])
        if existing.0 == 0, existing.1.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(printer.uri) {
            return
        }
        let result = try await run("/usr/sbin/lpadmin", [
            "-p", printer.queue, "-E", "-v", printer.uri,
            "-m", "everywhere", "-D", "Brother \(printer.name)",
            "-o", "printer-is-shared=false", "-o", "printer-error-policy=stop-printer",
        ])
        guard result.0 == 0 else { throw LabelError("Could not add printer: \(result.1)") }
        Logger.bridge.info("Registered printer queue \(printer.queue, privacy: .public)")
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            if process.isRunning {
                process.terminate()
            }
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, message))
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
