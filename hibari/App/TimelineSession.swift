import Foundation

struct TimelineSession {
    struct Timeline {
        let id: String
        let title: String
        let source: any TimelineSource
        var emptyMessage = "まだノートがありません"
    }

    let timelines: [Timeline]
    /// The notifications tab's: all of them, the notes that mention the account and the
    /// direct notes to it (as Misskey's web client has them). None for the fixtures of perf
    /// builds.
    var notificationTimelines: [Timeline] = []
    let engine: NoteLayoutEngine
    let clock: TimelineClock
    let account: Account
    /// The account's API, for everything besides timelines (post screen, reactions). nil
    /// for the fixtures of perf builds.
    let client: MisskeyClient?
    let emojis: EmojiCatalog
    /// The server's limit on a note's text (`/api/meta`); Misskey's default until known.
    var maxNoteTextLength = 3000

    /// An account's timelines on its server. `didReadNotifications`: the server marked the
    /// account's notifications read (they were fetched to show them).
    static func live(account: Account, token: String, resources: ServerResources,
                     didReadNotifications: @escaping @Sendable () -> Void = {}) -> TimelineSession {
        let client = MisskeyClient(server: account.server, token: token)
        return TimelineSession(
            timelines: TimelineKind.available(for: account, server: resources.info).map { kind in
                Timeline(id: kind.rawValue, title: kind.title,
                         source: APITimelineSource(client: client, endpoint: kind.endpoint))
            },
            notificationTimelines: [
                Timeline(id: "notifications", title: "すべて",
                         source: NotificationTimelineSource(client: client, didRead: didReadNotifications),
                         emptyMessage: "まだ通知がありません"),
                Timeline(id: "mentions", title: "メンション",
                         source: APITimelineSource(client: client, endpoint: "notes/mentions"),
                         emptyMessage: "まだメンションがありません"),
                Timeline(id: "direct", title: "ダイレクト",
                         source: APITimelineSource(client: client, endpoint: "notes/mentions",
                                                   parameters: ["visibility": "specified"]),
                         emptyMessage: "まだダイレクトがありません"),
            ],
            engine: NoteLayoutEngine(emojiResolver: resources.emojiResolver(), sizes: ImagePipeline.shared,
                                     server: account.server),
            clock: .live,
            account: account,
            client: client,
            emojis: resources.emojiCatalog(),
            maxNoteTextLength: resources.info.maxNoteTextLength ?? 3000)
    }
}
