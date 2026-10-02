import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import hibari

@Suite("Note drafts")
struct NoteDraftTests {
    @Test func parametersCarryOnlyWhatIsSet() {
        let note = NoteDraft(text: "hi", visibility: .followers, fileIDs: ["f1", "f2"], replyID: "r")
        let parameters = note.parameters
        #expect(parameters["text"] as? String == "hi")
        #expect(parameters["visibility"] as? String == "followers")
        #expect(parameters["fileIds"] as? [String] == ["f1", "f2"])
        #expect(parameters["replyId"] as? String == "r")
        #expect(parameters["renoteId"] == nil)

        let renote = NoteDraft(text: "", visibility: .home, renoteID: "n").parameters
        #expect(Set(renote.keys) == ["visibility", "renoteId"])

        let direct = NoteDraft(text: "hi", visibility: .specified, visibleUserIDs: ["u1", "u2"]).parameters
        #expect(direct["visibility"] as? String == "specified")
        #expect(direct["visibleUserIds"] as? [String] == ["u1", "u2"])
        #expect(NoteDraft(text: "hi", visibility: .home, visibleUserIDs: ["u1"]).parameters["visibleUserIds"] == nil)
    }

    @Test func aReplyToADirectNoteGoesToItsUsers() throws {
        #expect(try note(visibility: "specified", userID: "alice", visibleUserIDs: ["me"])
            .directRecipientIDs(excluding: "me") == ["alice"])
        #expect(try note(visibility: "specified", userID: "bob", visibleUserIDs: ["me", "carol", "bob"])
            .directRecipientIDs(excluding: "me") == ["bob", "carol"])
        #expect(try note(visibility: "specified", userID: "me", visibleUserIDs: ["alice"])
            .directRecipientIDs(excluding: "me") == ["alice"])
        let saved = try note(visibility: "specified", userID: "bob", visibleUserIDs: ["me", "carol"])
        let decoded = try MisskeyJSON.decoder().decode(Note.self, from: MisskeyJSON.encoder().encode(saved))
        #expect(decoded.visibleUserIds == ["me", "carol"])
    }

    @Test func lengthIsWhatMisskeyCounts() {
        #expect(NoteText.length("  abc \n") == 3)
        #expect(NoteText.length("日本語") == 3)
        #expect(NoteText.length("😀") == 1)
        #expect(NoteText.length("👍🏽") == 2)
        #expect(NoteText.length(":blobcat:\u{200B}w") == 11)
        #expect(NoteText.length(" \n ") == 0)
    }

    @Test func onlyLinksToNotesOfThisServerAreQuotes() {
        let server = URL(string: "https://misskey.example")!
        #expect(NoteText.linkedNoteID("https://misskey.example/notes/9abc0def12", server: server) == "9abc0def12")
        #expect(NoteText.linkedNoteID(" https://Misskey.example/notes/9abc/ \n", server: server) == "9abc")
        #expect(NoteText.linkedNoteID("https://misskey.example/notes/9abc?x=1#top", server: server) == "9abc")
        #expect(NoteText.linkedNoteID("https://other.example/notes/9abc", server: server) == nil)
        #expect(NoteText.linkedNoteID("見て https://misskey.example/notes/9abc", server: server) == nil)
        #expect(NoteText.linkedNoteID("https://misskey.example/notes/9abc/reactions", server: server) == nil)
        #expect(NoteText.linkedNoteID("https://misskey.example/@alice", server: server) == nil)
        #expect(NoteText.linkedNoteID("https://misskey.example/notes/../admin", server: server) == nil)

        let local = URL(string: "http://localhost:3000")!
        #expect(NoteText.linkedNoteID("http://localhost:3000/notes/a1", server: local) == "a1")
        #expect(NoteText.linkedNoteID("http://localhost/notes/a1", server: local) == nil)
    }

    @Test func visibilityNarrowsToTheTarget() throws {
        #expect(NoteVisibility.public.narrowed(to: .followers) == .followers)
        #expect(NoteVisibility.followers.narrowed(to: .public) == .followers)
        #expect(NoteVisibility.home.narrowed(to: nil) == .home)
        #expect(NoteVisibility.home.isNoWiderThan(.public) && !NoteVisibility.public.isNoWiderThan(.home))
        #expect(NoteVisibility(of: try note(visibility: "home")) == .home)
        #expect(NoteVisibility.public.narrowed(to: NoteVisibility(of: try note(visibility: "specified"))) == .specified)
        #expect(NoteVisibility(of: try note(visibility: "limited")) == nil)
        #expect(!NoteVisibility.pickable.contains(.specified))
    }

    @Test func renotingFollowsMisskeysRules() throws {
        let account = Account(server: TestData.server, me: try JSONDecoder().decode(
            MeDetailed.self, from: JSONSerialization.data(withJSONObject: ["id": "me", "username": "me"])))
        #expect(try note(visibility: "public").canBeRenoted(by: account))
        #expect(try note(visibility: "home").canBeRenoted(by: account))
        #expect(try !note(visibility: "followers").canBeRenoted(by: account))
        #expect(try note(visibility: "followers", userID: "me").canBeRenoted(by: account))
        #expect(try !note(visibility: "specified", userID: "me").canBeRenoted(by: account))
    }

    @Test func recentEmojisAndSettingsArePerAccount() throws {
        let suite = "RecentReactionsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONSerialization.data(withJSONObject: ["id": "r-\(UUID().uuidString)", "username": "r"])
        let account = Account(server: TestData.server, me: try JSONDecoder().decode(MeDetailed.self, from: data))
        let other = Account(server: URL(string: "https://other.example")!, me: account.meForTests)
        let recent = RecentReactions(account: account, defaults: defaults)
        recent.add(":blobcat:")
        recent.add("👍")
        recent.add(":blobcat:")
        #expect(recent.all == [":blobcat:", "👍"])
        #expect(RecentReactions(account: other, defaults: defaults).all.isEmpty)

        #expect(AppSettings.sensitiveMediaKey(for: account) != AppSettings.sensitiveMediaKey(for: other))
        defer {
            for key in [account, other].map(AppSettings.sensitiveMediaKey(for:)) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #expect(AppSettings.sensitiveMedia(for: account) == .hide)
        #expect(AppSettings.sensitiveMedia(for: other) == .hide)
        UserDefaults.standard.set(SensitiveMediaDisplay.show.rawValue, forKey: AppSettings.sensitiveMediaKey(for: account))
        UserDefaults.standard.set(SensitiveMediaDisplay.tap.rawValue, forKey: AppSettings.sensitiveMediaKey(for: other))
        #expect(AppSettings.sensitiveMedia(for: account) == .show)
        #expect(AppSettings.sensitiveMedia(for: other) == .tap)
    }

    private func note(visibility: String, userID: String = "u", visibleUserIDs: [String]? = nil) throws -> Note {
        var object: [String: Any] = [
            "id": "n1", "createdAt": "2026-09-23T15:00:00.000Z", "text": "x", "visibility": visibility,
            "user": ["id": userID, "username": "a"],
        ]
        if let visibleUserIDs { object["visibleUserIds"] = visibleUserIDs }
        return try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private extension Account {
    var meForTests: MeDetailed {
        try! JSONDecoder().decode(MeDetailed.self, from: JSONSerialization.data(withJSONObject: [
            "id": userID, "username": username,
        ]))
    }
}

@Suite("Composer text")
@MainActor
struct ComposeTextViewTests {
    private func textView() -> ComposeTextView {
        let catalog = EmojiCatalog(entries: Samples.emojis.sorted { $0.key < $1.key }.map {
            EmojiCatalog.Entry(name: $0.key, url: $0.value, aliases: [], category: nil)
        })
        let view = ComposeTextView(
            emojis: catalog,
            imagePipeline: ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory()))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        return view
    }

    private func emojis(in view: ComposeTextView) -> [EmojiTextAttachment] {
        var found: [EmojiTextAttachment] = []
        view.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
            if let attachment = value as? EmojiTextAttachment { found.append(attachment) }
        }
        return found
    }

    @Test func codesOfTheServersEmojisBecomeImages() throws {
        let view = textView()
        view.insertPlainText("やあ :blobcat: と :hibari_wide: と :nope:")
        let images = emojis(in: view)
        #expect(images.map(\.name) == ["blobcat", "hibari_wide"])
        let wide = try #require(images.last)
        #expect(abs(wide.bounds.width / wide.bounds.height - 4) < 0.2)
        #expect(view.source == "やあ :blobcat: と :hibari_wide: と :nope:")
        #expect(view.accessibilityValue == view.source)
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        view.copy(nil)
        #expect(UIPasteboard.general.string == view.source)
    }

    @Test func pickedEmojisGoInAtTheCursor() {
        let view = textView()
        view.insertPlainText("ab")
        view.selectedRange = NSRange(location: 1, length: 0)
        view.insertEmoji(":blobcat:")
        view.insertEmoji("🎉")
        #expect(view.source == "a:blobcat:🎉b")
        #expect(view.selectedRange == NSRange(location: 1 + 1 + 2, length: 0))
    }

    @Test func imagesStayEmojisWhateverComesNextToThem() {
        let view = textView()
        view.insertEmoji(":blobcat:")
        view.insertPlainText("w")
        #expect(view.source == ":blobcat:\u{200B}w")
        let afterLink = textView()
        afterLink.insertPlainText("https://example.com")
        afterLink.insertEmoji(":blobcat:")
        #expect(afterLink.source == "https://example.com\u{200B}:blobcat:")
        #expect(MFMParser.parse(afterLink.source).last == .emoji("blobcat"))
    }

    @Test func nothingChangesWhileAnInputMethodComposes() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let view = textView()
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.becomeFirstResponder()
        view.insertPlainText("#タグ ")
        view.setMarkedText(":blobcat:", selectedRange: NSRange(location: 9, length: 0))
        try #require(view.markedTextRange != nil, "no marked text outside a window")
        view.textViewDidChange(view)
        #expect(view.markedTextRange != nil && emojis(in: view).isEmpty)
        view.unmarkText()
        view.textViewDidChange(view)
        #expect(emojis(in: view).map(\.name) == ["blobcat"])
        #expect(view.source == "#タグ :blobcat:")
    }

    @Test func pastedTextCanBeTakenInstead() {
        let view = textView()
        var offered: [String] = []
        view.interceptsInsertion = { text in
            offered.append(text)
            return text.hasPrefix("https://")
        }
        #expect(!view.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0),
                               replacementText: "https://misskey.example/notes/abc"))
        #expect(view.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "あいう"))
        #expect(view.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "h"))
        #expect(offered == ["https://misskey.example/notes/abc", "あいう"])
    }
}

