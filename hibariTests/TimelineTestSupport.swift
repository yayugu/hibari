import UIKit
@testable import hibari

/// Drives the common timeline controller without windows, gestures or real networking.
/// Nothing lays its collection view out between changes, as for a list off screen: UIKit
/// takes up its reloads only when an update or a test reads the rows.
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

    static func loadAll(_ timeline: TimelineViewController) async {
        while timeline.hasMorePages {
            await withCheckedContinuation { continuation in
                timeline.loadNextPage { continuation.resume() }
            }
        }
    }

    static func refresh(_ timeline: TimelineViewController, startingOver: Bool = false,
                        keepingPosition: Bool = false) async {
        await withCheckedContinuation { continuation in
            timeline.refresh(startingOver: startingOver, keepingPosition: keepingPosition) { continuation.resume() }
        }
    }
}
