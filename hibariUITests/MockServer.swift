import XCTest

enum MockServer {
    static let url = ProcessInfo.processInfo.environment["HIBARI_MOCK_URL"]
        ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HIBARI_MOCK_URL"]
        ?? ""

    struct NotRunning: LocalizedError {
        var errorDescription: String? {
            "mock server unavailable at \(url); run the UI suite with scripts/test_ui.py"
        }
    }

    static func requireRunning() throws {
        guard !url.isEmpty, let endpoint = URL(string: "\(url)/api/meta") else { throw NotRunning() }
        var request = URLRequest(url: endpoint, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        guard ok else { throw NotRunning() }
    }

    static func postPlainNote() -> String {
        struct Posted: Decodable { let ids: [String] }
        guard let endpoint = URL(string: "\(url)/control/post?n=1&image=1&user=u03") else { return "" }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var id = ""
        URLSession.shared.dataTask(with: endpoint) { data, _, _ in
            id = data.flatMap { try? JSONDecoder().decode(Posted.self, from: $0) }?.ids.first ?? ""
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return id
    }

    static let openingPoint = CGVector(dx: 0.6, dy: 0.15)

    @MainActor
    static func cell(_ noteID: String, in timeline: XCUIElement) -> XCUIElement {
        timeline.cells["note.\(noteID)"]
    }

    static var launchArguments: [String] {
        ["-HibariTestAccounts", "YES", "-HibariSignInServer", url, "-HibariMockAccounts", "main"]
    }
}
