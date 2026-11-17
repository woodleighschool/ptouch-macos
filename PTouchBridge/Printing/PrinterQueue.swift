import CCUPS
import Foundation
import OSLog

enum PrinterQueue {
    static func update(_ printer: PrinterDescriptor, tape: Tape?, status: QueueStatus, configure: Bool) async throws {
        if configure, let tape {
            let existing = try await run("/usr/bin/lpstat", ["-v", printer.queue])
            var arguments = ["-p", printer.queue, "-o", "media-default=\(tape.mediaName)"]
            if existing.0 != 0 {
                arguments += [
                    "-E", "-v", printer.uri, "-m", "everywhere", "-D", "Brother \(printer.name)",
                    "-o", "printer-is-shared=false", "-o", "printer-error-policy=stop-printer",
                ]
            }
            let result = try await run("/usr/sbin/lpadmin", arguments)
            guard result.0 == 0 else { throw LabelError("Could not add printer: \(result.1)") }
            Logger.bridge.info("Updated paper default for \(printer.queue, privacy: .public)")
        }
        try Task.checkCancellation()
        try await publish(printer, status: status)
    }

    @concurrent
    private static func publish(_ printer: PrinterDescriptor, status: QueueStatus) async throws {
        guard let http = httpConnect2(cupsServer(), ippPort(), nil, AF_UNSPEC, HTTP_ENCRYPTION_IF_REQUESTED, 1, 5000, nil) else {
            throw LabelError("Cannot connect to the macOS print service.")
        }
        defer { httpClose(http) }
        httpSetTimeout(http, 5, nil, nil)
        guard let destination = cupsGetNamedDest(http, printer.queue, nil) else { return }
        defer { cupsFreeDests(1, destination) }
        // CUPS owns scheduling. Publishing device status must preserve a queue pause.
        let state = cupsGetOption("printer-state", destination.pointee.num_options, destination.pointee.options)
        let paused = state.map { String(cString: $0) == "5" } ?? false
        var reasons = status.reasons
        if paused {
            reasons = reasons.filter { $0 != "none" } + ["paused"]
        }
        let request = ippNewRequest(IPP_OP_CUPS_ADD_MODIFY_PRINTER)!
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/\(printer.queue)")
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        let storage = reasons.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        let pointers = storage.map { UnsafePointer<CChar>?($0) }
        pointers.withUnsafeBufferPointer {
            _ = ippAddStrings(request, IPP_TAG_PRINTER, IPP_TAG_KEYWORD, "printer-state-reasons", Int32($0.count), nil, $0.baseAddress)
        }
        if !paused {
            ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-state-message", nil, status.message)
        }
        guard let response = cupsDoRequest(http, request, "/admin/") else {
            throw LabelError(String(cString: cupsLastErrorString()))
        }
        defer { ippDelete(response) }
        guard ippGetStatusCode(response).rawValue < 0x0400 else {
            throw LabelError(String(cString: cupsLastErrorString()))
        }
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
