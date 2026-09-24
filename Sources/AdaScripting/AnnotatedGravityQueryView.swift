@_spi(Scripting) import AdaECS
import Gravity

/// Access is serialized by AdaScriptRuntimeCoordinator while a callback is active.
final class AnnotatedGravityQueryLease: @unchecked Sendable {
    var isActive = true
}

@GSExportable("AdaQuery")
final class AnnotatedGravityQueryBridge: @unchecked Sendable {
    private let cursor: DynamicQueryCursor
    private let row: AnnotatedGravityQueryRow
    private let virtualMachine: GravityVirtualMachine
    private var iterationIndex = 0
    private let lease: AnnotatedGravityQueryLease
    private let reportDiagnostic: @Sendable (String) -> Void

    @GSExportableIgnore
    static func make(
        cursor: DynamicQueryCursor,
        componentAccesses: [AnnotatedComponentAccess],
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> AnnotatedGravityQueryBridge {
        AnnotatedGravityQueryBridge(
            cursor: cursor,
            componentAccesses: componentAccesses,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        cursor: DynamicQueryCursor,
        componentAccesses: [AnnotatedComponentAccess],
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.cursor = cursor
        self.virtualMachine = virtualMachine
        self.lease = AnnotatedGravityQueryLease()
        self.reportDiagnostic = reportDiagnostic
        self.row = AnnotatedGravityQueryRow.make(
            cursor: cursor,
            componentAccesses: componentAccesses,
            lease: lease,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    func iterate(_ previous: GSValue) -> GSValue {
        guard lease.isActive else {
            reportDiagnostic("Query capability is no longer valid")
            return GSValue(boolean: false, in: virtualMachine)
        }
        if previous.isNull || previous.isUndefined {
            cursor.reset()
            iterationIndex = 0
        }
        guard cursor.advance() else {
            return GSValue(boolean: false, in: virtualMachine)
        }
        defer { iterationIndex += 1 }
        return GSValue(integer: iterationIndex, in: virtualMachine)
    }

    func next(_: Int) -> AnnotatedGravityQueryRow {
        row
    }

    @GSExportableIgnore
    func invalidate() { lease.isActive = false }
}

@GSExportable("AdaQueryRow")
final class AnnotatedGravityQueryRow: @unchecked Sendable {
    var id: Int {
        guard lease.isActive else {
            reportDiagnostic("Query row is no longer valid")
            return -1
        }
        return cursor.entityID
    }

    private let componentViews: [String: AnnotatedGravityComponentView]
    private let cursor: DynamicQueryCursor
    private let reportDiagnostic: @Sendable (String) -> Void
    private let virtualMachine: GravityVirtualMachine
    private let lease: AnnotatedGravityQueryLease

    @GSExportableIgnore
    static func make(
        cursor: DynamicQueryCursor,
        componentAccesses: [AnnotatedComponentAccess],
        lease: AnnotatedGravityQueryLease,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> AnnotatedGravityQueryRow {
        AnnotatedGravityQueryRow(
            cursor: cursor,
            componentAccesses: componentAccesses,
            lease: lease,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        cursor: DynamicQueryCursor,
        componentAccesses: [AnnotatedComponentAccess],
        lease: AnnotatedGravityQueryLease,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.cursor = cursor
        self.reportDiagnostic = reportDiagnostic
        self.virtualMachine = virtualMachine
        self.lease = lease
        self.componentViews = Dictionary(
            uniqueKeysWithValues: componentAccesses.map { access in
                (
                    access.alias,
                    AnnotatedGravityComponentView.make(
                        cursor: cursor,
                        access: access,
                        lease: lease,
                        reportDiagnostic: reportDiagnostic,
                        virtualMachine: virtualMachine
                    )
                )
            }
        )
    }

    func get(_ component: String, _ field: String) -> GSValue {
        guard lease.isActive else {
            reportDiagnostic("Query row is no longer valid")
            return GSValue(nullIn: virtualMachine)
        }
        guard let componentView = componentViews[component] else {
            reportDiagnostic("Unknown query component alias '\(component)'")
            return GSValue(nullIn: virtualMachine)
        }
        return componentView.get(field)
    }

    @discardableResult
    func set(_ component: String, _ field: String, _ value: GSValue) -> Bool {
        guard lease.isActive else {
            reportDiagnostic("Query row is no longer valid")
            return false
        }
        guard let componentView = componentViews[component] else {
            reportDiagnostic("Unknown query component alias '\(component)'")
            return false
        }
        return componentView.set(field, value)
    }

    func component(named alias: String) -> AnnotatedGravityComponentView? {
        guard lease.isActive else {
            reportDiagnostic("Query row is no longer valid")
            return nil
        }
        return componentViews[alias]
    }
}

@GSExportable("AdaComponent")
final class AnnotatedGravityComponentView: @unchecked Sendable {
    private let access: AnnotatedComponentAccess
    private let cursor: DynamicQueryCursor
    private let reportDiagnostic: @Sendable (String) -> Void
    private let virtualMachine: GravityVirtualMachine
    private let lease: AnnotatedGravityQueryLease

    @GSExportableIgnore
    static func make(
        cursor: DynamicQueryCursor,
        access: AnnotatedComponentAccess,
        lease: AnnotatedGravityQueryLease,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> AnnotatedGravityComponentView {
        AnnotatedGravityComponentView(
            cursor: cursor,
            access: access,
            lease: lease,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        cursor: DynamicQueryCursor,
        access: AnnotatedComponentAccess,
        lease: AnnotatedGravityQueryLease,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.cursor = cursor
        self.access = access
        self.reportDiagnostic = reportDiagnostic
        self.virtualMachine = virtualMachine
        self.lease = lease
    }

    func get(_ fieldName: String) -> GSValue {
        guard lease.isActive else {
            reportDiagnostic("Component view is no longer valid")
            return GSValue(nullIn: virtualMachine)
        }
        guard
            let field = access.fields[fieldName],
            let value = cursor.read(componentAt: access.componentIndex, field: field)
        else {
            reportDiagnostic("Unknown or unreadable field '\(access.alias).\(fieldName)'")
            return GSValue(nullIn: virtualMachine)
        }
        return AnnotatedGravityValueBridge.makeGravityValue(
            value,
            virtualMachine: virtualMachine
        )
    }

    @discardableResult
    func set(_ fieldName: String, _ value: GSValue) -> Bool {
        guard lease.isActive else {
            reportDiagnostic("Component view is no longer valid")
            return false
        }
        guard let field = access.fields[fieldName] else {
            reportDiagnostic("Unknown field '\(access.alias).\(fieldName)'")
            return false
        }
        guard
            let fieldValue = AnnotatedGravityValueBridge.makeReflectedFieldValue(value),
            cursor.write(componentAt: access.componentIndex, field: field, value: fieldValue)
        else {
            reportDiagnostic("Invalid value for '\(access.alias).\(fieldName)'")
            return false
        }
        return true
    }
}
