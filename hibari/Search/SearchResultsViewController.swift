import UIKit

final class SearchResultsViewController: UIViewController {
    enum Page: Int, CaseIterable {
        case notes
        case users

        var title: String {
            switch self {
            case .notes: "ノート"
            case .users: "ユーザー"
            }
        }
    }

    let services: NoteServices
    private(set) var query: SearchQuery

    private let header = SearchHeaderView(leading: .back, tabs: Page.allCases.map(\.title))
    private var field: SearchField { header.field }
    private var tabStrip: TabStripView { header.tabStrip! }
    private let pager = BackSwipePager()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let pageFeedback = UISelectionFeedbackGenerator()

    private var notes: TimelineViewController?
    private var users: UserListViewController?
    private var makeUsers: (() -> UserListViewController)?
    private(set) var currentPage = Page.notes
    private var generation = 0

    init(query: SearchQuery, services: NoteServices) {
        self.query = query
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "searchResults"

        field.text = query.text
        field.delegate = self
        header.cancelButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.field.text = self.query.text
            self.field.resignFirstResponder()
        }, for: .touchUpInside)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        view.addSubview(pager)

        view.addSubview(header)
        tabStrip.onSelect = { [weak self] index in
            guard let self, let page = Page(rawValue: index) else { return }
            self.select(page, animated: true)
        }

        spinner.color = .hibari(.secondaryText)
        view.addSubview(spinner)
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .hibari(.secondaryText)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "searchResults.message"
        view.addSubview(messageLabel)

        run()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        header.topInset = safe.top
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: header.height)

        let top = header.frame.maxY
        pager.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        pager.contentSize = CGSize(width: bounds.width * CGFloat(Page.allCases.count), height: pager.bounds.height)
        if !pager.isDragging && !pager.isDecelerating {
            pager.contentOffset.x = bounds.width * CGFloat(currentPage.rawValue)
        }
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: safe.bottom, right: 0)
        let pages: [(Page, UIViewController?)] = [(.notes, notes), (.users, users)]
        for (page, controller) in pages {
            controller?.view.frame = CGRect(x: bounds.width * CGFloat(page.rawValue), y: 0, width: bounds.width,
                                            height: pager.bounds.height)
        }
        notes?.contentInsets = insets
        users?.contentInsets = insets

        spinner.center = CGPoint(x: bounds.midX, y: top + 48)
        let width = bounds.width - 48
        let height = messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        messageLabel.frame = CGRect(x: 24, y: top + 48, width: width, height: height)
    }

    private func run() {
        generation += 1
        let generation = self.generation
        removeLists()
        messageLabel.text = nil
        guard let client = services.client, !query.isEmpty else { return }
        guard let from = query.from else {
            installLists(client: client, fromUser: nil)
            return
        }
        spinner.startAnimating()
        Task { [weak self] in
            do {
                let user = try await client.user(username: from.username, host: from.host)
                guard let self, self.generation == generation else { return }
                self.spinner.stopAnimating()
                self.installLists(client: client, fromUser: user)
            } catch {
                guard let self, self.generation == generation else { return }
                self.spinner.stopAnimating()
                self.lookupFailed(error, acct: from.host.map { "@\(from.username)@\($0)" } ?? "@\(from.username)")
            }
        }
    }

    private func lookupFailed(_ error: any Error, acct: String) {
        let apiError = error as? MisskeyAPIError
        let refused = apiError?.isAuthenticationFailure == true
        if refused {
            services.onAuthenticationFailure?()
        }
        switch apiError {
        case .server(let status, _) where (400..<500).contains(status) && !refused:
            messageLabel.text = SearchError.noSuchUser(acct).errorDescription
        default:
            messageLabel.text = apiError?.errorDescription ?? "検索できませんでした"
        }
        view.setNeedsLayout()
    }

    private func installLists(client: MisskeyClient, fromUser: UserDetailed?) {
        let query = self.query
        let search = query.noteSearch(userID: fromUser?.user.id)
        let notes = TimelineViewController(timelineID: "search", source: NoteSearchSource(client: client, search: search),
                                           services: services)
        notes.emptyMessage = "「\(query.text)」に一致するノートはありません"
        notes.onAuthenticationFailure = { [weak self] in self?.services.onAuthenticationFailure?() }
        add(notes)
        self.notes = notes

        let services = self.services
        makeUsers = {
            let source: any UserListSource = if query.keywords.isEmpty, let fromUser {
                FixedUserListSource(list: [fromUser])
            } else {
                UserSearchSource(client: client, query: query.keywords)
            }
            let users = UserListViewController(source: source, services: services)
            users.emptyMessage = "「\(query.keywords)」に一致するユーザーはいません"
            return users
        }
        if currentPage == .users { ensureUsers() }
        updateScrollsToTop()
        view.setNeedsLayout()
    }

    private func ensureUsers() {
        guard users == nil, let makeUsers else { return }
        let users = makeUsers()
        add(users)
        self.users = users
        updateScrollsToTop()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func add(_ child: UIViewController) {
        addChild(child)
        pager.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func removeLists() {
        for child in [notes, users].compactMap({ $0 }) {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        notes = nil
        users = nil
        makeUsers = nil
    }

    func select(_ page: Page, animated: Bool) {
        if page == currentPage, animated {
            scrollToTop()
            return
        }
        if page == .users { ensureUsers() }
        pager.setContentOffset(CGPoint(x: pager.bounds.width * CGFloat(page.rawValue), y: 0), animated: animated)
        if !animated { pageDidSettle() }
    }

    func scrollToTop() {
        switch currentPage {
        case .notes: notes?.scrollToTop(animated: true)
        case .users: users?.scrollToTop(animated: true)
        }
    }

    private func pageDidSettle() {
        let index = Int((pager.contentOffset.x / max(1, pager.bounds.width)).rounded())
        guard let page = Page(rawValue: index), page != currentPage else { return }
        currentPage = page
        updateScrollsToTop()
    }

    private func updateScrollsToTop() {
        notes?.collectionView.scrollsToTop = currentPage == .notes
        users?.scrollView.scrollsToTop = currentPage == .users
    }
}

extension SearchResultsViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        header.setEditing(true, animated: true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        header.setEditing(false, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let query = SearchQuery(textField.text ?? "", server: services.client?.server)
        guard !query.isEmpty else { return false }
        textField.resignFirstResponder()
        textField.text = query.text
        guard query != self.query else { return false }
        self.query = query
        run()
        return false
    }
}

extension SearchResultsViewController: BackSwipeGating {
    var allowsContentBackSwipe: Bool { pager.isAtFirstPage }
}

extension SearchResultsViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        let progress = pager.contentOffset.x / max(1, pager.bounds.width)
        if progress > 0.01 { ensureUsers() }
        let previous = tabStrip.selectedIndex
        tabStrip.setProgress(progress)
        if tabStrip.selectedIndex != previous && pager.isTracking {
            pageFeedback.selectionChanged()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pager { pageDidSettle() }
    }
}
