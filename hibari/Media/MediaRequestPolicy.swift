import Foundation

enum MediaRequestPolicy {
    /// Timeline preview of a drive file, or nil when the file has no visual preview.
    static func previewURL(for file: DriveFile) -> String? {
        if file.isImage && !file.isGIF {
            return file.url ?? file.thumbnailUrl
        }
        if file.isImage || file.isVideo {
            return file.thumbnailUrl
        }
        return nil
    }

    /// What the media viewer shows: the full image (animated ones too), or a video's
    /// thumbnail until the video plays.
    static func viewerURL(for file: DriveFile) -> String? {
        if file.isImage { return file.url ?? file.thumbnailUrl }
        if file.isVideo { return file.thumbnailUrl }
        return nil
    }

    static func remoteEmojiURL(_ rawURL: String, mediaProxy: String?) -> String {
        guard let mediaProxy, !rawURL.hasPrefix(mediaProxy + "/") else { return rawURL }
        return "\(mediaProxy)/image.webp?url=\(formEncode(rawURL))&emoji=1"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func formEncode(_ value: String) -> String {
        (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
            .replacingOccurrences(of: "%20", with: "+")
    }
}
