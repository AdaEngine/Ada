import AdaUIDescription

extension UICatalog {
    static var imageCapParameters: [UIParameter] {
        [number("capTop", 0), number("capLeading", 0), number("capBottom", 0), number("capTrailing", 0)]
    }
}

extension UIFactoryContext {
    func imageCapInsets() throws -> ImageCapInsets {
        @MainActor func pixels(_ key: String) throws -> Int {
            let value = number(key)
            guard value.isFinite, value >= 0, value <= Double(Int32.max), value.rounded() == value else {
                throw UIDiagnostic("\(key) must be a nonnegative integer in source pixels.")
            }
            return Int(value)
        }
        return try ImageCapInsets(top: pixels("capTop"), leading: pixels("capLeading"), bottom: pixels("capBottom"), trailing: pixels("capTrailing"))
    }
}
