#if os(Windows)
import Dispatch
import Foundation
import WinSDK
import ucrt

/// Console-free process ownership for background tools. Handles are immutable and synchronized by the
/// Windows kernel. The suspended child joins its job before it can spawn children.
final class EditorWindowsProcess: Sendable {
    let input: FileHandle
    let output: FileHandle
    let error: FileHandle
    let exit: AsyncStream<Int32>
    private let address: UInt
    private let tree: EditorWindowsProcessTree?

    var isRunning: Bool {
        var code: DWORD = 0
        return GetExitCodeProcess(HANDLE(bitPattern: address), &code) && code == STILL_ACTIVE
    }

    init(executable: URL, arguments: [String], directory: URL?, environment: [String: String], superviseTree: Bool = true) throws {
        guard !arguments.contains(where: { $0.contains("\0") }),
            !environment.contains(where: { $0.key.contains("\0") || $0.value.contains("\0") }) else {
            throw EditorWindowsProcessError(message: "Tool arguments and environment cannot contain null characters.")
        }
        let stdin = try NativePipe(parentReads: false)
        let stdout = try NativePipe(parentReads: true)
        let stderr = try NativePipe(parentReads: true)
        input = stdin.parent
        output = stdout.parent
        error = stderr.parent
        var inherited = [stdin.child, stdout.child, stderr.child]
        var attributeBytes: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeBytes)
        guard attributeBytes > 0 else { throw Self.failure("prepare process attributes") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeBytes), alignment: MemoryLayout<UInt>.alignment)
        defer { storage.deallocate() }
        var startup = STARTUPINFOEXW()
        startup.lpAttributeList = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeBytes) else { throw Self.failure("initialize process attributes") }
        defer { DeleteProcThreadAttributeList(startup.lpAttributeList) }
        let handlesConfigured = inherited.withUnsafeMutableBufferPointer { handles in
            UpdateProcThreadAttribute(startup.lpAttributeList, 0, DWORD_PTR(0x00020002) /* PROC_THREAD_ATTRIBUTE_HANDLE_LIST */,
                handles.baseAddress, SIZE_T(handles.count * MemoryLayout<HANDLE?>.stride), nil, nil)
        }
        guard handlesConfigured else { throw Self.failure("restrict inherited handles") }
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
        startup.StartupInfo.wShowWindow = WORD(SW_HIDE)
        startup.StartupInfo.hStdInput = inherited[0]
        startup.StartupInfo.hStdOutput = inherited[1]
        startup.StartupInfo.hStdError = inherited[2]
        var command = Array(([executable.path] + arguments).map(Self.quote).joined(separator: " ").utf16) + [0]
        let variables = environment.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        var environmentBlock = Array(variables.map { "\($0.key)=\($0.value)" }.joined(separator: "\0").utf16) + [0, 0]
        var processInfo = PROCESS_INFORMATION()
        let flags = DWORD(CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT)
        let workingDirectory = Array((directory?.path ?? FileManager.default.currentDirectoryPath).utf16) + [0]
        let created = withUnsafeMutablePointer(to: &startup) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { info in
                CreateProcessW(Array(executable.path.utf16) + [0], &command, nil, nil, true, flags, &environmentBlock, workingDirectory, info, &processInfo)
            }
        }
        guard created, let handle = processInfo.hProcess, let thread = processInfo.hThread else { throw Self.failure("launch background process") }
        defer { CloseHandle(thread) }
        do { tree = superviseTree ? try EditorWindowsProcessTree(processIdentifier: Int32(bitPattern: processInfo.dwProcessId)) : nil }
        catch {
            TerminateProcess(handle, 1)
            CloseHandle(handle)
            throw error
        }
        guard ResumeThread(thread) != DWORD.max else {
            TerminateProcess(handle, 1)
            CloseHandle(handle)
            throw Self.failure("resume background process")
        }
        address = UInt(bitPattern: handle)
        let completion = AsyncStream<Int32>.makeStream()
        exit = completion.stream
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = WaitForSingleObject(HANDLE(bitPattern: address), DWORD(INFINITE))
            var code: DWORD = 1
            GetExitCodeProcess(HANDLE(bitPattern: address), &code)
            completion.continuation.yield(Int32(bitPattern: code))
            completion.continuation.finish()
        }
    }

    func terminate() {
        if let tree { tree.terminate() } else { TerminateProcess(HANDLE(bitPattern: address), 1) }
    }

    deinit { CloseHandle(HANDLE(bitPattern: address)) }

    private static func failure(_ action: String) -> EditorWindowsProcessError {
        EditorWindowsProcessError(message: "Unable to \(action) (Windows error \(GetLastError())).")
    }

    /// CommandLineToArgvW/CRT quoting, including empty arguments and trailing slashes.
    static func quote(_ argument: String) -> String {
        // WSL parses its own command line and treats quoted options as Linux
        // commands. Quote only arguments that need it, as the Windows CRT does.
        if !argument.isEmpty, !argument.contains(where: { $0.isWhitespace || $0 == "\"" }) { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" { backslashes += 1; continue }
            result += String(repeating: "\\", count: character == "\"" ? backslashes * 2 + 1 : backslashes)
            result.append(character)
            backslashes = 0
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
/// The child end stays a native handle. FileHandle's fd initializer consumes the
/// parent's CRT descriptor and creates its own non-inheritable handle.
private final class NativePipe: Sendable {
    let parent: FileHandle
    private let childAddress: UInt
    var child: HANDLE? { HANDLE(bitPattern: childAddress) }

    init(parentReads: Bool) throws {
        var read: HANDLE?, write: HANDLE?
        var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        guard CreatePipe(&read, &write, &security, 0), let read, let write else {
            throw EditorWindowsProcessError(message: "Unable to create tool pipes (\(GetLastError())).")
        }
        let parentHandle = parentReads ? read : write
        let childHandle = parentReads ? write : read
        let descriptor = _open_osfhandle(Int(bitPattern: parentHandle), _O_BINARY)
        guard descriptor >= 0 else {
            CloseHandle(read)
            CloseHandle(write)
            throw EditorWindowsProcessError(message: "Unable to prepare tool pipe descriptors.")
        }
        parent = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        childAddress = UInt(bitPattern: childHandle)
    }

    deinit { CloseHandle(child) }
}

struct EditorWindowsProcessError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#endif
