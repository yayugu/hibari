import UIKit

enum AppSettings {
    static let didChange = Notification.Name("AppSettings.didChange")

    private static var defaults: UserDefaults { .standard }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Keeps accounts apart from the usual ones (other UserDefaults keys and Keychain
    /// service): the UI tests sign in to the mock server without touching the accounts
    /// the simulator is used with.
    static var usesTestAccounts: Bool { defaults.bool(forKey: "HibariTestAccounts") }

    /// Signs every account out at launch (UI tests of the sign-in screen). Together with
    /// `usesTestAccounts`, only the test accounts.
    static var signsOutOnLaunch: Bool { defaults.bool(forKey: "HibariSignOut") }

    /// Sets up mock accounts at launch for UI testing without going through Safari.
    /// "main": sets up @hibari_mock as current
    /// "both": sets up @hibari_mock and @hibari_sub (with @hibari_mock as current)
    static var mockAccounts: String? { defaults.string(forKey: "HibariMockAccounts") }

    static var signInServer: String { defaults.string(forKey: "HibariSignInServer") ?? "misskey.io" }

    static var showsPerfHUD: Bool { defaults.bool(forKey: "HibariPerfHUD") }

    /// Drops the processed-image memory/disk caches at launch (cold-cache measurements).
    static var clearImageCacheOnLaunch: Bool { defaults.bool(forKey: "HibariClearImageCache") }

    /// The settings screen's "テーマ", for the whole app (not per account).
    /// `-HibariAppearance dark` sets it for a launch (the settings screen cannot change it
    /// then).
    static var appearance: Appearance {
        defaults.string(forKey: appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    static let appearanceKey = "HibariAppearance"

    /// The settings screen's "センシティブなメディアの表示", per account.
    /// `-HibariSensitiveMedia show` sets it for a launch, for every account (the settings
    /// screen cannot change it then).
    static func sensitiveMedia(for account: Account) -> SensitiveMediaDisplay {
        let launch = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[sensitiveMediaBaseKey] as? String
        let value = launch ?? defaults.string(forKey: sensitiveMediaKey(for: account))
        return value.flatMap(SensitiveMediaDisplay.init(rawValue:)) ?? .hide
    }

    static func sensitiveMediaKey(for account: Account) -> String {
        sensitiveMediaBaseKey + "." + account.id
    }

    private static var sensitiveMediaBaseKey: String {
        usesTestAccounts ? "HibariUITestSensitiveMedia" : "HibariSensitiveMedia"
    }

    /// The composer's photo button attaches this many generated images instead of opening
    /// the photo picker (UI tests, which cannot drive the picker). Debug builds only.
    static var composeSampleImages: Int { defaults.integer(forKey: "HibariComposeSampleImages") }

    static var timelinePageSize: Int {
        let value = defaults.integer(forKey: "HibariTimelinePageSize")
        return value > 0 ? min(value, 100) : 20
    }

    #if PERF

    /// `scroll` or `layout`. See `Benchmark`.
    static var benchmarkMode: String? { defaults.string(forKey: "HibariBenchmark") }

    /// Auto-scroll speed for the scroll benchmark, in points per second.
    static var benchmarkSpeed: Double {
        let value = defaults.double(forKey: "HibariBenchmarkSpeed")
        return value > 0 ? value : 4000
    }

    static var benchmarkTimeline: String? { defaults.string(forKey: "HibariBenchmarkTimeline") }

    static var fixtureHiddenNewest: Int { max(0, defaults.integer(forKey: "HibariFixtureHiddenNewest")) }

    static var benchmarkFlings: Bool { defaults.bool(forKey: "HibariBenchmarkFling") }

    static var fixtureLatency: Duration {
        let seconds = defaults.object(forKey: "HibariFixtureLatency") != nil
            ? defaults.double(forKey: "HibariFixtureLatency")
            : (benchmarkMode == nil ? 0.4 : 0)
        return .milliseconds(Int(max(0, seconds) * 1000))
    }
    #endif
}

enum Appearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "システム"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SensitiveMediaDisplay: String, CaseIterable, Sendable {
    case hide
    case tap
    case show

    var title: String {
        switch self {
        case .hide: "デフォルト"
        case .tap: "Misskey Webと同等"
        case .show: "常に表示する"
        }
    }

    /// Whether `note` shows at all: not under "表示しない" when it (or its quote) has
    /// sensitive media.
    func shows(_ note: Note) -> Bool {
        guard self == .hide else { return true }
        let note = note.displayedNote
        return !(note.files + (note.renote?.files ?? [])).contains(where: \.isSensitive)
    }
}
