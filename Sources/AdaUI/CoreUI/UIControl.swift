//
//  UIControl.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 18.06.2024.
//

import AdaInput

/// A UI event action.
public final class UIEventAction: Hashable, Identifiable {
    /// The id of the UI event action.
    public lazy var id: ObjectIdentifier = ObjectIdentifier(self)

    /// The callback of the UI event action.
    let callback: () -> Void

    /// Initialize a new UI event action.
    ///
    /// - Parameter block: The block to initialize the UI event action with.
    public init(_ block: @escaping () -> Void) {
        self.callback = block
    }

    /// Call the UI event action.
    public func callAsFunction() {
        self.callback()
    }

    // MARK: - Hashable

    /// Hash the UI event action.
    ///
    /// - Parameter hasher: The hasher to hash the UI event action with.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Check if the UI event action is equal to another UI event action.
    ///
    /// - Parameters:
    ///   - lhs: The left UI event action.
    ///   - rhs: The right UI event action.
    /// - Returns: A Boolean value indicating whether the UI event action is equal to another UI event action.
    public static func == (lhs: UIEventAction, rhs: UIEventAction) -> Bool {
        lhs.id == rhs.id
    }
}

/// The base class for controls, which are visual elements that convey a specific action or intention in response to user interactions.
open class UIControl: UIView {
    /// Constants describing the state of a control.
    public struct State: OptionSet, Hashable, Sendable {
        /// The raw value of the UI control state.
        public let rawValue: UInt

        /// Initialize a new UI control state.
        ///
        /// - Parameter rawValue: The raw value of the UI control state.
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// A Boolean value indicating whether the control is in the enabled state.
        public var isEnabled: Bool {
            !self.contains(.disabled)
        }

        /// A Boolean value indicating whether the control is in the selected state.
        public var isSelected: Bool {
            self.contains(.selected)
        }

        /// A Boolean value indicating whether the control draws a highlight.
        public var isHighlighted: Bool {
            self.contains(.highlighted)
        }

        /// The normal state.
        public static let normal = Self(rawValue: 1 << 0)
        /// The disabled state.
        public static let disabled = Self(rawValue: 1 << 1)
        /// The highlighted state.
        public static let highlighted = Self(rawValue: 1 << 2)
        /// The focused state.
        public static let focused = Self(rawValue: 1 << 3)
        /// The selected state.
        public static let selected = Self(rawValue: 1 << 4)
    }

    /// Constants describing the types of events possible for controls.
    public struct Event: OptionSet, Hashable, Sendable {
        /// A UI control event.
        public let rawValue: UInt

        /// Initialize a new UI control event.
        ///
        /// - Parameter rawValue: The raw value of the UI control event.
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        /// The value changed event.
        public static let valueChanged = Self(rawValue: 1 << 0)
        /// The touch down event.
        public static let touchDown = Self(rawValue: 1 << 1)
        /// The touch up event.
        public static let touchUp = Self(rawValue: 1 << 2)
        /// The touch drag inside event.
        public static let touchDragInside = Self(rawValue: 1 << 3)
        public static let touchCancel = Self(rawValue: 1 << 4)
    }

    /// The state of the UI control.
    public var state: State = .normal {
        didSet {
            if oldValue != state {
                setNeedsDisplay()
            }
        }
    }

    /// The action of the UI control.
    public typealias Action = () -> Void

    internal var actions: [Event: Set<UIEventAction>] = [:]

    /// Add an action to the UI control.
    ///
    /// - Parameters:
    ///   - action: The action to add to the UI control.
    ///   - event: The event to add the action for.
    public func addAction(_ action: UIEventAction, for event: Event) {
        self.actions[event, default: []].insert(action)
    }

    /// Remove an action from the UI control.
    ///
    /// - Parameters:
    ///   - action: The action to remove from the UI control.
    ///   - event: The event to remove the action for.
    public func removeAction(_ action: UIEventAction, for event: Event) {
        self.actions[event]?.remove(action)
    }

    /// Trigger the actions for the given event.
    ///
    /// - Parameter event: The event to trigger the actions for.
    public func triggerActions(for event: Event) {
        self.actions[event]?
            .forEach {
                $0.callback()
            }
    }

    /// Handle the mouse event.
    ///
    /// - Parameter event: The mouse event to handle.
    override open func onMouseEvent(_ event: MouseEvent) {
        switch event.phase {
        case .began,
            .changed:
            switch event.button {
            case .none:
                state.insert(.highlighted)
            case .left:
                state.insert(.selected)
            default:
                return
            }
        case .ended,
            .cancelled:
            state.remove(.selected)
            state.remove(.focused)
            state.remove(.highlighted)
        }
    }
}
