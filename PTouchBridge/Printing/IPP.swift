import CCUPS
import Foundation

private final nonisolated class IPPBuffer {
    var data: Data
    var offset = 0
    init(_ data: Data = Data()) {
        self.data = data
    }
}

final nonisolated class IPPMessage {
    let pointer: OpaquePointer
    var document = Data()

    init(data: Data) throws {
        pointer = ippNew()!
        let input = IPPBuffer(data)
        let state = ippReadIO(Unmanaged.passUnretained(input).toOpaque(), { context, buffer, count in
            let input = Unmanaged<IPPBuffer>.fromOpaque(context!).takeUnretainedValue()
            let amount = min(count, input.data.count - input.offset)
            guard amount > 0, let buffer else { return 0 }
            input.data.copyBytes(to: buffer, from: input.offset ..< input.offset + amount)
            input.offset += amount
            return amount
        }, 1, nil, pointer)
        guard state == IPP_STATE_DATA else { throw LabelError("Malformed IPP request.") }
        document = data.dropFirst(input.offset)
    }

    init(responseTo request: IPPMessage) {
        pointer = ippNewResponse(request.pointer)!
    }

    deinit { ippDelete(pointer) }

    var operation: Int {
        Int(ippGetOperation(pointer).rawValue)
    }

    func text(_ name: String) -> String? {
        guard let attribute = ippFindAttribute(pointer, name, IPP_TAG_ZERO),
              let value = ippGetString(attribute, 0, nil) else { return nil }
        return String(cString: value)
    }

    func number(_ name: String) -> Int? {
        guard let attribute = ippFindAttribute(pointer, name, IPP_TAG_ZERO) else { return nil }
        return Int(ippGetInteger(attribute, 0))
    }

    func string(_ name: String, _ value: String, tag: ipp_tag_t = IPP_TAG_KEYWORD, group: ipp_tag_t = IPP_TAG_PRINTER) {
        ippAddString(pointer, group, tag, name, nil, value)
    }

    func strings(_ name: String, _ values: [String], tag: ipp_tag_t = IPP_TAG_KEYWORD) {
        let storage = values.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        let pointers = storage.map { UnsafePointer<CChar>?($0) }
        pointers.withUnsafeBufferPointer {
            _ = ippAddStrings(pointer, IPP_TAG_PRINTER, tag, name, Int32(values.count), nil, $0.baseAddress)
        }
    }

    func integer(_ name: String, _ value: Int, tag: ipp_tag_t = IPP_TAG_INTEGER, group: ipp_tag_t = IPP_TAG_PRINTER) {
        ippAddInteger(pointer, group, tag, name, Int32(value))
    }

    func integers(_ name: String, _ values: [Int32], tag: ipp_tag_t = IPP_TAG_INTEGER) {
        values.withUnsafeBufferPointer {
            _ = ippAddIntegers(pointer, IPP_TAG_PRINTER, tag, name, Int32(values.count), $0.baseAddress)
        }
    }

    func boolean(_ name: String, _ value: Bool) {
        ippAddBoolean(pointer, IPP_TAG_PRINTER, name, value ? 1 : 0)
    }

    func error(_ status: ipp_status_t, _ message: String) {
        ippSetStatusCode(pointer, status)
        string("status-message", message, tag: IPP_TAG_TEXT, group: IPP_TAG_OPERATION)
    }

    func data() -> Data {
        let output = IPPBuffer()
        ippSetState(pointer, IPP_STATE_IDLE)
        _ = ippWriteIO(Unmanaged.passUnretained(output).toOpaque(), { context, buffer, count in
            let output = Unmanaged<IPPBuffer>.fromOpaque(context!).takeUnretainedValue()
            guard let buffer else { return 0 }
            output.data.append(buffer, count: count)
            return count
        }, 1, nil, pointer)
        return output.data
    }

    func printerAttributes(device: PrinterDescriptor, loadedTape: Tape?, processing: Bool, uptime: Int) {
        string("printer-uri-supported", device.uri, tag: IPP_TAG_URI)
        string("uri-authentication-supported", "none")
        string("uri-security-supported", "none")
        string("printer-name", device.queue, tag: IPP_TAG_NAME)
        string("printer-info", "Brother \(device.name)", tag: IPP_TAG_TEXT)
        string("printer-location", "This Mac", tag: IPP_TAG_TEXT)
        string("printer-make-and-model", "Brother \(device.profile.model)", tag: IPP_TAG_TEXT)
        string("printer-more-info", "https://support.brother.com/", tag: IPP_TAG_URI)
        string("printer-device-id", "MFG:Brother;MDL:\(device.profile.model);CMD:PDF;", tag: IPP_TAG_TEXT)
        string("printer-uuid", device.uuid, tag: IPP_TAG_URI)
        integer("printer-state", processing ? 4 : 3, tag: IPP_TAG_ENUM)
        string("printer-state-reasons", "none")
        boolean("printer-is-accepting-jobs", true)
        integer("queued-job-count", processing ? 1 : 0)
        integer("printer-up-time", uptime)
        strings("ipp-versions-supported", ["1.1", "2.0"])
        integers("operations-supported", [2, 4, 5, 6, 8, 9, 10, 11], tag: IPP_TAG_ENUM)
        string("charset-configured", "utf-8", tag: IPP_TAG_CHARSET)
        string("charset-supported", "utf-8", tag: IPP_TAG_CHARSET)
        string("natural-language-configured", "en", tag: IPP_TAG_LANGUAGE)
        string("generated-natural-language-supported", "en", tag: IPP_TAG_LANGUAGE)
        string("document-format-default", "application/pdf", tag: IPP_TAG_MIMETYPE)
        string("document-format-supported", "application/pdf", tag: IPP_TAG_MIMETYPE)
        string("compression-supported", "none")
        boolean("color-supported", false)
        string("print-color-mode-default", "monochrome")
        string("print-color-mode-supported", "monochrome")
        string("sides-default", "one-sided")
        string("sides-supported", "one-sided")
        integer("copies-default", 1)
        ippAddRange(pointer, IPP_TAG_PRINTER, "copies-supported", 1, 99)
        boolean("multiple-document-jobs-supported", false)
        string("multiple-document-handling-default", "separate-documents-collated-copies")
        string("multiple-document-handling-supported", "separate-documents-collated-copies")
        string("job-hold-until-default", "no-hold")
        string("job-hold-until-supported", "no-hold")
        integer("job-priority-default", 50)
        integer("job-priority-supported", 1)
        integer("finishings-default", 3, tag: IPP_TAG_ENUM)
        integer("finishings-supported", 3, tag: IPP_TAG_ENUM)
        integer("orientation-requested-default", 3, tag: IPP_TAG_ENUM)
        integers("orientation-requested-supported", [3, 4, 5, 6], tag: IPP_TAG_ENUM)
        integer("print-quality-default", 4, tag: IPP_TAG_ENUM)
        integer("print-quality-supported", 4, tag: IPP_TAG_ENUM)
        for key in ["printer-resolution-default", "printer-resolution-supported"] {
            ippAddResolution(pointer, IPP_TAG_PRINTER, key, IPP_RES_PER_INCH, Int32(device.profile.dpi), Int32(device.profile.dpi))
        }
        let profile = device.profile
        let defaultTape = loadedTape ?? profile.tapes.last!
        func mediaName(_ tape: Tape) -> String {
            "custom_100x\(tape.name)mm_100x\(tape.name)mm"
        }
        string("media-default", mediaName(defaultTape))
        strings("media-supported", profile.tapes.map(mediaName))
        if let loadedTape {
            string("media-ready", mediaName(loadedTape))
        }
        string("media-source-supported", "roll-1")
        string("media-type-supported", "labels")
        strings("media-col-supported", ["media-size", "media-top-margin", "media-bottom-margin", "media-left-margin", "media-right-margin", "media-source", "media-type"])
        let margins = Array(Set(profile.tapes.map { Int32($0.marginHundredths(dpi: profile.dpi)) })).sorted()
        for key in ["media-top-margin-supported", "media-bottom-margin-supported"] {
            integers(key, margins)
        }
        for key in ["media-left-margin-supported", "media-right-margin-supported"] {
            integer(key, 0)
        }
        for tape in profile.tapes {
            let range = ippNew()!
            ippAddRange(range, IPP_TAG_ZERO, "x-dimension", Int32(profile.lengthMM.lowerBound * 100), Int32(profile.lengthMM.upperBound * 100))
            ippAddInteger(range, IPP_TAG_ZERO, IPP_TAG_INTEGER, "y-dimension", Int32(tape.widthMM * 100))
            appendCollection("media-size-supported", range)
            ippDelete(range)

            let size = ippNew()!
            ippAddInteger(size, IPP_TAG_ZERO, IPP_TAG_INTEGER, "x-dimension", 10000)
            ippAddInteger(size, IPP_TAG_ZERO, IPP_TAG_INTEGER, "y-dimension", Int32(tape.widthMM * 100))
            let media = ippNew()!
            ippAddCollection(media, IPP_TAG_ZERO, "media-size", size)
            ippDelete(size)
            ippAddString(media, IPP_TAG_ZERO, IPP_TAG_KEYWORD, "media-size-name", nil, mediaName(tape))
            ippAddString(media, IPP_TAG_ZERO, IPP_TAG_KEYWORD, "media-source", nil, "roll-1")
            ippAddString(media, IPP_TAG_ZERO, IPP_TAG_KEYWORD, "media-type", nil, "labels")
            let margin = tape.marginHundredths(dpi: profile.dpi)
            for (key, value) in [("media-top-margin", margin), ("media-bottom-margin", margin), ("media-left-margin", 0), ("media-right-margin", 0)] {
                ippAddInteger(media, IPP_TAG_ZERO, IPP_TAG_INTEGER, key, Int32(value))
            }
            appendCollection("media-col-database", media)
            if tape == defaultTape {
                appendCollection("media-col-default", media)
            }
            if tape == loadedTape {
                appendCollection("media-col-ready", media)
            }
            ippDelete(media)
        }
    }

    private func appendCollection(_ name: String, _ collection: OpaquePointer) {
        if let existing = ippFindAttribute(pointer, name, IPP_TAG_BEGIN_COLLECTION) {
            var attribute: OpaquePointer? = existing
            ippSetCollection(pointer, &attribute, ippGetCount(existing), collection)
        } else {
            ippAddCollection(pointer, IPP_TAG_PRINTER, name, collection)
        }
    }
}
