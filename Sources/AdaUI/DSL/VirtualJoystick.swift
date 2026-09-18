import AdaInput
import AdaUtils
import Math

/// Sizes are logical points. Color alpha is multiplied by the configured opacity.
public struct VirtualJoystickStyle: Equatable, Sendable {
    public var diameter: Float
    public var thumbDiameter: Float
    public var movementRadius: Float
    public var deadZone: Float
    public var baseColor: Color
    public var ringColor: Color
    public var thumbColor: Color
    public var ringWidth: Float
    public var idleOpacity: Float
    public var activeOpacity: Float
    public var idleThumbOpacity: Float
    public var activeThumbOpacity: Float

    public init(
        diameter: Float = 96,
        thumbDiameter: Float = 38,
        movementRadius: Float = 27,
        deadZone: Float = 0.12,
        baseColor: Color = .fromHex(0xE0D8C5),
        ringColor: Color = .fromHex(0x293C55),
        thumbColor: Color = .fromHex(0x477C80),
        ringWidth: Float = 3,
        idleOpacity: Float = 1,
        activeOpacity: Float = 1,
        idleThumbOpacity: Float = 1,
        activeThumbOpacity: Float = 1
    ) {
        self.diameter = diameter
        self.thumbDiameter = thumbDiameter
        self.movementRadius = movementRadius
        self.deadZone = deadZone
        self.baseColor = baseColor
        self.ringColor = ringColor
        self.thumbColor = thumbColor
        self.ringWidth = ringWidth
        self.idleOpacity = idleOpacity
        self.activeOpacity = activeOpacity
        self.idleThumbOpacity = idleThumbOpacity
        self.activeThumbOpacity = activeThumbOpacity
    }

    /// An invisible hit area; only the thumb appears after dragging outside the dead zone.
    public static var invisibleUntilDragged: Self {
        Self(idleOpacity: 0, activeOpacity: 0, idleThumbOpacity: 0)
    }

    var resolved: Self {
        var result = self
        result.diameter = diameter.isFinite ? min(4096, max(1, diameter)) : 96
        result.thumbDiameter = thumbDiameter.isFinite ? min(result.diameter, max(0, thumbDiameter)) : 38
        let availableRadius = (result.diameter - result.thumbDiameter) / 2
        result.movementRadius = movementRadius.isFinite ? min(availableRadius, max(0, movementRadius)) : availableRadius
        result.deadZone = Self.unit(deadZone, fallback: 0.12)
        result.ringWidth = ringWidth.isFinite ? min(result.diameter / 2, max(0, ringWidth)) : 3
        result.idleOpacity = Self.unit(idleOpacity)
        result.activeOpacity = Self.unit(activeOpacity)
        result.idleThumbOpacity = Self.unit(idleThumbOpacity)
        result.activeThumbOpacity = Self.unit(activeThumbOpacity)
        return result
    }

    private static func unit(_ value: Float, fallback: Float = 1) -> Float {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
}

/// A touch/mouse stick with normalized axes and exclusive ownership by the initiating contact.
public struct VirtualJoystick: View {
    private let x: Binding<Float>
    private let y: Binding<Float>
    private let style: VirtualJoystickStyle

    public init(x: Binding<Float>, y: Binding<Float>, style: VirtualJoystickStyle = .init()) {
        self.x = x
        self.y = y
        self.style = style
    }
    public var body: some View {
        JoystickSurface(x: x, y: y, style: style.resolved).frame(width: style.resolved.diameter, height: style.resolved.diameter)
    }
}

private struct JoystickSurface: UIViewRepresentable {
    let x: Binding<Float>
    let y: Binding<Float>
    let style: VirtualJoystickStyle
    func makeUIView(in _: Context) -> JoystickHost {
        let view = JoystickHost()
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: JoystickHost, in _: Context) {
        view.x = x
        view.y = y
        view.style = style
        view.setNeedsDisplay()
    }
}

final class JoystickHost: UIView {
    var x: Binding<Float>?
    var y: Binding<Float>?
    var style = VirtualJoystickStyle()
    private var activeContact: RID?
    private var mouseActive = false
    private(set) var isDragging = false
    var thumbOpacity: Float { isDragging ? style.resolved.activeThumbOpacity : style.resolved.idleThumbOpacity }

    override func draw(in rect: Rect, with context: UIGraphicsContext) {
        let style = style.resolved
        let scale = min(rect.width, rect.height) / style.diameter
        let diameter = style.diameter * scale
        let center = Vector2(rect.midX, rect.midY)
        let base = Rect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        let opacity = isDragging ? style.activeOpacity : style.idleOpacity
        context.drawEllipse(in: base, color: style.baseColor.opacity(style.baseColor.alpha * opacity))
        if style.ringWidth > 0 {
            context.drawEllipse(in: base, color: style.ringColor.opacity(style.ringColor.alpha * opacity), thickness: style.ringWidth / style.diameter)
        }
        let offset = Vector2(x?.wrappedValue ?? 0, -(y?.wrappedValue ?? 0)) * style.movementRadius * scale
        let thumb = style.thumbDiameter * scale
        context.drawEllipse(
            in: Rect(x: center.x + offset.x - thumb / 2, y: center.y + offset.y - thumb / 2, width: thumb, height: thumb),
            color: style.thumbColor.opacity(style.thumbColor.alpha * thumbOpacity)
        )
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard activeContact == nil else {
            return
        }
        if event.phase == .began {
            mouseActive = true
        }
        guard mouseActive else {
            return
        }
        if event.phase == .ended || event.phase == .cancelled {
            reset()
        } else {
            move(event.mousePosition)
        }
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard !mouseActive else {
            return
        }
        for touch in touches {
            if touch.phase == .began, activeContact == nil {
                activeContact = touch.contactID
            }
            guard activeContact == touch.contactID else {
                continue
            }
            if touch.phase == .ended || touch.phase == .cancelled {
                reset()
            } else {
                move(touch.location)
            }
        }
    }

    override func onFocusChanged(isFocused: Bool) {
        if !isFocused {
            reset()
        }
    }
    override func viewWillMove(to window: UIWindow?) {
        if window == nil {
            reset()
        }
    }
    override func viewWillMove(to parentView: UIView?) {
        if parentView == nil {
            reset()
        }
    }

    private func move(_ point: Point) {
        let style = style.resolved
        let radius = style.movementRadius * min(bounds.width, bounds.height) / style.diameter
        guard radius > 0, point.x.isFinite, point.y.isFinite else {
            reset()
            return
        }
        var axis = Vector2((point.x - bounds.width / 2) / radius, -(point.y - bounds.height / 2) / radius)
        let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
        if length > 1 {
            axis /= length
        }
        if length <= style.deadZone {
            axis = .zero
        } else {
            isDragging = true
        }
        x?.wrappedValue = axis.x
        y?.wrappedValue = axis.y
        setNeedsDisplay()
    }
    private func reset() {
        activeContact = nil
        mouseActive = false
        isDragging = false
        x?.wrappedValue = 0
        y?.wrappedValue = 0
        setNeedsDisplay()
    }
}
