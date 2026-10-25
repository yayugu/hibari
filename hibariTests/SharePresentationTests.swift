import Testing
import UIKit
@testable import hibari

/// What the share sheets are set up with, before they are presented: presenting them waits
/// on the system's share service, and on iPhone UIKit moves the popover's anchor.
@Suite("Share sheets")
@MainActor
struct SharePresentationTests {
    @Test func noteSheetIsAnchoredInTheMiddle() throws {
        let services = try TimelineTestSupport.services(client: MisskeyClient(server: TestData.server, token: "T"))
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let note = try #require(Samples.firstNote { !$0.isPureRenote })

        let sheet = try #require(services.shareSheet(for: note, from: view))
        let popover = try #require(sheet.popoverPresentationController)
        #expect(popover.sourceView === view)
        #expect(popover.sourceRect == CGRect(x: 200, y: 400, width: 0, height: 0))
        #expect(popover.permittedArrowDirections == [])
    }

    @Test func mediaSheetIsAnchoredWherePressed() throws {
        let services = try TimelineTestSupport.services()
        let viewer = MediaViewerController(files: [DriveFile(imageURL: "https://media.example/still.png")],
                                          startIndex: 0,
                                          source: MediaViewerSource(target: { _ in nil }, setHidden: { _ in }),
                                          imagePipeline: services.imagePipeline)
        viewer.loadViewIfNeeded()
        let point = CGPoint(x: 100, y: 150)
        // Nothing to share until the image has loaded.
        #expect(viewer.shareSheet(for: viewer.currentPage, at: point) == nil)

        viewer.currentPage.imageView.image = UIImage(systemName: "photo")
        let sheet = try #require(viewer.shareSheet(for: viewer.currentPage, at: point))
        let popover = try #require(sheet.popoverPresentationController)
        #expect(popover.sourceView === viewer.view)
        #expect(popover.sourceRect == CGRect(origin: point, size: .zero))
    }
}
