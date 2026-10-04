import AdaEngine

/// The panel stays in AdaUI. The SwiftUI scene supplies only spatial window actions.
struct GardenAdaTools: AdaUI.View {
    let model: GardenWorkspace
    let enter: @MainActor () -> Void
    let leave: @MainActor () -> Void

    var body: some AdaUI.View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Immersive Garden").font(.system(size: 24, weight: .bold))
            Text("Pinch a nearby crate to move it. Use both hands to rotate and resize it, or look at it and pinch to drag from a distance.")
                .font(.system(size: 16))
                .foregroundColor(.gray)
            if model.isImmersed {
                Text(model.selectionName ?? "Select a crate or the sphere")
                    .font(.system(size: 18, weight: .bold))
                if let transform = model.selectedTransform {
                    Text("Position: \(transform.position.x), \(transform.position.y), \(transform.position.z) m")
                        .font(.system(size: 14))
                    HStack(spacing: 12) {
                        Button("Smaller") { model.scaleSelected(by: 0.9) }
                        Button("Larger") { model.scaleSelected(by: 1.1) }
                    }.disabled(model.isGrabbed)
                }
                HStack(spacing: 12) {
                    Button("Save scene") { model.save() }
                    Button("Load scene") { model.load() }
                }.disabled(model.isGrabbed)
                Button("Reset objects") { model.reset() }.disabled(model.isGrabbed)
            }
            if let message = model.message {
                Text(message).font(.system(size: 14)).foregroundColor(.gray)
            }
            Button(model.isImmersed ? "Leave garden" : "Enter garden") {
                if model.isImmersed { leave() } else { enter() }
            }
            .disabled(model.isOpening)
        }
        .foregroundColor(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
