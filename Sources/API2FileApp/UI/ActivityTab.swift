import SwiftUI
import API2FileCore

struct ActivityTab: View {
    @ObservedObject var appState: AppState
    @State private var serviceFilter: String? = nil
    @State private var directionFilter: SyncDirection? = nil
    @State private var allActivity: [SyncHistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 12) {
                // Service filter
                Picker("Service", selection: $serviceFilter) {
                    Text("All Services").tag(nil as String?)
                    ForEach(appState.services, id: \.serviceId) { service in
                        Text(service.displayName).tag(service.serviceId as String?)
                    }
                }
                .frame(maxWidth: 200)
                .testId("activity-service-filter")

                // Direction filter
                Picker("Direction", selection: $directionFilter) {
                    Text("All").tag(nil as SyncDirection?)
                    Text("↓ Pull").tag(SyncDirection.pull as SyncDirection?)
                    Text("↑ Push").tag(SyncDirection.push as SyncDirection?)
                }
                .frame(maxWidth: 120)
                .testId("activity-direction-filter")

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Activity list
            if filteredActivity.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredActivity) { entry in
                            SyncHistoryRow(entry: entry, showServiceName: serviceFilter == nil)
                                .padding(.horizontal)
                                .testId("activity-row-\(entry.id)")
                            Divider()
                                .padding(.leading, 30)
                        }
                    }
                }
                .testId("activity-scroll-view")
            }
        }
        .task {
            await loadActivity()
        }
        .onChange(of: serviceFilter) { _ in
            Task { await loadActivity() }
        }
    }

    private var filteredActivity: [SyncHistoryEntry] {
        var result = allActivity
        if let directionFilter {
            result = result.filter { $0.direction == directionFilter }
        }
        return result
    }

    private func loadActivity() async {
        if let serviceFilter {
            allActivity = await appState.getServiceHistory(serviceId: serviceFilter, limit: 100)
        } else {
            await appState.refreshHistory()
            allActivity = appState.recentActivity
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No sync activity yet")
                .font(.headline)
            Text("Activity will appear here after\nyour first sync operation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .testId("activity-empty-state")
    }
}
