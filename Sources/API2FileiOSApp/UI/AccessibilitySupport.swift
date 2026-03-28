import Foundation

enum IOSRootTab: String, CaseIterable, Hashable {
    case services
    case browser
    case activity
    case settings

    var title: String {
        switch self {
        case .services:
            return "Services"
        case .browser:
            return "Browser"
        case .activity:
            return "Activity"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .services:
            return "cloud"
        case .browser:
            return "folder"
        case .activity:
            return "clock.arrow.circlepath"
        case .settings:
            return "gear"
        }
    }

    var accessibilityID: String {
        IOSAccessibility.id("tab", rawValue)
    }
}

enum IOSScreenID {
    static let services = "screen.services"
    static let browser = "screen.browser"
    static let activity = "screen.activity"
    static let settings = "screen.settings"
    static let addService = "screen.add-service"
    static let fileDetail = "screen.file-detail"
}

enum IOSAccessibility {
    static func id(_ parts: String...) -> String {
        parts
            .map(slug)
            .joined(separator: ".")
    }

    static func slug(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return normalized.isEmpty ? "item" : normalized
    }
}
