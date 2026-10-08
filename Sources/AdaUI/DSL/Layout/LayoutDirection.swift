/// The horizontal direction in which the user interface is laid out.
public enum LayoutDirection: Sendable {
    /// A direction where content flows from left to right.
    case leftToRight

    /// A direction where content flows from right to left.
    case rightToLeft
}

extension HorizontalAlignment {
    func resolved(for layoutDirection: LayoutDirection) -> HorizontalAlignment {
        guard layoutDirection == .rightToLeft else {
            return self
        }

        return switch self {
        case .leading: .trailing
        case .trailing: .leading
        case .center: .center
        }
    }
}

extension Alignment {
    func resolved(for layoutDirection: LayoutDirection) -> Alignment {
        Alignment(
            horizontal: horizontal.resolved(for: layoutDirection),
            vertical: vertical
        )
    }
}
