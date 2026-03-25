import SwiftUI
import API2FileCore

struct SyncHistoryRow: View {
    let entry: SyncHistoryEntry
    var showServiceName: Bool = true
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 6) {
                Image(systemName: entry.direction == .pull ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(entry.direction == .pull ? .blue : .green)
                    .font(.system(size: 14))
                    .testId("history-direction-\(entry.id)")

                if showServiceName {
                    Text(entry.serviceName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .testId("history-service-\(entry.id)")
                }

                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .testId("history-summary-\(entry.id)")

                Spacer()

                statusBadge
                    .testId("history-status-\(entry.id)")

                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 60, alignment: .trailing)

                if !entry.files.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                        .testId("history-expand-\(entry.id)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !entry.files.isEmpty {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            }
            .testId("history-row-\(entry.id)")

            // Expanded file breakdown
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: fileActionIcon(file.action))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)

                            Text(file.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            if file.recordsCreated + file.recordsUpdated + file.recordsDeleted > 0 {
                                Text(recordSummary(file))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            if let error = file.errorMessage {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        }
    }

    private func fileActionIcon(_ action: FileAction) -> String {
        switch action {
        case .downloaded: return "arrow.down"
        case .uploaded: return "arrow.up"
        case .created: return "plus"
        case .updated: return "pencil"
        case .deleted: return "trash"
        case .conflicted: return "exclamationmark.triangle"
        case .error: return "xmark"
        }
    }

    private func recordSummary(_ file: FileChange) -> String {
        var parts: [String] = []
        if file.recordsCreated > 0 { parts.append("+\(file.recordsCreated)") }
        if file.recordsUpdated > 0 { parts.append("~\(file.recordsUpdated)") }
        if file.recordsDeleted > 0 { parts.append("-\(file.recordsDeleted)") }
        return parts.joined(separator: " ")
    }
}
