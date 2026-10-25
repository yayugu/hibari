import SwiftUI
import UIKit

final class ListsViewController: UIViewController {
    enum Kind {
        case lists
        case antennas

        var title: String {
            switch self {
            case .lists: "リスト"
            case .antennas: "アンテナ"
            }
        }

        var icon: String {
            switch self {
            case .lists: "List"
            case .antennas: "Antenna"
            }
        }

        var emptyMessage: String {
            switch self {
            case .lists: "リストはまだありません。\nWeb版で作成できます"
            case .antennas: "アンテナはまだありません。\nWeb版で作成できます"
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
        install(form, title: kind.title, identifier: kind == .lists ? "lists" : "antennas")
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

    private enum State {
        case loading
        case loaded([TimelineTab])
        case failed(String)
    }

    @SwiftUI.State private var state = State.loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let tabs) where tabs.isEmpty:
                message(kind.emptyMessage)
            case .loaded(let tabs):
                List(tabs, id: \.id) { tab in
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
                                .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color(uiColor: .hibari(.background)))
                    .listRowSeparatorTint(Color(uiColor: .hibari(.separator)))
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
            let tabs = switch kind {
            case .lists: try await client.userLists().map { TimelineTab($0) }
            case .antennas: try await client.antennas().map { TimelineTab($0) }
            }
            state = .loaded(tabs)
        } catch {
            if (error as? MisskeyAPIError)?.isAuthenticationFailure == true { onAuthenticationFailure() }
            if case .loaded = state { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした")
        }
    }
}