@Suite("Photo uploads")
struct ImageUploadPreparationTests {
    private func image(width: Int, height: Int, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let context = try #require(Bitmap.makeContext(width: width, height: height, opaque: true))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func photosLoseTheirLocationAndAreDrawnUpright() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 139.76, kCGImagePropertyGPSLongitudeRef: "E"]
        let original = try image(width: 400, height: 300, type: .jpeg, properties: [
            kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6,
        ])
        #expect(try properties(of: original)[kCGImagePropertyGPSDictionary] != nil)

        let prepared = try ImageUploadPreparation.prepare(original)
        #expect(prepared.mimeType == "image/jpeg" && prepared.fileExtension == "jpg")
        #expect(prepared.pixelSize == CGSize(width: 300, height: 400))
        let output = try properties(of: prepared.data)
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
        #expect((output[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(output[kCGImagePropertyPixelWidth] as? Int == 300)
    }

    @Test func heicBecomesJPEG() throws {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        try #require(types.contains(UTType.heic.identifier), "HEIC encoding is not available here")
        let prepared = try ImageUploadPreparation.prepare(try image(width: 64, height: 48, type: .heic))
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.pixelSize == CGSize(width: 64, height: 48))
    }

    @Test func largeImagesAreScaledDownToTheLimit() throws {
        let prepared = try ImageUploadPreparation.prepare(try image(width: 5000, height: 1000, type: .png))
        #expect(prepared.mimeType == "image/png")
        #expect(prepared.pixelSize == CGSize(width: 4096, height: 819) || prepared.pixelSize == CGSize(width: 4096, height: 820))
    }

    @Test func smallPNGsAndGIFsGoAsTheyAre() throws {
        let png = try image(width: 120, height: 80, type: .png)
        #expect(try ImageUploadPreparation.prepare(png).data == png)
        let gif = try image(width: 20, height: 20, type: .gif)
        let prepared = try ImageUploadPreparation.prepare(gif)
        #expect(prepared.data == gif && prepared.mimeType == "image/gif")
    }

    @Test func otherDataIsRefused() {
        #expect(throws: ImageUploadPreparation.Failure.self) {
            try ImageUploadPreparation.prepare(Data("not an image".utf8))
        }
    }
}

