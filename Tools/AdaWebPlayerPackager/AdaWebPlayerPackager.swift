import AdaScriptCompilerCore
import Foundation

@main
enum AdaWebPlayerPackager {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw AdaWebPlayerProjectError.invalid("Usage: AdaWebPlayerPackager <player-template> <project-directory> <new-output-directory>")
        }
        try AdaWebPlayerBundle.assemble(
            template: URL(fileURLWithPath: arguments[0], isDirectory: true),
            project: URL(fileURLWithPath: arguments[1], isDirectory: true),
            output: URL(fileURLWithPath: arguments[2], isDirectory: true)
        )
        print("Exported Web Player bundle to \(arguments[2])")
    }
}
