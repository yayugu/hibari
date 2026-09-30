import SwiftUI
import UIKit

final class ReportViewController: UIHostingController<ReportView> {
    init(user: User, note: Note?, noteURL: URL?, client: MisskeyClient, server: String,
         onAuthenticationFailure: @escaping () -> Void) {
        let model = ReportModel(user: user, note: note, noteURL: noteURL, client: client, server: server)
        model.onAuthenticationFailure = onAuthenticationFailure
        super.init(rootView: ReportView(model: model))
        model.onFinish = { [weak self] outcome in
            self?.dismiss(animated: true)
            switch outcome {
            case .sent: Toast.show("通報しました")
            case .closed: break
            }
        }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError() }
}

@MainActor
@Observable
final class ReportModel {
    enum Outcome {
        case sent
        case closed
    }

    let user: User
    let notePreview: String?
    let noteURL: URL?
    let server: String
    var reason = ""
    private(set) var isSending = false
    private(set) var message: String?
    @ObservationIgnored var onFinish: ((Outcome) -> Void)?
    @ObservationIgnored var onAuthenticationFailure: (() -> Void)?
    @ObservationIgnored private let client: MisskeyClient
    @ObservationIgnored private let feedback = UINotificationFeedbackGenerator()

    init(user: User, note: Note?, noteURL: URL?, client: MisskeyClient, server: String) {
        self.user = user
        notePreview = note.map(Self.preview)
        self.noteURL = noteURL
        self.client = client
        self.server = server
    }

    var comment: String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let noteURL else { return reason }
        return "Note: \(noteURL.absoluteString)\n-----\n\(reason)"
    }

    var isTooLong: Bool { comment.unicodeScalars.count > MisskeyClient.maxReportLength }

    var canSend: Bool { !isSending && !comment.isEmpty && !isTooLong }

    func send() {
        guard canSend else { return }
        isSending = true
        message = nil
        let comment = comment
        let userID = user.id
        let client = client
        Task {
            do {
                try await client.report(userID, comment: comment)
                feedback.notificationOccurred(.success)
                onFinish?(.sent)
            } catch {
                isSending = false
                let apiError = error as? MisskeyAPIError
                if apiError?.isAuthenticationFailure == true {
                    onAuthenticationFailure?()
                }
                feedback.notificationOccurred(.error)
                message = switch apiError?.code {
                case "CANNOT_REPORT_THE_ADMIN": "サーバーの管理者は通報できません"
                case "NO_SUCH_USER": "ユーザーが見つかりませんでした"
                default: (error as? LocalizedError)?.errorDescription ?? "送信できませんでした"
                }
            }
        }
    }

    func close() {
        onFinish?(.closed)
    }

    private static func preview(of note: Note) -> String {
        let text = [note.cw, note.text].compactMap { $0 }.first { !$0.isEmpty }
        return text?.replacingOccurrences(of: "\n", with: " ") ?? "添付ファイル"
    }
}

struct ReportView: View {
    @Bindable var model: ReportModel
    @FocusState private var reasonFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("ユーザー", value: model.user.acct)
                    if let preview = model.notePreview {
                        LabeledContent("ノート") {
                            Text(preview).lineLimit(3)
                        }
                    }
                }
                Section {
                    TextField(model.noteURL == nil ? "理由（必須）" : "理由", text: $model.reason, axis: .vertical)
                        .lineLimit(6...)
                        .focused($reasonFocused)
                        .disabled(model.isSending)
                        .accessibilityIdentifier("report.reason")
                } footer: {
                    footer
                }
            }
            .navigationTitle(model.noteURL == nil ? "ユーザーを通報" : "ノートを通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { model.close() }
                        .disabled(model.isSending)
                        .accessibilityIdentifier("report.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        ProgressView()
                    } else {
                        Button("送信") { model.send() }
                            .disabled(!model.canSend)
                            .accessibilityIdentifier("report.send")
                    }
                }
            }
        }
        .interactiveDismissDisabled(!model.reason.isEmpty || model.isSending)
        .onAppear { reasonFocused = true }
    }

    @ViewBuilder
    private var footer: some View {
        if let message = model.message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("report.message")
        } else if model.isTooLong {
            Text("\(MisskeyClient.maxReportLength)文字までです")
                .foregroundStyle(.red)
        } else {
            Text("\(model.server) のモデレーターに送られます")
        }
    }
}
