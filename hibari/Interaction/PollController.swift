import Foundation

/// Sends the account's poll votes and keeps every copy of a note on screen in step with
/// them.
///
/// Like `ReactionController`, votes show at once: `didChange` is posted right away
/// (`userInfo["change"]` is the `PollChange`), and the request follows. Votes for one note
/// go out one after another. If one fails, the note is fetched again and its real poll
/// posted.
@MainActor
final class PollController {
    static let didChange = Notification.Name("PollController.didChange")

    private let client: MisskeyClient?
    private var pending: [String: (poll: Poll, count: Int)] = [:]
    private var queues: [String: Task<Void, Never>] = [:]

    init(client: MisskeyClient?) {
        self.client = client
    }

    /// What `note`'s poll shows once pending votes land.
    func poll(of note: Note) -> Poll? {
        pending[note.id]?.poll ?? note.poll
    }

    /// Votes for the choice at `index`. Returns false when that choice does not take the
    /// account's vote (already voted, a single-choice poll voted for, or ended).
    @discardableResult
    func vote(for index: Int, in note: Note, now: Date = Date()) -> Bool {
        guard let before = poll(of: note), before.canVote(for: index, closed: before.isClosed(at: now)) else {
            return false
        }
        let noteID = note.id
        let poll = before.voting(for: index)
        pending[noteID] = (poll, (pending[noteID]?.count ?? 0) + 1)
        post(PollChange(noteID: noteID, poll: poll))
        guard let client else {
            finish(noteID)
            return true
        }
        let previous = queues[noteID]
        queues[noteID] = Task {
            await previous?.value
            do {
                try await client.vote(in: noteID, choice: index)
            } catch {
                await recover(noteID, from: error, client: client)
            }
            finish(noteID)
        }
        return true
    }

    private func recover(_ noteID: String, from error: any Error, client: MisskeyClient) async {
        let apiError = error as? MisskeyAPIError
        if apiError?.code != "ALREADY_VOTED" {
            Toast.show(apiError?.errorDescription ?? "投票できませんでした")
        }
        guard let fresh = try? await client.note(noteID), let poll = fresh.poll else { return }
        if var entry = pending[noteID] {
            entry.poll = poll
            pending[noteID] = entry
        }
        post(PollChange(noteID: noteID, poll: poll))
    }

    private func finish(_ noteID: String) {
        guard let entry = pending[noteID] else { return }
        if entry.count > 1 {
            pending[noteID] = (entry.poll, entry.count - 1)
        } else {
            pending[noteID] = nil
            queues[noteID] = nil
        }
    }

    private func post(_ change: PollChange) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["change": change])
    }
}
