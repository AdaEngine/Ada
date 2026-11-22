import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

private struct Position {
    let ticks: UInt64
    let x: Int
}

private final class DividerCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var positions: [Position] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let frame = attachments.first,
              frame[.status] as? Int == SCFrameStatus.complete.rawValue,
              let ticks = (frame[.displayTime] as? NSNumber)?.uint64Value, ticks != 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        // The divider is the only continuous mint line through both scan rows.
        let rows = [height * 2 / 3, height * 4 / 5]
        let x = (20 ..< width - 20).first { x in
            rows.allSatisfy { y in
                let p = bytes + y * stride + x * 4
                return Int(p[1]) > 105 && Int(p[1]) - Int(p[2]) > 26 && p[0] > p[2]
            }
        }
        if let x {
            lock.withLock { positions.append(Position(ticks: ticks, x: x)) }
        }
    }

    func snapshot() -> [Position] { lock.withLock { positions } }
}

private enum ProbeError: Error {
    case arguments, permission, window, cursor, divider, screenshot
}

private func window(for pid: Int32) -> (CGWindowID, CGRect)? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for row in windows where row[kCGWindowOwnerPID as String] as? Int32 == pid {
        if row[kCGWindowLayer as String] as? Int == 0,
           let id = row[kCGWindowNumber as String] as? CGWindowID,
           let value = row[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: value), bounds.width >= 1_000 {
            return (id, bounds)
        }
    }
    return nil
}

private func send(_ event: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: event, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

private func screenshot(_ id: CGWindowID, _ url: URL) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(id), url.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw ProbeError.screenshot }
}

private func cpuTicks(_ pid: Int32) -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    precondition(result == 0)
    return usage.ri_user_time + usage.ri_system_time
}

@main
struct MeasureResize {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw ProbeError.arguments }
        guard CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else { throw ProbeError.permission }
        let app = URL(fileURLWithPath: args[1], isDirectory: true)
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let child = Process()
        child.executableURL = app.appendingPathComponent("Contents/MacOS/SplitEditor")
        let allowed = Set(["HOME", "LANG", "LC_ALL", "PATH", "TMPDIR", "USER", "ORBIT_SOFT_WRAP"])
        child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        for _ in 0..<100 {
            if window(for: child.processIdentifier) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(4))
        let pid = child.processIdentifier
        guard let (id, bounds) = window(for: pid),
              let target = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                .windows.first(where: { $0.windowID == id })
        else { throw ProbeError.window }

        var display: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &display, &displayCount)
        let maximumHz = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }?.maximumFramesPerSecond ?? 0
        let config = SCStreamConfiguration()
        // Point-sized output keeps the 1 pt divider resolvable.
        config.width = Int(bounds.width)
        config.height = Int(bounds.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = false
        let capture = DividerCapture()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "benchmark.divider"))
        try await stream.startCapture()
        for _ in 0..<60 {
            if capture.snapshot().last != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try screenshot(id, output.appendingPathComponent("before.png"))
        guard let baseline = capture.snapshot().last else { throw ProbeError.divider }

        let origin = CGPoint(x: bounds.minX + CGFloat(baseline.x), y: bounds.midY)
        let clock = ContinuousClock()
        var scale = mach_timebase_info_data_t()
        precondition(mach_timebase_info(&scale) == KERN_SUCCESS)
        let ms = Double(scale.numer) / Double(scale.denom) / 1e6
        guard CGWarpMouseCursorPosition(origin) == .success else { throw ProbeError.cursor }
        send(.mouseMoved, at: origin)
        try await Task.sleep(for: .milliseconds(80))
        send(.leftMouseDown, at: origin)
        var current = origin
        var held = true
        defer { if held { send(.leftMouseUp, at: current) } }
        try await Task.sleep(for: .milliseconds(100))
        let cpu = cpuTicks(pid)
        let time = clock.now
        let start = mach_absolute_time()
        var input = ["timestamp_ms,pointer_x"]
        for index in 1...288 {
            try await clock.sleep(until: time.advanced(by: .nanoseconds(index * 1_000_000_000 / 120)), tolerance: .zero)
            let dx = index <= 144 ? -CGFloat(index) * 1.3 : -187.2 + CGFloat(index - 144) * 2.05
            current.x = origin.x + dx
            let posted = mach_absolute_time()
            send(.leftMouseDragged, at: current)
            input.append("\(Double(posted - start) * ms),\(current.x - bounds.minX)")
        }
        let end = mach_absolute_time()
        send(.leftMouseUp, at: current)
        held = false
        try await Task.sleep(for: .milliseconds(100))
        let cpuMS = Double(cpuTicks(pid) - cpu) * ms
        try screenshot(id, output.appendingPathComponent("after.png"))
        try await stream.stopCapture()

        let positions = capture.snapshot()
        guard let final = positions.last, abs(final.x - baseline.x) >= 60 else { throw ProbeError.divider }
        let minimumX = positions.filter { $0.ticks >= start }.map(\.x).min()
        guard let minimumX, baseline.x - minimumX >= 160,
              abs(final.x - baseline.x - 108) <= 6 else { throw ProbeError.divider }
        var last = baseline.x
        let changes = positions.filter { position in
            guard position.ticks >= start, position.ticks <= end, position.x != last else { return false }
            last = position.x
            return true
        }
        guard let first = changes.first, let lastChange = changes.last, changes.count > 2 else { throw ProbeError.divider }
        let gaps = zip(changes, changes.dropFirst()).map { Double($1.ticks - $0.ticks) * ms }.sorted()
        let rate = Double(changes.count - 1) * 1_000 / (Double(lastChange.ticks - first.ticks) * ms)
        let p95 = gaps[Int(ceil(Double(gaps.count) * 0.95)) - 1]
        let lines = changes.map { "\(Double($0.ticks - start) * ms),\($0.x)" }
        try (["timestamp_ms,divider_x"] + lines).joined(separator: "\n").appending("\n")
            .write(to: output.appendingPathComponent("positions.csv"), atomically: true, encoding: .utf8)
        try input.joined(separator: "\n").appending("\n")
            .write(to: output.appendingPathComponent("input.csv"), atomically: true, encoding: .utf8)
        print("window_pt,display_max_hz,inputs,visible_changes,visible_hz,p95_ms,cpu_ms_with_capture,initial_x,final_x")
        print("\(Int(bounds.width))x\(Int(bounds.height)),\(maximumHz),288,\(changes.count),\(rate),\(p95),\(cpuMS),\(baseline.x),\(final.x)")
    }
}
