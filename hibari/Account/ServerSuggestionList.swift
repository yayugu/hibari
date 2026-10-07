import SwiftUI

/// The known servers under the sign-in screen's server field: all of them, most used first,
/// while the field is empty, and those matching what is typed after that.
struct ServerSuggestionList: View {
    let input: String
    let suggestions: KnownServers.Suggestions
    let onSelect: (KnownServer) -> Void

    static let baseRowHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = baseRowHeight
    /// The half row showing at the bottom tells that the list scrolls.
    static let maxRows = 5.5

    /// How many rows high the list is (it scrolls past `maxRows`).
    static func rows(for suggestions: KnownServers.Suggestions) -> Double {
        suggestions.matches.isEmpty ? 1 : min(Double(suggestions.matches.count), maxRows)
    }

    var body: some View {
        let matches = suggestions.matches
        let rows = Self.rows(for: suggestions)
        ScrollView {
            LazyVStack(spacing: 0) {
                if matches.isEmpty {
                    unknownServer
                } else {
                    ForEach(Array(matches.enumerated()), id: \.element.server.domain) { index, match in
                        row(match, isFirst: index == 0)
                    }
                }
            }
        }
        // Back to the top whenever the matches change.
        .id(KnownServers.query(from: input))
        .scrollIndicators(.visible)
        .frame(height: rowHeight * rows)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(uiColor: .hibari(.border)), lineWidth: 1)
        }
        .accessibilityIdentifier("signIn.suggestions")
    }

    private func row(_ match: KnownServers.Match, isFirst: Bool) -> some View {
        let server = match.server
        let selected = server == suggestions.exact
        return Button {
            onSelect(server)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.highlighted(server.name, match.nameRange))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: selected ? .hibari(.accent) : .hibari(.primaryText)))
                Text(Self.highlighted(server.domain, match.domainRange, base: .secondaryText))
                    .font(.footnote)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .background(selected ? Color(uiColor: .hibari(.chipReactedBackground)) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionButtonStyle())
        .overlay(alignment: .top) {
            if !isFirst {
                Color(uiColor: .hibari(.separator)).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("signIn.suggestion.\(server.domain)")
    }

    private var unknownServer: some View {
        var domain = AttributedString(KnownServers.query(from: input))
        domain.foregroundColor = Color(uiColor: .hibari(.primaryText))
        domain.inlinePresentationIntent = .stronglyEmphasized
        return Text(domain + AttributedString("にログインします"))
            .font(.footnote)
            .foregroundStyle(Color(uiColor: .hibari(.secondaryText)))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .accessibilityIdentifier("signIn.unknownServer")
    }

    /// `text` with `range` (what matched the query) in bold and the primary color.
    private static func highlighted(_ text: String, _ range: Range<String.Index>?,
                                    base: ColorRole? = nil) -> AttributedString {
        guard let range else {
            var string = AttributedString(text)
            if let base { string.foregroundColor = Color(uiColor: .hibari(base)) }
            return string
        }
        var before = AttributedString(text[..<range.lowerBound])
        var matched = AttributedString(text[range])
        var after = AttributedString(text[range.upperBound...])
        if let base {
            before.foregroundColor = Color(uiColor: .hibari(base))
            after.foregroundColor = Color(uiColor: .hibari(base))
        }
        matched.inlinePresentationIntent = .stronglyEmphasized
        matched.foregroundColor = Color(uiColor: .hibari(.primaryText))
        return before + matched + after
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .hibari(.chipBackground)) : .clear)
    }
}
