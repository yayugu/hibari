import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import hibari

/// Canned HTTP responses for one `URLSession`. Each session gets its own handler, so tests
/// running in parallel do not see each other's requests.
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status = 200
        var body = Data()
        var contentType = "application/json"

        static func json(_ object: Any, status: Int = 200) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)) ?? Data()
            return Response(status: status, body: body)
        }
    }

    typealias Handler = @Sendable (_ request: URLRequest, _ body: [String: Any]) throws -> Response

    private static let handlers = Locked<[String: Handler]>([:])
    private static let header = "X-Stub-Session"

    /// A session whose requests all go to `handler` (with the JSON body, if any, decoded).
    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [header: id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header),
              let handler = Self.handlers.withLock({ $0[id] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        do {
            let response = try handler(request, body)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": response.contentType])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

enum TestData {
    static let server = URL(string: "https://misskey.example")!

    static func png(width: Int, height: Int) -> Data {
        let context = Bitmap.makeContext(width: width, height: height, opaque: true)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func gif(width: Int, height: Int, frames: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in 0..<frames {
            let context = Bitmap.makeContext(width: width, height: height, opaque: true)!
            let shade = CGFloat(frame) / CGFloat(frames)
            context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: 0.03, kCGImagePropertyGIFUnclampedDelayTime: 0.03,
                ],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static var me: [String: Any] {
        [
            "id": "u1", "username": "alice", "name": "Alice", "avatarUrl": "https://misskey.example/avatar.png",
            "policies": ["ltlAvailable": true, "gtlAvailable": false],
        ]
    }

    static func note(id: String, text: String = "hello") -> [String: Any] {
        ["id": id, "createdAt": "2026-09-23T15:00:00.000Z", "user": ["id": "u", "username": "a"], "text": text]
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hibari-tests-\(UUID().uuidString)")
    }
}

final class Counter: Sendable {
    private let value = Locked(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { $0 += 1; return $0 }
    }

    var count: Int { value.withLock { $0 } }
}
