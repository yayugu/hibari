import SwiftUI
import UIKit

final class SettingsViewController: UIViewController {
    private let form: UIHostingController<SettingsView>
    
    /// `timelineKinds`: the ones the account has, for the tabs (none: the tabs cannot change).
    init(account: Account, timelineKinds: [TimelineKind] = [], onSignOut: @escaping () -> Void = {}) {
        form = UIHostingController(rootView: SettingsView(account: account, onSignOut: onSignOut))
        super.init(nibName: nil, bundle: nil)
        if !timelineKinds.isEmpty {
            form.rootView.onShowTimelineTabs = { [weak self] in
                self?.navigationController?.pushViewController(
                    TimelineTabsViewController(account: account, kinds: timelineKinds), animated: true)
            }
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        install(form, title: "設定", identifier: "settings")
    }
}

extension UIViewController {
    /// `form` over the whole screen, under a bar with `title` and the back button.
    func install(_ form: UIViewController, title: String, identifier: String) {
        addChild(form)
        form.view.frame = view.bounds
        form.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(form.view)
        form.didMove(toParent: self)
        NavigationHeaderView(title: title, identifier: identifier).install(in: self)
    }
}

struct SettingsView: View {
    let account: Account
    var onSignOut: () -> Void = {}
    /// Opens "タイムラインのタブ" (no row without it).
    var onShowTimelineTabs: (() -> Void)?
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.appearance
    @AppStorage private var sensitiveMedia: SensitiveMediaDisplay
    @State private var confirmsSignOut = false
    
    init(account: Account, onSignOut: @escaping () -> Void = {}) {
        self.account = account
        self.onSignOut = onSignOut
        _sensitiveMedia = AppStorage(wrappedValue: AppSettings.sensitiveMedia(for: account),
                                     AppSettings.sensitiveMediaKey(for: account))
    }
    
    var body: some View {
        Form {
            Picker("テーマ", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.inline)
            Picker("ノートの表示", selection: $sensitiveMedia) {
                ForEach(SensitiveMediaDisplay.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.inline)
            if let onShowTimelineTabs {
                Section {
                    Button(action: onShowTimelineTabs) {
                        HStack {
                            Text("タイムラインのタブ").foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.timelineTabs")
                }
            }
            Text("\(account.acct) の設定です")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
            Section("このアプリについて") {
                LabeledContent("バージョン", value: Self.version)
                link("利用規約", AppLinks.terms)
                link("プライバシーポリシー", AppLinks.privacy)
                link("サポート", AppLinks.support)
                link("お問い合わせ", AppLinks.contact, detail: AppLinks.contactAddress)
                link("ソースコード", AppLinks.source, detail: "GitHub")
                link("ライセンス", AppLinks.license, detail: "MIT")
            }
            Section {
                Button("ログアウト", role: .destructive) { confirmsSignOut = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("settings.signOut")
            } footer: {
                Text("\(account.acct) からログアウトします")
            }
        }
        .confirmationDialog("ログアウトしますか？", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("ログアウト", role: .destructive, action: onSignOut)
        } message: {
            Text(account.acct)
        }
        .onChange(of: appearance) {
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
        .onChange(of: sensitiveMedia) {
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
    }
}

extension SettingsView {
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private func link(_ title: String, _ url: URL, detail: String? = nil) -> some View {
        Link(destination: url) {
            HStack {
                Text(title).foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    SettingsView(account:Account(
        server: URL(string: "http://example.com").unsafelyUnwrapped,
        me: MeDetailed(id: "", username: "user", name: "", avatarUrl: "", policies: nil, followingCount: 0, followersCount: 0)))
}
