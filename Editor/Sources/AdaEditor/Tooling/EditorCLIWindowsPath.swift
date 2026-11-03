#if os(Windows)
import Foundation
import WinSDK

enum EditorCLIWindowsPath {
    static func appending(_ directory: String, to path: String) -> String {
        func normalized(_ entry: String) -> String {
            let value = entry.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\")).lowercased()
        }
        guard !path.split(separator: ";").contains(where: { normalized(String($0)) == normalized(directory) }) else { return path }
        return path + (path.isEmpty || path.hasSuffix(";") ? "" : ";") + directory
    }

    static func install(directory: URL, registryPath: String = "Environment", notify: Bool = true) throws {
        var key: HKEY?
        let status = registryPath.withCString(encodedAs: UTF16.self) {
            RegCreateKeyExW(HKEY_CURRENT_USER, $0, 0, nil, 0, DWORD(KEY_QUERY_VALUE | KEY_SET_VALUE), nil, &key, nil)
        }
        guard status == ERROR_SUCCESS, let key else { throw EditorCLIInstallation.InstallationError.registry(status) }
        defer { RegCloseKey(key) }
        var type = DWORD(REG_EXPAND_SZ)
        var count: DWORD = 0
        let read = "Path".withCString(encodedAs: UTF16.self) { RegQueryValueExW(key, $0, nil, &type, nil, &count) }
        guard read == ERROR_SUCCESS || read == ERROR_FILE_NOT_FOUND else { throw EditorCLIInstallation.InstallationError.registry(read) }
        if read == ERROR_FILE_NOT_FOUND { type = DWORD(REG_EXPAND_SZ) }
        var path = ""
        if read == ERROR_SUCCESS {
            guard type == REG_SZ || type == REG_EXPAND_SZ else { throw EditorCLIInstallation.InstallationError.registry(ERROR_INVALID_DATA) }
            var bytes = [UInt16](repeating: 0, count: Int(count) / 2 + 1)
            let result = bytes.withUnsafeMutableBytes { buffer in
                "Path".withCString(encodedAs: UTF16.self) { RegQueryValueExW(key, $0, nil, &type, buffer.bindMemory(to: BYTE.self).baseAddress, &count) }
            }
            guard result == ERROR_SUCCESS else { throw EditorCLIInstallation.InstallationError.registry(result) }
            path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF16.self)
        }
        let updated = appending(directory.path.replacingOccurrences(of: "/", with: "\\"), to: path)
        if updated != path {
            let bytes = Array(updated.utf16) + [0]
            let result = bytes.withUnsafeBytes { buffer in
                "Path".withCString(encodedAs: UTF16.self) { RegSetValueExW(key, $0, 0, type, buffer.bindMemory(to: BYTE.self).baseAddress, DWORD(buffer.count)) }
            }
            guard result == ERROR_SUCCESS else { throw EditorCLIInstallation.InstallationError.registry(result) }
        }
        if notify {
            _ = "Environment".withCString(encodedAs: UTF16.self) {
                SendMessageTimeoutW(HWND(bitPattern: 0xffff), UINT(WM_SETTINGCHANGE), 0, LPARAM(Int(bitPattern: $0)), UINT(SMTO_ABORTIFHUNG), 1000, nil)
            }
        }
    }
}
#endif
