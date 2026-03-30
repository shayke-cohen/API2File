import ExtensionFoundation
import FSKit
import Foundation

@available(macOS 26.0, *)
@main
struct API2FileManagedWorkspaceExtension: UnaryFileSystemExtension {
    var fileSystem: API2FileManagedWorkspaceFileSystem {
        API2FileManagedWorkspaceFileSystem()
    }
}
