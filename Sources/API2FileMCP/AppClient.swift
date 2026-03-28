import Foundation

/// HTTP client for communicating with the running API2File.app via its local REST API.
struct AppClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    init(host: String = "127.0.0.1", port: Int) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
    }

    /// Perform a synchronous GET request.
    /// Returns (HTTP status code, response body data).
    func get(_ path: String, queryItems: [URLQueryItem] = []) throws -> (Int, Data) {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return try performRequest(request)
    }

    /// Perform a synchronous POST request with an optional JSON body.
    /// Returns (HTTP status code, response body data).
    func post(_ path: String, body: [String: Any]? = nil) throws -> (Int, Data) {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0, options: []) }
        return try post(path, bodyData: bodyData)
    }

    /// Perform a synchronous POST request with an optional raw body.
    /// Returns (HTTP status code, response body data).
    func post(_ path: String, bodyData: Data?) throws -> (Int, Data) {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        return try performRequest(request)
    }

    // MARK: - Private

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppClientError.invalidResponse
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path == "/" ? "" : components.path
        components.path = basePath + normalizedPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw AppClientError.invalidResponse
        }
        return url
    }

    private func performRequest(_ request: URLRequest) throws -> (Int, Data) {
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            throw AppClientError.networkError(error.localizedDescription)
        }

        guard let httpResponse = resultResponse as? HTTPURLResponse else {
            throw AppClientError.invalidResponse
        }

        let data = resultData ?? Data()
        return (httpResponse.statusCode, data)
    }
}

enum AppClientError: Error, CustomStringConvertible {
    case networkError(String)
    case invalidResponse

    var description: String {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse: return "Invalid HTTP response"
        }
    }
}
