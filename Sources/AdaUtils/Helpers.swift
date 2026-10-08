//
//  Helpers.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/31/22.
//

import Foundation

// TODO: Think about it later. Maybe we should use some namespace
@inlinable
public func require<T>(
    _ valueBlock: @autoclosure () -> T?,
    message: @autoclosure () -> String = String()
) -> T {
    guard let value = valueBlock() else {
        fatalError(message())
    }
    return value
}

extension Optional {
    @inlinable
    public func unwrap(
        message: @autoclosure () -> String = String()
    ) -> Wrapped {
        require(self, message: message())
    }
}

/// Call fatal error, because method not implemented
public func fatalErrorMethodNotImplemented(
    functionName: String = #function,
    line: Int = #line,
    file: String = #fileID
) -> Never {
    fatalError("Method \(functionName):\(line) not implemented in \(file).")
}

/// Call fatal error, if TODO is called in DEBUG build
public func TODO(
    _ message: @autoclosure () -> String = "Not implemented",
    functionName: String = #function,
    line: Int = #line,
    file: StaticString = #file
) -> Never {
    #if DEBUG
        fatalError("TODO: [\(file):\(functionName):\(line)] \(message()).")
    #else
        fatalError("TODO: [\(file):\(functionName):\(line)] \(message()).")
    #endif
}

/// Performs a traditional C-style assert with an optional message.
///
/// Use this function for internal consistency checks that are active during testing
/// but do not impact performance of shipping code. To check for invalid usage
/// in Release builds, see `precondition(_:_:file:line:)`.
///
/// * In playgrounds and `-Onone` builds (the default for Xcode's Debug
///   configuration): If `condition` evaluates to `false`, stop program
///   execution in a debuggable state after printing `message`.
///
/// * In `-O` builds (the default for Xcode's Release configuration),
///   `condition` is not evaluated, and there are no effects.
///
/// * In `-Ounchecked` builds, `condition` is not evaluated, but the optimizer
///   may assume that it *always* evaluates to `true`. Failure to satisfy that
///   assumption is a serious programming error.
///
/// - Parameters:
///   - condition: The condition to test. `condition` is only evaluated in
///     playgrounds and `-Onone` builds.
///   - message: A string to print if `condition` is evaluated to `false`. The
///     default is an empty string.
///   - file: The file name to print with `message` if the assertion fails. The
///     default is the file where `assert(_:_:file:line:)` is called.
///   - line: The line number to print along with `message` if the assertion
///     fails. The default is the line number where `assert(_:_:file:line:)`
///     is called.
@inlinable public func assert(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Swift.assert(condition(), message(), file: file, line: line)
}

/// Indicates that an internal consistency check failed.
///
/// This function's effect varies depending on the build flag used:
///
/// * In playgrounds and `-Onone` builds (the default for Xcode's Debug
///   configuration), stop program execution in a debuggable state after
///   printing `message`.
///
/// * In `-O` builds, has no effect.
///
/// * In `-Ounchecked` builds, the optimizer may assume that this function is
///   never called. Failure to satisfy that assumption is a serious
///   programming error.
///
/// - Parameters:
///   - message: A string to print in a playground or `-Onone` build. The
///     default is an empty string.
///   - file: The file name to print with `message`. The default is the file
///     where `assertionFailure(_:file:line:)` is called.
///   - line: The line number to print along with `message`. The default is the
///     line number where `assertionFailure(_:file:line:)` is called.
@inlinable public func assertionFailure(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Swift.assertionFailure(message(), file: file, line: line)
}

/// Precondition that the current thread is the main thread.
///
/// This function's effect varies depending on the build flag used:
///
/// * In playgrounds and `-Onone` builds (the default for Xcode's Debug
///   configuration), stop program execution in a debuggable state after
///   printing `message`.
///
/// * In `-O` builds, has no effect.
///
/// * In `-Ounchecked` builds, the optimizer may assume that this function is
///   never called. Failure to satisfy that assumption is a serious
///   programming error.
@inlinable public func preconditionMainThreadOnly(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    #if os(WASI)
        return
    #else
        assert(Thread.isMainThread, message(), file: file, line: line)
    #endif
}
