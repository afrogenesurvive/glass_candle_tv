import SwiftUI

/// The scrollable list of unread articles.
///
/// Clicking a row opens the article in the default browser and marks it read.
/// The marking is deliberately optimistic and local: the API call is
/// fire-and-forget, so the list updates instantly rather than waiting on a round
/// trip the user is not looking at.
struct ArticleListView: View {

    let client: FreshRSSClient

    var body: some View {
        Group {
            if !client.isConfigured {
                EmptyState(
                    icon: "key",
                    title: "No API password",
                    detail: "Open Settings and enter the FreshRSS API password."
                )
            } else if client.articles.isEmpty {
                EmptyState(
                    icon: client.status.isConnected ? "checkmark.seal" : "bolt.horizontal.circle",
                    title: client.status.isConnected ? "Nothing unread" : "No data yet",
                    detail: client.status.isConnected
                        ? "You are caught up."
                        : "The list stays empty until a refresh succeeds."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(client.articles) { article in
                            ArticleRow(article: article) {
                                open(article)
                            }
                            if article.id != client.articles.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ article: Article) {
        client.open(article)
        Task { await client.markRead(article) }
    }
}

// MARK: - Row

private struct ArticleRow: View {
    let article: Article
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(article.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Text(article.feedTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if article.published > .distantPast {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(Self.relative(article.published))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(article.url?.absoluteString ?? article.displayTitle)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
