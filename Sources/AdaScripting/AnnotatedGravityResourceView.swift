@_spi(Scripting) import AdaECS
import Gravity

@GSExportable("AdaResource")
final class AnnotatedGravityResourceView: @unchecked Sendable {
    private let fields: [String: ReflectedComponentField]
    private let parameter: DynamicResource
    private let reportDiagnostic: @Sendable (String) -> Void
    private let virtualMachine: GravityVirtualMachine
    private var isActive = true

    @GSExportableIgnore
    static func make(
        parameter: DynamicResource,
        fields: [String: ReflectedComponentField],
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) -> AnnotatedGravityResourceView {
        AnnotatedGravityResourceView(
            parameter: parameter,
            fields: fields,
            reportDiagnostic: reportDiagnostic,
            virtualMachine: virtualMachine
        )
    }

    private init(
        parameter: DynamicResource,
        fields: [String: ReflectedComponentField],
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        virtualMachine: GravityVirtualMachine
    ) {
        self.parameter = parameter
        self.fields = fields
        self.reportDiagnostic = reportDiagnostic
        self.virtualMachine = virtualMachine
    }

    func available() -> Bool {
        guard isActive else {
            reportDiagnostic("Resource view is no longer valid")
            return false
        }
        return parameter.isAvailable
    }

    func get(_ fieldName: String) -> GSValue {
        guard isActive else {
            reportDiagnostic("Resource view is no longer valid")
            return GSValue(nullIn: virtualMachine)
        }
        guard let field = fields[fieldName], let value = parameter.read(field: field) else {
            reportDiagnostic("Unknown or unavailable resource field '\(fieldName)'")
            return GSValue(nullIn: virtualMachine)
        }
        return AnnotatedGravityValueBridge.makeGravityValue(value, virtualMachine: virtualMachine)
    }

    @discardableResult
    func set(_ fieldName: String, _ value: GSValue) -> Bool {
        guard isActive else {
            reportDiagnostic("Resource view is no longer valid")
            return false
        }
        guard let field = fields[fieldName] else {
            reportDiagnostic("Unknown resource field '\(fieldName)'")
            return false
        }
        guard
            let fieldValue = AnnotatedGravityValueBridge.makeReflectedFieldValue(value),
            parameter.write(field: field, value: fieldValue)
        else {
            reportDiagnostic("Invalid value for resource field '\(fieldName)'")
            return false
        }
        return true
    }

    @GSExportableIgnore
    func invalidate() { isActive = false }
}
