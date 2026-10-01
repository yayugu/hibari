import Foundation

/// The pages in `docs/app_store/`, published with GitHub Pages, and where to reach the developer.
enum AppLinks {
    static let terms = page("terms.html")
    static let privacy = page("privacy.html")
    static let support = page("support.html")
    static let source = URL(string: "https://github.com/yayugu/hibari").unsafelyUnwrapped
    static let license = URL(string: "https://github.com/yayugu/hibari/blob/main/LICENSE").unsafelyUnwrapped
    static let contactAddress = "hibari@hibari.yayugu.net"
    static let contact = URL(string: "mailto:\(contactAddress)").unsafelyUnwrapped

    private static func page(_ name: String) -> URL {
        URL(string: "https://yayugu.github.io/hibari/app_store/\(name)").unsafelyUnwrapped
    }
}
