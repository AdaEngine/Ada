import Foundation

enum EditorCloudConfiguration {
    static let productionServer = "https://cloud.adaengine.org"

    static func server(environment: String?, saved: String?, bundled: String?) -> String {
        for candidate in [environment, saved, bundled] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.hasPrefix("$(") else {
                continue
            }
            return value
        }
        return productionServer
    }
}
