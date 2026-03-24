import SwiftUI
#if DEBUG
import AppXray
#endif

extension View {
    /// Assign a test ID for AppXray and accessibility.
    /// Uses `.xrayId()` in DEBUG (registers in AppXray's O(1) registry + sets accessibilityIdentifier),
    /// falls back to `.accessibilityIdentifier()` in release builds.
    func testId(_ id: String) -> some View {
        #if DEBUG
        return self.xrayId(id)
        #else
        return self.accessibilityIdentifier(id)
        #endif
    }
}
