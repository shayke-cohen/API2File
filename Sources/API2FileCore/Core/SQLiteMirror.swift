import Foundation
import SQLite3
import CoreFoundation

enum SQLiteMirror {
    static let databaseFilename = "service.sqlite"

    enum MirrorError: LocalizedError {
        case openDatabase(String)
        case sqlite(String)
        case invalidQuery(String)
        case missingDatabase
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .openDatabase(let message):
                return "Failed to open SQLite database: \(message)"
            case .sqlite(let message):
                return "SQLite error: \(message)"
            case .invalidQuery(let message):
                return "Invalid SQL query: \(message)"
            case .missingDatabase:
                return "SQLite mirror does not exist yet"
            case .notFound(let message):
                return message
            }
        }
    }

    private struct RowInput {
        let record: [String: Any]
        let remoteId: String?
        let projectionPath: String
        let objectPath: String
        let lastSyncedAt: Date?
        let status: String?
        let jsonPayload: String
    }

    private enum ColumnAffinity: String {
        case integer = "INTEGER"
        case real = "REAL"
        case text = "TEXT"

        static func merge(_ lhs: ColumnAffinity, _ rhs: ColumnAffinity) -> ColumnAffinity {
            if lhs == rhs { return lhs }
            if (lhs == .integer && rhs == .real) || (lhs == .real && rhs == .integer) {
                return .real
            }
            return .text
        }
    }

    private struct ColumnSpec {
        let sourceKey: String
        let columnName: String
        let affinity: ColumnAffinity
    }

    enum FileSurface: String {
        case canonical
        case projection
    }

    private struct ResolvedRecord {
        let tableName: String
        let resourceName: String
        let recordId: String
        let row: [String: Any]
        let record: [String: Any]
        let canonicalPath: String
        let projectionPath: String
    }

    static func databaseURL(in serviceDir: URL) -> URL {
        serviceDir
            .appendingPathComponent(".api2file", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(databaseFilename, isDirectory: false)
    }

    static func refresh(
        serviceDir: URL,
        config: AdapterConfig,
        state: SyncState
    ) throws {
        let fileManager = FileManager.default
        let databaseURL = databaseURL(in: serviceDir)
        let cacheDirectory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let temporaryURL = cacheDirectory.appendingPathComponent("\(databaseFilename).tmp", isDirectory: false)
        try? fileManager.removeItem(at: temporaryURL)

        let resources = allResources(in: config)
        let fileLinks = (try? FileLinkManager.load(from: serviceDir).links) ?? []
        let tableNames = uniqueTableNames(for: resources)

        let database = try openDatabase(at: temporaryURL)
        defer {
            sqlite3_close(database)
        }

        try exec("PRAGMA journal_mode=DELETE", in: database)
        try exec("PRAGMA synchronous=NORMAL", in: database)
        try exec("BEGIN IMMEDIATE TRANSACTION", in: database)

        do {
            try createCatalogTable(in: database)

            for resource in resources {
                let rows = try loadRows(
                    for: resource,
                    serviceDir: serviceDir,
                    state: state,
                    fileLinks: fileLinks
                )
                let tableName = tableNames[resource.name] ?? sanitizedIdentifier(resource.name)
                let columns = inferColumns(from: rows)
                try createResourceTable(named: tableName, columns: columns, in: database)
                try insertRows(rows, columns: columns, into: tableName, in: database)
                try createResourceIndexes(for: tableName, in: database)
                try insertCatalogEntry(
                    tableName: tableName,
                    resourceName: resource.name,
                    rowCount: rows.count,
                    in: database
                )
            }

            try exec("COMMIT", in: database)
        } catch {
            try? exec("ROLLBACK", in: database)
            throw error
        }

        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: databaseURL)
    }

    static func listTablesJSON(in serviceDir: URL) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let rows = try queryRows(
            "SELECT table_name, resource_name, row_count FROM __api2file_tables ORDER BY resource_name COLLATE NOCASE",
            arguments: [],
            in: database
        )
        return try encodeJSONObject([
            "databasePath": databaseURL(in: serviceDir).path,
            "tables": rows
        ])
    }

    static func describeTableJSON(_ table: String, in serviceDir: URL) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let catalog = try catalogEntry(for: table, in: database)
        let escapedTable = quoteIdentifier(catalog.tableName)
        let columns = try queryRows("PRAGMA table_info(\(escapedTable))", arguments: [], in: database)

        return try encodeJSONObject([
            "databasePath": databaseURL(in: serviceDir).path,
            "table": catalog.tableName,
            "resourceName": catalog.resourceName,
            "rowCount": catalog.rowCount,
            "columns": columns
        ])
    }

    static func queryJSON(_ sql: String, in serviceDir: URL) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let rows = try queryRows(sql, arguments: [], in: database, requireReadOnly: true)
        let columns = rows.first.map { Array($0.keys).sorted() } ?? []
        return try encodeJSONObject([
            "databasePath": databaseURL(in: serviceDir).path,
            "query": sql,
            "rowCount": rows.count,
            "columns": columns,
            "rows": rows
        ])
    }

    static func searchJSON(
        text: String,
        resources: [String]?,
        in serviceDir: URL
    ) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let targetTables = try resolveTargetTables(resources: resources, in: database)
        let needle = "%\(text.lowercased())%"
        var results: [[String: Any]] = []

        for table in targetTables {
            let escaped = quoteIdentifier(table.tableName)
            let sql = """
            SELECT *, ? AS _table_name, ? AS _resource_name
            FROM \(escaped)
            WHERE lower(_json_payload) LIKE ?
            LIMIT 25
            """
            let rows = try queryRows(sql, arguments: [.text(table.tableName), .text(table.resourceName), .text(needle)], in: database)
            results.append(contentsOf: rows)
        }

        return try encodeJSONObject([
            "databasePath": databaseURL(in: serviceDir).path,
            "query": text,
            "rowCount": results.count,
            "rows": results
        ])
    }

    static func getRecordJSON(
        resource: String,
        recordId: String,
        in serviceDir: URL
    ) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let resolved = try resolveRecord(resource: resource, recordId: recordId, in: database)
        return try encodeJSONObject(recordResponsePayload(for: resolved, in: serviceDir))
    }

    static func openRecordFileJSON(
        resource: String,
        recordId: String,
        surface: FileSurface,
        in serviceDir: URL
    ) throws -> Data {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }

        let resolved = try resolveRecord(resource: resource, recordId: recordId, in: database)
        let relativePath = surface == .canonical ? resolved.canonicalPath : resolved.projectionPath
        let fileURL = serviceDir.appendingPathComponent(relativePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MirrorError.notFound("Record file not found at '\(relativePath)'")
        }

        let data = try Data(contentsOf: fileURL)
        var response = recordResponsePayload(for: resolved, in: serviceDir)
        response["surface"] = surface.rawValue
        response["relativePath"] = relativePath
        response["absolutePath"] = fileURL.path
        response["size"] = data.count

        if let text = String(data: data, encoding: .utf8) {
            response["content"] = text
            response["contentEncoding"] = "utf8"
        } else {
            response["contentBase64"] = data.base64EncodedString()
            response["contentEncoding"] = "base64"
        }

        return try encodeJSONObject(response)
    }

    // MARK: - Refresh

    private static func createCatalogTable(in database: OpaquePointer?) throws {
        try exec(
            """
            CREATE TABLE __api2file_tables (
              table_name TEXT PRIMARY KEY,
              resource_name TEXT NOT NULL,
              row_count INTEGER NOT NULL
            )
            """,
            in: database
        )
    }

    private static func createResourceTable(
        named tableName: String,
        columns: [ColumnSpec],
        in database: OpaquePointer?
    ) throws {
        var columnDefinitions = [
            "\"_remote_id\" TEXT",
            "\"_projection_path\" TEXT NOT NULL",
            "\"_object_path\" TEXT NOT NULL",
            "\"_last_synced_at\" TEXT",
            "\"_status\" TEXT",
            "\"_json_payload\" TEXT NOT NULL"
        ]
        columnDefinitions.append(contentsOf: columns.map { "\"\($0.columnName)\" \($0.affinity.rawValue)" })

        try exec(
            "CREATE TABLE \(quoteIdentifier(tableName)) (\(columnDefinitions.joined(separator: ", ")))",
            in: database
        )
    }

    private static func insertRows(
        _ rows: [RowInput],
        columns: [ColumnSpec],
        into tableName: String,
        in database: OpaquePointer?
    ) throws {
        guard !rows.isEmpty else { return }

        let orderedColumns = ["_remote_id", "_projection_path", "_object_path", "_last_synced_at", "_status", "_json_payload"]
            + columns.map(\.columnName)
        let placeholders = Array(repeating: "?", count: orderedColumns.count).joined(separator: ", ")
        let sql = "INSERT INTO \(quoteIdentifier(tableName)) (\(orderedColumns.map(quoteIdentifier).joined(separator: ", "))) VALUES (\(placeholders))"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw makeSQLiteError(in: database)
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            var values: [SQLiteArgument] = [
                .text(row.remoteId),
                .text(row.projectionPath),
                .text(row.objectPath),
                .text(row.lastSyncedAt.map { ISO8601DateFormatter().string(from: $0) }),
                .text(row.status),
                .text(row.jsonPayload)
            ]
            values.append(contentsOf: columns.map { column in
                scalarArgument(from: row.record[column.sourceKey])
            })

            try bind(values, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw makeSQLiteError(in: database)
            }
        }
    }

    private static func insertCatalogEntry(
        tableName: String,
        resourceName: String,
        rowCount: Int,
        in database: OpaquePointer?
    ) throws {
        let sql = "INSERT INTO __api2file_tables (table_name, resource_name, row_count) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw makeSQLiteError(in: database)
        }
        defer { sqlite3_finalize(statement) }

        try bind([.text(tableName), .text(resourceName), .integer(Int64(rowCount))], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw makeSQLiteError(in: database)
        }
    }

    private static func createResourceIndexes(
        for tableName: String,
        in database: OpaquePointer?
    ) throws {
        let sanitizedTableName = sanitizedIdentifier(tableName)
        try exec(
            """
            CREATE INDEX idx_\(sanitizedTableName)_remote_id
            ON \(quoteIdentifier(tableName)) ("_remote_id")
            """,
            in: database
        )
        try exec(
            """
            CREATE INDEX idx_\(sanitizedTableName)_projection_path
            ON \(quoteIdentifier(tableName)) ("_projection_path")
            """,
            in: database
        )
        try exec(
            """
            CREATE INDEX idx_\(sanitizedTableName)_object_path
            ON \(quoteIdentifier(tableName)) ("_object_path")
            """,
            in: database
        )
    }

    private static func loadRows(
        for resource: ResourceConfig,
        serviceDir: URL,
        state: SyncState,
        fileLinks: [FileLinkEntry]
    ) throws -> [RowInput] {
        let matchingLinks = fileLinks
            .filter { $0.resourceName == resource.name }
            .sorted { $0.userPath.localizedStandardCompare($1.userPath) == .orderedAscending }

        var rows: [RowInput] = []
        for link in matchingLinks {
            let objectURL = serviceDir.appendingPathComponent(link.canonicalPath)
            guard FileManager.default.fileExists(atPath: objectURL.path) else { continue }

            let fileState = state.files[link.userPath]
            switch resource.fileMapping.strategy {
            case .onePerRecord:
                let record = try ObjectFileManager.readRecordObjectFile(from: objectURL)
                rows.append(try makeRow(
                    record: record,
                    link: link,
                    fileState: fileState,
                    idField: resource.fileMapping.idField
                ))
            case .collection, .mirror:
                let records = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
                for record in records {
                    rows.append(try makeRow(
                        record: record,
                        link: link,
                        fileState: fileState,
                        idField: resource.fileMapping.idField
                    ))
                }
            }
        }

        return rows
    }

    private static func makeRow(
        record: [String: Any],
        link: FileLinkEntry,
        fileState: FileSyncState?,
        idField: String?
    ) throws -> RowInput {
        let payloadData = try JSONSerialization.data(withJSONObject: sanitizeJSONObject(record), options: [.sortedKeys])
        let payload = String(data: payloadData, encoding: .utf8) ?? "{}"
        return RowInput(
            record: record,
            remoteId: remoteID(from: record, idField: idField) ?? normalizedRemoteId(link.remoteId),
            projectionPath: link.userPath,
            objectPath: link.canonicalPath,
            lastSyncedAt: fileState?.lastSyncTime,
            status: fileState?.status.rawValue,
            jsonPayload: payload
        )
    }

    private static func inferColumns(from rows: [RowInput]) -> [ColumnSpec] {
        var affinityByKey: [String: ColumnAffinity] = [:]
        let reservedNames: Set<String> = [
            "_remote_id",
            "_projection_path",
            "_object_path",
            "_last_synced_at",
            "_status",
            "_json_payload"
        ]

        for row in rows {
            for (key, value) in row.record {
                guard let affinity = affinity(for: value) else { continue }
                if let existing = affinityByKey[key] {
                    affinityByKey[key] = ColumnAffinity.merge(existing, affinity)
                } else {
                    affinityByKey[key] = affinity
                }
            }
        }

        var usedNames = reservedNames
        return affinityByKey.keys.sorted().map { key in
            let suggested = sanitizedIdentifier(key)
            let baseName = reservedNames.contains(suggested) ? "field_\(suggested)" : suggested
            let columnName = uniqueName(startingWith: baseName, used: &usedNames)
            return ColumnSpec(sourceKey: key, columnName: columnName, affinity: affinityByKey[key] ?? .text)
        }
    }

    // MARK: - Query

    private static func openExistingDatabase(in serviceDir: URL) throws -> OpaquePointer? {
        let url = databaseURL(in: serviceDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MirrorError.missingDatabase
        }
        return try openDatabase(at: url)
    }

    static func indexNamesForTesting(table: String, in serviceDir: URL) throws -> [String] {
        let database = try openExistingDatabase(in: serviceDir)
        defer { sqlite3_close(database) }
        let rows = try queryRows("PRAGMA index_list(\(quoteIdentifier(table)))", arguments: [], in: database)
        return rows.compactMap { $0["name"] as? String }
    }

    private static func catalogEntry(for tableOrResource: String, in database: OpaquePointer?) throws -> (tableName: String, resourceName: String, rowCount: Int) {
        let sql = """
        SELECT table_name, resource_name, row_count
        FROM __api2file_tables
        WHERE table_name = ? OR resource_name = ?
        LIMIT 1
        """
        let rows = try queryRows(sql, arguments: [.text(tableOrResource), .text(tableOrResource)], in: database)
        guard let row = rows.first,
              let tableName = row["table_name"] as? String,
              let resourceName = row["resource_name"] as? String else {
            throw MirrorError.invalidQuery("Unknown table '\(tableOrResource)'")
        }
        let rowCount = row["row_count"] as? Int ?? 0
        return (tableName, resourceName, rowCount)
    }

    private static func resolveTargetTables(resources: [String]?, in database: OpaquePointer?) throws -> [(tableName: String, resourceName: String)] {
        if let resources, !resources.isEmpty {
            return try resources.map {
                let entry = try catalogEntry(for: $0, in: database)
                return (entry.tableName, entry.resourceName)
            }
        }

        let rows = try queryRows(
            "SELECT table_name, resource_name FROM __api2file_tables ORDER BY resource_name COLLATE NOCASE",
            arguments: [],
            in: database
        )
        return rows.compactMap { row in
            guard let tableName = row["table_name"] as? String,
                  let resourceName = row["resource_name"] as? String else { return nil }
            return (tableName, resourceName)
        }
    }

    private static func resolveRecord(
        resource: String,
        recordId: String,
        in database: OpaquePointer?
    ) throws -> ResolvedRecord {
        let normalizedId = normalizedRemoteId(recordId)
        guard let normalizedId else {
            throw MirrorError.invalidQuery("Record ID must not be empty")
        }

        let catalog = try catalogEntry(for: resource, in: database)
        let sql = """
        SELECT *
        FROM \(quoteIdentifier(catalog.tableName))
        WHERE _remote_id = ?
        LIMIT 1
        """
        let rows = try queryRows(sql, arguments: [.text(normalizedId)], in: database)
        guard let row = rows.first else {
            throw MirrorError.notFound("No record with id '\(normalizedId)' in resource '\(catalog.resourceName)'")
        }
        guard let canonicalPath = row["_object_path"] as? String,
              let projectionPath = row["_projection_path"] as? String else {
            throw MirrorError.sqlite("Resolved row is missing file path metadata")
        }

        let payloadRecord: [String: Any]
        if let payload = row["_json_payload"] as? String,
           let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
           let record = object as? [String: Any] {
            payloadRecord = record
        } else {
            payloadRecord = [:]
        }

        return ResolvedRecord(
            tableName: catalog.tableName,
            resourceName: catalog.resourceName,
            recordId: normalizedId,
            row: row,
            record: payloadRecord,
            canonicalPath: canonicalPath,
            projectionPath: projectionPath
        )
    }

    private static func recordResponsePayload(for resolved: ResolvedRecord, in serviceDir: URL) -> [String: Any] {
        [
            "databasePath": databaseURL(in: serviceDir).path,
            "table": resolved.tableName,
            "resourceName": resolved.resourceName,
            "recordId": resolved.recordId,
            "canonicalPath": resolved.canonicalPath,
            "projectionPath": resolved.projectionPath,
            "canonicalFile": serviceDir.appendingPathComponent(resolved.canonicalPath).path,
            "projectionFile": serviceDir.appendingPathComponent(resolved.projectionPath).path,
            "record": resolved.record,
            "row": resolved.row
        ]
    }

    private static func queryRows(
        _ sql: String,
        arguments: [SQLiteArgument],
        in database: OpaquePointer?,
        requireReadOnly: Bool = false
    ) throws -> [[String: Any]] {
        let statement = try prepareStatement(sql, in: database, requireReadOnly: requireReadOnly)
        defer { sqlite3_finalize(statement) }

        try bind(arguments, to: statement)

        var rows: [[String: Any]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw makeSQLiteError(in: database)
            }

            let columnCount = sqlite3_column_count(statement)
            var row: [String: Any] = [:]
            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = columnValue(statement: statement, index: index)
            }
            rows.append(row)
        }

        return rows
    }

    private static func prepareStatement(
        _ sql: String,
        in database: OpaquePointer?,
        requireReadOnly: Bool
    ) throws -> OpaquePointer? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MirrorError.invalidQuery("Query is empty")
        }

        var statement: OpaquePointer?
        var tail: UnsafePointer<Int8>?
        let result = sqlite3_prepare_v2(database, trimmed, -1, &statement, &tail)
        guard result == SQLITE_OK, let statement else {
            throw makeSQLiteError(in: database)
        }

        let remainingSQL = tail.map { String(cString: $0) }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        guard remainingSQL.isEmpty else {
            sqlite3_finalize(statement)
            throw MirrorError.invalidQuery("Only a single SQL statement is allowed")
        }

        if requireReadOnly {
            let uppercase = trimmed.uppercased()
            let allowedPrefixes = ["SELECT", "WITH", "PRAGMA", "EXPLAIN", "VALUES"]
            guard allowedPrefixes.contains(where: { uppercase.hasPrefix($0) }) else {
                sqlite3_finalize(statement)
                throw MirrorError.invalidQuery("Only read-only SELECT-style queries are allowed")
            }
            guard sqlite3_stmt_readonly(statement) != 0 else {
                sqlite3_finalize(statement)
                throw MirrorError.invalidQuery("Only read-only SQL queries are allowed")
            }
        }

        return statement
    }

    // MARK: - SQLite Helpers

    private enum SQLiteArgument {
        case null
        case integer(Int64)
        case real(Double)
        case text(String?)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK else {
            defer { if database != nil { sqlite3_close(database) } }
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
            throw MirrorError.openDatabase(message)
        }
        return database
    }

    private static func exec(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw makeSQLiteError(in: database)
        }
    }

    private static func bind(_ arguments: [SQLiteArgument], to statement: OpaquePointer?) throws {
        for (index, argument) in arguments.enumerated() {
            let parameterIndex = Int32(index + 1)
            let code: Int32
            switch argument {
            case .null:
                code = sqlite3_bind_null(statement, parameterIndex)
            case .integer(let value):
                code = sqlite3_bind_int64(statement, parameterIndex, value)
            case .real(let value):
                code = sqlite3_bind_double(statement, parameterIndex, value)
            case .text(let value):
                if let value {
                    code = sqlite3_bind_text(statement, parameterIndex, value, -1, sqliteTransient)
                } else {
                    code = sqlite3_bind_null(statement, parameterIndex)
                }
            }

            guard code == SQLITE_OK else {
                throw MirrorError.sqlite("Failed binding SQLite parameter \(parameterIndex)")
            }
        }
    }

    private static func columnValue(statement: OpaquePointer?, index: Int32) -> Any {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return Int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            return String(cString: sqlite3_column_text(statement, index))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_blob(statement, index)
            let count = Int(sqlite3_column_bytes(statement, index))
            if let bytes, count > 0 {
                return Data(bytes: bytes, count: count).base64EncodedString()
            }
            return ""
        default:
            return NSNull()
        }
    }

    private static func makeSQLiteError(in database: OpaquePointer?) -> MirrorError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
        return .sqlite(message)
    }

    // MARK: - Value Helpers

    private static func scalarArgument(from value: Any?) -> SQLiteArgument {
        switch sanitizedScalarValue(from: value) {
        case nil:
            return .null
        case let int as Int:
            return .integer(Int64(int))
        case let double as Double:
            return .real(double)
        case let string as String:
            return .text(string)
        case let bool as Bool:
            return .integer(bool ? 1 : 0)
        default:
            return .text(String(describing: value ?? ""))
        }
    }

    private static func affinity(for value: Any) -> ColumnAffinity? {
        switch sanitizedScalarValue(from: value) {
        case is Int, is Bool:
            return .integer
        case is Double:
            return .real
        case is String, is NSNull:
            return .text
        default:
            return nil
        }
    }

    private static func sanitizedScalarValue(from value: Any?) -> Any? {
        guard let value else { return nil }
        if value is NSNull {
            return NSNull()
        }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool
        }
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let doubleValue = number.doubleValue
            let intValue = number.int64Value
            if Double(intValue) == doubleValue {
                return Int(intValue)
            }
            return doubleValue
        }
        return nil
    }

    private static func sanitizeJSONObject(_ value: Any) -> Any {
        if value is NSNull {
            return NSNull()
        }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool
        }
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let doubleValue = number.doubleValue
            let intValue = number.int64Value
            if Double(intValue) == doubleValue {
                return Int(intValue)
            }
            return doubleValue
        }
        if let array = value as? [Any] {
            return array.map(sanitizeJSONObject)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitizeJSONObject)
        }
        return String(describing: value)
    }

    private static func remoteID(from record: [String: Any], idField: String?) -> String? {
        guard let idField else { return nil }
        if let value = record[idField] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = record[idField] as? Int {
            return String(value)
        }
        if let value = record[idField] as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func normalizedRemoteId(_ remoteId: String?) -> String? {
        guard let remoteId else { return nil }
        let trimmed = remoteId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Naming

    private static func allResources(in config: AdapterConfig) -> [ResourceConfig] {
        config.resources.flatMap { [$0] + ($0.children ?? []) }
    }

    private static func uniqueTableNames(for resources: [ResourceConfig]) -> [String: String] {
        var used: Set<String> = []
        var result: [String: String] = [:]
        for resource in resources {
            let sanitized = sanitizedIdentifier(resource.name)
            let unique = uniqueName(startingWith: sanitized, used: &used)
            result[resource.name] = unique
        }
        return result
    }

    private static func sanitizedIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = collapsed.isEmpty ? "resource" : collapsed.lowercased()
        if let first = base.first, first.isNumber {
            return "r_\(base)"
        }
        return base
    }

    private static func uniqueName(startingWith base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Encoding

    private static func encodeJSONObject(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
