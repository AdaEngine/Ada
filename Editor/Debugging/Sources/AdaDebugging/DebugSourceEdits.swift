import Foundation

public enum DebugSourceEdits {
    /// Moves line anchors across a text replacement, dropping anchors on deleted lines.
    public static func relocate(_ breakpoints: [SourceBreakpoint], path: String, old: String, new: String) -> [SourceBreakpoint] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let inserted = after.count - prefix - suffix
        let removed = before.count - prefix - suffix
        return breakpoints.compactMap { breakpoint in
            guard breakpoint.path == path, breakpoint.line > prefix else { return breakpoint }
            var result = breakpoint
            if breakpoint.line > prefix + removed { result.line += inserted - removed }
            else if inserted == 0 { return nil }
            else { result.line = prefix + min(breakpoint.line - prefix, inserted) }
            return result
        }
    }
}
