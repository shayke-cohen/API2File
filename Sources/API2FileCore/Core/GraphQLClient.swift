import Foundation

// MARK: - GraphQL Error

public struct GraphQLError: Error, Sendable {
    public let message: String
    public let locations: [[String: Int]]?
    public let path: [String]?

    public init(message: String, locations: [[String: Int]]? = nil, path: [String]? = nil) {
        self.message = message
        self.locations = locations
        self.path = path
    }
}

extension GraphQLError: LocalizedError {
    public var errorDescription: String? {
        "GraphQL error: \(message)"
    }
}

/// Aggregated GraphQL errors from a single response.
public struct GraphQLResponseError: Error, Sendable {
    public let errors: [GraphQLError]

    public init(errors: [GraphQLError]) {
        self.errors = errors
    }
}

extension GraphQLResponseError: LocalizedError {
    public var errorDescription: String? {
        let messages = errors.map(\.message).joined(separator: "; ")
        return "GraphQL errors: \(messages)"
    }
}

// MARK: - GraphQLClient

/// A client that wraps `HTTPClient` for GraphQL query and mutation operations.
public actor GraphQLClient {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    // MARK: - Query

    /// Executes a GraphQL query and returns the `data` dictionary from the response.
    ///
    /// - Parameters:
    ///   - query: The GraphQL query string.
    ///   - variables: Optional dictionary of variables.
    ///   - url: The GraphQL endpoint URL.
    /// - Returns: The `data` dictionary from the response.
    /// - Throws: `GraphQLResponseError` if the response contains errors, or `APIError` for transport-level failures.
    public func query(
        _ query: String,
        variables: [String: Any]? = nil,
        url: String
    ) async throws -> [String: Any] {
        return try await execute(query: query, variables: variables, url: url)
    }

    // MARK: - Mutation

    /// Executes a GraphQL mutation and returns the `data` dictionary from the response.
    ///
    /// - Parameters:
    ///   - mutation: The GraphQL mutation string.
    ///   - variables: Optional dictionary of variables.
    ///   - url: The GraphQL endpoint URL.
    /// - Returns: The `data` dictionary from the response.
    /// - Throws: `GraphQLResponseError` if the response contains errors, or `APIError` for transport-level failures.
    public func mutate(
        _ mutation: String,
        variables: [String: Any]? = nil,
        url: String
    ) async throws -> [String: Any] {
        return try await execute(query: mutation, variables: variables, url: url)
    }

    // MARK: - Internal

    private func execute(
        query: String,
        variables: [String: Any]?,
        url: String
    ) async throws -> [String: Any] {
        // Build the JSON body: {"query": "...", "variables": {...}}
        var bodyDict: [String: Any] = ["query": query]
        if let variables = variables {
            bodyDict["variables"] = variables
        }

        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        let apiRequest = APIRequest(
            method: .POST,
            url: url,
            headers: ["Content-Type": "application/json"],
            body: bodyData
        )

        let response = try await httpClient.request(apiRequest)

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw APIError.invalidResponse
        }

        // Check for GraphQL-level errors
        if let errorsArray = json["errors"] as? [[String: Any]], !errorsArray.isEmpty {
            let graphQLErrors = errorsArray.map { errorDict -> GraphQLError in
                let message = errorDict["message"] as? String ?? "Unknown GraphQL error"
                let locations = errorDict["locations"] as? [[String: Int]]
                let path = errorDict["path"] as? [String]
                return GraphQLError(message: message, locations: locations, path: path)
            }
            throw GraphQLResponseError(errors: graphQLErrors)
        }

        // Return the data dictionary
        guard let data = json["data"] as? [String: Any] else {
            throw APIError.invalidResponse
        }

        return data
    }
}
