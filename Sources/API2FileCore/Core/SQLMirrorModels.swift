import Foundation

public struct SQLMirrorTableSummary: Decodable, Identifiable, Equatable {
    public let tableName: String
    public let resourceName: String
    public let rowCount: Int

    public var id: String { tableName }

    private enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case resourceName = "resource_name"
        case rowCount = "row_count"
    }

    public init(tableName: String, resourceName: String, rowCount: Int) {
        self.tableName = tableName
        self.resourceName = resourceName
        self.rowCount = rowCount
    }
}

public struct SQLMirrorTableColumn: Decodable, Identifiable, Equatable {
    public let cid: Int
    public let name: String
    public let type: String
    public let notNull: Int
    public let defaultValue: String?
    public let primaryKey: Int

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case cid
        case name
        case type
        case notNull = "notnull"
        case defaultValue = "dflt_value"
        case primaryKey = "pk"
    }

    public init(cid: Int, name: String, type: String, notNull: Int, defaultValue: String?, primaryKey: Int) {
        self.cid = cid
        self.name = name
        self.type = type
        self.notNull = notNull
        self.defaultValue = defaultValue
        self.primaryKey = primaryKey
    }
}

public struct SQLMirrorTableDescription: Decodable, Equatable {
    public let databasePath: String
    public let table: String
    public let resourceName: String
    public let rowCount: Int
    public let columns: [SQLMirrorTableColumn]

    public init(
        databasePath: String,
        table: String,
        resourceName: String,
        rowCount: Int,
        columns: [SQLMirrorTableColumn]
    ) {
        self.databasePath = databasePath
        self.table = table
        self.resourceName = resourceName
        self.rowCount = rowCount
        self.columns = columns
    }
}

public struct SQLMirrorQueryRow: Identifiable, Equatable {
    public let id: UUID
    public let values: [String: String]
    public let recordId: String?

    public init(id: UUID = UUID(), values: [String: String], recordId: String?) {
        self.id = id
        self.values = values
        self.recordId = recordId
    }
}

public struct SQLMirrorQueryResult: Equatable {
    public let databasePath: String?
    public let query: String
    public let rowCount: Int
    public let columns: [String]
    public let rows: [SQLMirrorQueryRow]

    public init(
        databasePath: String?,
        query: String,
        rowCount: Int,
        columns: [String],
        rows: [SQLMirrorQueryRow]
    ) {
        self.databasePath = databasePath
        self.query = query
        self.rowCount = rowCount
        self.columns = columns
        self.rows = rows
    }
}

public enum SQLExplorerError: LocalizedError {
    case unavailable
    case invalidResponse
    case missingFilePath(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The sync engine is not available yet."
        case .invalidResponse:
            return "API2File returned an unexpected SQLite response."
        case .missingFilePath(let path):
            return "The resolved file does not exist: \(path)"
        }
    }
}

public struct SQLTablesPayload: Decodable, Equatable {
    public let tables: [SQLMirrorTableSummary]

    public init(tables: [SQLMirrorTableSummary]) {
        self.tables = tables
    }
}
