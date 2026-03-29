import SwiftUI
import API2FileCore

private struct SQLExplorerSelectedFile: Identifiable, Hashable {
    let url: URL
    let serviceID: String

    var id: String { "\(serviceID):\(url.path)" }
}

struct IOSDataExplorerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var appState: IOSAppState

    @State private var sqlTables: [SQLMirrorTableSummary] = []
    @State private var selectedTableName: String?
    @State private var selectedDescription: SQLMirrorTableDescription?
    @State private var sqlQuery = ""
    @State private var queryResult: SQLMirrorQueryResult?
    @State private var queryError: String?
    @State private var isLoadingTables = false
    @State private var isRunningQuery = false
    @State private var selectedRowID: UUID?
    @State private var selectedFile: SQLExplorerSelectedFile?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task {
            if appState.selectedServiceID == nil {
                appState.selectedServiceID = displayedServices.first?.serviceId
            }
            await refreshTables()
        }
        .onChange(of: displayedServices.map(\.serviceId)) { _ in
            Task {
                if appState.selectedServiceID == nil || !displayedServices.contains(where: { $0.serviceId == appState.selectedServiceID }) {
                    appState.selectedServiceID = displayedServices.first?.serviceId
                }
                await refreshTables()
            }
        }
        .onChange(of: appState.selectedServiceID) { _, _ in
            Task { await refreshTables() }
        }
        .onChange(of: selectedTableName) { _, _ in
            Task { await loadSelectedTable() }
        }
    }

    private var displayedServices: [ServiceInfo] {
        appState.services.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var currentService: ServiceInfo? {
        guard let selectedServiceID = appState.selectedServiceID else { return displayedServices.first }
        return displayedServices.first(where: { $0.serviceId == selectedServiceID }) ?? displayedServices.first
    }

    private var currentTable: SQLMirrorTableSummary? {
        guard let selectedTableName else { return nil }
        return sqlTables.first(where: { $0.tableName == selectedTableName })
    }

    private var selectedRow: SQLMirrorQueryRow? {
        guard let selectedRowID, let queryResult else { return nil }
        return queryResult.rows.first(where: { $0.id == selectedRowID })
    }

    private var compactLayout: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    servicePickerCard
                    tablesCard
                    explorerCard
                }
                .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
                .padding(.top, IOSTheme.contentTopInset)
                .padding(.bottom, IOSTheme.contentBottomInset)
            }
            .navigationTitle("Data Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedFile) { file in
                if let service = displayedServices.first(where: { $0.serviceId == file.serviceID }) {
                    IOSFileDetailView(
                        service: service,
                        serviceDir: appState.syncRootURL.appendingPathComponent(service.serviceId, isDirectory: true),
                        fileURL: file.url,
                        onOpenFile: { nextURL in
                            selectedFile = SQLExplorerSelectedFile(url: nextURL, serviceID: file.serviceID)
                        },
                        onSave: { url in
                            Task { await appState.markFileChanged(serviceID: file.serviceID, fileURL: url) }
                        }
                    )
                }
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                servicePickerCard
                tablesSidebar
            }
            .padding(.horizontal, IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .navigationTitle("Data")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    explorerCard
                }
                .padding(.horizontal, IOSTheme.regularHorizontalInset)
                .padding(.top, IOSTheme.contentTopInset)
                .padding(.bottom, IOSTheme.contentBottomInset)
            }
            .navigationTitle(currentService?.displayName ?? "Data Explorer")
        } detail: {
            detailPane
        }
    }

    private var heroCard: some View {
        IOSHeroCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local SQL mirror")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .tracking(1.2)

                Text(currentService.map { "Explore \($0.displayName)" } ?? "Explore synced data")
                    .font(horizontalSizeClass == .compact ? .title3.weight(.bold) : .title2.weight(.bold))
                    .foregroundStyle(.white)

                Text(currentService.map {
                    "\($0.serviceId) · browse read-only SQL over the local mirror and jump back to the real files."
                } ?? "Choose a service to inspect its local SQLite mirror.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))

                HStack(spacing: 10) {
                    IOSSecondaryPill("\(sqlTables.count) tables", systemImage: "tablecells")
                    if let queryResult {
                        IOSSecondaryPill("\(queryResult.rowCount) result row\(queryResult.rowCount == 1 ? "" : "s")", systemImage: "list.bullet.rectangle")
                    } else if let currentTable {
                        IOSSecondaryPill("\(currentTable.rowCount) mirrored row\(currentTable.rowCount == 1 ? "" : "s")", systemImage: "number")
                    }
                    if let currentService {
                        IOSSecondaryPill(currentService.status == .paused ? "Paused" : "Ready", systemImage: currentService.status == .paused ? "pause.circle" : "checkmark.circle")
                    }
                }
            }
        }
        .accessibilityIdentifier("data-explorer.hero")
    }

    private var servicePickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IOSSectionTitle("Service", eyebrow: "Context", detail: "The Data Explorer follows the same selected service as the rest of the app.")

            if displayedServices.isEmpty {
                Text("Connect a service first to build a local mirror.")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
            } else {
                Picker("Service", selection: $appState.selectedServiceID) {
                    ForEach(displayedServices, id: \.serviceId) { service in
                        Text(service.displayName).tag(Optional(service.serviceId))
                    }
                }
                .pickerStyle(.menu)
                .tint(IOSTheme.accent)
                .accessibilityIdentifier("data-explorer.service-picker")
            }
        }
        .iosCardStyle()
    }

    private var tablesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IOSSectionTitle("Tables", detail: "Mirrored resources available for SQL browsing.")
                Spacer(minLength: 12)
                Button {
                    Task { await refreshTables() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IOSTheme.accent)
                .accessibilityIdentifier("data-explorer.refresh")
            }

            if isLoadingTables {
                ProgressView("Loading tables…")
                    .tint(IOSTheme.accent)
            } else if sqlTables.isEmpty {
                Text("No tables yet. Sync this service once and the mirror will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
            } else {
                List(sqlTables, selection: $selectedTableName) { table in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(table.tableName)
                            .font(.headline)
                        Text("\(table.rowCount) rows · \(table.resourceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(table.tableName))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("data-explorer.tables-list")
            }
        }
    }

    private var tablesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IOSSectionTitle("Tables", eyebrow: "Mirror", detail: "Choose a mirrored table before running a query.")
                Spacer(minLength: 12)
                Button {
                    Task { await refreshTables() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .foregroundStyle(IOSTheme.accent)
                .accessibilityIdentifier("data-explorer.refresh")
            }

            if isLoadingTables {
                ProgressView("Loading tables…")
                    .tint(IOSTheme.accent)
            } else if sqlTables.isEmpty {
                Text("No tables found yet for this service.")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
            } else {
                Picker("Table", selection: $selectedTableName) {
                    ForEach(sqlTables) { table in
                        Text(table.tableName).tag(Optional(table.tableName))
                    }
                }
                .pickerStyle(.menu)
                .tint(IOSTheme.accent)
                .accessibilityIdentifier("data-explorer.table-picker")
            }
        }
        .iosCardStyle()
    }

    private var explorerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSSectionTitle(
                currentTable == nil ? "Read-only query" : "Read-only query for \(currentTable?.tableName ?? "")",
                eyebrow: "SQL",
                detail: "Run safe local SQL against the mirrored data, then open canonical or projection files from a row."
            )

            if let description = selectedDescription {
                schemaScroller(description: description)
            }

            queryEditor

            HStack(spacing: 10) {
                Button("Sample Query") {
                    resetQueryToSample()
                }
                .buttonStyle(IOSOutlineButtonStyle())
                .disabled(currentTable == nil)
                .accessibilityIdentifier("data-explorer.sample-query")

                Spacer(minLength: 12)

                Button(isRunningQuery ? "Running..." : "Run Query") {
                    Task { await runQuery() }
                }
                .buttonStyle(IOSProminentButtonStyle())
                .disabled(isRunningQuery || sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("data-explorer.run-query")
            }

            if let queryError, !queryError.isEmpty {
                Text(queryError)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSTheme.danger)
                    .accessibilityIdentifier("data-explorer.query-error")
            }

            resultsSection
        }
        .iosCardStyle()
        .accessibilityIdentifier("data-explorer.query-card")
    }

    private var queryEditor: some View {
        TextEditor(text: $sqlQuery)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(minHeight: 140)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("data-explorer.query-editor")
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let queryResult {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IOSSecondaryPill("\(queryResult.rowCount) row\(queryResult.rowCount == 1 ? "" : "s")", systemImage: "list.number")
                    if let databasePath = queryResult.databasePath {
                        IOSSecondaryPill(URL(fileURLWithPath: databasePath).lastPathComponent, systemImage: "externaldrive")
                    }
                }

                if queryResult.rows.isEmpty {
                    Text("The query returned no rows.")
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(queryResult.rows) { row in
                            Button {
                                selectedRowID = row.id
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(rowTitle(for: row))
                                            .font(.headline)
                                            .foregroundStyle(IOSTheme.textPrimary)
                                            .lineLimit(2)
                                        Spacer(minLength: 8)
                                        if selectedRowID == row.id {
                                            IOSSecondaryPill("Selected", systemImage: "checkmark.circle")
                                        }
                                    }

                                    ForEach(previewFields(for: row), id: \.key) { field in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(field.key)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(IOSTheme.textSecondary)
                                                .frame(width: 92, alignment: .leading)
                                            Text(field.value)
                                                .font(.subheadline)
                                                .foregroundStyle(IOSTheme.textPrimary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .accessibilityIdentifier("data-explorer.results")
        } else {
            Text(currentTable == nil ? "Choose a table and run a query." : "Run a read-only SQL query to inspect mirrored rows.")
                .font(.subheadline)
                .foregroundStyle(IOSTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedFile, let service = displayedServices.first(where: { $0.serviceId == selectedFile.serviceID }) {
            IOSFileDetailView(
                service: service,
                serviceDir: appState.syncRootURL.appendingPathComponent(service.serviceId, isDirectory: true),
                fileURL: selectedFile.url,
                onOpenFile: { nextURL in
                    self.selectedFile = SQLExplorerSelectedFile(url: nextURL, serviceID: selectedFile.serviceID)
                },
                onSave: { url in
                    Task { await appState.markFileChanged(serviceID: selectedFile.serviceID, fileURL: url) }
                }
            )
        } else if let selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    IOSSectionTitle("Selected row", eyebrow: "Detail", detail: selectedRow.recordId.map { "Record id: \($0)" })

                    VStack(spacing: 10) {
                        ForEach(selectedRow.values.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top, spacing: 12) {
                                Text(key)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(IOSTheme.textSecondary)
                                    .frame(width: 110, alignment: .leading)
                                Text(selectedRow.values[key] ?? "")
                                    .font(.subheadline)
                                    .foregroundStyle(IOSTheme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }

                    openFileActions
                }
                .padding(20)
            }
            .iosScreenBackground()
        } else {
            IOSEmptyStateCard(
                title: "Choose a row",
                message: "Select a SQL result row to inspect its values and jump back to the synced file.",
                systemImage: "tablecells.badge.ellipsis"
            )
            .padding(20)
            .iosScreenBackground()
        }
    }

    @ViewBuilder
    private var openFileActions: some View {
        if let currentService, let currentTable, let recordID = selectedRow?.recordId {
            VStack(alignment: .leading, spacing: 12) {
                IOSSectionTitle("Open Files", detail: "Jump from the local SQL mirror back to the canonical or projection file.")

                HStack(spacing: 12) {
                    Button("Open Canonical") {
                        Task { await openSelectedRecord(surface: "canonical") }
                    }
                    .buttonStyle(IOSProminentButtonStyle())
                    .accessibilityIdentifier("data-explorer.open-canonical")

                    Button("Open Projection") {
                        Task { await openSelectedRecord(surface: "projection") }
                    }
                    .buttonStyle(IOSOutlineButtonStyle())
                    .accessibilityIdentifier("data-explorer.open-projection")
                }
            }
            .accessibilityIdentifier(IOSAccessibility.id("data-explorer", currentService.serviceId, currentTable.tableName, recordID))
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
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary.opacity(0.7)))
                }
            }
        }
        .accessibilityIdentifier("data-explorer.schema")
    }

    private func rowTitle(for row: SQLMirrorQueryRow) -> String {
        for key in ["name", "title", "label", "slug", "id", "_id"] {
            if let value = row.values[key], !value.isEmpty {
                return value
            }
        }
        return row.recordId ?? "Result Row"
    }

    private func previewFields(for row: SQLMirrorQueryRow) -> [(key: String, value: String)] {
        row.values
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .filter { !$0.value.isEmpty }
            .prefix(4)
            .map { ($0.key, $0.value) }
    }

    private func refreshTables() async {
        guard let service = currentService else {
            sqlTables = []
            selectedTableName = nil
            selectedDescription = nil
            queryResult = nil
            return
        }

        isLoadingTables = true
        let tables = await appState.listSQLTables(serviceID: service.serviceId)
            .sorted { $0.tableName.localizedStandardCompare($1.tableName) == .orderedAscending }
        sqlTables = tables
        if selectedTableName == nil || !tables.contains(where: { $0.tableName == selectedTableName }) {
            selectedTableName = tables.first?.tableName
        }
        if sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetQueryToSample()
        }
        isLoadingTables = false
        await loadSelectedTable()
    }

    private func loadSelectedTable() async {
        queryResult = nil
        queryError = nil
        selectedRowID = nil
        guard let service = currentService, let selectedTableName else {
            selectedDescription = nil
            return
        }

        selectedDescription = await appState.describeSQLTable(serviceID: service.serviceId, table: selectedTableName)
    }

    private func resetQueryToSample() {
        if let currentTable {
            sqlQuery = "SELECT * FROM \(currentTable.tableName) LIMIT 20"
        } else {
            sqlQuery = ""
        }
    }

    private func runQuery() async {
        guard let service = currentService else { return }
        let trimmed = sqlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queryError = "Enter a read-only SQL query first."
            return
        }

        isRunningQuery = true
        defer { isRunningQuery = false }

        do {
            let result = try await appState.runSQLQuery(serviceID: service.serviceId, query: trimmed)
            queryResult = result
            queryError = nil
            selectedRowID = result.rows.first?.id
        } catch {
            queryResult = nil
            queryError = error.localizedDescription
        }
    }

    private func openSelectedRecord(surface: String) async {
        guard let service = currentService,
              let currentTable,
              let recordID = selectedRow?.recordId else {
            return
        }

        do {
            let fileURL = try await appState.openSQLRecordFile(
                serviceID: service.serviceId,
                resource: currentTable.resourceName,
                recordID: recordID,
                surface: surface
            )
            selectedFile = SQLExplorerSelectedFile(url: fileURL, serviceID: service.serviceId)
            queryError = nil
        } catch {
            queryError = error.localizedDescription
        }
    }
}
