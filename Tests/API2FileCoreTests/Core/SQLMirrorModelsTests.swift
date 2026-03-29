import XCTest
@testable import API2FileCore

final class SQLMirrorModelsTests: XCTestCase {
    func testSQLTablesPayloadDecodesSharedSnakeCaseModels() throws {
        let data = Data(
            """
            {
              "tables": [
                {
                  "table_name": "contacts",
                  "resource_name": "contacts",
                  "row_count": 12
                }
              ]
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(SQLTablesPayload.self, from: data)

        XCTAssertEqual(payload.tables, [
            SQLMirrorTableSummary(tableName: "contacts", resourceName: "contacts", rowCount: 12)
        ])
    }

    func testSQLMirrorTableDescriptionDecodesColumnMetadata() throws {
        let data = Data(
            """
            {
              "databasePath": "/tmp/service/.api2file/mirror.sqlite",
              "table": "contacts",
              "resourceName": "contacts",
              "rowCount": 2,
              "columns": [
                { "cid": 0, "name": "id", "type": "TEXT", "notnull": 1, "dflt_value": null, "pk": 1 },
                { "cid": 1, "name": "name", "type": "TEXT", "notnull": 0, "dflt_value": null, "pk": 0 }
              ]
            }
            """.utf8
        )

        let description = try JSONDecoder().decode(SQLMirrorTableDescription.self, from: data)

        XCTAssertEqual(description.table, "contacts")
        XCTAssertEqual(description.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(description.columns.first?.primaryKey, 1)
    }
}
