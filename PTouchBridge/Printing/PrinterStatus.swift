import Foundation

nonisolated struct PrinterIssue: LocalizedError, Equatable {
    let reason: String
    let message: String

    var errorDescription: String? {
        message
    }
}

nonisolated enum PrinterState: Equatable {
    case offline(String)
    case connecting
    case ready(Tape)
    case printing(Tape)
    case stopped(PrinterIssue)

    var tape: Tape? {
        switch self {
        case let .ready(tape), let .printing(tape): tape
        default: nil
        }
    }

    var reason: String {
        switch self {
        case .offline, .connecting: "offline-report"
        case let .stopped(issue): issue.reason
        case .ready, .printing: "none"
        }
    }

    var message: String {
        switch self {
        case let .offline(message): message
        case .connecting: "Connecting to printer."
        case let .stopped(issue): issue.message
        case .ready, .printing: ""
        }
    }
}

nonisolated struct QueueStatus: Equatable {
    let printer: PrinterState
    let jobError: String?

    var reasons: [String] {
        var reasons = printer.reason == "none" ? [] : [printer.reason]
        if jobError != nil, !reasons.contains("other-error") {
            reasons.append("other-error")
        }
        return reasons.isEmpty ? ["none"] : reasons
    }

    var message: String {
        [printer.message, jobError ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var ippState: Int {
        if jobError != nil {
            return 5
        }
        switch printer {
        case .stopped: return 5
        case .printing: return 4
        case .offline, .connecting, .ready: return 3
        }
    }
}

nonisolated struct PrinterStatus {
    let kind: UInt8
    let printing: Bool
    let tape: Tape?
    let issue: PrinterIssue?

    init(_ bytes: [UInt8], profile: PrinterProfile) throws {
        guard bytes.count == 32, bytes.starts(with: [0x80, 0x20, 0x42]) else {
            throw LabelError("The printer returned an unexpected status packet.")
        }
        kind = bytes[18]
        printing = bytes[19] == 1
        // Flexible ID TZe (14h) shares laminated cassette geometry. Brother's P710BT reference
        // omits it, but the printer reports it alongside the Flex. ID tape colour (90h).
        tape = [0x01, 0x03, 0x14].contains(bytes[11]) ? profile.tapes.first { $0.statusCode == bytes[10] } : nil
        if bytes[8] & 0x01 != 0 || bytes[11] == 0 {
            issue = PrinterIssue(reason: "media-empty-error", message: "Load a tape cassette.")
        } else if bytes[9] & 0x10 != 0 {
            issue = PrinterIssue(reason: "cover-open-error", message: "Close the printer cover.")
        } else if bytes[8] & 0x04 != 0 {
            issue = PrinterIssue(reason: "cutter-jam-error", message: "Clear the printer's cutter jam.")
        } else if bytes[8] & 0x08 != 0 {
            issue = PrinterIssue(reason: "other-error", message: "Charge the printer battery.")
        } else if bytes[9] & 0x20 != 0 {
            issue = PrinterIssue(reason: "other-error", message: "Let the printer cool down.")
        } else if bytes[8] != 0 || bytes[9] != 0 {
            issue = PrinterIssue(reason: "other-error", message: "Printer error \(bytes[8])/\(bytes[9]). Check tape and power.")
        } else if tape == nil {
            issue = PrinterIssue(reason: "media-needed-error", message: "The loaded cassette is not supported by this printer profile.")
        } else {
            issue = nil
        }
    }
}
