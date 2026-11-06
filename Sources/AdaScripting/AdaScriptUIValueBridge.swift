import AdaUI
import Gravity

/// All calls run inside AdaScriptRuntimeCoordinator's lock. Raw VM values only exist
/// during this synchronous conversion; factories receive the detached UIValue result.
enum AdaScriptUIValueBridge {
    static func make(_ value: UIValue, in vm: GravityVirtualMachine) -> GSValue {
        switch value {
        case .null: return GSValue(nullIn: vm)
        case let .bool(value): return GSValue(boolean: value, in: vm)
        case let .number(value): return GSValue(double: value, in: vm)
        case let .string(value): return GSValue(string: value, in: vm)
        case let .array(values): return GSValue(newArrayIn: vm, items: values.map { make($0, in: vm) as Any })
        case let .object(values):
            let result = GSValue(newMapIn: vm, length: values.count)
            for (key, value) in values {
                let key = GSValue(string: key, in: vm)
                let value = make(value, in: vm)
                // gravity_map_insert does not use its VM argument (also passed as NULL by Gravity's decoder).
                unsafe gravity_map_insert(nil, result.toGravityMap, key.value, value.value)
            }
            return result
        }
    }

    static func detached(_ value: GSValue, maximumNodes: Int = .max, maximumStringBytes: Int = .max) -> UIValue? {
        var nodes = maximumNodes
        var bytes = maximumStringBytes
        return unsafe detach(value.value, depth: 0, nodes: &nodes, bytes: &bytes)
    }

    private static func detach(_ value: gravity_value_t, depth: Int, nodes: inout Int, bytes: inout Int) -> UIValue? {
        guard depth < 64, nodes > 0 else {
            return nil
        }
        nodes -= 1
        if unsafe gravity_value_isa_null(value) {
            return .null
        }
        if unsafe gravity_value_isa_bool(value) {
            return .bool(value.n != 0)
        }
        if unsafe gravity_value_isa_int(value) {
            return .number(Double(value.n))
        }
        if unsafe gravity_value_isa_float(value) {
            return value.f.isFinite ? .number(value.f) : nil
        }
        if unsafe gravity_value_isa_string(value), let string = unsafe gravity_cast_value_as_string(value),
            let pointer = unsafe gravity_cast_value_as_cString(value) {
            let count = unsafe Int(string.pointee.len)
            guard count <= bytes else { return nil }
            bytes -= count
            let contents = unsafe UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: count)
            return .string(unsafe String(decoding: contents, as: UTF8.self))
        }
        if unsafe gravity_value_isa_list(value) {
            var values: [UIValue] = []
            let count = unsafe gravity_list_count(value)
            guard count <= nodes else { return nil }
            for index in 0..<count {
                guard let child = unsafe detach(gravity_list_get_value_at_index(value, Int32(index)), depth: depth + 1, nodes: &nodes, bytes: &bytes) else {
                    return nil
                }
                values.append(child)
            }
            return .array(values)
        }
        if unsafe gravity_value_isa_map(value), let map = unsafe gravity_cast_value_as_map(value) {
            // Bound the temporary inventory too. Shared subgraphs are charged again at each expansion.
            var inventory: (entries: [(gravity_value_t, gravity_value_t)], limit: Int, overflow: Bool) = ([], nodes / 2, false)
            unsafe withUnsafeMutablePointer(to: &inventory) { pointer in
                gravity_hash_iterate(
                    map.pointee.hash,
                    { _, key, value, storage in
                        guard let storage else {
                            return
                        }
                        let inventory = storage.assumingMemoryBound(to: (entries: [(gravity_value_t, gravity_value_t)], limit: Int, overflow: Bool).self)
                        if inventory.pointee.entries.count < inventory.pointee.limit { inventory.pointee.entries.append((key, value)) }
                        else { inventory.pointee.overflow = true }
                    },
                    pointer
                )
            }
            guard !inventory.overflow else { return nil }
            var result: [String: UIValue] = [:]
            for (key, value) in inventory.entries {
                guard let key = detach(key, depth: depth + 1, nodes: &nodes, bytes: &bytes)?.string,
                    let value = detach(value, depth: depth + 1, nodes: &nodes, bytes: &bytes) else {
                    return nil
                }
                result[key] = value
            }
            return .object(result)
        }
        return nil
    }
}
