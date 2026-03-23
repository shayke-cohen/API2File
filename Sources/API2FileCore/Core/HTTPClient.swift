import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP Method

public enum HTTPMethod: String, Sendable {
    case GET
    case POST
    case PUT
    case PATCH
    case DELETE
}

// MARK: - APIRequest

public struct APIRequest: Sendable {
    public let method: HTTPMethod
    public let url: String
    public let headers: [String: String]
    public let body: Data?
    public let timeout: TimeInterval

    public init(
        method: HTTPMethod = .GET,
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

// MARK: - APIResponse

public struct APIResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let duration: TimeInterval

    public init(statusCode: Int, headers: [String: String], body: Data, duration: TimeInterval) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.duration = duration
    }
}

// MARK: - APIError

public enum APIError: Error, Sendable {
    case unauthorized
    case rateLimited
    case serverError(Int)
    case networkError(Error)
    case timeout
    case invalidResponse

    // Sendable conformance requires manually implementing Equatable-like behavior
    // since Error is not Sendable by default. We wrap it.
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication failed — invalid or missing credentials."
        case .rateLimited:
            return "Rate limited by the server. Retry later."
        case .serverError(let code):
            return "Server error (HTTP \(code))."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .timeout:
            return "Request timed out."
        case .invalidResponse:
            return "Invalid or unparseable response from server."
        }
    }
}

// MARK: - HTTPClient

/// A thread-safe HTTP client with auth injection, rate-limit handling, and retry logic.
public actor HTTPClient {
    private let session: URLSession
    private var authHeader: (name: String, value: String)?

    /// Retry delays for 5xx errors (exponential backoff).
    private static let retryDelays: [TimeInterval] = [1, 5, 15]
    private static let maxRetries = 3

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Auth

    /// Sets a persistent auth header that is injected into every request.
    public func setAuthHeader(_ header: String, value: String) {
        self.authHeader = (name: header, value: value)
    }

    /// Clears the stored auth header.
    public func clearAuthHeader() {
        self.authHeader = nil
    }

    // MARK: - Request

    /// Sends an API request with automatic retry for 5xx and 429 responses.
    public func request(_ apiRequest: APIRequest) async throws -> APIResponse {
        var lastError: Error?

        for attempt in 0...Self.maxRetries {
            do {
                let response = try await performRequest(apiRequest)

                // 2xx — success
                if (200..<300).contains(response.statusCode) {
                    return response
                }

                // 401 — unauthorized, fail immediately
                if response.statusCode == 401 {
                    throw APIError.unauthorized
                }

                // 429 — rate limited, read Retry-After and wait
                if response.statusCode == 429 {
                    let retryAfter = parseRetryAfter(from: response.headers)
                    if attempt < Self.maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }
                    throw APIError.rateLimited
                }

                // 5xx — server error, retry with exponential backoff
                if (500..<600).contains(response.statusCode) {
                    if attempt < Self.maxRetries {
                        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        lastError = APIError.serverError(response.statusCode)
                        continue
                    }
                    throw APIError.serverError(response.statusCode)
                }

                // Other non-2xx — return the response as-is (caller decides)
                return response

            } catch let error as APIError {
                // Re-throw non-retryable API errors immediately
                switch error {
                case .unauthorized, .invalidResponse:
                    throw error
                case .rateLimited where attempt >= Self.maxRetries:
                    throw error
                case .serverError where attempt >= Self.maxRetries:
                    throw error
                default:
                    lastError = error
                }
            } catch let error as URLError where error.code == .timedOut {
                throw APIError.timeout
            } catch {
                throw APIError.networkError(error)
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    // MARK: - Internal

    private func performRequest(_ apiRequest: APIRequest) async throws -> APIResponse {
        guard let url = URL(string: apiRequest.url) else {
            throw APIError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = apiRequest.method.rawValue
        urlRequest.timeoutInterval = apiRequest.timeout
        urlRequest.httpBody = apiRequest.body

        // Merge headers: request-level headers take precedence
        if let auth = authHeader {
            urlRequest.setValue(auth.value, forHTTPHeaderField: auth.name)
        }
        for (key, value) in apiRequest.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let (data, urlResponse) = try await session.data(for: urlRequest)
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Convert header fields to [String: String]
        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                responseHeaders[k] = v
            }
        }

        return APIResponse(
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data,
            duration: duration
        )
    }

    /// Parses the `Retry-After` header. Supports seconds (integer) format.
    /// Defaults to 1 second if the header is missing or unparseable.
    private func parseRetryAfter(from headers: [String: String]) -> TimeInterval {
        // Check case-insensitive
        let value = headers["Retry-After"] ?? headers["retry-after"] ?? "1"
        return TimeInterval(value) ?? 1.0
    }
}
