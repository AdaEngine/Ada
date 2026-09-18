#if canImport(AppKit) && os(macOS)
    @_spi(AdaEngine) import AdaEngine
    import AppKit

    struct EditorInspectorTextureDropTarget: AppKitViewRepresentable {
        let onClick: () -> Void
        let onDrop: (URL) -> Void

        func makeNSView(context _: Context) -> TextureDropView {
            TextureDropView(onClick: onClick, onDrop: onDrop)
        }

        func updateNSView(_ view: TextureDropView, context _: Context) {
            view.onClick = onClick
            view.onDrop = onDrop
        }

        final class TextureDropView: NSView {
            var onClick: () -> Void
            var onDrop: (URL) -> Void

            init(onClick: @escaping () -> Void, onDrop: @escaping (URL) -> Void) {
                self.onClick = onClick
                self.onDrop = onDrop
                super.init(frame: .zero)
                registerForDraggedTypes([.fileURL])
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                nil
            }

            override func mouseDown(with _: NSEvent) {
                onClick()
            }

            override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
                droppedFileURL(from: sender) == nil ? [] : .copy
            }

            override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
                guard let url = droppedFileURL(from: sender) else {
                    return false
                }
                onDrop(url)
                return true
            }

            private func droppedFileURL(from draggingInfo: any NSDraggingInfo) -> URL? {
                guard let fileURLClass = NSClassFromString("NSURL") else {
                    return nil
                }
                return draggingInfo.draggingPasteboard.readObjects(forClasses: [fileURLClass])?.first as? URL
            }
        }
    }
#endif
