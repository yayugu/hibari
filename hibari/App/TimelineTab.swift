import Foundation

/// A tab over the home timelines, in the order of the settings' "タイムラインのタブ".
struct TimelineTab: Codable, Hashable, Sendable {
    /// What the tab lists (lists and antennas to come).
    enum Source: Codable, Hashable, Sendable {
        case timeline(kind: TimelineKind)
    }

    var source: Source
    /// Only the notes with files, like the profile's "メディア".
    var mediaOnly: Bool

    init(_ kind: TimelineKind, mediaOnly: Bool = false) {
        source = .timeline(kind: kind)
        self.mediaOnly = mediaOnly
    }

    /// Until the settings change them: every timeline, with all of its notes.
    static let defaults = TimelineKind.allCases.map { TimelineTab($0) }

    /// Unique among the tabs. The timeline's too (its saved position, its accessibility
    /// identifier): the kind's own for all of its notes, as before the tabs could change.
    var id: String {
        switch source {
        case .timeline(let kind): mediaOnly ? kind.rawValue + ".media" : kind.rawValue
        }
    }

    /// In the settings (and read for the tab, which shows the media mark before the
    /// timeline's title instead).
    var title: String {
        mediaOnly ? Self.mediaTitle(timelineTitle) : timelineTitle
    }

    private var timelineTitle: String {
        switch source {
        case .timeline(let kind): kind.title
        }
    }

    /// The tab of `title`'s notes with files.
    static func mediaTitle(_ title: String) -> String {
        title + "のメディア"
    }

    /// The tabs there are for the timelines the account has (`kinds`): with all of their
    /// notes, then with the ones with files.
    static func choices(of kinds: [TimelineKind]) -> [TimelineTab] {
        [false, true].flatMap { mediaOnly in kinds.map { TimelineTab($0, mediaOnly: mediaOnly) } }
    }

    /// `tabs` without repeats and without the timelines the account does not have
    /// (`kinds`: the server or the account's role may turn some off). Home when none is
    /// left.
    static func shown(_ tabs: [TimelineTab], of kinds: [TimelineKind]) -> [TimelineTab] {
        let choices = Set(choices(of: kinds))
        var seen: Set<TimelineTab> = []
        let shown = tabs.filter { choices.contains($0) && seen.insert($0).inserted }
        return shown.isEmpty ? [TimelineTab(.home)] : shown
    }

    func timeline(client: MisskeyClient) -> TimelineSession.Timeline {
        let source: any TimelineSource
        switch self.source {
        case .timeline(let kind):
            let all = APITimelineSource(client: client, endpoint: kind.endpoint)
            if !mediaOnly {
                source = all
            } else if kind == .featured {
                // `notes/featured` takes no `withFiles`.
                source = NotesWithFilesSource(base: all)
            } else {
                source = APITimelineSource(client: client, endpoint: kind.endpoint, parameters: ["withFiles": true])
            }
        }
        return TimelineSession.Timeline(id: id, title: timelineTitle, source: source, mediaOnly: mediaOnly)
    }
}