@Suite("Posting API")
struct PostingAPITests {
    @Test func createNoteSendsTheDraftAndReadsTheNote() async throws {
        let urlSession = StubURLProtocol.session { request, body in
            #expect(request.url?.path == "/api/notes/create")
            #expect(body["i"] as? String == "T")
            #expect(body["text"] as? String == "こんにちは")
            #expect(body["visibility"] as? String == "home")
            #expect(body["fileIds"] as? [String] == ["f1"])
            #expect(body["renoteId"] as? String == "q1")
            return .json(["createdNote": TestData.note(id: "new", text: "こんにちは")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let note = try await client.createNote(NoteDraft(text: "こんにちは", visibility: .home, fileIDs: ["f1"],
                                                         renoteID: "q1"))
        #expect(note.id == "new")
    }

    @Test func uploadsAreMultipartToTheDrive() async throws {
        let urlSession = StubURLProtocol.session { request, _ in
            #expect(request.url?.path == "/api/drive/files/create")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return .json(["id": "f1", "type": "image/jpeg", "name": "IMG_0001.jpg",
                          "properties": ["width": 300, "height": 400], "url": "https://misskey.example/f1.jpg"])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let file = try await client.uploadFile(Data([1, 2, 3]), name: "IMG_0001.jpg", mimeType: "image/jpeg")
        #expect(file.id == "f1" && file.aspectRatio == 0.75)
    }

    @Test func multipartBodies() throws {
        var form = MultipartForm()
        form.add("i", "token")
        form.add("file", data: Data("DATA".utf8), filename: "a\"b.jpg", mimeType: "image/jpeg")
        let body = try #require(String(data: form.body, encoding: .utf8))
        let boundary = form.boundary
        #expect(form.contentType == "multipart/form-data; boundary=\(boundary)")
        #expect(body == "--\(boundary)\r\nContent-Disposition: form-data; name=\"i\"\r\n\r\ntoken\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a%22b.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\nDATA\r\n--\(boundary)--\r\n")
    }
}
