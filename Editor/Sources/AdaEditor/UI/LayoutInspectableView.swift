//
//  LayoutInspectableView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.05.2026.
//

@_spi(AdaEngine) import AdaEngine

class LayoutInspectableView: UIView {
    var speed: Float = 0.2
    var pitch: Angle = Angle.radians(0)
    var yaw: Angle = Angle.radians(-90)
    let sensitivity: Float = 0.1

    private var cameraTransform = Transform3D.identity
    private var cameraUp: Vector3 = Vector3(0, 1, 0)
    private var cameraFront: Vector3 = Vector3(0, 0, -1)
    private var viewMatrix: Transform3D = .identity

    var lastMousePosition: Point = .zero
    var inspectLayout = false
    var drawDebugBorders = false
    private var zoom: Float = 1
    private var isViewMatrixDirty = true

    override func hitTest(_ point: Point, with event: any InputEvent) -> UIView? {
        if let event = (event as? MouseEvent), inspectLayout {
            if event.button == .scrollWheel && event.modifierKeys.contains(.main) {
                return self
            }
        }

        return super.hitTest(point, with: event)
    }

    override func update(_: TimeInterval) {
        if !inspectLayout {
            self.viewMatrix = .identity
            self.cameraTransform = .identity
            self.cameraFront = Vector3(0, 0, -1)
            return
        }

        if isViewMatrixDirty {
            self.viewMatrix = Transform3D.lookAt(
                eye: cameraTransform.origin,
                center: cameraTransform.origin + self.cameraFront,
                up: self.cameraUp
            )

            isViewMatrixDirty = false
        }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        if viewMatrix != .identity {
            context.concatenate(viewMatrix)
        }
        super.draw(with: context)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard event.button == .scrollWheel, event.modifierKeys.contains(.main) else {
            return
        }

        self.cameraTransform.origin += event.scrollDelta.y * sensitivity * speed * cameraFront
        self.isViewMatrixDirty = true

        guard event.button == .left && event.phase != .began else {
            return
        }

        let position = event.mousePosition
        var xoffset = position.x - self.lastMousePosition.x
        var yoffset = self.lastMousePosition.y - position.y
        self.lastMousePosition = position

        let sensitivity: Float = 0.1
        xoffset *= sensitivity
        yoffset *= sensitivity

        yaw += xoffset
        pitch += yoffset

        if pitch.radians > 89.0 {
            pitch = 89.0
        } else if pitch.radians < -89.0 {
            pitch = -89.0
        }

        var direction = Vector3()
        direction.x = Math.cos(yaw.radians) * Math.cos(pitch.radians)
        direction.y = Math.sin(pitch.radians)
        direction.z = Math.sin(yaw.radians) * Math.cos(pitch.radians)

        self.cameraFront = direction.normalized

        self.isViewMatrixDirty = true
    }

    override func onKeyPressed(_ event: Set<KeyEvent>) {
        for key in event where key.status == .down {
            switch key.keyCode {
            case .w:
                cameraTransform.origin += speed * cameraFront
                self.isViewMatrixDirty = true
            case .a:
                cameraTransform.origin -= cross(cameraFront, cameraUp).normalized * speed
                self.isViewMatrixDirty = true
            case .d:
                cameraTransform.origin += cross(cameraFront, cameraUp).normalized * speed
                self.isViewMatrixDirty = true
            case .s:
                cameraTransform.origin -= speed * cameraFront
                self.isViewMatrixDirty = true
            default:
                return
            }
        }
    }
}
