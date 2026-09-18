//
//  Time.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

import Foundation

#if os(iOS) || os(tvOS)
    import QuartzCore
#endif
#if os(macOS)
    import Quartz
#endif
#if os(Android) || os(Linux)
    import Glibc
#endif

// TODO: (Vlad) Time for Windows OS

/// Represent time interval in system.
public typealias TimeInterval = Float
public typealias LongTimeInterval = Double

/// A helper for works with time.
public struct Time {
    /// Return current time in system.
    public static var absolute: LongTimeInterval {
        #if os(iOS) || os(tvOS) || os(OSX) || os(watchOS)
            return LongTimeInterval(CACurrentMediaTime())
        #elseif os(Windows)
            // Windows doesn't have clock_gettime, use Foundation's ProcessInfo
            return LongTimeInterval(ProcessInfo.processInfo.systemUptime)
        #elseif os(WASI)
            return LongTimeInterval(Date().timeIntervalSince1970)
        #else
            var time = timespec()
            clock_gettime(CLOCK_MONOTONIC, &time)

            return LongTimeInterval(time.tv_sec) + LongTimeInterval(time.tv_nsec) / LongTimeInterval(1.0e-9)
        #endif
    }
}
