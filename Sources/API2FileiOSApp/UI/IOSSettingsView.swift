import SwiftUI

struct IOSSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var appState: IOSAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IOSHeroCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Sync preferences")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Tune how the iOS client stores files, shows updates, and behaves during background-friendly syncs.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.84))

                        HStack(spacing: 12) {
                            IOSMetricTile(
                                label: "Notifications",
                                value: appState.config.showNotifications ? "On" : "Off",
                                systemImage: "bell.badge.fill"
                            )
                            IOSMetricTile(
                                label: "Auto commit",
                                value: appState.config.gitAutoCommit ? "On" : "Off",
                                systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                            )
                        }
                    }
                }

                IOSSectionTitle(
                    "Preferences",
                    eyebrow: "Settings",
                    detail: "These controls affect the app-wide sync behavior across all connected services."
                )

                VStack(alignment: .leading, spacing: 16) {
                    IOSSectionTitle("Storage", detail: "The sync root stays inside the app's Files container on iPhone and iPad.")

                    Text(appState.syncRootURL.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(IOSTheme.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.sync-folder")
                }
                .iosCardStyle()

                VStack(alignment: .leading, spacing: 16) {
                    IOSSectionTitle("Behavior", detail: "Balance awareness, history, and manual control.")

                    Toggle("Notifications", isOn: Binding(
                        get: { appState.config.showNotifications },
                        set: { appState.setShowNotificationsEnabled($0) }
                    ))
                    .tint(IOSTheme.accent)
                    .accessibilityIdentifier("settings.notifications")

                    Toggle("Auto Commit", isOn: Binding(
                        get: { appState.config.gitAutoCommit },
                        set: { appState.setGitAutoCommitEnabled($0) }
                    ))
                    .tint(IOSTheme.accent)
                    .accessibilityIdentifier("settings.auto-commit")

                    Button("Sync All Now") {
                        Task { await appState.syncAllServices() }
                    }
                    .buttonStyle(IOSProminentButtonStyle())
                    .accessibilityIdentifier("settings.sync-all")
                }
                .iosCardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    IOSSectionTitle("About", detail: "The iOS client uses the same adapter-driven API-to-files model as the desktop app.")

                    Text("Each connected service stores synced resources in the app container, preserving editable files, hidden metadata, and local history so the workflow feels consistent across platforms.")
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                }
                .iosCardStyle()
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .padding(.bottom, IOSTheme.contentBottomInset)
        }
        .accessibilityIdentifier(IOSScreenID.settings)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .iosScreenBackground()
    }
}
