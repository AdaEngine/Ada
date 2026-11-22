import Foundation
import ZLib

/// Bounded, CRC-checked ZIP interchange. Exports use stored entries for portable decoding.
public enum StudioArchive {
    public static func encode(_ files: [StudioFile]) throws -> Data {
        guard files.count <= 4096, files.reduce(0, { $0 + $1.data.count }) <= StudioSnapshot.maximumBytes,
            files.allSatisfy({ StudioSnapshot.validPath($0.path) || $0.path == "ada-game.json" || $0.path == "ada-manifest.json" })
        else {
            throw StudioError.invalid("Недопустимое содержимое архива.")
        }
        var archive = Data()
        var directory = Data()
        for file in files.sorted(by: { $0.path < $1.path }) {
            let name = Data(file.path.utf8)
            let size = UInt32(file.data.count)
            let offset = UInt32(archive.count)
            let crc = crc32(file.data)
            archive.integer(UInt32(0x0403_4b50))
            for value: UInt16 in [20, 0x0800, 0, 0, 33] { archive.integer(value) }
            for value in [crc, size, size] { archive.integer(value) }
            archive.integer(UInt16(name.count))
            archive.integer(UInt16(0))
            archive.append(name)
            archive.append(file.data)
            directory.integer(UInt32(0x0201_4b50))
            for value: UInt16 in [20, 20, 0x0800, 0, 0, 33] { directory.integer(value) }
            for value in [crc, size, size] { directory.integer(value) }
            for value in [UInt16(name.count), 0, 0, 0, 0] { directory.integer(value) }
            directory.integer(UInt32(0))
            directory.integer(offset)
            directory.append(name)
        }
        let offset = UInt32(archive.count)
        archive.append(directory)
        archive.integer(UInt32(0x0605_4b50))
        for value in [UInt16(0), 0, UInt16(files.count), UInt16(files.count)] { archive.integer(value) }
        archive.integer(UInt32(directory.count))
        archive.integer(offset)
        archive.integer(UInt16(0))
        return archive
    }

    public static func decode(_ archive: Data) throws -> [StudioFile] {
        try decode(
            archive,
            maximumBytes: StudioSnapshot.maximumBytes,
            maximumFileBytes: 16 * 1024 * 1024,
            maximumFiles: StudioSnapshot.maximumFiles,
            permits: StudioSnapshot.validPath
        )
    }

    /// Decodes a bounded ZIP with a caller-owned path allowlist.
    public static func decode(
        _ archive: Data,
        maximumBytes: Int,
        maximumFileBytes: Int,
        maximumFiles: Int,
        permits: (String) -> Bool
    ) throws -> [StudioFile] {
        guard maximumBytes > 0, maximumBytes <= 128 * 1024 * 1024, maximumFileBytes > 0, maximumFileBytes <= maximumBytes,
            maximumFiles > 0, maximumFiles <= 4096, archive.count <= maximumBytes + 1024 * 1024, archive.count >= 22
        else {
            throw StudioError.invalid("Архив слишком велик или повреждён.")
        }
        var end: Int?
        for offset in stride(from: archive.count - 22, through: max(0, archive.count - 65557), by: -1) {
            if archive.read32(offset) == 0x0605_4b50, offset + 22 + Int(archive.read16(offset + 20)) == archive.count {
                end = offset
                break
            }
        }
        guard let end, archive.read16(end + 4) == 0, archive.read16(end + 6) == 0,
            archive.read16(end + 8) == archive.read16(end + 10)
        else { throw StudioError.invalid("Некорректный ZIP.") }
        let count = Int(archive.read16(end + 10))
        guard let centralSize = Int(exactly: archive.read32(end + 12)), let start = Int(exactly: archive.read32(end + 16)),
            start <= end, centralSize <= end
        else { throw StudioError.invalid("Некорректный каталог ZIP.") }
        guard count > 0, count <= maximumFiles, start + centralSize == end else { throw StudioError.invalid("Некорректный каталог ZIP.") }
        var cursor = start
        var files: [StudioFile] = []
        var names = Set<String>()
        var total = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, archive.read32(cursor) == 0x0201_4b50 else { throw StudioError.invalid("Повреждённый ZIP.") }
            let flags = archive.read16(cursor + 8)
            let method = archive.read16(cursor + 10)
            let crc = archive.read32(cursor + 16)
            guard let compressed = Int(exactly: archive.read32(cursor + 20)), let size = Int(exactly: archive.read32(cursor + 24)),
                let local = Int(exactly: archive.read32(cursor + 42)), compressed <= archive.count, local <= start
            else {
                throw StudioError.invalid("Некорректный размер ZIP.")
            }
            let nameSize = Int(archive.read16(cursor + 28))
            let extra = Int(archive.read16(cursor + 30))
            let comment = Int(archive.read16(cursor + 32))
            let next = cursor + 46 + nameSize + extra + comment
            guard next <= end, local + 30 <= start, flags & 0x0001 == 0, [0, 8].contains(method),
                size <= maximumFileBytes, archive.read32(local) == 0x0403_4b50
            else {
                throw StudioError.invalid("Архив повреждён, зашифрован или использует неподдерживаемый метод сжатия.")
            }
            guard let name = String(bytes: archive[(cursor + 46)..<(cursor + 46 + nameSize)], encoding: .utf8) else {
                throw StudioError.invalid("Некорректное имя файла ZIP.")
            }
            let localName = Int(archive.read16(local + 26))
            let payload = local + 30 + localName + Int(archive.read16(local + 28))
            total += size
            guard permits(name), names.insert(name.lowercased()).inserted, total <= maximumBytes,
                local + 30 + localName <= start, payload + compressed <= start,
                archive.read16(local + 8) == method, archive.read16(local + 6) == flags,
                flags & 8 != 0 || (archive.read32(local + 18) == UInt32(compressed) && archive.read32(local + 22) == UInt32(size)),
                String(bytes: archive[(local + 30)..<(local + 30 + localName)], encoding: .utf8) == name
            else { throw StudioError.invalid("Недопустимый путь или размер файла ZIP.") }
            let packed = Data(archive[payload..<(payload + compressed)])
            let data = method == 0 ? packed : try inflate(packed, size: size)
            guard data.count == size else { throw StudioError.invalid("Некорректный размер файла ZIP.") }
            guard crc32(data) == crc else { throw StudioError.invalid("Ошибка контрольной суммы: \(name)") }
            files.append(.init(path: name, data: data))
            cursor = next
        }
        guard cursor == end else { throw StudioError.invalid("Повреждённый каталог ZIP.") }
        return files
    }

    private static func inflate(_ input: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw StudioError.invalid("Не удалось открыть сжатый ZIP.")
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, size))
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(max(1, size))
                defer {
                    stream.next_in = nil
                    stream.next_out = nil
                }
                return ZLib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.total_in == input.count else {
            throw StudioError.invalid("Повреждённый сжатый файл ZIP.")
        }
        return output.prefix(size)
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc ^ UInt32.max
    }
    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb8_8320 : 0) }
        return value
    }
}

private extension Data {
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        for index in 0..<MemoryLayout<T>.size { append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
    func read16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func read32(_ offset: Int) -> UInt32 { UInt32(read16(offset)) | UInt32(read16(offset + 2)) << 16 }
}
