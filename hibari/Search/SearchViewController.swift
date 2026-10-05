import UIKit

final class SearchViewController: UIViewController {
    let services: NoteServices
    /// The header's avatar was tapped (opens the side drawer). The tab's root only.
    var onAccountButton: (() -> Void)?

    private let isTabRoot: Bool
    private let initialText: String?
    private let header: SearchHeaderView
    private var field: SearchField { header.field }
    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var pullToRefresh = PullToRefresh(scrollView: tableView)
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var trends: [Trend] = []
    private var trendsLoadedAt: Date?
    private var isLoadingTrends = false
    private var didFocus = false

    private static let trendsLifetime: TimeInterval = 5 * 60

    /// `initialText`: in the field, which is focused (from a profile). Without it, the
    /// tab's root, with the account's avatar.
    init(services: NoteServices, initialText: String? = nil) {
        self.services = services
        self.initialText = initialText
        isTabRoot = initialText == nil
        header = SearchHeaderView(leading: isTabRoot ? .avatar : .back)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)

        field.text = initialText
        field.delegate = self
        header.cancelButton.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() },
                                      for: .touchUpInside)
        if isTabRoot {
            header.leadingButton.addAction(UIAction { [weak self] _ in self?.onAccountButton?() }, for: .touchUpInside)
            update(services.account)
        }

        tableView.backgroundColor = .hibari(.background)
        tableView.separatorColor = .hibari(.separator)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.tableFooterView = UIView()
        tableView.sectionHeaderTopPadding = 0
        tableView.register(TrendCell.self, forCellReuseIdentifier: TrendCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityIdentifier = "search.trends"
        pullToRefresh.onRefresh = { [weak self] in self?.loadTrends() }
        pullToRefresh.onInsetChange = { [weak self] in
            guard let self else { return }
            self.tableView.contentInset.top = self.pullToRefresh.inset
        }
        view.addSubview(tableView)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .hibari(.secondaryText)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true
        messageLabel.accessibilityIdentifier = "search.trendsMessage"
        tableView.addSubview(messageLabel)
        spinner.color = .hibari(.secondaryText)
        tableView.addSubview(spinner)
        view.addSubview(header)

        loadTrends()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let loaded = trendsLoadedAt, Date().timeIntervalSince(loaded) > Self.trendsLifetime { loadTrends() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isTabRoot, !didFocus {
            didFocus = true
            field.becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        header.topInset = safe.top
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: header.height)
        tableView.frame = CGRect(x: 0, y: header.frame.maxY, width: bounds.width,
                                 height: bounds.height - header.frame.maxY)
        tableView.contentInset.bottom = safe.bottom
        tableView.verticalScrollIndicatorInsets.bottom = safe.bottom
        let top = TrendsHeaderView.height + 24
        let width = view.bounds.width - 48
        let height = messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        messageLabel.frame = CGRect(x: 24, y: top, width: width, height: height)
        spinner.center = CGPoint(x: view.bounds.midX, y: top + 12)
    }

    func update(_ account: Account) {
        guard account.id == services.account.id else { return }
        header.leadingButton.accessibilityValue = account.acct
        header.setAvatar(account.avatarUrl)
    }

    func setDrawerProgress(_ progress: CGFloat) {
        header.leadingButton.alpha = 1 - progress
    }

    func focusSearchField() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        field.becomeFirstResponder()
    }

    private func loadTrends() {
        guard let client = services.client, !isLoadingTrends else {
            if !isLoadingTrends { pullToRefresh.endRefreshing() }
            return
        }
        isLoadingTrends = true
        if trends.isEmpty, !pullToRefresh.isRefreshing {
            messageLabel.isHidden = true
            spinner.startAnimating()
        }
        Task { [weak self] in
            do {
                let trends = try await client.trends()
                self?.finishLoadingTrends(.success(trends))
            } catch {
                self?.finishLoadingTrends(.failure(error))
            }
        }
    }

    private func finishLoadingTrends(_ result: Result<[Trend], any Error>) {
        isLoadingTrends = false
        spinner.stopAnimating()
        pullToRefresh.endRefreshing(foundNew: false)
        switch result {
        case .success(let trends):
            trendsLoadedAt = Date()
            self.trends = trends
            messageLabel.text = trends.isEmpty ? "いまトレンドになっているハッシュタグはありません" : nil
        case .failure(let error):
            if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
                services.onAuthenticationFailure?()
            }
            guard trends.isEmpty else {
                Toast.show((error as? LocalizedError)?.errorDescription ?? "トレンドを読み込めませんでした", in: view.window)
                return
            }
            messageLabel.text = "トレンドを読み込めませんでした\n" + ((error as? LocalizedError)?.errorDescription ?? "")
        }
        messageLabel.isHidden = messageLabel.text == nil
        tableView.reloadData()
        view.setNeedsLayout()
    }

    private func search(_ text: String) {
        let query = SearchQuery(text, server: services.client?.server)
        guard !query.isEmpty else { return }
        field.resignFirstResponder()
        services.openSearch(query.text, from: self)
    }
}

