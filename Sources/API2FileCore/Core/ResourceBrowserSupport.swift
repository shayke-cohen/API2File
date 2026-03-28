import Foundation

/// Shared browsing/path logic used by the iOS and desktop file browsers.
public enum ResourceBrowserSupport {
    public static func sortResources(_ lhs: ResourceConfig, _ rhs: ResourceConfig) -> Bool {
        let lhsFolder = lhs.fileMapping.strategy != .collection
        let rhsFolder = rhs.fileMapping.strategy != .collection
        if lhsFolder != rhsFolder { return lhsFolder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    public static func directoryURL(for resource: ResourceConfig, serviceRoot: URL) -> URL {
        let directory = resource.fileMapping.directory
        if directory == "." || directory.isEmpty {
            return serviceRoot
        }
        return serviceRoot.appendingPathComponent(directory, isDirectory: true)
    }

    public static func collectionURL(for resource: ResourceConfig, serviceRoot: URL) -> URL {
        let base = directoryURL(for: resource, serviceRoot: serviceRoot)
        let fileName = resource.fileMapping.filename ?? "\(resource.name).\(defaultExtension(for: resource.fileMapping.format))"
        return base.appendingPathComponent(fileName)
    }

    public static func resource(for fileURL: URL, in resources: [ResourceConfig], serviceRoot: URL) -> ResourceConfig? {
        let filePath = fileURL.path
        for resource in resources {
            let mapping = resource.fileMapping
            let dir = directoryURL(for: resource, serviceRoot: serviceRoot)
            if mapping.strategy == .collection {
                if let filename = mapping.filename,
                   dir.appendingPathComponent(filename).path == filePath {
                    return resource
                }
            } else if filePath.hasPrefix(dir.path) {
                return resource
            }

            if hasCMSChildren(resource),
               let child = resource.children?.first(where: { $0.fileMapping.directory.hasPrefix("cms") }),
               filePath.contains("/cms/") {
                if let filename = child.fileMapping.filename, filename.contains("{") {
                    let expectedExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
                    if !expectedExtension.isEmpty,
                       fileURL.pathExtension.lowercased() == expectedExtension {
                        return child
                    }
                } else if fileURL.lastPathComponent == child.fileMapping.filename {
                    return child
                }
            }
        }
        return nil
    }

    public static func dashboardURL(for fileURL: URL, serviceConfig: AdapterConfig, serviceRoot: URL) -> URL? {
        let resource = resource(for: fileURL, in: serviceConfig.resources, serviceRoot: serviceRoot)
        guard let dashboardURL = resource?.dashboardUrl ?? serviceConfig.dashboardUrl,
              !dashboardURL.isEmpty else {
            return nil
        }
        return URL(string: dashboardURL)
    }

    public static func defaultExtension(for format: FileFormat) -> String {
        switch format {
        case .markdown:
            return "md"
        case .yaml:
            return "yaml"
        case .text:
            return "txt"
        default:
            return format.rawValue
        }
    }

    public static func canCreateTextFile(_ resource: ResourceConfig) -> Bool {
        guard resource.fileMapping.strategy != .collection else { return false }
        guard resource.fileMapping.readOnly != true else { return false }
        switch resource.fileMapping.format {
        case .raw, .svg, .docx, .xlsx, .pptx:
            return false
        default:
            return true
        }
    }

    public static func canImportFile(_ resource: ResourceConfig) -> Bool {
        resource.fileMapping.strategy != .collection && resource.fileMapping.readOnly != true
    }

    public static func uniqueDestinationURL(
        originalName: String,
        directory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let baseURL = directory.appendingPathComponent(originalName)
        guard fileExists(baseURL) else { return baseURL }

        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        for index in 2...500 {
            let candidate = directory.appendingPathComponent("\(stem)-\(index)")
                .appendingPathExtension(ext)
            if !fileExists(candidate) {
                return candidate
            }
        }
        return baseURL
    }

    private static func hasCMSChildren(_ resource: ResourceConfig) -> Bool {
        resource.children?.contains(where: { $0.fileMapping.directory.hasPrefix("cms") }) == true
    }
}
