import UIKit
@testable import hibari

/// Drives the common timeline controller without windows, gestures or real networking.
@MainActor
enum TimelineTestSupport {
    static func services(client: MisskeyClient? = nil) throws -> NoteServices {
        let account = Account(server: TestData.server, me: try MisskeyJSON.decoder().decode(
            MeDetailed.self, from: JSONSerialization.data(withJSONObject: TestData.me)))
        let session = TimelineSession(timelines: [], engine: Samples.engine(), clock: .live,
                                      account: account, client: client, emojis: EmojiCatalog(entries: []))
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory())
        return NoteServices(session: session, renderer: NoteRenderer(imagePipeline: pipeline), imagePipeline: pipeline)
    }

    static func layout(_ timeline: TimelineViewController) {
        // Consume pending reloads before another request changes the item count:
        // there is no window laying out this test's collection view.
        timeline.collectionView.layoutIfNeeded()
        _ = timeline.collectionView.numberOfItems(inSection: 0)
    }

    static func loadAll(_ timeline: TimelineViewController) async {
        while timeline.hasMorePages {
            layout(timeline)
            await withCheckedContinuation { continuation in
                timeline.loadNextPage {
                    layout(timeline)
                    continuation.resume()
                }
            }
        }
    }

    static func refresh(_ timeline: TimelineViewController, startingOver: Bool = false,
                        keepingPosition: Bool = false) async {
        layout(timeline)
        await withCheckedContinuation { continuation in
            timeline.refresh(startingOver: startingOver, keepingPosition: keepingPosition) {
                layout(timeline)
                continuation.resume()
            }
        }
    }
}
