import SwiftUI
import UIKit

final class TimelineTabsViewController: UIViewController {
    private let form: UIHostingController<TimelineTabsView>

    init(account: Account, kinds: [TimelineKind], client: MisskeyClient? = nil) {
        form = UIHostingController(rootView: TimelineTabsView(account: account, kinds: kinds, client: client))
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
    let client: MisskeyClient?
    @State private var tabs: [TimelineTab]
    @State private var lists: [UserList]?
    @State private var antennas: [Antenna]?

    init(account: Account, kinds: [TimelineKind], client: MisskeyClient? = nil) {
        self.account = account
        self.kinds = kinds
        self.client = client
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
            additions(TimelineTab.choices(of: kinds), header: "追加できるタブ")
            if let lists {
                additions(TimelineTab.choices(of: lists), header: "追加できるリスト")
            }
            if let antennas {
                additions(TimelineTab.choices(of: antennas), header: "追加できるアンテナ")
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
        .task { await loadListsAndAntennas() }
    }

    @ViewBuilder
    private func additions(_ choices: [TimelineTab], header: String) -> some View {
        let shown = Set(tabs.map(\.id))
        let others = choices.filter { !shown.contains($0.id) }
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
                Text(header)
            }
        }
    }

    private var defaults: [TimelineTab] {
        TimelineTab.shown(TimelineTab.defaults, of: kinds)
    }

    /// Also renames the shown ones and takes out the deleted.
    private func loadListsAndAntennas() async {
        guard let client else { return }
        async let fetchedLists = try? client.userLists()
        async let fetchedAntennas = try? client.antennas()
        let (lists, antennas) = await (fetchedLists, fetchedAntennas)
        withAnimation {
            self.lists = lists
            self.antennas = antennas
            let current = TimelineTab.shown(TimelineTab.reconciled(tabs, lists: lists, antennas: antennas), of: kinds)
            if current != tabs { tabs = current }
        }
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
