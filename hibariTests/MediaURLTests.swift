import Foundation
import Testing
@testable import hibari

@Suite("Media URLs")
struct MediaURLTests {
    @Test func remoteEmojisGoThroughTheMediaProxy() {
        let url = MediaRequestPolicy.remoteEmojiURL("https://a.example/emoji/猫 1.png", mediaProxy: "https://proxy.example")
        #expect(url == "https://proxy.example/image.webp?url=https%3A%2F%2Fa.example%2Femoji%2F%E7%8C%AB+1.png&emoji=1")
        #expect(MediaRequestPolicy.remoteEmojiURL("https://proxy.example/x", mediaProxy: "https://proxy.example")
            == "https://proxy.example/x")
    }

    @Test func previewPolicy() throws {
        let json = """
        [{"id":"a","type":"image/png","name":"a","isSensitive":false,"properties":{},"url":"U","thumbnailUrl":"T"},
         {"id":"b","type":"image/gif","name":"b","isSensitive":false,"properties":{},"url":"U","thumbnailUrl":"T"},
         {"id":"c","type":"video/mp4","name":"c","isSensitive":false,"properties":{},"url":"U","thumbnailUrl":"T"},
         {"id":"d","type":"audio/mpeg","name":"d","isSensitive":false,"properties":{},"url":"U","thumbnailUrl":null}]
        """
        let files = try MisskeyJSON.decoder().decode([DriveFile].self, from: Data(json.utf8))
        #expect(files.map(MediaRequestPolicy.previewURL(for:)) == ["U", "T", "T", nil])
    }

    @Test func reactionKeys() {
        let resolver = EmojiResolver(localEmojis: ["blobcat": "L"], mediaProxy: "https://p")
        #expect(resolver.reaction("❤", reactionEmojis: [:]) == .unicode("❤"))
        #expect(resolver.reaction(":blobcat@.:", reactionEmojis: [:]) == .custom(name: "blobcat", url: "L"))
        #expect(resolver.reaction(":x@remote.example:", reactionEmojis: ["x@remote.example": "https://r/x.png"])
            == .custom(name: "x", url: "https://p/image.webp?url=https%3A%2F%2Fr%2Fx.png&emoji=1"))
        #expect(resolver.reaction(":gone@remote.example:", reactionEmojis: [:]) == .custom(name: "gone", url: nil))
    }
}
