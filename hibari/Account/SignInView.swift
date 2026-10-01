import AuthenticationServices
import SwiftUI
import UIKit

final class SignInViewController: UIHostingController<SignInView> {
    /// Called with the approved account; throwing shows the error on the screen.
    var onSignIn: ((Account, String) throws -> Void)? {
        get { model.onSignIn }
        set { model.onSignIn = newValue }
    }

    private let model: SignInModel

    /// `onClose`: shows a close button (adding an account to the ones signed in).
    init(message: String? = nil, onClose: (() -> Void)? = nil) {
        let model = SignInModel(message: message, onClose: onClose)
        self.model = model
        super.init(rootView: SignInView(model: model))
        model.presentationContextProvider = self
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError() }

    func handleCallback(_ url: URL) {
        model.checkApproval(callback: url)
    }

    func appDidBecomeActive() {
        model.checkApproval(callback: nil)
    }
}

extension SignInViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = view.window { return window }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.lazy.compactMap(\.keyWindow).first ?? ASPresentationAnchor(windowScene: scenes[0])
    }
}

@MainActor
@Observable
final class SignInModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case waiting(MiAuthSession)
        case completing
    }

    var server = AppSettings.signInServer
    /// Asked once, before the first sign-in (and again when the terms change).
    let asksForTerms = !AppSettings.hasAcceptedTerms
    var acceptsTerms = AppSettings.hasAcceptedTerms
    private(set) var phase = Phase.idle
    var message: String?
    @ObservationIgnored var onSignIn: ((Account, String) throws -> Void)?
    @ObservationIgnored let onClose: (() -> Void)?
    @ObservationIgnored private let pending = PendingMiAuthStore()
    @ObservationIgnored weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    @ObservationIgnored private var browser: ASWebAuthenticationSession?
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var callbackArrived = false
    @ObservationIgnored private var browserClosed = false
    @ObservationIgnored private let feedback = UINotificationFeedbackGenerator()

    init(message: String?, onClose: (() -> Void)? = nil) {
        self.message = message
        self.onClose = onClose
        if let session = pending.session {
            phase = .waiting(session)
            server = session.server.host() ?? server
        }
    }

    var canSignIn: Bool {
        phase == .idle && acceptsTerms && ServerAddress.url(from: server) != nil
    }

    var isWorking: Bool {
        phase == .preparing || phase == .completing
    }

    func signIn() {
        guard canSignIn else { return }
        AppSettings.hasAcceptedTerms = true
        phase = .preparing
        message = nil
        Task {
            do {
                let session = try await MiAuthSession.start(server)
                guard phase == .preparing else { return }
                pending.session = session
                phase = .waiting(session)
                openBrowser()
            } catch {
                if phase == .preparing { fail(error) }
            }
        }
    }

    func openBrowser() {
        guard case .waiting(let session) = phase, browser == nil else { return }
        let browser = ASWebAuthenticationSession(url: session.authorizationURL,
                                                 callback: .customScheme(MiAuth.callbackScheme)) { [weak self] url, _ in
            Task { @MainActor in self?.browserDidFinish(session, callback: url) }
        }
        browser.presentationContextProvider = presentationContextProvider
        self.browser = browser
        if !browser.start() {
            self.browser = nil
            cancel()
            fail(SignInError.notApproved)
        }
    }

    private func browserDidFinish(_ session: MiAuthSession, callback: URL?) {
        browser = nil
        guard phase == .waiting(session) else { return }
        if let callback {
            checkApproval(callback: callback)
        } else {
            browserClosed = true
            checkApproval(callback: nil)
        }
    }

    func cancel() {
        closeBrowser()
        pending.session = nil
        phase = .idle
    }

    private func closeBrowser() {
        browser?.cancel()
        browser = nil
    }

    func close() {
        cancel()
        onClose?()
    }

    /// Asks the server whether the waiting session was approved. With a `callback` (the
    /// approval page sent the user back) a "no" is an error; without one it just means
    /// the user has not approved yet, or, once the page was closed, gave up.
    func checkApproval(callback: URL?) {
        guard case .waiting(let session) = phase else { return }
        if let callback {
            guard MiAuth.session(fromCallback: callback) == session.id else { return }
            callbackArrived = true
        }
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            while true {
                let afterCallback = callbackArrived
                let afterClose = browserClosed
                callbackArrived = false
                browserClosed = false
                do {
                    let result = try await session.complete()
                    guard phase == .waiting(session) else { return }
                    if let (account, token) = result {
                        pending.session = nil
                        finish(account, token)
                        return
                    }
                    if afterCallback {
                        pending.session = nil
                        fail(SignInError.notApproved)
                        return
                    }
                    if afterClose {
                        cancel()
                        return
                    }
                    guard callbackArrived || browserClosed else { return }
                } catch {
                    guard phase == .waiting(session) else { return }
                    if afterCallback || callbackArrived { message = Self.describe(error) }
                    if afterClose || browserClosed { cancel() }
                    return
                }
            }
        }
    }

    private func finish(_ account: Account, _ token: String) {
        closeBrowser()
        phase = .completing
        do {
            try onSignIn?(account, token)
            feedback.notificationOccurred(.success)
        } catch {
            fail(SignInError.keychain)
        }
    }

    private func fail(_ error: any Error) {
        phase = .idle
        message = Self.describe(error)
        feedback.notificationOccurred(.error)
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct SignInView: View {
    @Bindable var model: SignInModel
    @FocusState private var serverFocused: Bool

    private var isWaiting: Bool {
        if case .waiting = model.phase { true } else { false }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image("BirdMark")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .accessibilityLabel("Hibari")

                Text("Misskey に\nログイン")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                    .padding(.top, 56)

                Text("サーバー")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
                    .padding(.top, 40)
                serverField

                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                        .accessibilityIdentifier("signIn.message")
                }

                if isWaiting {
                    waitingCard.padding(.top, 28)
                } else {
                    signInButtons.padding(.top, 28)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .animation(.snappy, value: model.phase)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .hibari(.background)))
        .overlay(alignment: .topLeading) {
            if model.onClose != nil {
                Button("キャンセル") { model.close() }
                    .font(.body)
                    .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .padding(.top, 8)
                    .accessibilityIdentifier("signIn.close")
            }
        }
    }

    private var serverField: some View {
        TextField("misskey.io", text: $model.server)
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($serverFocused)
            .onSubmit { model.signIn() }
            .disabled(model.phase != .idle)
            .font(.title3)
            .foregroundStyle(Color(uiColor: model.phase == .idle ? .hibari(.primaryText) : .hibari(.secondaryText)))
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(serverFocused ? Color(uiColor: .hibari(.accent)) : Color(uiColor: .hibari(.border)),
                            lineWidth: serverFocused ? 2 : 1)
            }
            .padding(.top, 8)
            .accessibilityIdentifier("signIn.server")
    }

    private var signInButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.asksForTerms {
                termsAgreement.padding(.bottom, 20)
            }
            Button {
                serverFocused = false
                model.signIn()
            } label: {
                ZStack {
                    Text("ログイン").opacity(model.isWorking ? 0 : 1)
                    if model.isWorking { ProgressView().tint(.white) }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(Capsule().fill(Color(uiColor: .hibari(.accent))))
                .opacity(model.canSignIn || model.isWorking ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!model.canSignIn)
            .accessibilityIdentifier("signIn.button")

            Text("サーバーの許可の画面が開きます。Safari で Misskey にログイン済みなら、そのアカウントを許可するだけです。")
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }

    private static let termsText = (try? AttributedString(markdown:
        "[利用規約](\(AppLinks.terms.absoluteString))と[プライバシーポリシー](\(AppLinks.privacy.absoluteString))に同意します。不適切なコンテンツや迷惑行為は容認されません。"))
        ?? AttributedString("利用規約とプライバシーポリシーに同意します")

    private var termsAgreement: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                model.acceptsTerms.toggle()
            } label: {
                Image(systemName: model.acceptsTerms ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(Color(uiColor: model.acceptsTerms ? .hibari(.accent) : .hibari(.secondaryText)))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)
            .accessibilityLabel("利用規約とプライバシーポリシーに同意する")
            .accessibilityAddTraits(model.acceptsTerms ? .isSelected : [])
            .accessibilityIdentifier("signIn.terms")

            Text(Self.termsText)
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                .tint(Color(uiColor: .hibari(.accent)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var waitingCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 36))
                .foregroundStyle(Color(uiColor: .hibari(.accent)))
                .symbolEffect(.pulse)
            Text("サーバーの画面で Hibari を許可してください")
                .font(.headline)
                .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                .multilineTextAlignment(.center)
            Text("許可するとログインが完了します")
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
                .multilineTextAlignment(.center)
            Button {
                model.openBrowser()
            } label: {
                Text("許可の画面をもう一度開く")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Color(uiColor: .hibari(.primaryText)))
                    .background(Capsule().stroke(Color(uiColor: .hibari(.border))))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .accessibilityIdentifier("signIn.reopen")
            Button("キャンセル") { model.cancel() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
                .accessibilityIdentifier("signIn.cancel")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .hibari(.chipBackground))))
    }
}

