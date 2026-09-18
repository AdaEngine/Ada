import Foundation

/// Capabilities of the distribution containing the SwiftPM executable.
/// Read the host app metadata: Xcode target compilation flags do not propagate to packages.
public enum EditorDistribution: String, Sendable {
    case appStore
    case standalone

    public static let current: Self = {
        #if os(iOS) || os(tvOS) || os(visionOS)
            return .appStore
        #else
            return resolve(
                channel: Bundle.main.object(forInfoDictionaryKey: "AdaEditorDistribution") as? String,
                isAppBundle: Bundle.main.bundleURL.pathExtension == "app"
            )
        #endif
    }()

    static func resolve(channel: String?, isAppBundle: Bool) -> Self {
        if let channel, let distribution = Self(rawValue: channel) {
            return distribution
        }
        // Packaged apps fail closed; command-line development builds keep native tooling.
        return isAppBundle ? .appStore : .standalone
    }

    public var supportsSwiftProjects: Bool { self == .standalone }

    public var projectTemplates: [EditorProjectTemplate] {
        supportsSwiftProjects ? EditorProjectTemplate.allCases : [.adaScript]
    }

    public func validate(buildSystem: AdaProjectBuildSystem) throws {
        guard supportsSwiftProjects || buildSystem.isAdaScript else {
            throw EditorDistributionError.swiftProjectsUnavailable
        }
    }
}

enum EditorDistributionError: LocalizedError {
    case swiftProjectsUnavailable

    var errorDescription: String? { Self.swiftProjectsMessage }

    static let swiftProjectsMessage = "This version supports AdaScript projects only. Open Swift and hybrid projects in the standalone macOS version from the Ada website."
}
