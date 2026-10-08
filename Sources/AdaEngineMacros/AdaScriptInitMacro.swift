import SwiftSyntax
import SwiftSyntaxMacros

/// Marker consumed by ``ComponentMacro`` when generating a direct runtime
/// constructor. The marker itself does not emit a peer declaration.
public struct AdaScriptInitMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
