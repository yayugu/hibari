import Foundation

struct TimelineSession {
    struct Timeline {
        let id: String
        let title: String
        let source: any TimelineSource
        var emptyMessage = "まだノートがありません"
        /// Only the notes with files: the tab has the media mark before `title`.
        var mediaOnly = false
        /// The channel the timeline is of: the compose button posts in it. As the tab has it
        /// (only its name and color).
        var channel: Channel?
    }

    /// The home tab's, as the settings had them when the session started.
    let timelines: [Timeline]
    /// The notifications tab's: all of them, the notes that mention the account and the
    /// direct notes to it (as Misskey's web client has them). None for the fixtures of perf
    /// builds.
    var notificationTimelines: [Timeline] = []
    /// The timelines the account has, for the settings' tabs. None for the fixtures of perf
    /// builds.
    var timelineKinds: [TimelineKind] = []
    let engine: NoteLayoutEngine
    let clock: TimelineClock
    let account: Account
    /// The account's API, for everything besides timelines (post screen, reactions). nil
    /// for the fixtures of perf builds.
    let client: MisskeyClient?
    let emojis: EmojiCatalog
    /// The server's limit on a note's text (`/api/meta`); Misskey's default until known.
    var maxNoteTextLength = 3000

    /// An account's timelines on its server. `onMissingPermission`: the server refused a
    /// request for a permission the token lacks. `didReadNotifications`: the server marked
    /// the account's notifications read (they were fetched to show them).
    static func live(account: Account, token: String, resources: ServerResources,
                     onMissingPermission: @escaping @Sendable () -> Void = {},
                     didReadNotifications: @escaping @Sendable () -> Void = {}) -> TimelineSession {
        var client = MisskeyClient(server: account.server, token: token)
        client.onMissingPermission = onMissingPermission
        let kinds = TimelineKind.available(for: account, server: resources.info)
        return TimelineSession(
            timelines: TimelineTab.shown(AppSettings.timelineTabs(for: account), of: kinds).map {
                $0.timeline(client: client)
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
            timelineKinds: kinds,
            engine: NoteLayoutEngine(emojiResolver: resources.emojiResolver(), sizes: ImagePipeline.shared,
                                     linkPreviews: LinkPreviewStore(server: account.server,
                                                                    media: ImagePipeline.shared.source),
                                     server: account.server),
            clock: .live,
            account: account,
            client: client,
            emojis: resources.emojiCatalog(),
            maxNoteTextLength: resources.info.maxNoteTextLength ?? 3000)
    }

    /// The home tab's timelines for the settings' `tabs`, of the ones the account has. nil
    /// for the fixtures of perf builds, which stay as they are.
    func timelines(for tabs: [TimelineTab]) -> [Timeline]? {
        guard let client else { return nil }
        return TimelineTab.shown(tabs, of: timelineKinds).map { $0.timeline(client: client) }
    }
}
