import UIKit

@MainActor
protocol NoteListHost: UIViewController {
    var services: NoteServices { get }
    var collectionView: UICollectionView { get }
    func indexPath(forNote noteID: String) -> IndexPath?
    /// The note shown with the id `noteID` (a timeline item id).
    func item(forNote noteID: String) -> TimelineItem?
    /// Changes the display state of the note `noteID` (a timeline item id) and lays it out
    /// again.
    func updateState(ofNote noteID: String, _ update: (inout NoteDisplayState) -> Void)
}

extension NoteListHost {
    /// Does what tapping `action` on `item` means (nil: the note itself).
    func perform(_ action: NoteTapAction?, on item: TimelineItem, cell: NoteCell?) {
        let outer: Note
        switch item.content {
        case .note(let note):
            outer = note
        case .notification(let notification):
            perform(action, on: notification)
            return
        }
        let note = outer.displayedNote
        func origin(of action: NoteTapAction) -> CGRect? {
            guard let cell, let target = cell.layout?.targets.last(where: { $0.action == action }) else { return nil }
            return cell.convert(target.frame, to: nil)
        }
        switch action {
        case nil:
            services.openNote(outer, from: self)
        case .reply:
            services.replyTapped(note, from: self)
        case .quote:
            if let quoted = note.renote { services.openNote(quoted, from: self) }
        case .media(let media):
            openMedia(media, of: item)
        case .revealSensitive:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updateState(ofNote: item.id) { $0.sensitiveRevealed = true }
        case .toggleCW:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updateState(ofNote: item.id) { $0.cwExpanded.toggle() }
        case .expandText:
            updateState(ofNote: item.id) { $0.textExpanded = true }
        case .reaction(let key):
            services.reactionTapped(key, on: note, origin: origin(of: .reaction(key)))
        case .react:
            services.reactButtonTapped(note, from: self, origin: origin(of: .react))
        case .renote:
            services.renoteTapped(note, from: self)
        case .bookmark:
            services.bookmarkTapped(note)
        case .share:
            services.share(note, from: self)
        case .more:
            break
        case .link(let link):
            services.open(link: link, from: self)
        case .user(let userID):
            if let user = Self.user(userID, in: outer) { services.openUser(user, from: self) }
        }
    }

    private func perform(_ action: NoteTapAction?, on notification: MisskeyNotification) {
        switch action {
        case .user(let userID):
            if let user = notification.users.first(where: { $0.id == userID }) { services.openUser(user, from: self) }
        case nil:
            if let note = notification.subjectNote {
                services.openNote(note, from: self)
            } else if let user = notification.users.first {
                services.openUser(user, from: self)
            }
        default:
            break
        }
    }

    private static func user(_ userID: String, in outer: Note) -> User? {
        let note = outer.displayedNote
        return [outer.user, note.user, note.reply?.user, note.renote?.user].lazy.compactMap { $0 }.first { $0.id == userID }
    }

    func accessibilityActions(for cell: NoteCell) -> [UIAccessibilityCustomAction] {
        guard let noteID = cell.layout?.key.noteID, let item = item(forNote: noteID) else { return [] }
        guard let note = item.note?.displayedNote else {
            return (item.notification?.users ?? []).prefix(5).map { user in
                UIAccessibilityCustomAction(name: "\(user.displayName)のプロフィール") { [weak self] _ in
                    guard let self else { return false }
                    self.services.openUser(user, from: self)
                    return true
                }
            }
        }
        var actions: [UIAccessibilityCustomAction] = []
        if !note.visualFiles.isEmpty {
            actions.append(UIAccessibilityCustomAction(name: "メディアを表示") { [weak self] _ in
                guard let self else { return false }
                self.perform(.media(MediaRef(owner: .note, index: 0)), on: item, cell: self.noteCell(for: noteID))
                return true
            })
        }
        actions.append(UIAccessibilityCustomAction(name: "\(note.user.displayName)のプロフィール") { [weak self] _ in
            guard let self else { return false }
            self.services.openUser(note.user, from: self)
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: "返信") { [weak self] _ in
            guard let self else { return false }
            self.perform(.reply, on: item, cell: self.noteCell(for: noteID))
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: "リノート") { [weak self] _ in
            guard let self else { return false }
            self.perform(.renote, on: item, cell: self.noteCell(for: noteID))
            return true
        })
        actions.append(UIAccessibilityCustomAction(name: Icon.reactButton(for: note).label) { [weak self] _ in
            guard let self else { return false }
            self.perform(.react, on: item, cell: self.noteCell(for: noteID))
            return true
        })
        let bookmark = note.isBookmarked ? "ブックマークから削除" : "ブックマーク"
        actions.append(UIAccessibilityCustomAction(name: bookmark) { [weak self] _ in
            guard let self else { return false }
            self.perform(.bookmark, on: item, cell: self.noteCell(for: noteID))
            return true
        })
        return actions
    }

    func menuElements(for cell: NoteCell) -> [UIMenuElement] {
        guard let noteID = cell.layout?.key.noteID, let note = item(forNote: noteID)?.note?.displayedNote else { return [] }
        return services.menu(for: note, from: self).children
    }

    func noteCell(for noteID: String) -> NoteCell? {
        indexPath(forNote: noteID).flatMap { collectionView.cellForItem(at: $0) as? NoteCell }
    }

    func openMedia(_ media: MediaRef, of item: TimelineItem) {
        guard let note = item.note?.displayedNote, let owner = media.owner == .note ? note : note.renote else { return }
        let files = owner.visualFiles
        guard files.indices.contains(media.index) else { return }
        let noteID = item.id
        let source = MediaViewerSource(
            target: { [weak self] index in
                self?.mediaTarget(noteID: noteID, media: MediaRef(owner: media.owner, index: index))
            },
            setHidden: { [weak self] index in
                self?.setHiddenMedia(index.map { MediaRef(owner: media.owner, index: $0) }, noteID: noteID)
            })
        MediaViewerController.present(files: files, startIndex: media.index, source: source,
                                      imagePipeline: services.imagePipeline, from: self)
    }

    private func mediaTarget(noteID: String, media: MediaRef) -> MediaTransitionTarget? {
        guard let cell = noteCell(for: noteID), let (slot, image) = cell.mediaSlot(media) else { return nil }
        let frame = cell.convert(slot.frame, to: nil)
        let visible = collectionView.convert(collectionView.bounds.inset(by: collectionView.adjustedContentInset), to: nil)
        guard visible.intersects(frame) else { return nil }
        return MediaTransitionTarget(frame: frame, cornerRadius: slot.cornerRadius,
                                     corners: CACornerMask(slot.corners), image: image)
    }

    private func setHiddenMedia(_ media: MediaRef?, noteID: String) {
        for case let cell as NoteCell in collectionView.visibleCells {
            cell.setHiddenMedia(nil, of: noteID)
        }
        noteCell(for: noteID)?.setHiddenMedia(media, of: noteID)
    }
}
