import SwiftUI
import API2FileCore

struct IOSActivityView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var appState: IOSAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IOSHeroCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Sync timeline")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Follow pulls, pushes, conflicts, and errors across every connected service.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))

                        HStack(spacing: 12) {
                            IOSMetricTile(
                                label: "Events",
                                value: "\(appState.history.count)",
                                systemImage: "clock.badge.checkmark"
                            )
                            IOSMetricTile(
                                label: "Conflicts",
                                value: "\(appState.history.filter { $0.status == .conflict }.count)",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                        }
                    }
                }
                .accessibilityIdentifier("activity.hero")

                IOSSectionTitle(
                    appState.history.isEmpty ? "No recent activity" : "Recent activity",
                    eyebrow: "Audit trail",
                    detail: "Every sync operation leaves a readable timeline so you can tell what changed and why."
                )

                if appState.history.isEmpty {
                    IOSEmptyStateCard(
                        title: "No sync activity yet",
                        message: "Once a pull or push runs, the latest events will show up here with files and outcomes.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .accessibilityIdentifier("activity.empty")
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(appState.history) { entry in
                            ActivityCard(entry: entry)
                        }
                    }
                    .accessibilityIdentifier("activity.list")
                }
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .padding(.bottom, IOSTheme.contentBottomInset)
        }
        .accessibilityIdentifier(IOSScreenID.activity)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await appState.refresh()
        }
        .iosScreenBackground()
    }
}

private struct ActivityCard: View {
    let entry: SyncHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(entry.serviceName, systemImage: directionIcon)
                        .font(.headline)
                        .foregroundStyle(IOSTheme.textPrimary)

                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    IOSStatusPill(outcome: entry.status)
                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(IOSTheme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                IOSSecondaryPill(entry.direction.rawValue.capitalized, systemImage: directionIcon)
                IOSSecondaryPill(durationLabel, systemImage: "timer")
                IOSSecondaryPill("\(entry.files.count) file\(entry.files.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
            }

            if let firstFile = entry.files.first {
                Text(firstFile.path)
                    .font(.caption)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .iosCardStyle()
        .accessibilityIdentifier(IOSAccessibility.id("activity", entry.id.uuidString))
    }

    private var directionIcon: String {
        entry.direction == .pull ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
    }

    private var durationLabel: String {
        String(format: "%.1fs", entry.duration)
    }
}
