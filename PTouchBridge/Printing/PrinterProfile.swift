import Foundation

nonisolated struct Tape: Equatable, Sendable {
    let widthMM: Double
    let statusCode: UInt8
    let printableDots: Int

    var name: String {
        widthMM.rounded() == widthMM ? String(Int(widthMM)) : String(widthMM)
    }

    func marginHundredths(dpi: Int) -> Int {
        Int(((widthMM - Double(printableDots) * 25.4 / Double(dpi)) * 50).rounded(.up))
    }
}

nonisolated struct PrinterProfile: Sendable {
    let model: String
    let dpi: Int
    let headDots: Int
    let tapes: [Tape]
    let lengthMM: ClosedRange<Double>
    let feedDots: Int

    /// Brother's raster reference defines geometry per model, not per bridge or document.
    static let profiles = [
        PrinterProfile(
            model: "PT-P710BT", dpi: 180, headDots: 128,
            tapes: [
                Tape(widthMM: 3.5, statusCode: 4, printableDots: 24),
                Tape(widthMM: 6, statusCode: 6, printableDots: 32),
                Tape(widthMM: 9, statusCode: 9, printableDots: 50),
                Tape(widthMM: 12, statusCode: 12, printableDots: 70),
                Tape(widthMM: 18, statusCode: 18, printableDots: 112),
                Tape(widthMM: 24, statusCode: 24, printableDots: 128),
            ],
            lengthMM: 4.4 ... 1000, feedDots: 14
        ),
    ]

    static func matching(_ name: String) -> PrinterProfile? {
        profiles.first { name.hasPrefix($0.model) }
    }
}

nonisolated struct PrinterDescriptor: Sendable {
    let address: String
    let name: String
    let profile: PrinterProfile

    var id: String {
        address.filter(\.isHexDigit).uppercased()
    }

    var queue: String {
        "PTouch_\(id)"
    }

    var uri: String {
        "ipp://127.0.0.1:8632/ipp/print/\(id)"
    }

    var uuid: String {
        "urn:uuid:00000000-0000-4000-8000-\(id.lowercased())"
    }
}
