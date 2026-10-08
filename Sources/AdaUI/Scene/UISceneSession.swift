/// Compatibility name for UI scenes authored before the runtime was renamed.
/// New code should use `UISceneInstance` to avoid ambiguity with UIKit.
@available(*, deprecated, renamed: "UISceneInstance")
public typealias UISceneSession = UISceneInstance
