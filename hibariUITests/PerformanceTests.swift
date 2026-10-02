import XCTest

final class PerformanceTests: XCTestCase {
    private enum Budget {
        static let hitchRatio = value("HIBARI_MAX_HITCH_RATIO", default: 5)
        static let renderLateRatio = value("HIBARI_MAX_RENDER_LATE_RATIO", default: 0.02)
        static let layoutP95Ms = value("HIBARI_MAX_LAYOUT_P95_MS", default: 4)
        static let renderP95Ms = value("HIBARI_MAX_RENDER_P95_MS", default: 8)

        private static func value(_ key: String, default fallback: Double) -> Double {
            ProcessInfo.processInfo.environment[key].flatMap(Double.init) ?? fallback
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    @MainActor
    func testAutoScrollHitches() throws {
        let result = try runBenchmark(["-HibariBenchmark", "scroll", "-HibariClearImageCache", "YES"])
        let frames = try XCTUnwrap(result["frames"] as? [String: Any])
        let ratio = try XCTUnwrap(frames["hitchTimeRatio"] as? Double)
        let displayed = max(1, result["cellsDisplayed"] as? Int ?? 1)
        let renderLate = result["renderLate"] as? Int ?? 0
        XCTAssertLessThan(ratio, Budget.hitchRatio, "hitch time ratio \(ratio) ms/s")
        XCTAssertLessThanOrEqual(Double(renderLate) / Double(displayed), Budget.renderLateRatio,
                                 "\(renderLate) of \(displayed) cells appeared before their blocks were rendered")
    }

    @MainActor
    func testLayoutAndRenderCosts() throws {
        let result = try runBenchmark(["-HibariBenchmark", "layout"])
        let layout = try XCTUnwrap(result["layoutMsPerNote"] as? [String: Double])
        let render = try XCTUnwrap(result["renderWarmMsPerNote"] as? [String: Double])
        XCTAssertLessThan(layout["p95"] ?? .infinity, Budget.layoutP95Ms)
        XCTAssertLessThan(render["p95"] ?? .infinity, Budget.renderP95Ms)
        let requested = try XCTUnwrap(result["mediaRequested"] as? Int)
        let missing = try XCTUnwrap(result["mediaMissing"] as? Int)
        XCTAssertLessThanOrEqual(Double(missing), Double(requested) * 0.02,
                                 "\(missing) of \(requested) requested media are not in the fixture: rerun scripts/fetch_fixtures.py")
    }

    @MainActor
    func testGapFillWhileScrollingUp() throws {
        let result = try runBenchmark(["-HibariBenchmark", "gapfill", "-HibariFixtureHiddenNewest", "200",
                                       "-HibariFixtureLatency", "0.3", "-HibariBenchmarkSpeed", "3000"])
        try checkGapFill(result)
        let frames = try XCTUnwrap(result["frames"] as? [String: Any])
        let ratio = try XCTUnwrap(frames["hitchTimeRatio"] as? Double)
        XCTAssertLessThan(ratio, Budget.hitchRatio, "hitch time ratio \(ratio) ms/s")
    }

    @MainActor
    func testGapFillDuringFlings() throws {
        let app = XCUIApplication()
        let arguments = ["-HibariBenchmark", "gapfill", "-HibariBenchmarkFling", "YES",
                         "-HibariFixtureHiddenNewest", "200", "-HibariFixtureLatency", "0.3"]
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.otherElements["benchmark.ready"].waitForExistence(timeout: 120), "the gap was not set up")
        let timeline = app.collectionViews["timeline.local"]
        let done = app.staticTexts["benchmark.result"]
        for _ in 0..<80 where !done.exists {
            timeline.swipeDown(velocity: .fast)
        }
        let result = try readResult(of: app, arguments: arguments)
        try checkGapFill(result)
        let whileDecelerating = try XCTUnwrap(result["reloadsWhileDecelerating"] as? Int)
        XCTAssertGreaterThan(whileDecelerating, 0, "no notes went in during a fling: nothing was measured")
        XCTAssertEqual(result["interruptedDecelerations"] as? Int, 0, "notes going in stopped a fling")
    }

    private func checkGapFill(_ result: [String: Any]) throws {
        XCTAssertEqual(result["gapsRemaining"] as? Int, 0, "the gap did not close")
        XCTAssertEqual(result["notes"] as? Int, result["expectedNotes"] as? Int, "notes are missing or doubled")
        let jump = try XCTUnwrap(result["maxJumpPoints"] as? Double)
        XCTAssertLessThan(jump, 1, "the note in the middle of the screen moved \(jump) pt as notes went in above")
    }

    @MainActor
    private func runBenchmark(_ arguments: [String]) throws -> [String: Any] {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return try readResult(of: app, arguments: arguments)
    }

    @MainActor
    private func readResult(of app: XCUIApplication, arguments: [String]) throws -> [String: Any] {
        let element = app.staticTexts["benchmark.result"]
        XCTAssertTrue(element.waitForExistence(timeout: 300), "benchmark did not finish")
        let json = try XCTUnwrap(element.value as? String)
        let attachment = XCTAttachment(string: json)
        attachment.name = "benchmark \(arguments.joined(separator: " "))"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("HIBARI_BENCHMARK_RESULT \(json.replacingOccurrences(of: "\n", with: " "))")
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
