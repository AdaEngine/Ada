//
//  PreferenceModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.07.2024.
//

/// A named value produced by a view.
public protocol PreferenceKey {
    /// The type of value produced by this preference.
    associatedtype Value

    /// The default value of the preference.
    static var defaultValue: Value { get }

    /// Combines a sequence of values by modifying the previously-accumulated value with the result of a closure that provides the next value.
    static func reduce(value: inout Value, nextValue: () -> Value)
}

extension View {
    public func preference<K: PreferenceKey>(key: K.Type, value: K.Value) -> some View {
        self.transformPreference(key) {
            $0 = value
        }
    }

    public func transformPreference<K: PreferenceKey>(_ key: K.Type, _ block: @escaping (inout K.Value) -> Void) -> some View {
        modifier(TransformPreference(content: self, key: key, block: block))
    }

    public func onPreferenceChange<K: PreferenceKey>(_ key: K.Type, perform action: @escaping (K.Value) -> Void) -> some View {
        modifier(PreferenceChangeModifier(content: self, key: key, action: action))
    }
}

struct PreferenceChangeModifier<V: View, K: PreferenceKey>: ViewModifier, ViewNodeBuilder {
    let content: V
    let key: K.Type
    let action: (K.Value) -> Void

    typealias Body = Never

    func buildViewNode(in context: BuildContext) -> ViewNode {
        PreferenceChangeViewNode<K>(contentNode: context.makeNode(from: content), content: content, action: action)
    }
}

final class PreferenceChangeViewNode<Key: PreferenceKey>: ViewModifierNode {
    var action: (Key.Value) -> Void

    init<Content>(contentNode: ViewNode, content: Content, action: @escaping (Key.Value) -> Void) where Content: View {
        self.action = action
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? Self else {
            return
        }

        action = node.action
    }

    override func updatePreference<K>(key: K.Type, value: K.Value) where K: PreferenceKey {
        super.updatePreference(key: key, value: value)

        if Key.self == K.self && Key.Value.self == K.Value.self {
            action(value as! Key.Value)
        }
    }
}

struct TransformPreference<V: View, K: PreferenceKey>: ViewModifier, ViewNodeBuilder {
    let content: V
    let key: K.Type
    let block: (inout K.Value) -> Void

    typealias Body = Never

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TransformPreferenceViewNode<K>(contentNode: context.makeNode(from: content), content: content, block: block)
    }
}

final class TransformPreferenceViewNode<K: PreferenceKey>: ViewModifierNode {
    private(set) var block: (inout K.Value) -> Void
    private(set) var preferences = PreferenceValues()

    init<Content>(contentNode: ViewNode, content: Content, block: @escaping (inout K.Value) -> Void) where Content: View {
        self.block = block
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? Self else {
            return
        }

        block = node.block
        self.performChangeBlock()
    }

    private func performChangeBlock() {
        var value = self.preferences[K.self]
        self.block(&value)
        self.contentNode.updatePreference(key: K.self, value: value)
    }

    override func didMove(to _: ViewNode?) {
        self.performChangeBlock()
    }
}

struct PreferenceValues {
    private var values: [ObjectIdentifier: Any] = [:]

    /// Accesses the preference value associated with a custom key.
    subscript<K: PreferenceKey>(_ type: K.Type) -> K.Value {
        get {
            (self.values[ObjectIdentifier(type)] as? K.Value) ?? K.defaultValue
        }
        set {
            self.values[ObjectIdentifier(type)] = newValue
        }
    }
}
