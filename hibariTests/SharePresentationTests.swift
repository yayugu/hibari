import Testing
import UIKit
@testable import hibari

@Suite("Share presentation", .serialized)
@MainActor
struct SharePresentationTests {
    private func window(showing controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    @Test func noteSharingPresentsAndDismisses() async throws {
        let services = try TimelineTestSupport.services(client: MisskeyClient(server: TestData.server, token: "T"))
        let controller = UIViewController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let note = try #require(Samples.firstNote { !$0.isPureRenote })

        services.share(note, from: controller)
        try await Task.sleep(for: .milliseconds(600))
        let sheet = try #require(controller.presentedViewController as? UIActivityViewController)
        #expect(sheet.view.window != nil)
        #expect(sheet.popoverPresentationController?.sourceView?.window === window)
        await withCheckedContinuation { continuation in
            sheet.dismiss(animated: false) { continuation.resume() }
        }
        #expect(controller.presentedViewController == nil)
    }

    @Test func longPressSharesMedia() async throws {
        let services = try TimelineTestSupport.services()
        let viewer = MediaViewerController(files: [DriveFile(imageURL: "https://media.example/still.png")],
                                          startIndex: 0,
                                          source: MediaViewerSource(target: { _ in nil }, setHidden: { _ in }),
                                          imagePipeline: services.imagePipeline)
        let window = try window(showing: viewer)
        defer { window.isHidden = true }
        viewer.currentPage.imageView.image = UIImage(systemName: "photo")
        let point = CGPoint(x: 100, y: 150)
        let gesture = ShareLongPress(point: point)

        viewer.perform(NSSelectorFromString("longPressed:"), with: gesture)
        try await Task.sleep(for: .milliseconds(600))
        let sheet = try #require(viewer.presentedViewController as? UIActivityViewController)
        #expect(sheet.view.window != nil)
        #expect(sheet.popoverPresentationController?.sourceView === viewer.view)
        #expect(sheet.popoverPresentationController?.sourceRect.origin == point)
        await withCheckedContinuation { continuation in
            sheet.dismiss(animated: false) { continuation.resume() }
        }
        #expect(viewer.presentedViewController == nil)
    }
}

private final class ShareLongPress: UILongPressGestureRecognizer {
    let point: CGPoint

    init(point: CGPoint) {
        self.point = point
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { .began }
        set {}
    }

    override func location(in view: UIView?) -> CGPoint { point }
}
