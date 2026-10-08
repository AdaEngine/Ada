//
//  Alert.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/31/22.
//

/// The object describes an alert.
public struct Alert {
    public let title: String
    public let message: String?
    public let buttons: [Button]

    public init(title: String, message: String? = nil, buttons: [Self.Button] = []) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

extension Alert {
    /// Button for alert view.
    public struct Button {
        public enum Kind: UInt {
            case cancel
            case plain
        }

        public typealias CompletionBlock = () -> Void

        public let kind: Kind
        public let title: String
        public let action: CompletionBlock?

        /// Create cancel button with custom action.
        public static func cancel(_ title: String? = nil, action: CompletionBlock? = nil) -> Self {
            return Self(kind: .cancel, title: title ?? "Cancel", action: action)
        }

        /// Create plain button with action.
        public static func button(_ title: String, action: CompletionBlock? = nil) -> Self {
            return Self(kind: .plain, title: title, action: action)
        }
    }
}
