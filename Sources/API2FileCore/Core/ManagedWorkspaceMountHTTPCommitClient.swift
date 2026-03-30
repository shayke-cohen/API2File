import Foundation

#if canImport(Darwin)
import Darwin
#endif

public final class ManagedWorkspaceMountHTTPCommitClient: ManagedWorkspaceMountCommitClient {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func commit(relativePath: String, data: Data, sourceApplication: String?) async throws {
        let route = try route(for: relativePath)
        var request = URLRequest(url: route.url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let sourceApplication, !sourceApplication.isEmpty {
            request.setValue(sourceApplication, forHTTPHeaderField: "X-API2File-Source-Application")
        }
        let (responseData, response) = try await session.data(for: request)
        try validate(response: response, data: responseData)
    }

    public func remove(relativePath: String, sourceApplication: String?) async throws {
        let route = try route(for: relativePath)
        var request = URLRequest(url: route.url)
        request.httpMethod = "DELETE"
        if let sourceApplication, !sourceApplication.isEmpty {
            request.setValue(sourceApplication, forHTTPHeaderField: "X-API2File-Source-Application")
        }
        let (responseData, response) = try await session.data(for: request)
        try validate(response: response, data: responseData)
    }

    private func route(for relativePath: String) throws -> (serviceId: String, filePath: String, url: URL) {
        let normalized = relativePath
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .map(String.init)
        guard normalized.count >= 2 else {
            throw posixError(EINVAL, "Managed mount paths must include a service directory.")
        }

        let serviceId = normalized[0]
        let filePath = normalized.dropFirst().joined(separator: "/")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw posixError(EIO, "Invalid managed mount server URL.")
        }
        components.path = "/api/services/\(serviceId)/workspace/file"
        components.queryItems = [URLQueryItem(name: "path", value: filePath)]
        guard let url = components.url else {
            throw posixError(EIO, "Failed to construct managed mount commit URL.")
        }
        return (serviceId, filePath, url)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw posixError(EIO, "Managed mount server returned an invalid response.")
        }
        if (200..<300).contains(httpResponse.statusCode) {
            return
        }

        let message = parseErrorMessage(data: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
        switch httpResponse.statusCode {
        case 400, 404, 409, 422:
            throw posixError(EINVAL, message)
        case 401, 403:
            throw posixError(EPERM, message)
        default:
            throw posixError(EIO, message)
        }
    }

    private func parseErrorMessage(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        return json["error"] as? String
    }

    private func posixError(_ code: Int32, _ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}
