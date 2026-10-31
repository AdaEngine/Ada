import Foundation

/// Only authored group paths create sections; field names and value paths never do.
enum EditorInspectorFieldLayout {
    struct Row: Identifiable, Equatable {
        var id: String
        var level: Int
        var fieldIndex: Int?
        var groupPath: [String]
        var title: String
    }

    static func rows(fields: [EditorComponentField], collapsed: Set<String> = []) -> [Row] {
        let paths = fields.map { Array($0.groupPath.prefix(4)) }
        func append(prefix: [String], indices: [Int], to rows: inout [Row]) {
            var seen = Set<String>()
            for index in indices {
                let path = paths[index]
                guard path.count > prefix.count else {
                    rows.append(
                        Row(
                            id: "field:\(fields[index].id)", level: prefix.count,
                            fieldIndex: index, groupPath: [], title: ""))
                    continue
                }
                let title = path[prefix.count]
                guard seen.insert(title).inserted else { continue }
                let group = prefix + [title]
                let id = group.joined(separator: "/")
                rows.append(Row(id: "group:\(id)", level: prefix.count, groupPath: group, title: title))
                if !collapsed.contains(id) {
                    append(prefix: group, indices: indices.filter { paths[$0].starts(with: group) }, to: &rows)
                }
            }
        }
        var result: [Row] = []
        append(prefix: [], indices: Array(fields.indices), to: &result)
        return result
    }
}
