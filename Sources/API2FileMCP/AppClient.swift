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
    func get(_ path: String) throws -> (Int, Data) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return try performRequest(request)
    }

    /// Perform a synchronous POST request with an optional JSON body.
    /// Returns (HTTP status code, response body data).
    func post(_ path: String, body: [String: Any]? = nil) throws -> (Int, Data) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        return try performRequest(request)
    }

    // MARK: - Private

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
