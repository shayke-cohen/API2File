import API2FileCore
import Foundation

final actor WixRenderedPageSnapshotService: RenderedPageSnapshotService {
    private let session: URLSession
    private let browserSnapshotService: BrowserRenderedPageSnapshotService

    init(
        browserDelegate: any BrowserControlDelegate,
        session: URLSession = .shared
    ) {
        self.session = session
        self.browserSnapshotService = BrowserRenderedPageSnapshotService(browserDelegate: browserDelegate)
    }

    func capture(url: String) async throws -> RenderedPageSnapshot {
        let fetched = try await fetchCrawlerHTML(url: url)
        let preparedHTML = Self.injectBaseURL(into: fetched.sanitizedHTML, baseURL: fetched.finalURL)
        let fileURL = try Self.writeTemporaryHTML(preparedHTML)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let localSnapshot = try await browserSnapshotService.capture(url: fileURL.absoluteString)

        return RenderedPageSnapshot(
            sourceURL: url,
            finalURL: fetched.finalURL.absoluteString,
            html: localSnapshot.html,
            screenshotData: localSnapshot.screenshotData,
            title: localSnapshot.title.isEmpty ? Self.extractTitle(from: fetched.originalHTML) : localSnapshot.title
        )
    }

    private func fetchCrawlerHTML(url: String) async throws -> FetchedCrawlerPage {
        guard let sourceURL = URL(string: url) else {
            throw BrowserError.navigationFailed("Invalid URL: \(url)")
        }

        var request = URLRequest(url: sourceURL)
        request.setValue(BrowserWebViewDefaults.crawlerUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrowserError.navigationFailed("Unexpected response for \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BrowserError.navigationFailed("HTTP \(http.statusCode) for \(url)")
        }

        let finalURL = http.url ?? sourceURL
        let html = Self.decodeHTML(data: data)
        return FetchedCrawlerPage(
            finalURL: finalURL,
            originalHTML: html,
            sanitizedHTML: Self.stripScripts(from: html)
        )
    }

    private static func decodeHTML(data: Data) -> String {
        if let html = String(data: data, encoding: .utf8) {
            return html
        }
        if let html = String(data: data, encoding: .windowsCP1252) {
            return html
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stripScripts(from html: String) -> String {
        html.replacingOccurrences(
            of: #"(?is)<script\b[^>]*>.*?</script>"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func extractTitle(from html: String) -> String {
        guard let match = html.range(
            of: #"(?is)<title[^>]*>\s*(.*?)\s*</title>"#,
            options: .regularExpression
        ) else {
            return ""
        }

        let raw = String(html[match])
        return raw
            .replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func injectBaseURL(into html: String, baseURL: URL) -> String {
        let baseTag = #"<base href="\#(baseURL.absoluteString)">"#
        if html.range(of: "<base ", options: [.caseInsensitive]) != nil {
            return html
        }
        if let headRange = html.range(of: "<head>", options: [.caseInsensitive]) {
            var updated = html
            updated.insert(contentsOf: baseTag, at: headRange.upperBound)
            return updated
        }
        return baseTag + html
    }

    private static func writeTemporaryHTML(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-wix-snapshot-\(UUID().uuidString)")
            .appendingPathExtension("html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct FetchedCrawlerPage {
    let finalURL: URL
    let originalHTML: String
    let sanitizedHTML: String
}
