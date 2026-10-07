import Foundation

/// UI diagnostics need a nominal name, never an expanded generic type spelling.
/// Both reflected and mangled names can allocate enormous intermediate trees for
/// repeated generic arguments. Read the compiler-owned nominal descriptor instead.
///
/// Safety: Swift runtime descriptors are immutable and live for the process lifetime.
/// No application pointer is accepted, retained, or mutated. Reads follow the stable
/// context-descriptor ABI (flags, relative parent, relative name), with bounded walks.
/// See swift/docs/ABI/TypeMetadata.rst and swift/include/swift/Runtime/Metadata.h.
enum UIInspectionTypeName {
    static func name(of type: Any.Type) -> String {
        guard let descriptor = unsafe contextDescriptor(type) else {
            return "Unknown"
        }
        let flags = unsafe descriptor.load(as: UInt32.self)
        guard (16...18).contains(flags & 0x1F), let nominal = relativeName(descriptor) else {
            return "Unknown"
        }
        var module: String?
        var current = parent(descriptor)
        for _ in 0..<32 {
            guard let context = current else { break }
            if unsafe context.load(as: UInt32.self) & 0x1F == 0 {
                module = relativeName(context)
                break
            }
            current = parent(context)
        }
        let prefix = module.map { $0 + "." } ?? ""
        return prefix + nominal + (flags & 0x80 != 0 ? "<…>" : "")
    }

    private static func relativeName(_ descriptor: UnsafeRawPointer) -> String? {
        // ContextDescriptor: UInt32 flags + Int32 relative parent; nominal/module name follows.
        let field = unsafe descriptor.advanced(by: 8)
        let offset = unsafe field.load(as: Int32.self)
        guard offset != 0 else {
            return nil
        }
        let name = unsafe field.advanced(by: Int(offset))
        var bytes: [UInt8] = []
        for index in 0..<128 {
            let byte = unsafe name.load(fromByteOffset: index, as: UInt8.self)
            if byte == 0 {
                return (String(bytes: bytes, encoding: .utf8) ?? "Unknown")
            }
            bytes.append(byte)
        }
        return (String(bytes: bytes, encoding: .utf8) ?? "Unknown") + "…"
    }

    private static func parent(_ descriptor: UnsafeRawPointer) -> UnsafeRawPointer? {
        let field = unsafe descriptor.advanced(by: 4)
        let offset = unsafe field.load(as: Int32.self)
        guard offset != 0 else {
            return nil
        }
        // RelativeIndirectablePointer uses bit zero to identify an indirect reference.
        let pointer = unsafe field.advanced(by: Int(offset & ~1))
        return offset & 1 == 0 ? pointer : unsafe pointer.load(as: UnsafeRawPointer?.self)
    }
}

// The runtime entry point uses Swift calling convention and accepts type metadata directly.
@_silgen_name("swift_getTypeContextDescriptor")
private func contextDescriptor(_ type: Any.Type) -> UnsafeRawPointer?
