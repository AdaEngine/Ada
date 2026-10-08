import AdaPackageManifestTool
import Foundation

@main
struct AdaPackageTool {
    static func main() throws {
        do {
            let invocation = try Invocation(arguments: Array(CommandLine.arguments.dropFirst()))
            let manifest = try String(contentsOf: invocation.packageURL, encoding: .utf8)
            let result = try PackageManifestEditor.edit(manifest, command: invocation.command)
            if result.changed {
                try result.manifest.write(to: invocation.packageURL, atomically: true, encoding: .utf8)
            }
            print(#"{"changed":\#(result.changed),"path":"\#(invocation.packageURL.path)"}"#)
        } catch let error as PackageManifestEditError {
            FileHandle.standardError.write(Data((error.structuredDescription + "\n").utf8))
            Foundation.exit(2)
        } catch {
            FileHandle.standardError.write(Data((#"{"error":"toolFailure","reason":"\#(error.localizedDescription)"}"# + "\n").utf8))
            Foundation.exit(1)
        }
    }
}

private struct Invocation {
    var packageURL: URL
    var command: PackageManifestCommand

    init(arguments: [String]) throws {
        guard let rawCommand = arguments.first else {
            throw PackageManifestEditError.invalidArgument("Missing command.")
        }

        let options = Self.options(from: Array(arguments.dropFirst()))
        let packagePath = options["package"] ?? "Package.swift"
        packageURL = URL(fileURLWithPath: packagePath, isDirectory: false)

        switch rawCommand {
        case "add-target":
            command = .addTarget(
                name: try Self.required("name", in: options),
                dependencies: Self.list("dependency", in: options)
            )
        case "add-executable-target":
            command = .addExecutableTarget(
                name: try Self.required("name", in: options),
                dependencies: Self.list("dependency", in: options)
            )
        case "add-test-target":
            command = .addTestTarget(
                name: try Self.required("name", in: options),
                dependencies: Self.list("dependency", in: options)
            )
        case "add-dependency":
            command = .addDependency(
                url: try Self.required("url", in: options),
                requirement: options["requirement"] ?? #"from: "0.0.1""#
            )
        case "add-local-dependency":
            command = .addLocalDependency(
                name: options["name"],
                path: try Self.required("path", in: options)
            )
        case "remove-dependency":
            command = .removeDependency(identity: try Self.required("identity", in: options))
        case "ensure-adaengine":
            command = .ensureAdaEngineDependency(
                path: try Self.required("path", in: options),
                targetName: options["target"]
            )
        case "configure-target":
            command = .configureTarget(
                name: try Self.required("name", in: options),
                sources: Self.list("source", in: options),
                exclude: Self.list("exclude", in: options),
                resources: Self.list("resource", in: options)
            )
        case "add-plugin":
            command = .addPlugin(
                name: try Self.required("name", in: options),
                capability: options["capability"] ?? ".buildTool()"
            )
        case "ensure-asset-resources":
            command = .ensureAssetResources(
                targetName: options["target"],
                assetsPath: options["assets-path"] ?? "Assets"
            )
        default:
            throw PackageManifestEditError.invalidArgument("Unknown command: \(rawCommand).")
        }
    }

    private static func options(from arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }

            let key = String(argument.dropFirst(2))
            let valueIndex = index + 1
            if valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") {
                result[key] = arguments[valueIndex]
                index += 2
            } else {
                result[key] = "true"
                index += 1
            }
        }

        return result
    }

    private static func required(_ key: String, in options: [String: String]) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw PackageManifestEditError.invalidArgument("Missing --\(key).")
        }
        return value
    }

    private static func list(_ key: String, in options: [String: String]) -> [String] {
        options[key]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }
}
