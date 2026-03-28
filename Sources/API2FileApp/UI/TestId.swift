import SwiftUI
#if DEBUG
#if canImport(AppXray)
import AppXray
#endif
#endif

extension View {
    /// Assign a test ID for AppXray and accessibility.
    /// Uses `.xrayId()` in DEBUG (registers in AppXray's O(1) registry + sets accessibilityIdentifier),
    /// falls back to `.accessibilityIdentifier()` in release builds.
    func testId(_ id: String) -> some View {
        #if DEBUG
        #if canImport(AppXray)
        return self.xrayId(id)
        #else
        return self.accessibilityIdentifier(id)
        #endif
        #else
        return self.accessibilityIdentifier(id)
        #endif
    }
}
