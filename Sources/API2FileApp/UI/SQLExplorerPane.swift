import SwiftUI
import API2FileCore

struct SQLExplorerPane: View {
    @ObservedObject var appState: AppState
    let initialServiceId: String?

    @State private var selectedServiceId: String?
    @State private var sqlTables: [SQLMirrorTableSummary] = []
    @State private var selectedTableName: String?
    @State private var selectedDescription: SQLMirrorTableDescription?
    @State private var sqlQuery = ""
    @State private var queryResult: SQLMirrorQueryResult?
    @State private var queryError: String?
    @State private var isLoadingTables = false
    @State private var isRunningQuery = false
    @State private var selectedRowID: UUID?

    private var enabledServices: [ServiceInfo] {
        appState.services
            .filter { $0.config.enabled != false }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var selectedService: ServiceInfo? {
        guard let selectedServiceId else { return enabledServices.first }
        return enabledServices.first(where: { $0.serviceId == selectedServiceId }) ?? enabledServices.first
    }

    private var selectedTable: SQLMirrorTableSummary? {
        guard let selectedTableName else { return nil }
        return sqlTables.first(where: { $0.tableName == selectedTableName })
    }

    private var selectedRow: SQLMirrorQueryRow? {
        guard let selectedRowID, let queryResult else { return nil }
        return queryResult.rows.first(where: { $0.id == selectedRowID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                servicePickerRow
                contentCard
            }
            .padding()
        }
        .task {
            if selectedServiceId == nil {
                selectedServiceId = initialServiceId ?? enabledServices.first?.serviceId
            }
            await refreshTables()
        }
        .onChange(of: enabledServices.map(\.serviceId)) { _ in
            Task {
                if selectedServiceId == nil || !enabledServices.contains(where: { $0.serviceId == selectedServiceId }) {
                    selectedServiceId = initialServiceId ?? enabledServices.first?.serviceId
                }
                await refreshTables()
            }
        }
        .onChange(of: selectedServiceId) { _ in
            Task { await refreshTables() }
        }
        .onChange(of: selectedTableName) { _ in
            Task { await loadSelectedTable() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Data Explorer", systemImage: "cylinder.split.1x2")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Browse the local SQLite mirror for any synced service, run read-only SQL, and jump directly to canonical or projection files.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var servicePickerRow: some View {
        HStack(spacing: 10) {
            Picker("Service", selection: $selectedServiceId) {
                ForEach(enabledServices, id: \.serviceId) { service in
                    Text(service.displayName).tag(Optional(service.serviceId))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 260)

            if let selectedService {
                Text(selectedService.serviceId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
            }

            Spacer()

            Button {
                Task { await refreshTables() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    private var contentCard: some View {
        GroupBox {
            if enabledServices.isEmpty {
                emptyState("Connect a service first to build a SQLite mirror.")
            } else if isLoadingTables {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading tables…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else if sqlTables.isEmpty {
                emptyState("No tables found yet for this service. Sync it once and the mirror will appear here.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    tableControls
                    if let selectedDescription {
                        schemaScroller(description: selectedDescription)
                    }
                    queryEditor
                    resultActions
                    if let queryError {
                        Text(queryError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    resultsView
                }
            }
        }
    }

    private var tableControls: some View {
        HStack(spacing: 8) {
            Picker("Table", selection: $selectedTableName) {
                ForEach(sqlTables) { table in
                    Text(table.tableName).tag(Optional(table.tableName))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 240)

            if let selectedTable {
                Text("\(selectedTable.rowCount) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))

                Text(selectedTable.resourceName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Sample Query") {
                resetQueryToSample()
            }
            .controlSize(.small)
        }
    }

    private func schemaScroller(description: SQLMirrorTableDescription) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(description.columns) { column in
                    HStack(spacing: 4) {
                        Text(column.name)
                            .fontWeight(.medium)
                        Text(column.type.isEmpty ? "TEXT" : column.type)
                            .foregroundStyle(.secondary)
                        if column.primaryKey != 0 {
                            Text("pk")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary.opacity(0.7)))
                }
            }
        }
    }

    private var queryEditor: some View {
        TextEditor(text: $sqlQuery)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 120)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.45))
            )
    }

    private var resultActions: some View {
        HStack(spacing: 8) {
            if let selectedRow, let recordId = selectedRow.recordId, let selectedTable, let selectedService {
                Button("Open Canonical") {
                    Task {
                        await openSelectedRecord(
                            serviceId: selectedService.serviceId,
                            resource: selectedTable.resourceName,
                            recordId: recordId,
                            surface: "canonical"
                        )
                    }
                }
                .controlSize(.small)

                Button("Open Projection") {
                    Task {
                        await openSelectedRecord(
                            serviceId: selectedService.serviceId,
                            resource: selectedTable.resourceName,
                            recordId: recordId,
                            surface: "projection"
                        )
                    }
                }
                .controlSize(.small)
            }

            Spacer()

            Button {
                Task { await runQuery() }
            } label: {
                if isRunningQuery {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Run Query", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isRunningQuery || sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if let queryResult {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(queryResult.rowCount) row\(queryResult.rowCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let databasePath = queryResult.databasePath {
                        Text(URL(fileURLWithPath: databasePath).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !queryResult.columns.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(queryResult.columns, id: \.self) { column in
                                    Text(column)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 180, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                }
                            }
                            .background(.bar)

                            Divider()

                            ForEach(queryResult.rows) { row in
                                Button {
                                    selectedRowID = row.id
                                } label: {
                                    HStack(spacing: 0) {
                                        ForEach(queryResult.columns, id: \.self) { column in
                                            Text(row.values[column] ?? "")
                                                .font(.system(size: 11, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .frame(width: 180, alignment: .leading)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 6)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(selectedRowID == row.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text("Query completed with no visible columns.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 360)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
            }
        } else {
            emptyState("Choose a table and run a read-only SQL query.")
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle")
                .font(.title2)
                .foregroundStyle(.quaternary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func refreshTables() async {
        guard let selectedService else {
            sqlTables = []
            selectedTableName = nil
            selectedDescription = nil
            queryResult = nil
            queryError = nil
            selectedRowID = nil
            return
        }

        isLoadingTables = true
        let tables = await appState.listSQLTables(serviceId: selectedService.serviceId)
        isLoadingTables = false
        sqlTables = tables

        if selectedTableName == nil || !tables.contains(where: { $0.tableName == selectedTableName }) {
            selectedTableName = tables.first?.tableName
        } else {
            await loadSelectedTable()
        }

        if tables.isEmpty {
            selectedDescription = nil
            queryResult = nil
            queryError = nil
            selectedRowID = nil
        }
    }

    private func loadSelectedTable() async {
        guard let selectedService, let selectedTable else {
            selectedDescription = nil
            return
        }

        selectedDescription = await appState.describeSQLTable(
            serviceId: selectedService.serviceId,
            table: selectedTable.tableName
        )

        if sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetQueryToSample()
        }
    }

    private func resetQueryToSample() {
        guard let selectedTable else { return }
        let escaped = selectedTable.tableName.replacingOccurrences(of: "\"", with: "\"\"")
        sqlQuery = "SELECT * FROM \"\(escaped)\" LIMIT 25"
    }

    private func runQuery() async {
        guard let selectedService else { return }
        let trimmed = sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queryError = "Enter a read-only SQL query first."
            return
        }

        isRunningQuery = true
        defer { isRunningQuery = false }

        do {
            let result = try await appState.runSQLQuery(serviceId: selectedService.serviceId, query: trimmed)
            queryResult = result
            queryError = nil
            selectedRowID = result.rows.first?.id
        } catch {
            queryResult = nil
            selectedRowID = nil
            queryError = error.localizedDescription
        }
    }

    private func openSelectedRecord(
        serviceId: String,
        resource: String,
        recordId: String,
        surface: String
    ) async {
        do {
            try await appState.openSQLRecordInEditor(
                serviceId: serviceId,
                resource: resource,
                recordId: recordId,
                surface: surface
            )
            queryError = nil
        } catch {
            queryError = error.localizedDescription
        }
    }
}
