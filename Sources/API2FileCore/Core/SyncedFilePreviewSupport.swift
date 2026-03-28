import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum SyncedFilePreviewKind: String, Sendable {
    case csv
    case markdown
    case json
    case html
    case yaml
    case text
    case image
    case svg
    case pdf
    case audio
    case movie
    case calendar
    case contact
    case email
    case office
    case archive
    case binary
}

public enum SyncedFilePreviewSupport {
    public static let editableExtensions: Set<String> = [
        "csv", "md", "markdown", "json", "txt", "yaml", "yml", "html", "htm",
        "ics", "vcf", "eml", "xml", "log", "ini", "toml"
    ]

    public static let quickLookTypeIdentifiers: [String] = [
        "public.comma-separated-values-text",
        "net.daringfireball.markdown",
        "public.json",
        "public.plain-text",
        "public.yaml",
        "public.html",
        "public.svg-image",
        "public.calendar-event",
        "public.vcard",
        "public.email-message",
        "public.image",
        "com.adobe.pdf",
        "public.audio",
        "public.movie",
        "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.presentationml.presentation",
    ]

    public static func kind(for fileURL: URL) -> SyncedFilePreviewKind {
        switch fileURL.pathExtension.lowercased() {
        case "csv":
            return .csv
        case "md", "markdown":
            return .markdown
        case "json":
            return .json
        case "html", "htm":
            return .html
        case "yaml", "yml":
            return .yaml
        case "txt", "xml", "log", "ini", "toml":
            return .text
        case "png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "heic", "heif", "ico":
            return .image
        case "svg":
            return .svg
        case "pdf":
            return .pdf
        case "mp3", "wav", "m4a", "aac", "flac":
            return .audio
        case "mp4", "mov", "m4v", "avi":
            return .movie
        case "ics":
            return .calendar
        case "vcf":
            return .contact
        case "eml":
            return .email
        case "docx", "xlsx", "pptx":
            return .office
        case "zip":
            return .archive
        default:
            return .binary
        }
    }

    public static func isUserFacingFile(_ fileURL: URL, serviceRoot: URL) -> Bool {
        guard let relativePath = relativePath(for: fileURL, serviceRoot: serviceRoot) else {
            return false
        }

        return isUserFacingRelativePath(relativePath)
    }

    public static func isUserFacingRelativePath(_ relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return false }

        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        if components.contains(where: { $0.hasPrefix(".") }) {
            return false
        }

        if normalized.contains(".objects/") || normalized.contains(".conflict.") {
            return false
        }

        return true
    }

    public static func userFacingFiles(in serviceRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: serviceRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard isUserFacingFile(url, serviceRoot: serviceRoot) else { continue }
            files.append(url)
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    public static func defaultPreviewCandidate(in serviceRoot: URL) -> URL? {
        let files = userFacingFiles(in: serviceRoot)
        guard !files.isEmpty else { return nil }

        return files.max { lhs, rhs in
            let lhsDate = modificationDate(for: lhs)
            let rhsDate = modificationDate(for: rhs)
            if lhsDate == rhsDate {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedDescending
            }
            return lhsDate < rhsDate
        }
    }

    public static func relativePath(for fileURL: URL, serviceRoot: URL) -> String? {
        let filePath = fileURL.standardizedFileURL.path
        let servicePath = serviceRoot.standardizedFileURL.path
        guard filePath.hasPrefix(servicePath) else { return nil }

        let suffix = filePath.dropFirst(servicePath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? nil : suffix
    }

    public static func supportsInlineEditing(_ fileURL: URL) -> Bool {
        switch kind(for: fileURL) {
        case .csv, .markdown, .json, .html, .yaml, .text, .calendar, .contact, .email:
            return true
        case .image, .svg, .pdf, .audio, .movie, .office, .archive, .binary:
            return false
        }
    }

    #if canImport(UniformTypeIdentifiers)
    public static func passthroughContentType(for fileURL: URL) -> UTType? {
        switch kind(for: fileURL) {
        case .html, .image, .svg, .pdf, .audio, .movie:
            return UTType(filenameExtension: fileURL.pathExtension.lowercased())
        default:
            return nil
        }
    }
    #endif

    public static func fileKindLabel(for fileURL: URL) -> String {
        switch kind(for: fileURL) {
        case .csv:
            return "CSV"
        case .markdown:
            return "Markdown"
        case .json:
            return "JSON"
        case .html:
            return "HTML"
        case .yaml:
            return "YAML"
        case .text:
            return "Text"
        case .image:
            return "Image"
        case .svg:
            return "SVG"
        case .pdf:
            return "PDF"
        case .audio:
            return "Audio"
        case .movie:
            return "Video"
        case .calendar:
            return "Calendar"
        case .contact:
            return "Contact"
        case .email:
            return "Email"
        case .office:
            return "Office"
        case .archive:
            return "Archive"
        case .binary:
            return fileURL.pathExtension.isEmpty ? "File" : fileURL.pathExtension.uppercased()
        }
    }

    private static func modificationDate(for fileURL: URL) -> Date {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
