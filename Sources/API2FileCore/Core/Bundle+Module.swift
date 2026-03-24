import Foundation

// SPM auto-generates `Bundle.module` for packages with resources.
// Xcode (xcodegen) does not — this shim provides it for Xcode builds.
#if !SWIFT_PACKAGE
extension Bundle {
    static var module: Bundle = {
        class _BundleFinder {}
        return Bundle(for: _BundleFinder.self)
    }()
}
#endif
