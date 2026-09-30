import Foundation

/// The account's notifications, grouped as Misskey's web client shows them
/// (`i/notifications-grouped`). Every page marks all of them read on the server
/// (`markAsRead`, Misskey's default), so it is only asked for while they are on screen;
/// `didRead` is called after each page. The cursor is the id of the last entry (for a
/// group, Misskey gives the oldest one's).
struct NotificationTimelineSource: TimelineSource {
    let client: MisskeyClient
    let didRead: @Sendable () -> Void

    func page(until cursor: String?, limit: Int) async throws -> TimelinePage {
        var parameters: [String: any Sendable] = ["limit": limit, "markAsRead": true]
        if let cursor { parameters["untilId"] = cursor }
        let data = try await client.data("i/notifications-grouped", parameters)
        let page = try MisskeyJSON.decodeNotifications(from: data)
        didRead()
        var notifications = page.notifications
        var next = page.lastID
        // Misskey groups reactions (and renotes) within a page: a run of them the page cut
        // off would go on as another group in the next one. It waits for that page, which
        // then starts after the entry before it.
        if notifications.count > 1, let last = notifications.last, last.id == page.lastID, last.isGroupable {
            notifications.removeLast()
            next = notifications.last?.id
        }
        return TimelinePage(entries: notifications.map(TimelineEntry.notification), cursor: next)
    }
}

struct UnreadNotificationCount: Decodable, Sendable {
    let hasUnreadNotification: Bool?
    let unreadNotificationsCount: Int?

    /// Servers without the count only say whether there are any.
    var count: Int {
        unreadNotificationsCount ?? (hasUnreadNotification == true ? 1 : 0)
    }
}
