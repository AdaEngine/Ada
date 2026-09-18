#if canImport(AppKit) && os(macOS)
    @_spi(AdaEngine) import AdaEngine
    import AppKit
    import Math

    struct EditorProjectFileDropTarget: AppKitViewRepresentable {
        let isEnabled: Bool
        let onDrop: ([URL]) -> Bool

        func makeNSView(context _: Context) -> FileDropView {
            FileDropView(isEnabled: isEnabled, onDrop: onDrop)
        }

        func updateNSView(_ view: FileDropView, context _: Context) {
            view.isEnabled = isEnabled
            view.onDrop = onDrop
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView _: FileDropView, context _: Context) -> Size {
            proposal.replacingUnspecifiedDimensions()
        }

        final class FileDropView: NSView {
            var isEnabled: Bool
            var onDrop: ([URL]) -> Bool
            private var isForwardingEvent = false

            init(isEnabled: Bool, onDrop: @escaping ([URL]) -> Bool) {
                self.isEnabled = isEnabled
                self.onDrop = onDrop
                super.init(frame: .zero)
                registerForDraggedTypes([.fileURL])
                wantsLayer = true
                layer?.cornerRadius = 8
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) { nil }

            override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
                draggingUpdated(sender)
            }

            override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
                let accepts =
                    isEnabled && sender.draggingSourceOperationMask.contains(.copy)
                    && !Self.fileURLs(from: sender.draggingPasteboard).isEmpty
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.borderWidth = accepts ? 2 : 0
                return accepts ? .copy : []
            }

            override func draggingExited(_: (any NSDraggingInfo)?) {
                layer?.borderWidth = 0
            }

            override func draggingEnded(_: any NSDraggingInfo) {
                layer?.borderWidth = 0
            }

            override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
                draggingUpdated(sender) == .copy
            }

            override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
                layer?.borderWidth = 0
                guard isEnabled, sender.draggingSourceOperationMask.contains(.copy) else {
                    return false
                }
                let urls = Self.fileURLs(from: sender.draggingPasteboard)
                return !urls.isEmpty && onDrop(urls)
            }

            static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
                let objects =
                    pasteboard.readObjects(
                        // AppKit's pasteboard API requires the Objective-C class.
                        // swiftlint:disable:next legacy_objc_type
                        forClasses: [NSURL.self],
                        options: [.urlReadingFileURLsOnly: true]
                    ) ?? []
                return objects.compactMap { ($0 as? URL).flatMap { $0.isFileURL ? $0 : nil } }
            }

            // Native overlays sit above the Metal view. Keep the drop surface native,
            // but route ordinary input to the original view beneath it.
            override func hitTest(_ point: NSPoint) -> NSView? {
                isForwardingEvent ? nil : super.hitTest(point)
            }

            private func forward(_ event: NSEvent, action: (NSView, NSEvent) -> Void) {
                guard let contentView = window?.contentView else {
                    return
                }
                isForwardingEvent = true
                defer { isForwardingEvent = false }
                let point = contentView.convert(event.locationInWindow, from: nil)
                if let target = contentView.hitTest(point), target !== self {
                    action(target, event)
                }
            }

            override func mouseDown(with event: NSEvent) { forward(event) { $0.mouseDown(with: $1) } }
            override func mouseUp(with event: NSEvent) { forward(event) { $0.mouseUp(with: $1) } }
            override func mouseDragged(with event: NSEvent) { forward(event) { $0.mouseDragged(with: $1) } }
            override func rightMouseDown(with event: NSEvent) { forward(event) { $0.rightMouseDown(with: $1) } }
            override func rightMouseUp(with event: NSEvent) { forward(event) { $0.rightMouseUp(with: $1) } }
            override func rightMouseDragged(with event: NSEvent) { forward(event) { $0.rightMouseDragged(with: $1) } }
            override func otherMouseDown(with event: NSEvent) { forward(event) { $0.otherMouseDown(with: $1) } }
            override func otherMouseUp(with event: NSEvent) { forward(event) { $0.otherMouseUp(with: $1) } }
            override func otherMouseDragged(with event: NSEvent) { forward(event) { $0.otherMouseDragged(with: $1) } }
            override func scrollWheel(with event: NSEvent) { forward(event) { $0.scrollWheel(with: $1) } }
        }
    }
#endif
