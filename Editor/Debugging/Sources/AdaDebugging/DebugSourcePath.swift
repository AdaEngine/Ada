import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum DebugSourcePath {
    /// DWARF uses physical paths. Foundation may normalize /private/var back to /var,
    /// so use realpath when constructing a mapping from compiler paths to editor paths.
    public static func physical(_ path: String) -> String {
        #if canImport(Darwin)
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
        #else
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        #endif
    }
}
