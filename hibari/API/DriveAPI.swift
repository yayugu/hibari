import Foundation

extension MisskeyClient {
    /// `drive/files/create` (multipart): a new file in the drive's root. `progress` gets the
    /// share of the body sent so far (0...1), on some background thread.
    func uploadFile(_ data: Data, name: String, mimeType: String,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> DriveFile {
        var form = MultipartForm()
        if let token { form.add("i", token) }
        form.add("name", name)
        form.add("force", "true")
        form.add("file", data: data, filename: name, mimeType: mimeType)

        var request = URLRequest(url: url(for: "drive/files/create"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.body
        let response = try await send(request, delegate: progress.map(UploadProgress.init))
        do {
            return try MisskeyJSON.decoder().decode(DriveFile.self, from: response)
        } catch {
            throw MisskeyAPIError.invalidResponse
        }
    }
}

struct MultipartForm {
    let boundary = "hibari-\(UUID().uuidString)"
    private var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    var body: Data {
        parts + Data("--\(boundary)--\r\n".utf8)
    }

    mutating func add(_ name: String, _ value: String) {
        parts += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n\(value)\r\n".utf8)
    }

    mutating func add(_ name: String, data: Data, filename: String, mimeType: String) {
        parts += Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(Self.quoted(name))\"; filename=\"\(Self.quoted(filename))\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n").utf8)
        parts += data
        parts += Data("\r\n".utf8)
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
