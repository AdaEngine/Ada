import AdaUIDescription

/// A2UI root-scoped JSON Pointer. Relative collection scopes are not advertised by this catalog.
struct A2UIPointer: Hashable {
    let tokens: [String]
    let path: String

    init(_ path: String) throws {
        guard path.utf8.count <= 4096, path.split(separator: "/", omittingEmptySubsequences: false).count <= 65 else {
            throw A2UIValidationError(path: "/path", message: "JSON Pointer exceeds the length or depth limit.")
        }
        guard path.isEmpty || path.hasPrefix("/") else {
            throw A2UIValidationError(path: "/path", message: "This catalog requires an absolute JSON Pointer.")
        }
        self.path = path
        if path.isEmpty || path == "/" {
            tokens = []
        } else {
            tokens = try path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { token in
                var result = ""
                var iterator = token.makeIterator()
                while let character = iterator.next() {
                    if character != "~" {
                        result.append(character)
                    } else {
                        switch iterator.next() {
                        case "0": result.append("~")
                        case "1": result.append("/")
                        default: throw A2UIValidationError(path: "/path", message: "Invalid JSON Pointer escape.")
                        }
                    }
                }
                return result
            }
        }
    }

    var bindingName: String { "data_" + path.utf8.map { String($0, radix: 16) }.joined(separator: "_") }

    func read(_ root: UIValue) -> UIValue? {
        var value = root
        for token in tokens {
            switch value {
            case let .object(fields):
                guard let next = fields[token] else {
                    return nil
                }
                value = next
            case let .array(items):
                guard let index = arrayIndex(token), items.indices.contains(index) else {
                    return nil
                }
                value = items[index]
            default: return nil
            }
        }
        return value
    }

    /// Missing value deletes object keys; array deletions retain their slot as JSON null.
    func replacing(in root: UIValue, with value: UIValue?) throws -> UIValue {
        try replace(root, tokens: tokens[...], value: value)
    }

    private func replace(_ current: UIValue, tokens: ArraySlice<String>, value: UIValue?) throws -> UIValue {
        guard let token = tokens.first else {
            return value ?? .object([:])
        }
        switch current {
        case var .array(items):
            guard let index = arrayIndex(token), index <= items.count else {
                throw A2UIValidationError(path: path, message: "Invalid or out-of-range array index.")
            }
            if index == items.count {
                guard value != nil else {
                    return current
                }
                items.append(.object([:]))
            }
            items[index] = tokens.count == 1
                ? value ?? .null
                : try replace(items[index], tokens: tokens.dropFirst(), value: value)
            return .array(items)
        case var .object(fields):
            if tokens.count == 1 {
                fields[token] = value
            } else {
                if value == nil, fields[token] == nil {
                    return current
                }
                fields[token] = try replace(fields[token] ?? .object([:]), tokens: tokens.dropFirst(), value: value)
            }
            return .object(fields)
        default:
            throw A2UIValidationError(path: path, message: "Cannot traverse a scalar data value.")
        }
    }

    private func arrayIndex(_ token: String) -> Int? {
        guard token == "0" || (!token.hasPrefix("0") && !token.isEmpty), token.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(token)
    }
}
