import CCUPS
import Foundation
import OSLog

@MainActor
final class PrintServer {
    let device: PrinterDescriptor
    let printer: BluetoothPrinter
    private var loadedTape: Tape?

    init(device: PrinterDescriptor) {
        self.device = device
        printer = BluetoothPrinter(device: device)
        printer.onProgress = { text in Logger.bridge.info("\(text, privacy: .public)") }
    }

    private let started = Date()
    private var nextID = Int(Date().timeIntervalSince1970)
    private var jobs: [Int: Job] = [:]
    private var pending: [(Int, [Label])] = []
    private var printing = false

    struct Job {
        let id: Int
        let name: String
        let user: String
        let copies: Int
        var state = 4
        var message = "Waiting for document"
        var pages = 0
    }

    func handle(_ request: IPPMessage) -> IPPMessage {
        let response = IPPMessage(responseTo: request)
        switch request.operation {
        case 11:
            response.printerAttributes(device: device, loadedTape: loadedTape, processing: printing, uptime: Int(Date().timeIntervalSince(started)))
        case 4:
            if let format = request.text("document-format"), format != "application/pdf", format != "application/octet-stream" {
                response.error(IPP_STATUS_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED, "Use a PDF with a paper size supported by this printer.")
            }
        case 2, 5:
            let copies = request.number("copies") ?? 1
            guard (1 ... 99).contains(copies) else {
                response.error(IPP_STATUS_ERROR_ATTRIBUTES_OR_VALUES, "Copies must be between 1 and 99.")
                return response
            }
            let job = Job(id: nextID, name: request.text("job-name") ?? "Print job", user: request.text("requesting-user-name") ?? "local", copies: copies)
            nextID += 1
            jobs[job.id] = job
            if request.operation == 2 {
                enqueue(request.document, job: job.id, response: response)
            }
            add(jobs[job.id]!, to: response)
        case 6:
            guard let id = jobID(request), jobs[id]?.state == 4 else {
                response.error(IPP_STATUS_ERROR_NOT_FOUND, "No job is waiting for this document.")
                return response
            }
            enqueue(request.document, job: id, response: response)
            add(jobs[id]!, to: response)
        case 9:
            guard let id = jobID(request), let job = jobs[id] else {
                response.error(IPP_STATUS_ERROR_NOT_FOUND, "Job not found.")
                return response
            }
            add(job, to: response)
        case 10:
            let which = request.text("which-jobs") ?? "not-completed"
            for job in jobs.values.sorted(by: { $0.id < $1.id }) where which == "all" || (which == "completed" ? job.state >= 7 : job.state < 7) {
                add(job, to: response)
                ippAddSeparator(response.pointer)
            }
        case 8:
            guard let id = jobID(request), let job = jobs[id] else {
                response.error(IPP_STATUS_ERROR_NOT_FOUND, "Job not found.")
                return response
            }
            if job.state == 5 {
                response.error(IPP_STATUS_ERROR_NOT_POSSIBLE, "The label is already being sent to the printer.")
            } else if job.state < 7 {
                pending.removeAll { $0.0 == id }
                jobs[id]?.state = 7
                jobs[id]?.message = "Cancelled"
            }
        default:
            response.error(IPP_STATUS_ERROR_OPERATION_NOT_SUPPORTED, "Unsupported IPP operation.")
        }
        return response
    }

    private func jobID(_ request: IPPMessage) -> Int? {
        request.number("job-id") ?? request.text("job-uri").flatMap { Int($0.split(separator: "/").last ?? "") }
    }

    private func add(_ job: Job, to response: IPPMessage) {
        response.integer("job-id", job.id, group: IPP_TAG_JOB)
        response.string("job-uri", "\(device.uri)/jobs/\(job.id)", tag: IPP_TAG_URI, group: IPP_TAG_JOB)
        response.string("job-printer-uri", device.uri, tag: IPP_TAG_URI, group: IPP_TAG_JOB)
        response.string("job-name", job.name, tag: IPP_TAG_NAME, group: IPP_TAG_JOB)
        response.string("job-originating-user-name", job.user, tag: IPP_TAG_NAME, group: IPP_TAG_JOB)
        response.integer("job-state", job.state, tag: IPP_TAG_ENUM, group: IPP_TAG_JOB)
        let reason = job.state == 9 ? "job-completed-successfully" : job.state == 8 ? "job-completed-with-errors" : job.state == 7 ? "job-canceled-by-user" : job.state == 4 ? "job-data-insufficient" : "none"
        response.string("job-state-reasons", reason, group: IPP_TAG_JOB)
        response.string("job-state-message", job.message, tag: IPP_TAG_TEXT, group: IPP_TAG_JOB)
        response.integer("job-impressions-completed", job.pages, group: IPP_TAG_JOB)
        response.integer("job-printer-up-time", Int(Date().timeIntervalSince(started)), group: IPP_TAG_JOB)
    }

    private func enqueue(_ data: Data, job id: Int, response: IPPMessage) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            guard data.starts(with: Data("%PDF-".utf8)) else { throw LabelError("The printer accepts PDF labels.") }
            try data.write(to: file, options: .atomic)
            let pages = try render(file.path, profile: device.profile)
            let labels = (0 ..< (jobs[id]?.copies ?? 1)).flatMap { _ in pages }
            jobs[id]?.state = 3
            jobs[id]?.message = "Queued"
            pending.append((id, labels))
            if !printing {
                printing = true
                Task { await drain() }
            }
        } catch {
            jobs[id]?.state = 8
            jobs[id]?.message = error.localizedDescription
            Logger.bridge.error("Rejected document: \(error.localizedDescription, privacy: .public)")
            response.error(IPP_STATUS_ERROR_DOCUMENT_FORMAT_ERROR, error.localizedDescription)
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let (id, labels) = pending.removeFirst()
            jobs[id]?.state = 5
            jobs[id]?.message = "Printing"
            do {
                loadedTape = try await printer.perform(labels: labels)
                jobs[id]?.state = 9
                jobs[id]?.pages = labels.count
                jobs[id]?.message = "Printed"
            } catch {
                jobs[id]?.state = 8
                jobs[id]?.message = error.localizedDescription
            }
        }
        printing = false
    }
}