final class ConnectingViewController: UIViewController {
    var onRetry: (() -> Void)?
    var onSignOut: (() -> Void)?

    private let account: Account
    private let spinner = UIActivityIndicatorView(style: .large)
    private let stack = UIStackView()
    private let messageLabel = UILabel()

    init(account: Account) {
        self.account = account
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        spinner.color = .hibari(.secondaryText)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        spinner.alpha = 0
        spinner.startAnimating()
        UIView.animate(withDuration: 0.3, delay: 0.6) { self.spinner.alpha = 1 }

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .hibari(.primaryText)
        let retry = UIButton(configuration: .filled(), primaryAction: UIAction(title: "再試行") { [weak self] _ in
            self?.onRetry?()
        })
        retry.configuration?.cornerStyle = .capsule
        retry.configuration?.baseBackgroundColor = .hibari(.accent)
        let signOut = UIButton(configuration: .plain(), primaryAction: UIAction(title: "ログアウト") { [weak self] _ in
            self?.onSignOut?()
        })
        signOut.configuration?.baseForegroundColor = .hibari(.secondaryText)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        [messageLabel, retry, signOut].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    func showError(_ error: any Error) {
        spinner.stopAnimating()
        let reason = (error as? LocalizedError)?.errorDescription ?? "接続できませんでした"
        messageLabel.text = "\(account.host) に接続できませんでした\n\(reason)"
        stack.isHidden = false
    }
}

extension ConnectingViewController: SideDrawerContent {
    var allowsOpeningSideDrawer: Bool { presentedViewController == nil }
}
