import SwiftUI

/// The panel shown when the menu bar item is clicked.
///
/// Layout, top to bottom: identity header, an error banner when something is
/// wrong, category chips, the article list, and a footer of actions.
///
/// The error banner is deliberately part of the main flow rather than a
/// transient alert: the whole point of this app is to answer "is there anything
/// for me", and "the stack is down" is a legitimate answer to that question.
struct PopoverView: View {

    let client: FreshRSSClient
    let prefs: PrefsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let remedy = client.status.remedy {
                StatusBanner(status: client.status, remedy: remedy, client: client)
                Divider()
            }

            if prefs.useEmbeddedWebView {
                WebViewPane(url: prefs.webUIURL)
            } else {
                CategoryStrip(categories: client.snapshot.categories)
                if !client.snapshot.categories.isEmpty { Divider() }
                ArticleListView(client: client)
            }

            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .task {
            // The scheduler also refreshes, but doing it here means opening the
            // panel always shows current data even if the timer just fired.
            if client.isConfigured { await client.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: CandleIcon.image(size: NSSize(width: 22, height: 22)))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("black_glass_candle")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusDot(status: client.status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        switch client.status {
        case .ok, .refreshing, .idle:
            let unread = client.snapshot.total
            let noun = unread == 1 ? "unread article" : "unread articles"
            return "\(unread) \(noun) · updated \(client.relativeLastRefresh)"
        case .unconfigured:
            return "Not configured yet"
        default:
            return "Last good reading \(client.relativeLastRefresh)"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await client.refresh(manual: true) }
            } label: {
                if client.isManualRefresh {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh now")

            Button {
                client.openWebUI()
            } label: {
                Image(systemName: "safari")
            }
            .help("Open the FreshRSS web interface")

            Button {
                Task { await client.markAllRead() }
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("Mark everything as read")
            .disabled(!client.status.isConnected || client.snapshot.total == 0)

            Spacer()

            BridgeIndicator(state: client.bridge)

            Button {
                client.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Status dot

private struct StatusDot: View {
    let status: ConnectionStatus

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .help(status.label)
    }

    private var colour: Color {
        switch status {
        case .ok:                       return .green
        case .refreshing, .idle:        return .blue
        case .unauthorized, .apiDisabled: return .orange
        case .unreachable, .unconfigured: return .secondary
        }
    }
}

// MARK: - Bridge indicator

private struct BridgeIndicator: View {
    let state: BridgeHealthCheck.State

    var body: some View {
        if state == .notConfigured {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(colour)
                    .frame(width: 6, height: 6)
                Text("bridge")
                    .font(.system(size: 10))
            }
            .help(state.label)
        }
    }

    private var colour: Color {
        switch state {
        case .up:            return .green
        case .down:          return .red
        case .unknown, .notConfigured: return .secondary
        }
    }
}

// MARK: - Error banner

/// Shown when the connection is not healthy. States the problem *and* the fix,
/// because "cannot connect" on its own leaves the user with nothing to do.
private struct StatusBanner: View {
    let status: ConnectionStatus
    let remedy: String
    let client: FreshRSSClient

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(status.label)
                    .font(.system(size: 11, weight: .semibold))
                Text(remedy)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Retry") {
                Task { await client.refresh(manual: true) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }
}

// MARK: - Category strip

private struct CategoryStrip: View {
    let categories: [CategoryCount]

    var body: some View {
        if categories.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories.prefix(12)) { category in
                        HStack(spacing: 4) {
                            Text(category.name)
                                .font(.system(size: 10, weight: .medium))
                            Text("\(category.unread)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.07))
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
        }
    }
}
