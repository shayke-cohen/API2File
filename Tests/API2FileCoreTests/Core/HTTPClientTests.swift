import XCTest
@testable import API2FileCore

final class HTTPClientTests: XCTestCase {

    // MARK: - APIRequest construction

    func testAPIRequestDefaults() {
        let req = APIRequest(url: "https://api.example.com/items")

        XCTAssertEqual(req.method, .GET)
        XCTAssertEqual(req.url, "https://api.example.com/items")
        XCTAssertTrue(req.headers.isEmpty)
        XCTAssertNil(req.body)
        XCTAssertEqual(req.timeout, 30)
    }

    func testAPIRequestCustomValues() {
        let body = "{\"key\":\"value\"}".data(using: .utf8)!
        let req = APIRequest(
            method: .POST,
            url: "https://api.example.com/create",
            headers: ["Content-Type": "application/json", "X-Custom": "test"],
            body: body,
            timeout: 60
        )

        XCTAssertEqual(req.method, .POST)
        XCTAssertEqual(req.url, "https://api.example.com/create")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")
        XCTAssertEqual(req.headers["X-Custom"], "test")
        XCTAssertEqual(req.body, body)
        XCTAssertEqual(req.timeout, 60)
    }

    func testAllHTTPMethods() {
        XCTAssertEqual(HTTPMethod.GET.rawValue, "GET")
        XCTAssertEqual(HTTPMethod.POST.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.PUT.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.PATCH.rawValue, "PATCH")
        XCTAssertEqual(HTTPMethod.DELETE.rawValue, "DELETE")
    }

    // MARK: - APIResponse construction

    func testAPIResponseConstruction() {
        let body = "{\"id\":1}".data(using: .utf8)!
        let response = APIResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: body,
            duration: 0.25
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        XCTAssertEqual(response.body, body)
        XCTAssertEqual(response.duration, 0.25, accuracy: 0.001)
    }

    // MARK: - APIError cases

    func testAPIErrorDescriptions() {
        let errors: [APIError] = [
            .unauthorized,
            .rateLimited,
            .serverError(503),
            .networkError(URLError(.notConnectedToInternet)),
            .timeout,
            .invalidResponse,
        ]

        // Verify all errors have non-nil descriptions
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
        }
    }

    func testAPIErrorUnauthorizedDescription() {
        let error = APIError.unauthorized
        XCTAssertTrue(error.errorDescription?.contains("Authentication") == true)
    }

    func testAPIErrorServerErrorContainsCode() {
        let error = APIError.serverError(502)
        XCTAssertTrue(error.errorDescription?.contains("502") == true)
    }

    func testAPIErrorTimeoutDescription() {
        let error = APIError.timeout
        XCTAssertTrue(error.errorDescription?.contains("timed out") == true)
    }

    // MARK: - HTTPClient auth header

    func testSetAndClearAuthHeader() async {
        let client = HTTPClient()
        await client.setAuthHeader("Authorization", value: "Bearer test-token")
        // No assertion on internal state (actor), but verifies the API compiles and runs.
        await client.clearAuthHeader()
    }

    // MARK: - GraphQL error types

    func testGraphQLErrorDescription() {
        let error = GraphQLError(message: "Field 'foo' not found")
        XCTAssertTrue(error.errorDescription?.contains("foo") == true)
    }

    func testGraphQLResponseErrorAggregation() {
        let errors = GraphQLResponseError(errors: [
            GraphQLError(message: "Error 1"),
            GraphQLError(message: "Error 2"),
        ])
        let desc = errors.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Error 1"))
        XCTAssertTrue(desc.contains("Error 2"))
    }
}
