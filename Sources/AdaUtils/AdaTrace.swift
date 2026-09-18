//
//  AdaTrace.swift
//  AdaEngine
//
//  Created by Codex on 02.03.2026.
//

import Synchronization
import Tracing

public enum AdaTrace {
    /// Profiling target inherited by child tasks and nested render worlds.
    @TaskLocal public static var profileTargetID: String?
    /// True only while executing the target's own update, not a nested render update.
    @TaskLocal public static var profileFrameRoot = false

    @usableFromInline
    static let recordingEnabled = Atomic(true)

    @usableFromInline
    static let emptySpan = NoOpTracer.NoOpSpan(context: .topLevel)

    /// Controls new automatic spans. Existing spans still finish normally.
    /// Disabled lazy scopes skip their name/attributes arguments; the operation still runs.
    /// Enabled by default to preserve externally installed tracing providers.
    public static var isEnabled: Bool {
        get { recordingEnabled.load(ordering: .acquiring) }
        set { recordingEnabled.store(newValue, ordering: .releasing) }
    }

    @usableFromInline
    static func nonRecordingSpan() -> NoOpTracer.NoOpSpan {
        ServiceContext.current.map { NoOpTracer.NoOpSpan(context: $0) } ?? emptySpan
    }

    @inlinable
    static func mergeAttributes(_ attributes: SpanAttributes, into span: any Span) {
        guard !attributes.isEmpty else {
            return
        }
        var existing = span.attributes
        if existing.isEmpty {
            span.attributes = attributes
        } else {
            existing.merge(attributes)
            span.attributes = existing
        }
    }

    /// Executes a synchronous operation inside a tracing span.
    /// - Parameters:
    ///   - name: The span name.
    ///   - body: The operation to execute.
    /// - Returns: The operation result.
    @inlinable
    public static func span<T>(
        _ name: String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        _ body: @Sendable () throws -> T
    ) rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try body()
        }
        return try Tracing.withSpan(name, function: function, file: fileID, line: line) { _ in
            try body()
        }
    }

    /// Executes a synchronous operation inside a tracing span and exposes the span for metadata.
    @inlinable
    public static func span<T>(
        _ name: String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        _ body: @Sendable (any Span) throws -> T
    ) rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try body(nonRecordingSpan())
        }
        return try Tracing.withSpan(name, function: function, file: fileID, line: line, body)
    }

    /// Starts a span and returns it for manual lifecycle control.
    /// - Parameter name: The span name.
    /// - Returns: The started span.
    @inlinable
    public static func startSpan(_ name: String, function: String = #function, file fileID: String = #fileID, line: UInt = #line) -> any Span {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return nonRecordingSpan()
        }
        return InstrumentationSystem.tracer.startSpan(name, function: function, file: fileID, line: line)
    }

    /// Executes an async operation inside a tracing span.
    /// - Parameters:
    ///   - name: The span name.
    ///   - body: The operation to execute.
    /// - Returns: The operation result.
    @inlinable
    public static func span<T>(
        _ name: String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try await body()
        }
        return try await Tracing.withSpan(name, function: function, file: fileID, line: line) { _ in
            try await body()
        }
    }

    /// Executes an async operation inside a tracing span and exposes the span for metadata.
    @inlinable
    public static func span<T>(
        _ name: String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        _ body: @Sendable (any Span) async throws -> T
    ) async rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try await body(nonRecordingSpan())
        }
        return try await Tracing.withSpan(name, function: function, file: fileID, line: line, body)
    }

    /// Executes a synchronous operation inside a tracing span.
    /// - Parameters:
    ///   - name: The span name, evaluated only when automatic tracing is enabled.
    ///   - body: The operation to execute.
    /// - Returns: The operation result.
    @inlinable
    public static func span<T>(
        lazyName name: @autoclosure () -> String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        attributes: @autoclosure () -> SpanAttributes = [:],
        _ body: @Sendable () throws -> T
    ) rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try body()
        }
        return try Tracing.withSpan(name(), function: function, file: fileID, line: line) { span in
            if span.isRecording {
                mergeAttributes(attributes(), into: span)
            }
            return try body()
        }
    }

    /// Executes a synchronous operation inside a tracing span and exposes the span for metadata.
    @inlinable
    public static func span<T>(
        lazyName name: @autoclosure () -> String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        _ body: @Sendable (any Span) throws -> T
    ) rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try body(nonRecordingSpan())
        }
        return try Tracing.withSpan(name(), function: function, file: fileID, line: line, body)
    }

    /// Starts a span and returns it for manual lifecycle control.
    /// - Parameter name: The span name, evaluated only when automatic tracing is enabled.
    /// - Returns: The started span.
    @inlinable
    public static func startSpan(
        lazyName name: @autoclosure () -> String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        attributes: @autoclosure () -> SpanAttributes = [:]
    ) -> any Span {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return nonRecordingSpan()
        }
        let span = InstrumentationSystem.tracer.startSpan(name(), function: function, file: fileID, line: line)
        if span.isRecording {
            mergeAttributes(attributes(), into: span)
        }
        return span
    }

    /// Executes an async operation inside a tracing span.
    /// - Parameters:
    ///   - name: The span name, evaluated only when automatic tracing is enabled.
    ///   - body: The operation to execute.
    /// - Returns: The operation result.
    @inlinable
    public static func span<T>(
        lazyName name: @autoclosure () -> String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        isolation _: isolated (any Actor)? = #isolation,
        attributes: @autoclosure () -> SpanAttributes = [:],
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try await body()
        }
        // Evaluate metadata before entering the SDK's async context.
        let spanAttributes = attributes()
        return try await Tracing.withSpan(name(), function: function, file: fileID, line: line) { span in
            if span.isRecording {
                mergeAttributes(spanAttributes, into: span)
            }
            return try await body()
        }
    }

    /// Executes an async operation inside a tracing span and exposes the span for metadata.
    @inlinable
    public static func span<T>(
        lazyName name: @autoclosure () -> String,
        function: String = #function,
        file fileID: String = #fileID,
        line: UInt = #line,
        isolation _: isolated (any Actor)? = #isolation,
        _ body: @Sendable (any Span) async throws -> T
    ) async rethrows -> T {
        guard recordingEnabled.load(ordering: .acquiring) else {
            return try await body(nonRecordingSpan())
        }
        return try await Tracing.withSpan(name(), function: function, file: fileID, line: line, body)
    }
}
