import SwiftUI
import UIKit

final class TimelineTabsViewController: UIViewController {
    private let form: UIHostingController<TimelineTabsView>

    init(account: Account, kinds: [TimelineKind]) {
        form = UIHostingController(rootView: TimelineTabsView(account: account, kinds: kinds))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        install(form, title: "タイムラインのタブ", identifier: "timelineTabs")
    }
}

/// The home timelines' tabs: the shown ones to reorder and remove, and the others to add.
/// Every change shows on home at once.
struct TimelineTabsView: View {
    let account: Account
    /// The timelines the account has.
    let kinds: [TimelineKind]
    @State private var tabs: [TimelineTab]

    init(account: Account, kinds: [TimelineKind]) {
        self.account = account
        self.kinds = kinds
        _tabs = State(initialValue: TimelineTab.shown(AppSettings.timelineTabs(for: account), of: kinds))
    }

    var body: some View {
        Form {
            Section {
                ForEach(tabs, id: \.id) { tab in
                    TabTitle(tab: tab)
                        .deleteDisabled(tabs.count == 1)
                }
                .onMove { tabs.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { tabs.remove(atOffsets: $0) }
            } header: {
                Text("表示するタブ")
            }
            if !others.isEmpty {
                Section {
                    // Apart from the shown ones: a row that moves over keeps the look it had
                    // here, without the controls to remove and reorder.
                    ForEach(others, id: \.choiceID) { tab in
                        Button {
                            withAnimation { tabs.append(tab) }
                        } label: {
                            Label {
                                TabTitle(tab: tab)
                            } icon: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.white, .green)
                            }
                        }
                        .accessibilityLabel("\(tab.title)を追加")
                    }
                } header: {
                    Text("追加できるタブ")
                } footer: {
                    Text("「〜のメディア」は、画像や動画などのファイルが付いたノートだけを表示します")
                }
            }
            Section {
                Button("最初の状態に戻す") {
                    withAnimation { tabs = defaults }
                }
                .disabled(tabs == defaults)
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.editMode, .constant(.active))
        .onChange(of: tabs) {
            AppSettings.setTimelineTabs(tabs, for: account)
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
    }

    private var others: [TimelineTab] {
        TimelineTab.choices(of: kinds).filter { !tabs.contains($0) }
    }

    private var defaults: [TimelineTab] {
        TimelineTab.shown(TimelineTab.defaults, of: kinds)
    }
}

/// With the mark the tab has.
private struct TabTitle: View {
    let tab: TimelineTab

    var body: some View {
        // One text, for the separator to start from the mark as from the other titles.
        Group {
            if tab.mediaOnly {
                // Centered on the capitals, as on the tab.
                let height = UIImage(named: "MediaMark")?.size.height ?? 0
                let mark = Text(Image("MediaMark").renderingMode(.template))
                    .baselineOffset((UIFont.preferredFont(forTextStyle: .body).capHeight - height) / 2)
                Text("\(mark) \(tab.title)")
            } else {
                Text(tab.title)
            }
        }
        .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
    }
}

private extension TimelineTab {
    var choiceID: String { "add." + id }
}

#Preview {
    TimelineTabsView(account: Account(
        server: URL(string: "http://example.com").unsafelyUnwrapped,
        me: MeDetailed(id: "", username: "user", name: "", avatarUrl: "", policies: nil, followingCount: 0,
                       followersCount: 0)),
                     kinds: TimelineKind.allCases)
}
