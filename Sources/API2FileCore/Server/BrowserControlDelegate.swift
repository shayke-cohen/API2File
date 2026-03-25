import Foundation

/// Protocol for controlling an embedded browser window from the LocalServer actor.
/// All methods are `@MainActor` because they operate on WKWebView/NSWindow.
/// The LocalServer crosses the actor boundary via `await`.
public protocol BrowserControlDelegate: AnyObject {
    @MainActor func openBrowser() async throws
    @MainActor func isBrowserOpen() async -> Bool
    @MainActor func navigate(to url: String) async throws -> String
    @MainActor func goBack() async throws
    @MainActor func goForward() async throws
    @MainActor func reload() async throws
    @MainActor func captureScreenshot(width: Int?, height: Int?) async throws -> Data
    @MainActor func getDOM(selector: String?) async throws -> String
    @MainActor func click(selector: String) async throws
    @MainActor func type(selector: String, text: String) async throws
    @MainActor func evaluateJS(_ code: String) async throws -> String
    @MainActor func getCurrentURL() async -> String?
    @MainActor func waitFor(selector: String, timeout: TimeInterval) async throws
    @MainActor func scroll(direction: ScrollDirection, amount: Int?) async throws
}

public enum ScrollDirection: String, Sendable {
    case up, down, left, right
}

public enum BrowserError: Error, LocalizedError {
    case windowNotOpen
    case elementNotFound(selector: String)
    case timeout(selector: String, seconds: TimeInterval)
    case evaluationFailed(String)
    case navigationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .windowNotOpen:
            return "Browser window is not open"
        case .elementNotFound(let selector):
            return "Element not found: \(selector)"
        case .timeout(let selector, let seconds):
            return "Timeout after \(Int(seconds))s waiting for: \(selector)"
        case .evaluationFailed(let message):
            return "JavaScript evaluation failed: \(message)"
        case .navigationFailed(let message):
            return "Navigation failed: \(message)"
        }
    }
}
