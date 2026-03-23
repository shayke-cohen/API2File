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
                // Direction icon
                Image(systemName: entry.direction == .pull ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(entry.direction == .pull ? .blue : .green)
                    .font(.caption)

                if showServiceName {
                    Text(entry.serviceName)
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                // Status badge
                statusBadge

                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // Expand toggle (only if there are file details)
                if !entry.files.isEmpty {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

            // Expanded file breakdown
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: fileActionIcon(file.action))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)

                            Text(file.path)
                                .font(.caption2)
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
                .padding(.leading, 22)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
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
