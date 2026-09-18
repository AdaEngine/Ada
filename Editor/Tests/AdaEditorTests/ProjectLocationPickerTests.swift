import Foundation
import Testing

@testable import AdaEditor

@Suite("Project location picker")
struct ProjectLocationPickerTests {
    @Test("selection stores the folder and failures explain what happened")
    @MainActor
    func appliesPickerResults() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("ProjectLocationPicker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        let viewModel = ProjectOpeningViewModel(
            store: EditorProjectStore(storageURL: rootURL.appendingPathComponent("projects.json"))
        )

        viewModel.applyProjectLocationPickerResult(.selected(rootURL))
        #expect(viewModel.projectLocation == rootURL.standardizedFileURL.path)
        #expect(viewModel.statusMessage.contains(rootURL.lastPathComponent))

        viewModel.applyProjectLocationPickerResult(.unavailable("AdaEditor has no active window from which to open Files."))
        #expect(viewModel.statusMessage == "Could not choose a project location: AdaEditor has no active window from which to open Files.")

        viewModel.applyProjectLocationPickerResult(.cancelled)
        #expect(viewModel.statusMessage == "Project location selection cancelled.")
    }
}
