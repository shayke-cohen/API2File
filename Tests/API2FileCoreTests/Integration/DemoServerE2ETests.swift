import XCTest
@testable import API2FileCore

final class DemoServerE2ETests: XCTestCase {

    // MARK: - Properties

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Use a random port to avoid conflicts between parallel test runs
        let randomPort = UInt16.random(in: 19000...29999)
        let candidate_server = DemoAPIServer(port: randomPort)
        try await candidate_server.start()
        server = candidate_server
        port = randomPort

        // Wait for server to bind and verify it's ready with retry
        var ready = false
        for attempt in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let url = URL(string: "\(baseURL)/api/tasks")!
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    ready = true
                    break
                }
            } catch {
                if attempt == 9 {
                    XCTFail("Server not ready after 10 attempts on port \(randomPort): \(error)")
                }
            }
        }

        guard ready else { return }

        // Reset to clean seed state
        await server.reset()
    }

    override func tearDown() async throws {
        if let server {
            await server.stop()
        }
        server = nil
        port = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() -> HTTPClient {
        HTTPClient()
    }

    private func getTasks(_ client: HTTPClient) async throws -> [[String: Any]] {
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/tasks")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let tasks = json as? [[String: Any]] else {
            XCTFail("Expected array of tasks")
            return []
        }
        return tasks
    }

    private func getTask(_ client: HTTPClient, id: Int) async throws -> [String: Any] {
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/tasks/\(id)")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let task = json as? [String: Any] else {
            XCTFail("Expected task dictionary")
            return [:]
        }
        return task
    }

    // MARK: - Test: Pull tasks from demo server

    func testPullTasksFromDemoServer() async throws {
        let client = makeClient()
        let tasks = try await getTasks(client)

        XCTAssertEqual(tasks.count, 3, "Should have 3 seed tasks")

        // Verify first task (Buy groceries)
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(task1)
        XCTAssertEqual(task1?["name"] as? String, "Buy groceries")
        XCTAssertEqual(task1?["status"] as? String, "todo")
        XCTAssertEqual(task1?["priority"] as? String, "medium")
        XCTAssertEqual(task1?["assignee"] as? String, "Alice")
        XCTAssertEqual(task1?["dueDate"] as? String, "2026-03-25")

        // Verify second task (Fix login bug)
        let task2 = tasks.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(task2)
        XCTAssertEqual(task2?["name"] as? String, "Fix login bug")
        XCTAssertEqual(task2?["status"] as? String, "in-progress")
        XCTAssertEqual(task2?["priority"] as? String, "high")
        XCTAssertEqual(task2?["assignee"] as? String, "Bob")
        XCTAssertEqual(task2?["dueDate"] as? String, "2026-03-24")

        // Verify third task (Write docs)
        let task3 = tasks.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNotNil(task3)
        XCTAssertEqual(task3?["name"] as? String, "Write docs")
        XCTAssertEqual(task3?["status"] as? String, "done")
        XCTAssertEqual(task3?["priority"] as? String, "low")
        XCTAssertEqual(task3?["assignee"] as? String, "Alice")
        XCTAssertEqual(task3?["dueDate"] as? String, "2026-03-20")
    }

    // MARK: - Test: Create task via API

    func testCreateTaskViaAPI() async throws {
        let client = makeClient()

        let newTask: [String: Any] = [
            "name": "Deploy v2",
            "status": "todo",
            "priority": "high",
            "assignee": "Charlie",
            "dueDate": "2026-04-01"
        ]
        let body = try JSONSerialization.data(withJSONObject: newTask)
        let createRequest = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/tasks",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let createResponse = try await client.request(createRequest)
        XCTAssertEqual(createResponse.statusCode, 201)

        // Verify response includes the created task
        let createdTask = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertNotNil(createdTask)
        XCTAssertEqual(createdTask?["name"] as? String, "Deploy v2")
        XCTAssertEqual(createdTask?["assignee"] as? String, "Charlie")

        // Get all tasks and verify 4 now exist
        let tasks = try await getTasks(client)
        XCTAssertEqual(tasks.count, 4, "Should have 4 tasks after creating one")

        // Verify the new task is in the list
        let found = tasks.first(where: { ($0["name"] as? String) == "Deploy v2" })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?["status"] as? String, "todo")
        XCTAssertEqual(found?["priority"] as? String, "high")
        XCTAssertEqual(found?["assignee"] as? String, "Charlie")
        XCTAssertEqual(found?["dueDate"] as? String, "2026-04-01")
    }

    // MARK: - Test: Update task via API

    func testUpdateTaskViaAPI() async throws {
        let client = makeClient()

        let updateData: [String: Any] = ["name": "Buy organic groceries"]
        let body = try JSONSerialization.data(withJSONObject: updateData)
        let putRequest = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/tasks/1",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let putResponse = try await client.request(putRequest)
        XCTAssertEqual(putResponse.statusCode, 200)

        // GET the task back and verify the name changed
        let task = try await getTask(client, id: 1)
        XCTAssertEqual(task["name"] as? String, "Buy organic groceries")
        // Other fields should remain unchanged
        XCTAssertEqual(task["status"] as? String, "todo")
        XCTAssertEqual(task["priority"] as? String, "medium")
    }

    // MARK: - Test: Delete task via API

    func testDeleteTaskViaAPI() async throws {
        let client = makeClient()

        let deleteRequest = APIRequest(
            method: .DELETE,
            url: "\(baseURL)/api/tasks/3"
        )
        let deleteResponse = try await client.request(deleteRequest)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        // GET all tasks and verify only 2 remain
        let tasks = try await getTasks(client)
        XCTAssertEqual(tasks.count, 2, "Should have 2 tasks after deleting one")

        // Verify task 3 is gone
        let task3 = tasks.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNil(task3, "Task 3 should have been deleted")

        // Verify tasks 1 and 2 remain
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 })
        let task2 = tasks.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(task1)
        XCTAssertNotNil(task2)
    }

    // MARK: - Test: Full pull pipeline — API to CSV file

    func testFullPullPipeline_APIToCSVFile() async throws {
        let client = makeClient()

        // Step 1: GET /api/tasks
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/tasks")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Step 2: The response is a JSON array at root; JSONPath "$" on an array returns the array itself
        // Parse the raw array directly since the server returns a JSON array (not wrapped in an object)
        let rawArray = try JSONSerialization.jsonObject(with: response.body)
        let records: [[String: Any]]
        if let array = rawArray as? [[String: Any]] {
            records = array
        } else if let dict = rawArray as? [String: Any] {
            // Fallback: try JSONPath extraction
            let extracted = JSONPath.extract("$", from: dict)
            records = (extracted as? [[String: Any]]) ?? []
        } else {
            XCTFail("Unexpected response format")
            return
        }
        XCTAssertEqual(records.count, 3)

        // Step 3: Convert to CSV using CSVFormat
        let csvData = try CSVFormat.encode(records: records, options: nil)

        // Step 4: Write to temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-tasks-\(UUID().uuidString).csv")
        try csvData.write(to: tempFile)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        // Step 5: Read back and verify CSV
        let readData = try Data(contentsOf: tempFile)
        let readCSV = String(data: readData, encoding: .utf8)!

        // Verify headers
        let lines = readCSV.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 4, "Header + 3 data rows")
        let headers = lines[0]
        XCTAssertTrue(headers.contains("_id"), "Should have _id column")
        XCTAssertTrue(headers.contains("name"), "Should have name column")
        XCTAssertTrue(headers.contains("status"), "Should have status column")
        XCTAssertTrue(headers.contains("priority"), "Should have priority column")
        XCTAssertTrue(headers.contains("assignee"), "Should have assignee column")
        XCTAssertTrue(headers.contains("dueDate"), "Should have dueDate column")

        // Verify 3 data rows
        XCTAssertEqual(lines.count, 4, "Header + 3 data rows") // header + 3 rows

        // Step 6: Decode back and verify 3 records
        let decodedRecords = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decodedRecords.count, 3, "Should decode back to 3 records")

        // Verify decoded record content
        let buyGroceries = decodedRecords.first(where: { ($0["name"] as? String) == "Buy groceries" })
        XCTAssertNotNil(buyGroceries)
        XCTAssertEqual(buyGroceries?["status"] as? String, "todo")
    }

    // MARK: - Test: Full push pipeline — CSV edit to API update

    func testFullPushPipeline_CSVEditToAPIUpdate() async throws {
        let client = makeClient()

        // Step 1: Pull tasks
        let tasks = try await getTasks(client)
        XCTAssertEqual(tasks.count, 3)

        // Step 2: Convert to CSV
        let csvData = try CSVFormat.encode(records: tasks, options: nil)

        // Step 3: Write to temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-tasks-push-\(UUID().uuidString).csv")
        try csvData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Step 4: Modify the CSV (change task 2's status from "in-progress" to "done")
        var csvString = String(data: csvData, encoding: .utf8)!
        csvString = csvString.replacingOccurrences(of: "in-progress", with: "done")
        try csvString.data(using: .utf8)!.write(to: tempFile)

        // Step 5: Decode the modified CSV
        let modifiedData = try Data(contentsOf: tempFile)
        let modifiedRecords = try CSVFormat.decode(data: modifiedData, options: nil)
        XCTAssertEqual(modifiedRecords.count, 3)

        // Step 6: Find the changed record (task with id 2)
        let changedRecord = modifiedRecords.first(where: {
            if let id = $0["id"] as? Int { return id == 2 }
            return false
        })
        XCTAssertNotNil(changedRecord)
        XCTAssertEqual(changedRecord?["status"] as? String, "done")

        // Step 7: PUT the update to the server
        let updateBody = try JSONSerialization.data(withJSONObject: ["status": "done"])
        let putRequest = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/tasks/2",
            headers: ["Content-Type": "application/json"],
            body: updateBody
        )
        let putResponse = try await client.request(putRequest)
        XCTAssertEqual(putResponse.statusCode, 200)

        // Step 8: GET the task back and verify the change persisted
        let updatedTask = try await getTask(client, id: 2)
        XCTAssertEqual(updatedTask["status"] as? String, "done")
        XCTAssertEqual(updatedTask["name"] as? String, "Fix login bug")
    }

    // MARK: - Test: Full round-trip — pull, edit CSV, push

    func testFullRoundTrip_PullEditCSVPush() async throws {
        let client = makeClient()

        // Step 1: Pull all tasks to CSV
        let tasks = try await getTasks(client)
        XCTAssertEqual(tasks.count, 3)
        let csvData = try CSVFormat.encode(records: tasks, options: nil)
        let csvString = String(data: csvData, encoding: .utf8)!

        // Step 2: Add a new row to the CSV (new task — no existing id)
        // Parse headers to build a proper new row
        let csvLines = csvString.components(separatedBy: "\n").filter { !$0.isEmpty }
        let headers = csvLines[0]
        let headerFields = headers.components(separatedBy: ",")

        // Build new row matching header order
        var newRowValues: [String] = []
        for field in headerFields {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            switch trimmed {
            case "_id": newRowValues.append("") // no id for new task
            case "name": newRowValues.append("Run integration tests")
            case "status": newRowValues.append("todo")
            case "priority": newRowValues.append("high")
            case "assignee": newRowValues.append("Dave")
            case "dueDate": newRowValues.append("2026-04-15")
            default: newRowValues.append("")
            }
        }
        let newRow = newRowValues.joined(separator: ",")
        let modifiedCSV = csvString.trimmingCharacters(in: .newlines) + "\n" + newRow + "\n"

        // Step 3: Decode the modified CSV
        let modifiedData = Data(modifiedCSV.utf8)
        let modifiedRecords = try CSVFormat.decode(data: modifiedData, options: nil)
        XCTAssertEqual(modifiedRecords.count, 4)

        // Step 4: Detect the new record (empty or missing id)
        let newRecord = modifiedRecords.first(where: {
            let idVal = $0["id"]
            if idVal == nil { return true }
            if let strId = idVal as? String, strId.isEmpty { return true }
            return false
        })
        XCTAssertNotNil(newRecord, "Should detect one new record without an id")
        XCTAssertEqual(newRecord?["name"] as? String, "Run integration tests")

        // Step 5: POST to create the new task
        var createPayload: [String: Any] = [:]
        createPayload["name"] = newRecord?["name"]
        createPayload["status"] = newRecord?["status"]
        createPayload["priority"] = newRecord?["priority"]
        createPayload["assignee"] = newRecord?["assignee"]
        createPayload["dueDate"] = newRecord?["dueDate"]

        let createBody = try JSONSerialization.data(withJSONObject: createPayload)
        let createRequest = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/tasks",
            headers: ["Content-Type": "application/json"],
            body: createBody
        )
        let createResponse = try await client.request(createRequest)
        XCTAssertEqual(createResponse.statusCode, 201)

        // Step 6: Pull again
        let updatedTasks = try await getTasks(client)
        XCTAssertEqual(updatedTasks.count, 4, "Should have 4 tasks after adding one")

        // Step 7: Verify the new task appears in the API
        let newTaskInAPI = updatedTasks.first(where: { ($0["name"] as? String) == "Run integration tests" })
        XCTAssertNotNil(newTaskInAPI, "New task should exist in the API")
        XCTAssertEqual(newTaskInAPI?["status"] as? String, "todo")
        XCTAssertEqual(newTaskInAPI?["priority"] as? String, "high")
        XCTAssertEqual(newTaskInAPI?["assignee"] as? String, "Dave")

        // Step 8: Re-pull as CSV and verify new task is in re-pulled CSV
        let rePulledCSVData = try CSVFormat.encode(records: updatedTasks, options: nil)
        let rePulledRecords = try CSVFormat.decode(data: rePulledCSVData, options: nil)
        XCTAssertEqual(rePulledRecords.count, 4)
        let rePulledNewTask = rePulledRecords.first(where: { ($0["name"] as? String) == "Run integration tests" })
        XCTAssertNotNil(rePulledNewTask, "New task should appear in re-pulled CSV")
    }

    // MARK: - Test: Services CRUD (DevOps adapter)

    func testPullServicesFromDemoServer() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/services")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let services = json as? [[String: Any]] else {
            XCTFail("Expected array of services"); return
        }
        XCTAssertEqual(services.count, 3, "Should have 3 seed services")

        let auth = services.first(where: { ($0["name"] as? String) == "auth-service" })
        XCTAssertNotNil(auth)
        XCTAssertEqual(auth?["status"] as? String, "healthy")
        XCTAssertEqual(auth?["version"] as? String, "3.2.1")

        let payment = services.first(where: { ($0["name"] as? String) == "payment-api" })
        XCTAssertNotNil(payment)
        XCTAssertEqual(payment?["status"] as? String, "degraded")
    }

    func testCreateServiceViaAPI() async throws {
        let client = makeClient()

        let newService: [String: Any] = [
            "name": "email-gateway",
            "status": "healthy",
            "uptime": 99.9,
            "lastChecked": "2026-03-23T11:00:00Z",
            "responseTimeMs": 80,
            "version": "1.0.0"
        ]
        let body = try JSONSerialization.data(withJSONObject: newService)
        let createRequest = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/services",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let createResponse = try await client.request(createRequest)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertEqual(created?["name"] as? String, "email-gateway")

        // Verify 4 services now
        let listRequest = APIRequest(method: .GET, url: "\(baseURL)/api/services")
        let listResponse = try await client.request(listRequest)
        let all = try JSONSerialization.jsonObject(with: listResponse.body) as? [[String: Any]]
        XCTAssertEqual(all?.count, 4)
    }

    func testUpdateServiceViaAPI() async throws {
        let client = makeClient()

        let update: [String: Any] = ["status": "healthy", "responseTimeMs": 50]
        let body = try JSONSerialization.data(withJSONObject: update)
        let putRequest = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/services/2",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let putResponse = try await client.request(putRequest)
        XCTAssertEqual(putResponse.statusCode, 200)

        let updated = try JSONSerialization.jsonObject(with: putResponse.body) as? [String: Any]
        XCTAssertEqual(updated?["status"] as? String, "healthy")
        XCTAssertEqual(updated?["responseTimeMs"] as? Int, 50)
        XCTAssertEqual(updated?["name"] as? String, "payment-api") // unchanged
    }

    func testDeleteServiceViaAPI() async throws {
        let client = makeClient()

        let deleteRequest = APIRequest(method: .DELETE, url: "\(baseURL)/api/services/3")
        let deleteResponse = try await client.request(deleteRequest)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let listRequest = APIRequest(method: .GET, url: "\(baseURL)/api/services")
        let listResponse = try await client.request(listRequest)
        let all = try JSONSerialization.jsonObject(with: listResponse.body) as? [[String: Any]]
        XCTAssertEqual(all?.count, 2)
    }

    // MARK: - Test: Incidents CRUD (DevOps adapter)

    func testPullIncidentsFromDemoServer() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/incidents")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let incidents = json as? [[String: Any]] else {
            XCTFail("Expected array of incidents"); return
        }
        XCTAssertEqual(incidents.count, 4, "Should have 4 seed incidents")

        let critical = incidents.first(where: { ($0["severity"] as? String) == "critical" })
        XCTAssertNotNil(critical)
        XCTAssertEqual(critical?["service"] as? String, "payment-api")
        XCTAssertEqual(critical?["message"] as? String, "Database connection pool exhausted")
        XCTAssertEqual(critical?["resolved"] as? Bool, false)
    }

    func testCreateIncidentViaAPI() async throws {
        let client = makeClient()

        let newIncident: [String: Any] = [
            "timestamp": "2026-03-23T12:00:00Z",
            "severity": "warning",
            "service": "auth-service",
            "message": "Elevated login failure rate",
            "resolved": false
        ]
        let body = try JSONSerialization.data(withJSONObject: newIncident)
        let createRequest = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/incidents",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let createResponse = try await client.request(createRequest)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertEqual(created?["severity"] as? String, "warning")
        XCTAssertEqual(created?["service"] as? String, "auth-service")

        // Verify 5 incidents now
        let listRequest = APIRequest(method: .GET, url: "\(baseURL)/api/incidents")
        let listResponse = try await client.request(listRequest)
        let all = try JSONSerialization.jsonObject(with: listResponse.body) as? [[String: Any]]
        XCTAssertEqual(all?.count, 5)
    }

    func testUpdateIncidentViaAPI() async throws {
        let client = makeClient()

        let update: [String: Any] = ["resolved": true]
        let body = try JSONSerialization.data(withJSONObject: update)
        let putRequest = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/incidents/2",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let putResponse = try await client.request(putRequest)
        XCTAssertEqual(putResponse.statusCode, 200)

        let updated = try JSONSerialization.jsonObject(with: putResponse.body) as? [String: Any]
        XCTAssertEqual(updated?["resolved"] as? Bool, true)
        XCTAssertEqual(updated?["severity"] as? String, "warning") // unchanged
    }

    func testDeleteIncidentViaAPI() async throws {
        let client = makeClient()

        let deleteRequest = APIRequest(method: .DELETE, url: "\(baseURL)/api/incidents/1")
        let deleteResponse = try await client.request(deleteRequest)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let listRequest = APIRequest(method: .GET, url: "\(baseURL)/api/incidents")
        let listResponse = try await client.request(listRequest)
        let all = try JSONSerialization.jsonObject(with: listResponse.body) as? [[String: Any]]
        XCTAssertEqual(all?.count, 3)
    }

    // MARK: - Test: Server reset

    func testServerReset() async throws {
        let client = makeClient()

        // Create a new task
        let newTask: [String: Any] = ["name": "Temporary task", "status": "todo", "priority": "low", "assignee": "Eve", "dueDate": "2026-05-01"]
        let createBody = try JSONSerialization.data(withJSONObject: newTask)
        let createRequest = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/tasks",
            headers: ["Content-Type": "application/json"],
            body: createBody
        )
        let createResponse = try await client.request(createRequest)
        XCTAssertEqual(createResponse.statusCode, 201)

        // Delete task 1
        let deleteRequest = APIRequest(method: .DELETE, url: "\(baseURL)/api/tasks/1")
        let deleteResponse = try await client.request(deleteRequest)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        // Verify state is modified
        let modifiedTasks = try await getTasks(client)
        XCTAssertEqual(modifiedTasks.count, 3) // 3 seed - 1 deleted + 1 created = 3
        let task1Before = modifiedTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNil(task1Before, "Task 1 should be deleted")

        // Reset the server
        await server.reset()

        // Verify back to 3 seed tasks
        let resetTasks = try await getTasks(client)
        XCTAssertEqual(resetTasks.count, 3, "Should be back to 3 seed tasks after reset")

        // Verify seed tasks are restored
        let task1After = resetTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(task1After, "Task 1 should be restored after reset")
        XCTAssertEqual(task1After?["name"] as? String, "Buy groceries")

        let task2After = resetTasks.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(task2After)
        XCTAssertEqual(task2After?["name"] as? String, "Fix login bug")

        let task3After = resetTasks.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNotNil(task3After)
        XCTAssertEqual(task3After?["name"] as? String, "Write docs")

        // Verify temporary task is gone
        let tempTask = resetTasks.first(where: { ($0["name"] as? String) == "Temporary task" })
        XCTAssertNil(tempTask, "Temporary task should be gone after reset")
    }
}
