import Foundation
import Network

enum HTTPError: Error { case closed }

@MainActor
final class HTTPConnection {
    let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    private func receive() async throws {
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: HTTPError.closed)
                } else {
                    continuation.resume(throwing: LabelError("Empty request."))
                }
            }
        }
        buffer.append(bytes)
    }

    private func line() async throws -> String {
        let separator = Data([13, 10])
        while buffer.range(of: separator) == nil {
            guard buffer.count < 16384 else { throw LabelError("HTTP header is too large.") }
            try await receive()
        }
        let range = buffer.range(of: separator)!
        let text = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return text
    }

    private func read(_ count: Int) async throws -> Data {
        guard (0 ... 64 * 1024 * 1024).contains(count) else { throw LabelError("Print request is too large.") }
        while buffer.count < count {
            try await receive()
        }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    func request() async throws -> (String, Data) {
        let request = try await line()
        guard request.hasPrefix("POST /ipp/print ") || request.hasPrefix("POST /ipp/print/") else { throw LabelError("Expected IPP print request.") }
        let path = String(request.split(separator: " ")[1])
        var headers: [String: String] = [:]
        while true {
            let header = try await line()
            if header.isEmpty {
                break
            }
            let parts = header.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        if headers["expect"]?.lowercased() == "100-continue" {
            try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            var data = Data()
            while true {
                let lengthLine = try await line().split(separator: ";", maxSplits: 1).first
                guard let lengthLine, let count = Int(lengthLine, radix: 16), count >= 0 else { throw LabelError("Invalid HTTP chunk.") }
                if count == 0 {
                    while try await !line().isEmpty {}
                    return (path, data)
                }
                guard data.count + count <= 64 * 1024 * 1024 else { throw LabelError("Print request is too large.") }
                try await data.append(read(count))
                guard try await read(2) == Data([13, 10]) else { throw LabelError("Invalid HTTP chunk ending.") }
            }
        }
        guard let count = headers["content-length"].flatMap(Int.init) else { throw LabelError("Missing request length.") }
        return try await (path, read(count))
    }

    func respond(_ data: Data) async throws {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        try await send(Data(header.utf8) + data)
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
