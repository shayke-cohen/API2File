import XCTest
@testable import API2FileCore

/// Live CRUD coverage for monday.com board item rows represented as CSV records.
///
/// Requires a monday token in Keychain under `api2file.monday.api-key`.
/// Tests skip automatically when credentials or a writable board are unavailable.
final class MondayLiveE2ETests: XCTestCase {

    private var token: String!
    private var httpClient: HTTPClient!
    private var engine: AdapterEngine!
    private var config: AdapterConfig!
    private var syncRoot: URL!
    private var serviceDir: URL!

    override func setUp() async throws {
        try await super.setUp()

        let loadedToken = Self.loadTokenFromSecurityCLI()
        try XCTSkipIf(loadedToken == nil, "No monday token in keychain — skipping live tests")
        token = loadedToken!

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/monday.adapter.json"))
        config = try JSONDecoder().decode(AdapterConfig.self, from: data)

        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-monday-live-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("monday")
        try FileManager.default.createDirectory(
            at: serviceDir.appendingPathComponent(".api2file"),
            withIntermediateDirectories: true
        )

        httpClient = HTTPClient()
        await httpClient.setAuthHeader("Authorization", value: token)
        engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
    }

    override func tearDown() async throws {
        if let dir = syncRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private static func loadTokenFromSecurityCLI() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "api2file.monday.api-key", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            var data = stdout.fileHandleForReading.readDataToEndOfFile()
            if data.last == 10 { data.removeLast() }
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func mondayAPI(query: String, variables: [String: Any]? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["query": query]
        if let variables {
            body["variables"] = variables
        }
        let response = try await httpClient.request(
            APIRequest(
                method: .POST,
                url: "https://api.monday.com/v2",
                headers: ["Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body),
                timeout: 15
            )
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func queryBoards() async throws -> [[String: Any]] {
        let result = try await mondayAPI(
            query: """
            query {
              boards(limit: 25) {
                id
                name
                state
                columns {
                  id
                  title
                  type
                }
              }
            }
            """
        )
        return ((result["data"] as? [String: Any])?["boards"] as? [[String: Any]]) ?? []
    }

    private func queryItems(boardId: String) async throws -> [[String: Any]] {
        let result = try await mondayAPI(
            query: """
            query($boardIds: [ID!]) {
              boards(ids: $boardIds) {
                items_page(limit: 200) {
                  items {
                    id
                    name
                    column_values {
                      id
                      text
                      type
                      column { title }
                    }
                  }
                }
              }
            }
            """,
            variables: ["boardIds": [boardId]]
        )
        let boards = ((result["data"] as? [String: Any])?["boards"] as? [[String: Any]]) ?? []
        return (((boards.first)?["items_page"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    }

    private func chooseWritableBoard() async throws -> (id: String, name: String, updatableColumnId: String)? {
        let boards = try await queryBoards()
        for board in boards {
            guard let state = board["state"] as? String, state == "active" else { continue }
            guard let boardId = board["id"] as? String ?? (board["id"] as? Int).map(String.init) else { continue }
            guard let name = board["name"] as? String else { continue }
            let columns = board["columns"] as? [[String: Any]] ?? []
            if let columnId = columns.first(where: {
                let type = ($0["type"] as? String ?? "").lowercased()
                return type == "status" || type == "text" || type == "long_text"
            })?["id"] as? String {
                return (boardId, name, columnId)
            }
        }
        return nil
    }

    private func boardItemsResource(boardName: String) -> ResourceConfig {
        let push = PushConfig(
            create: EndpointConfig(url: "https://api.monday.com/v2", type: .graphql, bodyType: "monday-item-create"),
            update: EndpointConfig(url: "https://api.monday.com/v2", type: .graphql, bodyType: "monday-item-update"),
            delete: EndpointConfig(url: "https://api.monday.com/v2", type: .graphql, mutation: "mutation { delete_item(item_id: {id}) { id } }")
        )
        let mapping = FileMappingConfig(
            strategy: .collection,
            directory: "boards/\(TemplateEngine.render("{name|slugify}", with: ["name": boardName]))",
            filename: "items.csv",
            format: .csv,
            idField: "id"
        )
        return ResourceConfig(
            name: "board-items",
            description: "Monday board items as CSV rows",
            push: push,
            fileMapping: mapping,
            sync: SyncConfig(interval: 5, debounceMs: 500)
        )
    }

    private func csvRows(for boardId: String, items: [[String: Any]]) -> [[String: Any]] {
        items.map { item in
            var columns: [String: Any] = [:]
            for column in item["column_values"] as? [[String: Any]] ?? [] {
                if let key = column["id"] as? String, let text = column["text"] as? String, !text.isEmpty {
                    columns[key] = text
                }
            }
            return [
                "id": item["id"] as? String ?? "",
                "boardId": boardId,
                "name": item["name"] as? String ?? "",
                "columns": columns
            ]
        }
    }

    private func writeCSVRows(_ rows: [[String: Any]], for boardName: String) throws -> URL {
        let resource = boardItemsResource(boardName: boardName)
        let relativePath = "\(resource.fileMapping.directory)/\(resource.fileMapping.filename ?? "items.csv")"
        let url = serviceDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try CSVFormat.encode(records: rows, options: nil)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func localBoardFiles() -> [(boardName: String, boardId: String)] {
        let liveRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("API2File-Data/monday/boards")
        guard let enumerator = FileManager.default.enumerator(at: liveRoot, includingPropertiesForKeys: nil) else {
            return []
        }

        var result: [(String, String)] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "items.csv" {
            guard let boardName = fileURL.deletingLastPathComponent().lastPathComponent.removingPercentEncoding else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? CSVFormat.decode(data: data, options: nil),
                  let boardId = records.first?["boardId"] as? String,
                  !boardId.isEmpty
            else {
                continue
            }
            result.append((boardName, boardId))
        }
        return result.sorted { lhs, rhs in lhs.0 < rhs.0 }
    }

    func testBoardItemsCSVFullCRUD() async throws {
        let board = try await chooseWritableBoard()
        try XCTSkipIf(board == nil, "No writable monday board with a simple editable column was found")
        let boardId = board!.id
        let boardName = board!.name
        let columnId = board!.updatableColumnId
        let resource = boardItemsResource(boardName: boardName)

        let originalItems = try await queryItems(boardId: boardId)
        let originalRows = csvRows(for: boardId, items: originalItems)
        let csvURL = try writeCSVRows(originalRows, for: boardName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path), "Expected a CSV file for the selected monday board")

        let createName = "API2File Monday Live Create \(UUID().uuidString.prefix(8))"
        let createdId = try await engine.pushRecord(
            [
                "boardId": boardId,
                "name": createName,
                "columns": [:]
            ],
            resource: resource,
            action: .create
        )
        let remoteId = try XCTUnwrap(createdId, "Monday create should return a new item id")

        try await Task.sleep(nanoseconds: 1_500_000_000)
        var itemsAfterCreate = try await queryItems(boardId: boardId)
        XCTAssertTrue(
            itemsAfterCreate.contains(where: { ($0["id"] as? String) == remoteId && ($0["name"] as? String) == createName }),
            "Created monday item should be present on the server"
        )

        try await engine.pushRecord(
            [
                "id": remoteId,
                "boardId": boardId,
                "name": createName,
                "columns": [columnId: "Done"]
            ],
            resource: resource,
            action: .update(id: remoteId)
        )

        try await Task.sleep(nanoseconds: 1_500_000_000)
        itemsAfterCreate = try await queryItems(boardId: boardId)
        let updatedRemote = itemsAfterCreate.first(where: { ($0["id"] as? String) == remoteId })
        XCTAssertNotNil(updatedRemote, "Updated monday item should still exist")
        let updatedColumnValues = updatedRemote?["column_values"] as? [[String: Any]] ?? []
        let updatedColumn = updatedColumnValues.first(where: { ($0["id"] as? String) == columnId })
        XCTAssertEqual(updatedColumn?["text"] as? String, "Done")

        try await engine.delete(remoteId: remoteId, resource: resource)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let itemsAfterDelete = try await queryItems(boardId: boardId)
        XCTAssertFalse(
            itemsAfterDelete.contains(where: { ($0["id"] as? String) == remoteId }),
            "Deleted monday item should no longer exist on the server"
        )
    }

    func testAllCurrentBoardFiles_CreateFiveRowsEach() async throws {
        let boardFiles = localBoardFiles()
        try XCTSkipIf(boardFiles.isEmpty, "No local monday board files found to validate")

        var createdByBoard: [String: [String]] = [:]
        defer {
            Task {
                for (boardId, ids) in createdByBoard {
                    let boardName = boardFiles.first(where: { $0.boardId == boardId })?.boardName ?? boardId
                    let resource = boardItemsResource(boardName: boardName)
                    for id in ids.reversed() {
                        try? await engine.delete(remoteId: id, resource: resource)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
        }

        for board in boardFiles {
            let resource = boardItemsResource(boardName: board.boardName)
            var createdIds: [String] = []

            for index in 1...5 {
                let name = "API2File Monday Bulk \(board.boardName) \(index) \(UUID().uuidString.prefix(6))"
                let createdId = try await engine.pushRecord(
                    [
                        "boardId": board.boardId,
                        "name": name,
                        "columns": [:]
                    ],
                    resource: resource,
                    action: .create
                )
                createdIds.append(try XCTUnwrap(createdId))
            }

            try await Task.sleep(nanoseconds: 1_500_000_000)
            let items = try await queryItems(boardId: board.boardId)
            for id in createdIds {
                XCTAssertTrue(
                    items.contains(where: { ($0["id"] as? String) == id }),
                    "Expected created item \(id) to exist on monday board \(board.boardName)"
                )
            }
            createdByBoard[board.boardId] = createdIds
        }
    }
}
