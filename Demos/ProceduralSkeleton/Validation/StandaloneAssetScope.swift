import Foundation

// The CLI has no ECS asset manager. Supply only the loader's resource-scope boundary;
// GLB decoding, skin/animation import and writing all use the actual engine sources.
// This host always restricts external dependencies instead of granting unrestricted access.
enum AssetsManager {
    static let restrictedResourceRoot: URL? = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["SKELETON_RIG_RESOURCE_ROOT"] ?? FileManager.default.currentDirectoryPath)
}
