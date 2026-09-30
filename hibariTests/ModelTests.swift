import Foundation
import Testing
@testable import hibari

@Suite("Misskey model")
struct ModelTests {
    private func note(_ fields: String) -> String {
        """
        {"id":"n\(UUID().uuidString)","createdAt":"2026-09-23T15:00:00.000Z",
         "user":{"id":"u","username":"a"}\(fields.isEmpty ? "" : ",")\(fields)}
        """
    }

    private func decode(_ notes: [String]) throws -> [Note] {
        try MisskeyJSON.decodeNotes(from: Data("[\(notes.joined(separator: ","))]".utf8))
    }

    @Test func aBrokenNoteDoesNotFailItsPage() throws {
        let notes = try decode([
            note(#""text":"ok""#),
            #"{"id":"broken","user":{"id":"u","username":"a"}}"#,
            #"{"id":1}"#,
            note(#""text":"also ok""#),
        ])
        #expect(notes.map(\.text) == ["ok", "also ok"])
    }

    @Test func malformedOptionalFieldsFallBackToDefaults() throws {
        let notes = try decode([
            note(#""text":"x","reactions":[],"reactionEmojis":[],"renoteCount":"many","poll":{"choices":1}"#),
        ])
        let decoded = try #require(notes.first)
        #expect(decoded.reactions.isEmpty && decoded.reactionEmojis.isEmpty)
        #expect(decoded.renoteCount == 0)
        #expect(decoded.poll == nil)
    }

    @Test func aBrokenFileIsDroppedFromItsNote() throws {
        let notes = try decode([
            note(#""files":[{"id":"f1","type":"image/png","url":"U"},{"type":"image/png"}]"#),
        ])
        #expect(notes.first?.files.map(\.id) == ["f1"])
    }

    @Test func renoteKinds() throws {
        let target = note(#""text":"original""#)
        let notes = try decode([
            note(#""renoteId":"r","renote":\#(target)"#),
            note(#""renoteId":"r","renote":\#(target),"replyId":"p""#),
            note(#""renoteId":"r","renote":\#(target),"text":"quote""#),
            note(#""renoteId":"gone""#),
            note(#""renoteId":"gone","renote":{"id":"broken"}"#),
        ])
        #expect(notes.map(\.isPureRenote) == [true, false, false, false, false])
        #expect(notes.map(\.isUnavailableRenote) == [false, false, false, true, true])
        #expect(notes[0].displayedNote.text == "original")
        #expect(notes[1].displayedNote === notes[1], "a renote that replies is a quote")
    }

    @Test func hidingSensitiveMediaLeavesOutTheNotesShowingIt() throws {
        let sensitive = note(#""text":"s","files":[{"id":"f","type":"image/png","isSensitive":true}]"#)
        let notes = try decode([
            sensitive,
            note(#""renoteId":"r","renote":\#(sensitive)"#),
            note(#""renoteId":"r","renote":\#(sensitive),"text":"quote""#),
            note(#""text":"t","files":[{"id":"g","type":"image/png"}]"#),
        ])
        #expect(notes.map(SensitiveMediaDisplay.hide.shows) == [false, false, false, true])
        #expect(notes.allSatisfy(SensitiveMediaDisplay.tap.shows) && notes.allSatisfy(SensitiveMediaDisplay.show.shows))
    }
}
