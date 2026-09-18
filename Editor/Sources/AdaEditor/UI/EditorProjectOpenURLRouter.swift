//
//  EditorProjectOpenURLRouter.swift
//  AdaEditor
//

@_spi(AdaEngine) import AdaEngine
import Foundation

/// Buffers document URLs delivered before the project-opening view is ready and
/// forwards later deliveries to the active project-opening model.
@MainActor
final class EditorProjectOpenURLRouter {
    static let shared = EditorProjectOpenURLRouter()

    private var observer: NSObjectProtocol?
    private var pendingProjectURLs: [URL] = []
    private weak var viewModel: ProjectOpeningViewModel?

    init(
        notificationCenter: NotificationCenter = .default,
        notificationName: Notification.Name = .adaEngineOpenURL
    ) {
        self.observer = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else {
                return
            }
            MainActor.assumeIsolated {
                self?.receive(url)
            }
        }
    }

    /// Installs the current project-opening destination and drains any cold-launch URL.
    /// - Returns: `true` when one or more buffered URLs were forwarded.
    @discardableResult
    func attach(_ viewModel: ProjectOpeningViewModel) -> Bool {
        self.viewModel = viewModel
        let pendingProjectURLs = self.pendingProjectURLs
        self.pendingProjectURLs.removeAll()
        for url in pendingProjectURLs {
            openProject(at: url, with: viewModel)
        }
        return !pendingProjectURLs.isEmpty
    }

    func detach(_ viewModel: ProjectOpeningViewModel) {
        guard self.viewModel === viewModel else {
            return
        }
        self.viewModel = nil
    }

    func receive(_ url: URL) {
        guard let viewModel else {
            pendingProjectURLs.append(url)
            return
        }
        openProject(at: url, with: viewModel)
    }

    private func openProject(at url: URL, with viewModel: ProjectOpeningViewModel) {
        let projectURL = ProjectOpenPicker.projectDirectoryURL(fromPickerSelection: url)
        #if canImport(UIKit)
            viewModel.openProject(at: ProjectOpenPicker.retainSecurityScopedAccess(to: projectURL))
        #else
            viewModel.openProject(at: projectURL)
        #endif
    }
}
