//
//  AppleEmbeddedApplication.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/24/22.
//

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    import AdaApp
    import AdaECS
    @_spi(Internal) import AdaInput
    @_spi(Internal) import AdaUI
    import UIKit

    @safe @MainActor
    final class AppleEmbeddedApplication: Application {
        let argc: Int32
        let argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

        private let screenManager: AppleEmbeddedScreenManager
        private var appWorlds: AppWorlds?
        private var task: Task<Void, Never>?
        private var configuredFrameRateRange: ClosedRange<Int>?
        var displayLink: CADisplayLink!

        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            unsafe self.argv = argv
            self.argc = argc

            let screenManager = AppleEmbeddedScreenManager()
            self.screenManager = screenManager
            Screen.screenManager = screenManager
            try unsafe super.init(argc: argc, argv: argv)
            self.windowManager = AppleEmbeddedWindowManager(screenManager: screenManager)
            UIWindowManager.setShared(self.windowManager)
        }

        override func run(_ appWorlds: AppWorlds) throws {
            self.appWorlds = appWorlds
            self.setupInput(for: appWorlds)

            self.displayLink =
                UIScreen.main.displayLink(withTarget: self, selector: #selector(update))
                ?? CADisplayLink(target: self, selector: #selector(update))
            self.configureDisplayLinkFrameRate()
            self.displayLink.add(to: .main, forMode: .common)

            // FIXME: We should store bundleIdentifier? err ("Invalid parameter not satisfying: bundleIdentifier")
            let exitCode = unsafe UIApplicationMain(
                argc,
                argv,
                NSStringFromClass(AdaApplication.self),
                NSStringFromClass(AppleEmbeddedAppDelegate.self)
            )

            if exitCode != EXIT_SUCCESS {
                throw NSError(domain: "", code: Int(exitCode))
            }
        }

        @discardableResult
        override func openURL(_ url: URL) -> Bool {
            UIApplication.shared.open(url)
            return true
        }

        override func showAlert(_ alert: Alert) {
            let window = UIApplication.shared.connectedScenes
                .lazy
                .compactMap { ($0 as? UIWindowScene) }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }

            guard let window else {
                return
            }

            let alertController = UIAlertController(
                title: alert.title,
                message: alert.message,
                preferredStyle: .alert
            )

            for button in alert.buttons {
                let style: UIAlertAction.Style

                switch button.kind {
                case .cancel:
                    style = .cancel
                case .plain:
                    style = .`default`
                }

                let action = UIAlertAction(
                    title: button.title,
                    style: style,
                    handler: { _ in
                        button.action?()
                    }
                )

                alertController.addAction(action)
            }

            window.rootViewController?.present(alertController, animated: true)
        }

        override func terminate() {
            self.task?.cancel()
            self.displayLink?.invalidate()
            exit(EXIT_SUCCESS)
        }

        // MARK: - Private

        private func setupInput(for app: AppWorlds) {
            let mutableInput = app.main.getRefResource(Input.self)
            self.windowManager.inputRef = mutableInput
        }

        @objc private func update() {
            guard let appWorlds = self.appWorlds else {
                return
            }
            self.configureDisplayLinkFrameRate()

            // Use a task to handle async update
            if task == nil {
                task = Task(priority: .userInitiated) { [weak self] in
                    do {
                        try await appWorlds.update()
                    } catch {
                        print("Update error: \(error.localizedDescription)")
                    }
                    self?.task = nil
                }
            }
        }

        private func configureDisplayLinkFrameRate() {
            guard
                let displayLink,
                let framePacing = appWorlds?.getResource(ApplicationFramePacing.self)
            else {
                return
            }

            #if os(watchOS)
                let displayMaximumFramesPerSecond = 60
            #else
                let displayMaximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
            #endif
            let range = framePacing.resolvedFrameRateRange(
                forDisplayMaximumFramesPerSecond: displayMaximumFramesPerSecond
            )
            guard configuredFrameRateRange != range else {
                return
            }
            configuredFrameRateRange = range
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(range.lowerBound),
                maximum: Float(range.upperBound),
                preferred: Float(range.upperBound)
            )
        }
    }

    final class AdaApplication: UIApplication {}

#endif
