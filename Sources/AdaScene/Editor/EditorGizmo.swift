//
//  EditorGizmo.swift
//  AdaEngine
//

import AdaECS
import AdaUtils

public enum EditorGizmoKind: String, Codable, Hashable, Sendable, CaseIterable {
    case transform
    case light
    case camera
    case audio
    case custom
}

@Component
public struct EditorGizmo: Codable, Hashable, Sendable {
    public var name: String
    public var kind: EditorGizmoKind
    public var isEnabled: Bool
    public var size: Float
    public var color: Color?

    public init(
        name: String = "Gizmo",
        kind: EditorGizmoKind = .custom,
        isEnabled: Bool = true,
        size: Float = 1,
        color: Color? = nil
    ) {
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.size = size
        self.color = color
    }
}
