import Foundation

@MainActor
final class RenoteController {
    static let didChange = Notification.Name("RenoteController.didChange")

    enum State: Equatable {
        case sending
        /// The account's renote, by id.
        case renoted(String)
        case deleting(String)
        /// Taken back (or never made): copies that say otherwise are out of date.
        case notRenoted
    }

    private let accountUserID: String
    private var states: [String: State] = [:]

    init(accountUserID: String) {
        self.accountUserID = accountUserID
    }

    func state(of noteID: String) -> State? {
        states[noteID]
    }

    func isRenoted(_ note: Note) -> Bool {
        switch states[note.id] {
        case .sending, .renoted: true
        case .deleting, .notRenoted: false
        case nil: note.isRenotedByMe
        }
    }

    func isBusy(_ note: Note) -> Bool {
        switch states[note.id] {
        case .sending, .deleting: true
        default: false
        }
    }

    /// Sets the note's state and tells every copy, with `renoteCount` unless nil.
    func set(_ state: State, for noteID: String, renoteCount: Int?) {
        states[noteID] = state
        let isRenoted = switch state {
        case .sending, .renoted: true
        case .deleting, .notRenoted: false
        }
        post(RenoteChange(noteID: noteID, isRenoted: isRenoted, renoteCount: renoteCount))
    }

    /// Remembers the account's renotes among `notes` (pure renotes by the account), for
    /// copies of the renoted notes elsewhere and for taking them back.
    func learn(from notes: some Sequence<Note>) {
        let marks = self.marks
        for note in notes where marks.isAccountsRenote(note) {
            guard let target = note.renote, states[target.id] == nil else { continue }
            states[target.id] = .renoted(note.id)
            post(RenoteChange(noteID: target.id, isRenoted: true, renoteCount: nil))
        }
    }

    var marks: RenoteMarks {
        var marks = RenoteMarks(accountUserID: accountUserID)
        for (noteID, state) in states {
            switch state {
            case .sending, .renoted: marks.renoted.insert(noteID)
            case .deleting, .notRenoted: marks.notRenoted.insert(noteID)
            }
        }
        return marks
    }

    func marked(_ note: Note) -> Note {
        marks.apply(to: note)
    }

    private func post(_ change: RenoteChange) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["change": change])
    }
}

struct RenoteMarks: Sendable {
    let accountUserID: String
    var renoted: Set<String> = []
    var notRenoted: Set<String> = []

    func isAccountsRenote(_ note: Note) -> Bool {
        note.isPureRenote && note.user.host == nil && note.user.id == accountUserID
    }

    /// `note` with the account's renotes marked, in it and the notes it embeds. A pure
    /// renote by the account marks the note it renotes (unless that renote was taken back).
    func apply(to note: Note) -> Note {
        var marked = note
        if isAccountsRenote(note), let target = note.renote, !notRenoted.contains(target.id) {
            marked = marked.applying(RenoteChange(noteID: target.id, isRenoted: true, renoteCount: nil))
        }
        guard !renoted.isEmpty || !notRenoted.isEmpty else { return marked }
        for noteID in note.containedNoteIDs {
            if renoted.contains(noteID) {
                marked = marked.applying(RenoteChange(noteID: noteID, isRenoted: true, renoteCount: nil))
            } else if notRenoted.contains(noteID) {
                marked = marked.applying(RenoteChange(noteID: noteID, isRenoted: false, renoteCount: nil))
            }
        }
        return marked
    }
}
