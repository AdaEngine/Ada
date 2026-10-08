import AdaECS

/// Generates ECS conformance, stable field-tagged coding, and multiplayer schema metadata.
///
/// Applying this macro implies ``Component``. Adding the generated component to an entity
/// also adds ``ReplicatedEntity`` through the required-component relationship.
@attached(member, names: named(CodingKeys))
@attached(
    extension,
    conformances: Component, Codable, Sendable, NetworkReplicatedComponent,
    names: named(requiredComponents), named(networkDescriptor)
)
public macro ReplicatedComponent(
    id: StaticString,
    version: UInt16 = 1,
    authority: NetworkAuthority = .host,
    visibility: NetworkVisibility = .allPeers
) = #externalMacro(module: "AdaEngineMacros", type: "ReplicatedComponentMacro")

/// Marks a stored property as part of its enclosing generated network schema.
@attached(peer)
public macro NetworkField(
    _ tag: UInt16,
    mode: FieldReplicationMode = .state,
    interpolate: FieldInterpolationMode = .none
) = #externalMacro(module: "AdaEngineMacros", type: "NetworkFieldMacro")

/// Documents that a stored property is deliberately excluded from the network payload.
@attached(peer)
public macro LocalOnly() = #externalMacro(module: "AdaEngineMacros", type: "LocalOnlyMacro")

/// Generates a typed peer-to-Host command and its stable field-tagged wire schema.
@attached(member, names: named(CodingKeys))
@attached(
    extension,
    conformances: Codable, Sendable, NetworkCommand, NetworkDescribedMessage,
    names: named(networkIdentifier), named(networkVersion), named(networkDescriptor)
)
public macro NetworkCommand(
    id: StaticString,
    version: UInt16 = 1,
    direction: RPCDirection = .peerToHost,
    delivery: NetworkDelivery = .reliableOrdered,
    channel: String = "command",
    maximumPayloadSize: Int = 64 * 1_024
) = #externalMacro(module: "AdaEngineMacros", type: "NetworkCommandMacro")
