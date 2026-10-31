import SwiftUI
import UIKit

final class ListsViewController: UIViewController {
    enum Kind {
        case lists
        case antennas
        case channels

        var title: String {
            switch self {
            case .lists: "リスト"
            case .antennas: "アンテナ"
            case .channels: "チャンネル"
            }
        }

        var icon: String {
            switch self {
            case .lists: "List"
            case .antennas: "Antenna"
            case .channels: "Channel"
            }
        }

        var identifier: String {
            switch self {
            case .lists: "lists"
            case .antennas: "antennas"
            case .channels: "channels"
            }
        }

        var emptyMessage: String {
            switch self {
            case .lists: "リストはまだありません。\nWeb版で作成できます"
            case .antennas: "アンテナはまだありません。\nWeb版で作成できます"
            case .channels: "フォローやお気に入りのチャンネルはまだありません。\nWeb版で探せます"
            }
        }
    }

    let kind: Kind
    let services: NoteServices
    private let form: UIHostingController<ListsView>

    init(kind: Kind, services: NoteServices) {
        self.kind = kind
        self.services = services
        form = UIHostingController(rootView: ListsView(kind: kind, client: services.client))
        super.init(nibName: nil, bundle: nil)
        form.rootView.onOpen = { [weak self] tab in self?.open(tab) }
        form.rootView.onAuthenticationFailure = { [weak services] in services?.onAuthenticationFailure?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        install(form, title: kind.title, identifier: kind.identifier)
    }

    private func open(_ tab: TimelineTab) {
        navigationController?.pushViewController(ListTimelineViewController(tab: tab, services: services),
                                                 animated: true)
    }
}

struct ListsView: View {
    let kind: ListsViewController.Kind
    let client: MisskeyClient?
    var onOpen: (TimelineTab) -> Void = { _ in }
    var onAuthenticationFailure: () -> Void = {}

    struct Section: Identifiable {
        /// nil for the only one.
        let title: String?
        let tabs: [TimelineTab]

        var id: String { title ?? "" }
    }

    private enum State {
        case loading
        case loaded([Section])
        case failed(String)
    }

    @SwiftUI.State private var state = State.loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let sections) where sections.allSatisfy(\.tabs.isEmpty):
                message(kind.emptyMessage)
            case .loaded(let sections):
                List {
                    ForEach(sections.filter { !$0.tabs.isEmpty }) { section in
                        if let title = section.title {
                            SwiftUI.Section {
                                rows(section)
                            } header: {
                                Text(title)
                            }
                        } else {
                            rows(section)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            case .failed(let error):
                VStack(spacing: 12) {
                    message(error)
                    Button("再試行") {
                        state = .loading
                        Task { await load() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .hibari(.background)))
        .task { await load() }
    }

    private func rows(_ section: Section) -> some View {
        ForEach(section.tabs) { tab in
            Button {
                onOpen(tab)
            } label: {
                Label {
                    Text(tab.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                } icon: {
                    Image(kind.icon)
                        .renderingMode(.template)
                        .foregroundStyle(Color(uiColor: tab.channel?.rgb.map { Palette.RGBA($0).uiColor }
                            ?? .hibari(.primaryText)))
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color(uiColor: .hibari(.background)))
            .listRowSeparatorTint(Color(uiColor: .hibari(.separator)))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private func load() async {
        guard let client else { return }
        do {
            let sections = switch kind {
            case .lists: [Section(title: nil, tabs: try await client.userLists().map { TimelineTab($0) })]
            case .antennas: [Section(title: nil, tabs: try await client.antennas().map { TimelineTab($0) })]
            case .channels: try await channelSections(client)
            }
            state = .loaded(sections)
        } catch {
            if (error as? MisskeyAPIError)?.isAuthenticationFailure == true { onAuthenticationFailure() }
            if case .loaded = state { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした")
        }
    }

    /// The favorites, then the followed ones; one can be in both, as on Misskey's web client.
    private func channelSections(_ client: MisskeyClient) async throws -> [Section] {
        async let favorites = client.favoriteChannels()
        async let followed = client.followedChannels()
        return [Section(title: "お気に入り", tabs: try await favorites.map { TimelineTab($0) }),
                Section(title: "フォロー中", tabs: try await followed.map { TimelineTab($0) })]
    }
}