extension SearchViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        header.setEditing(true, animated: true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        header.setEditing(false, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        search(textField.text ?? "")
        return false
    }
}

extension SearchViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        trends.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TrendCell.reuseIdentifier, for: indexPath) as! TrendCell
        cell.configure(trends[indexPath.row], rank: indexPath.row + 1)
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        TrendsHeaderView()
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        TrendsHeaderView.height
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        field.resignFirstResponder()
        services.openSearch("#" + trends[indexPath.row].tag, from: self)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pullToRefresh.scrollViewWillBeginDragging(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pullToRefresh.scrollViewDidScroll(scrollView)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh.scrollViewWillEndDragging(scrollView)
    }
}

private final class TrendsHeaderView: UIView {
    static let height: CGFloat = 52

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .hibari(.background)
        label.text = "トレンド"
        label.font = .systemFont(ofSize: 20, weight: .heavy)
        label.textColor = .hibari(.primaryText)
        label.accessibilityTraits = .header
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: UIEdgeInsets(top: 8, left: 16, bottom: 0, right: 16))
    }
}

final class TrendCell: UITableViewCell {
    static let reuseIdentifier = "Trend"

    private let tagLabel = UILabel()
    private let detailLabel = UILabel()
    private let chart = SparklineView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .hibari(.background)
        let selection = UIView()
        selection.backgroundColor = .hibari(.chipBackground)
        selectedBackgroundView = selection

        tagLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .bold))
        detailLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 14))
        for label in [tagLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
        }
        tagLabel.textColor = .hibari(.primaryText)
        detailLabel.textColor = .hibari(.secondaryText)

        let text = UIStackView(arrangedSubviews: [tagLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 6
        for view in [text, chart] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            text.trailingAnchor.constraint(lessThanOrEqualTo: chart.leadingAnchor, constant: -12),
            chart.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chart.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chart.widthAnchor.constraint(equalToConstant: 72),
            chart.heightAnchor.constraint(equalToConstant: 28),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ trend: Trend, rank: Int) {
        tagLabel.text = "#" + trend.tag
        let posting = trend.usersCount > 0 ? "\(trend.usersCount.formatted())人が投稿中" : nil
        detailLabel.text = ["\(rank)", "トレンド", posting].compactMap { $0 }.joined(separator: " · ")
        chart.values = trend.history
        chart.isHidden = trend.usersCount == 0
        accessibilityLabel = ["\(rank)位", "#\(trend.tag)", posting].compactMap { $0 }.joined(separator: "、")
        accessibilityIdentifier = "trend.\(trend.tag)"
    }
}

final class SparklineView: UIView {
    var values: [Int] = [] {
        didSet { setNeedsLayout() }
    }

    private let line = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        line.fillColor = nil
        line.lineWidth = 2
        line.lineCap = .round
        line.lineJoin = .round
        layer.addSublayer(line)
        updateColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateColor() {
        line.strokeColor = UIColor.hibari(.accent).resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = bounds
        line.path = Self.path(values, in: bounds.insetBy(dx: 1, dy: 1))
    }

    nonisolated static func path(_ values: [Int], in rect: CGRect) -> CGPath? {
        guard values.count > 1, rect.width > 0 else { return nil }
        let peak = CGFloat(max(1, values.max() ?? 1))
        let step = rect.width / CGFloat(values.count - 1)
        let path = CGMutablePath()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + step * CGFloat(index), y: rect.maxY - rect.height * CGFloat(value) / peak)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
