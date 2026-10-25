import Foundation

/// A tab over the home timelines, in the order of the settings' "タイムラインのタブ".
struct TimelineTab: Codable, Hashable, Sendable {
    /// What the tab lists.
    enum Source: Codable, Hashable, Sendable {
        case timeline(kind: TimelineKind)
        /// With its name when last seen, the title until `reconciled`.
        case list(id: String, name: String)
        case antenna(id: String, name: String)
    }

    var source: Source
    /// Only the notes with files, like the profile's "メディア".
    var mediaOnly: Bool

    init(_ source: Source, mediaOnly: Bool = false) {
        self.source = source
        self.mediaOnly = mediaOnly
    }

    init(_ kind: TimelineKind, mediaOnly: Bool = false) {
        self.init(.timeline(kind: kind), mediaOnly: mediaOnly)
    }

    init(_ list: UserList, mediaOnly: Bool = false) {
        self.init(.list(id: list.id, name: list.name), mediaOnly: mediaOnly)
    }

    init(_ antenna: Antenna, mediaOnly: Bool = false) {
        self.init(.antenna(id: antenna.id, name: antenna.name), mediaOnly: mediaOnly)
    }

    /// Until the settings change them: every timeline, with all of its notes.
    static let defaults = TimelineKind.allCases.map { TimelineTab($0) }

    /// Unique among the tabs. The timeline's too (its saved position, its accessibility
    /// identifier): the kind's own for all of its notes, as before the tabs could change.
    var id: String {
        let id = switch source {
        case .timeline(let kind): kind.rawValue
        case .list(let id, _): "list." + id
        case .antenna(let id, _): "antenna." + id
        }
        return mediaOnly ? id + ".media" : id
    }

    /// In the settings (and read for the tab, which shows the media mark before the
    /// timeline's title instead).
    var title: String {
        mediaOnly ? Self.mediaTitle(timelineTitle) : timelineTitle
    }

    private var timelineTitle: String {
        switch source {
        case .timeline(let kind): kind.title
        case .list(_, let name), .antenna(_, let name): name
        }
    }

    /// The tab of `title`'s notes with files.
    static func mediaTitle(_ title: String) -> String {
        title + "のメディア"
    }

    /// The tabs there are for the timelines the account has (`kinds`): with all of their
    /// notes, then with the ones with files.
    static func choices(of kinds: [TimelineKind]) -> [TimelineTab] {
        choices(kinds.map { .timeline(kind: $0) })
    }

    static func choices(of lists: [UserList]) -> [TimelineTab] {
        choices(lists.map { .list(id: $0.id, name: $0.name) })
    }

    static func choices(of antennas: [Antenna]) -> [TimelineTab] {
        choices(antennas.map { .antenna(id: $0.id, name: $0.name) })
    }

    private static func choices(_ sources: [Source]) -> [TimelineTab] {
        [false, true].flatMap { mediaOnly in sources.map { TimelineTab($0, mediaOnly: mediaOnly) } }
    }

    /// `tabs` without repeats and without the timelines the account does not have
    /// (`kinds`: the server or the account's role may turn some off). Home when none is
    /// left. The lists and antennas stay: they are not known until fetched (`reconciled`).
    static func shown(_ tabs: [TimelineTab], of kinds: [TimelineKind]) -> [TimelineTab] {
        let choices = Set(choices(of: kinds))
        var seen: Set<String> = []
        let shown = tabs.filter { tab in
            let has = switch tab.source {
            case .timeline: choices.contains(tab)
            case .list, .antenna: true
            }
            return has && seen.insert(tab.id).inserted
        }
        return shown.isEmpty ? [TimelineTab(.home)] : shown
    }

    /// `tabs` with the lists' and antennas' current names, without the deleted ones. nil
    /// `lists` or `antennas` (not fetched) leaves their tabs as they are.
    static func reconciled(_ tabs: [TimelineTab], lists: [UserList]?, antennas: [Antenna]?) -> [TimelineTab] {
        let listNames = lists.map { Dictionary($0.map { ($0.id, $0.name) }) { first, _ in first } }
        let antennaNames = antennas.map { Dictionary($0.map { ($0.id, $0.name) }) { first, _ in first } }
        return tabs.compactMap { tab in
            var tab = tab
            switch tab.source {
            case .timeline:
                break
            case .list(let id, _):
                guard let listNames else { break }
                guard let name = listNames[id] else { return nil }
                tab.source = .list(id: id, name: name)
            case .antenna(let id, _):
                guard let antennaNames else { break }
                guard let name = antennaNames[id] else { return nil }
                tab.source = .antenna(id: id, name: name)
            }
            return tab
        }
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
        case .list(let id, _):
            var parameters: [String: any Sendable] = ["listId": id]
            if mediaOnly { parameters["withFiles"] = true }
            source = APITimelineSource(client: client, endpoint: "notes/user-list-timeline", parameters: parameters,
                                       refreshPolicy: .preserveHistory)
        case .antenna(let id, _):
            let all = APITimelineSource(client: client, endpoint: "antennas/notes", parameters: ["antennaId": id],
                                        refreshPolicy: .preserveHistory)
            // `antennas/notes` takes no `withFiles`.
            source = mediaOnly ? NotesWithFilesSource(base: all) : all
        }
        return TimelineSession.Timeline(id: id, title: timelineTitle, source: source, mediaOnly: mediaOnly)
    }
}
