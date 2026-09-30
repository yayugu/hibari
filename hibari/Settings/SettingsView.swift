import SwiftUI
import UIKit

final class SettingsViewController: UIViewController {
    private let form: UIHostingController<SettingsView>
    
    init(account: Account) {
        form = UIHostingController(rootView: SettingsView(account: account))
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(form)
        form.view.frame = view.bounds
        form.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(form.view)
        form.didMove(toParent: self)
        NavigationHeaderView(title: "設定", identifier: "settings").install(in: self)
    }
}

struct SettingsView: View {
    let account: Account
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.appearance
    @AppStorage private var sensitiveMedia: SensitiveMediaDisplay
    
    init(account: Account) {
        self.account = account
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
            Text("\(account.acct) の設定です")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .onChange(of: appearance) {
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
        .onChange(of: sensitiveMedia) {
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
    }
}

#Preview {
    SettingsView(account:Account(
        server: URL(string: "http://example.com").unsafelyUnwrapped,
        me: MeDetailed(id: "", username: "user", name: "", avatarUrl: "", policies: nil, followingCount: 0, followersCount: 0)))
}
