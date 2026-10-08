@_spi(Scripting) import AdaECS
import AdaMultiplayer
import AdaScriptCompilerCore
import Gravity

enum AdaScriptNetworkBridge {
    static func descriptor(for schema: AdaScriptDataSchema) throws -> NetworkTypeDescriptor {
        guard schema.kind == .component, let replication = schema.replication else {
            throw AdaScriptError.invalidManifest("'\(schema.name)' is not a replicated component")
        }
        guard let version = UInt16(exactly: replication.version) else {
            throw AdaScriptError.invalidManifest("Replicated component '\(schema.name)' version is out of range")
        }
        let authority: NetworkAuthority = replication.authority == "host" ? .host : .anyPeer
        return NetworkTypeDescriptor(
            typeID: schema.id,
            version: version,
            kind: .component,
            authority: authority,
            visibility: .allPeers,
            fields: try schema.fields.compactMap { field in
                guard let network = field.network else {
                    return nil
                }
                return NetworkFieldDescriptor(
                    tag: network.tag,
                    wireType: wireType(for: field.defaultValue),
                    replication: try replicationMode(network.mode),
                    interpolation: try interpolationMode(network.interpolation)
                )
            }
        )
    }

    static func descriptor(for schema: AdaScriptNetworkCommandSchema) throws -> NetworkTypeDescriptor {
        guard let version = UInt16(exactly: schema.version) else {
            throw AdaScriptError.invalidManifest("Network command '\(schema.name)' version is out of range")
        }
        let direction: RPCDirection
        switch schema.direction {
        case "peer_to_host": direction = .peerToHost
        case "host_to_peer": direction = .hostToPeer
        case "bidirectional": direction = .bidirectional
        default:
            throw AdaScriptError.invalidManifest("Unknown network direction '\(schema.direction)'")
        }
        let delivery: NetworkDelivery
        switch schema.delivery {
        case "reliable_ordered": delivery = .reliableOrdered
        case "unreliable": delivery = .unreliable
        case "unreliable_sequenced": delivery = .unreliableSequenced
        default:
            throw AdaScriptError.invalidManifest("Unknown network delivery '\(schema.delivery)'")
        }
        return NetworkTypeDescriptor(
            typeID: schema.id,
            version: version,
            kind: .command,
            authority: .anyPeer,
            direction: direction,
            delivery: delivery,
            channel: schema.channel,
            maximumPayloadSize: schema.maximumPayloadSize,
            fields: try schema.fields.map { field in
                guard let network = field.network else {
                    throw AdaScriptError.invalidManifest("Network command field '\(field.name)' has no tag")
                }
                return NetworkFieldDescriptor(
                    tag: network.tag,
                    wireType: wireType(for: field.defaultValue),
                    replication: try replicationMode(network.mode),
                    interpolation: try interpolationMode(network.interpolation)
                )
            }
        )
    }

    static func prelude(commands: [AdaScriptNetworkCommandSchema]) -> String {
        guard !commands.isEmpty else {
            return ""
        }
        return "extern var __adaNetworkFactory;\n"
    }

    private static func wireType(for value: AdaScriptSchemaField.Value) -> NetworkWireType {
        switch value {
        case .bool: .bool
        case .double: .floatingPoint
        case .int: .signedInteger
        case .string: .string
        }
    }

    private static func replicationMode(_ value: String) throws -> FieldReplicationMode {
        switch value {
        case "state": .state
        case "latest": .latest
        case "initial_only": .initialOnly
        default: throw AdaScriptError.invalidManifest("Unknown field replication mode '\(value)'")
        }
    }

    private static func interpolationMode(_ value: String) throws -> FieldInterpolationMode {
        switch value {
        case "none": .none
        case "linear": .linear
        case "custom": .custom
        default: throw AdaScriptError.invalidManifest("Unknown field interpolation mode '\(value)'")
        }
    }
}

@GSExportable("AdaNetworkCommandValue")
final class AdaScriptNetworkCommandValue: @unchecked Sendable {
    @GSExportableIgnore
    let commandName: String

    @GSExportableIgnore
    let values: [ReflectedFieldValue]

    @GSExportableIgnore
    init(commandName: String, values: [ReflectedFieldValue]) {
        self.commandName = commandName
        self.values = values
    }

