//
//  Application.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

import AdaApp
import AdaECS
@_spi(Internal) import AdaRender
@_spi(Internal) import AdaUI
import Foundation

extension Notification.Name {
    public static let adaEngineOpenURL = Notification.Name("AdaEngine.OpenURL")
}
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    import Darwin
#elseif os(Linux) || os(Android)
    import Glibc
#elseif os(Windows)
    import WinSDK
#endif

#if os(Windows)
    @_silgen_name("exit")
    func exit(_ code: Int32) -> Never

    let EXIT_SUCCESS: Int32 = 0
#endif

/// The main class represents application instance.
/// The application cannot be created manualy, instead use an ``App`` protocol.
/// To get access to the application instance, use static property `shared`
@MainActor
open class Application: Resource {
    /// Contains application instance if application created from ``App``.
    @MainActor public internal(set) static var shared: Application!

    /// Current runtime platform.
    public var platform: RuntimePlatform {
        #if os(macOS)
            return .macOS
        #elseif os(iOS)
            return .iOS
        #elseif os(watchOS)
            return .watchOS
        #elseif os(tvOS)
            return .tvOS
        #elseif os(visionOS)
            return .visionOS
        #elseif os(Windows)
            return .windows
        #elseif os(Linux)
            return .linux
        #elseif os(Android)
            return .android
        #elseif WASM
            return .web
        #endif
    }

    @_spi(Internal)
    @MainActor @preconcurrency
    public var windowManager: UIWindowManager = UIWindowManager()

    public var lastWindowCloseBehavior: LastWindowCloseBehavior = .terminateApplication

    // MARK: - Internal

    public init(
        argc _: Int32,
        argv _: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) throws {
        AlertPresentationCenter.showAlert = { [weak self] presentation in
            let alert = Alert(
                title: presentation.title,
                message: presentation.message,
                buttons: presentation.buttons.map { button in
                    let action = button.action

                    switch button.role {
                    case .cancel:
                        return .cancel(button.title, action: action)
                    case .destructive,
                        .none:
                        return .button(button.title, action: action)
                    }
                }
            )
            self?.showAlert(alert)
        }
    }

    #if ENABLE_RUN_IN_CONCURRENCY
        /// Call this method to start main loop.
        func run(_: AppWorlds) async throws {
            assertionFailure("Not implemented")
        }
    #else
        /// Call this method to start main loop.
        func run(_: AppWorlds) throws {
            assertionFailure("Not implemented")
        }
    #endif

    // MARK: - Public methods

    /// Call this method to terminate app execution with 0 status code.
    @MainActor
    open func terminate() {
        #if WASM
            return
        #elseif os(Windows)
            exit(0)
        #else
            exit(EXIT_SUCCESS)
        #endif
    }

    /// Method to open url.
    @MainActor
    @discardableResult
    open func openURL(_: URL) -> Bool {
        assertionFailure("Not implemented")
        return false
    }

    /// Call this method to show specific alert.
    @MainActor
    open func showAlert(_: Alert) {
        assertionFailure("Not implemented")
    }

    @MainActor
    public func setLastWindowCloseBehavior(_ behavior: LastWindowCloseBehavior) {
        self.lastWindowCloseBehavior = behavior
    }
}

extension Application {
    public enum LastWindowCloseBehavior: Hashable, Sendable {
        case terminateApplication
        case keepApplicationRunning
    }

    /// The collection of available Application States.
    public enum State: Hashable, Sendable {
        case active
        case inactive
        case background
    }
}

extension Application {
    @_spi(Internal)
    public static func setApplication(_ app: Application) {
        self.shared = app
    }
}
