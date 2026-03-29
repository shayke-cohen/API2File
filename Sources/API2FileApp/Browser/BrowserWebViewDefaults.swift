import WebKit

enum BrowserWebViewDefaults {
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let crawlerUserAgent =
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    private static let sharedProcessPool = WKProcessPool()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.processPool = sharedProcessPool
        config.websiteDataStore = .default()
        return config
    }

    static func makeStaticSnapshotConfiguration() -> WKWebViewConfiguration {
        let config = makeConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }

    static func configure(_ webView: WKWebView) {
        webView.customUserAgent = safariUserAgent
    }
}