    @GSExportableIgnore
    init() {
        self.commandName = ""
        self.values = []
    }
}

@GSExportable("AdaNetworkCommandFactory")
final class AdaScriptNetworkCommandFactory: @unchecked Sendable {
    @GSExportableIgnore
    private let fieldCountByName: [String: Int]

    @GSExportableIgnore
    private let reportDiagnostic: @Sendable (String) -> Void

    @GSExportableIgnore
    static func make(
        schemas: [AdaScriptNetworkCommandSchema],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> Self {
        Self(
            fieldCountByName: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.fields.count) }),
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        fieldCountByName: [String: Int],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.fieldCountByName = fieldCountByName
        self.reportDiagnostic = reportDiagnostic
    }

    func make(_ commandName: String, _ values: GSValue) -> AdaScriptNetworkCommandValue {
        guard let expectedCount = fieldCountByName[commandName], values.isList else {
            reportDiagnostic("Unknown AdaScript network command '\(commandName)'")
            return AdaScriptNetworkCommandValue()
        }
        var detached: [ReflectedFieldValue] = []
        for value in values.toList {
            guard let field = AnnotatedGravityValueBridge.makeReflectedFieldValue(value) else {
                reportDiagnostic("Unsupported value in network command '\(commandName)'")
                return AdaScriptNetworkCommandValue()
            }
            detached.append(field)
        }
        guard detached.count == expectedCount else {
            reportDiagnostic("Network command '\(commandName)' expects \(expectedCount) fields")
            return AdaScriptNetworkCommandValue()
        }
        return AdaScriptNetworkCommandValue(commandName: commandName, values: detached)
    }
}

@GSExportable("AdaMultiplayer")
final class AdaScriptMultiplayerAPI: @unchecked Sendable, AdaScriptNonSendableBridge {
    @GSExportableIgnore
    private var runtime: Ref<AdaScriptNetworkRuntime>?

    @GSExportableIgnore
    private let reportDiagnostic: @Sendable (String) -> Void

    @GSExportableIgnore
    static func make(
        runtime: Ref<AdaScriptNetworkRuntime>?,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> Self {
        Self(runtime: runtime, reportDiagnostic: reportDiagnostic)
    }

    private init(
        runtime: Ref<AdaScriptNetworkRuntime>?,
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.runtime = runtime
        self.reportDiagnostic = reportDiagnostic
    }

    func send(_ command: AdaScriptNetworkCommandValue) -> Bool {
        guard !command.commandName.isEmpty, let runtime else {
            reportDiagnostic("AdaScript multiplayer runtime is unavailable")
            return false
        }
        guard runtime.wrappedValue.send(commandNamed: command.commandName, values: command.values) else {
            reportDiagnostic("Unable to queue network command '\(command.commandName)'")
            return false
        }
        return true
    }

    @GSExportableIgnore
    func invalidate() {
        runtime = nil
    }
}

@GSExportable("AdaRemoteCommand")
final class AdaScriptRemoteCommandBridge: @unchecked Sendable {
    let source: String
    let value: AdaScriptNetworkValueBridge

    @GSExportableIgnore
    init(payload: AdaScriptRemoteCommandPayload, virtualMachine: GravityVirtualMachine) {
        self.source = payload.source
        self.value = AdaScriptNetworkValueBridge(values: payload.values, virtualMachine: virtualMachine)
    }

    @GSExportableIgnore
    init() {
        self.source = ""
        self.value = AdaScriptNetworkValueBridge()
    }
}

@GSExportable("AdaNetworkValue")
final class AdaScriptNetworkValueBridge: @unchecked Sendable {
    @GSExportableIgnore
    private let values: [String: ReflectedFieldValue]

    @GSExportableIgnore
    private weak var virtualMachine: GravityVirtualMachine?

    @GSExportableIgnore
    init(values: [String: ReflectedFieldValue], virtualMachine: GravityVirtualMachine) {
        self.values = values
        self.virtualMachine = virtualMachine
    }

    @GSExportableIgnore
    init() {
        self.values = [:]
        self.virtualMachine = nil
    }

    @GSExportableIgnore
    func get(_ name: String) -> GSValue? {
        guard let value = values[name], let virtualMachine else {
            return nil
        }
        return AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
    }
}
