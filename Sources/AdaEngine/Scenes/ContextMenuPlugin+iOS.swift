#if os(iOS)
    @_spi(Internal) import AdaUI
    import UIKit

    @MainActor
    enum IOSContextMenuPresentationCenter {
        private static var activeSession: IOSContextMenuSession?

        static func present(_ presentation: ContextMenuPresentation) {
            activeSession?.dismiss()

            guard let session = IOSContextMenuSession(presentation: presentation) else {
                presentation.onDismiss?()
                activeSession = nil
                return
            }

            activeSession = session
            session.present()
        }

        @discardableResult
        static func dismissAll() -> Bool {
            guard let activeSession else {
                return false
            }
            activeSession.dismiss()
            return true
        }

        static func dismissForInteraction(in window: AdaUI.UIWindow?) {
            guard let activeSession, let window, activeSession.sourceWindow === window else {
                return
            }
            activeSession.dismiss()
        }

        static func dismissForDeactivation(of window: AdaUI.UIWindow?) {
            guard let activeSession, let window, activeSession.sourceWindow === window else {
                return
            }
            activeSession.dismiss()
        }

        static func sessionDidDismiss(_ session: IOSContextMenuSession) {
            guard activeSession === session else {
                return
            }
            activeSession = nil
        }
    }

    @MainActor
    final class IOSContextMenuSession: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
        weak var sourceWindow: AdaUI.UIWindow?

        private weak var hostView: UIKit.UIView?
        private let presentation: ContextMenuPresentation
        private lazy var interaction = UIEditMenuInteraction(delegate: self)
        private var didFinishDismissal = false

        init?(presentation: ContextMenuPresentation) {
            guard
                let sourceWindow = presentation.sourceWindow,
                let systemWindow = sourceWindow.systemWindow as? UIKit.UIWindow,
                let hostView = systemWindow.rootViewController?.view
            else {
                return nil
            }

            self.presentation = presentation
            self.sourceWindow = sourceWindow
            self.hostView = hostView
            super.init()
        }

        func present() {
            guard let hostView else {
                finishDismissal()
                return
            }

            hostView.addInteraction(interaction)
            let sourcePoint = CGPoint(
                x: CGFloat(presentation.location.x),
                y: CGFloat(presentation.location.y)
            )
            interaction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: sourcePoint
                )
            )
        }

        func dismiss() {
            interaction.dismissMenu()
            finishDismissal()
        }

        func editMenuInteraction(
            _: UIEditMenuInteraction,
            menuFor _: UIEditMenuConfiguration,
            suggestedActions _: [UIKit.UIMenuElement]
        ) -> UIKit.UIMenu? {
            UIKit.UIMenu(children: menuElements(for: presentation.items))
        }

        func editMenuInteraction(
            _: UIEditMenuInteraction,
            willDismissMenuFor _: UIEditMenuConfiguration,
            animator: any UIEditMenuInteractionAnimating
        ) {
            animator.addCompletion { [weak self] in
                self?.finishDismissal()
            }
        }

        private func menuElements(for items: [ContextMenuPresentation.Item]) -> [UIKit.UIMenuElement] {
            let sections = items.split(whereSeparator: \.isSeparator)
            guard sections.count > 1 else {
                return sections.first.map { menuElements(forSection: Array($0)) } ?? []
            }

            return sections.map { section in
                UIKit.UIMenu(
                    title: "",
                    options: .displayInline,
                    children: menuElements(forSection: Array(section))
                )
            }
        }

        private func menuElements(forSection items: [ContextMenuPresentation.Item]) -> [UIKit.UIMenuElement] {
            items.map { item in
                if !item.submenu.isEmpty {
                    return UIKit.UIMenu(
                        title: item.title,
                        children: menuElements(for: item.submenu)
                    )
                }

                let attributes: UIKit.UIMenuElement.Attributes = item.role == .destructive ? .destructive : []
                return UIKit.UIAction(title: item.title, attributes: attributes, state: item.isSelected ? .on : .off) { [weak self] _ in
                    self?.dismiss()
                    item.action?()
                }
            }
        }

        private func finishDismissal() {
            guard !didFinishDismissal else {
                return
            }
            didFinishDismissal = true
            if let hostView {
                hostView.removeInteraction(interaction)
            }
            presentation.onDismiss?()
            IOSContextMenuPresentationCenter.sessionDidDismiss(self)
        }
    }
#endif
