import Foundation
import Observation

/// A disposable editing draft. Nothing reaches disk until Save is pressed.
@MainActor @Observable
final class EditorBuildTargetsModel {
    var isPresented = false
    var isMenuPresented = false
    var targets: [AdaProjectBuildTarget] = []
    var activeID: String?
    var draft: AdaProject?
    var errorMessage: String?
    var sceneText = ""
    var argumentsText = ""
    var resourceRootsText = ""
    var includedFilesText = ""
    var excludedFilesText = ""
    var productText = ""

    var activeName: String { targets.first { $0.id == activeID }?.name ?? L10n.text("Main") }
    var editedTarget: AdaProjectBuildTarget? { draft?.activeBuildTarget }

    func refresh(_ project: AdaProject) {
        targets = project.buildTargets
        activeID = project.activeBuildTargetID
    }

    func begin(_ project: AdaProject, product: String?) {
        var draft = project
        draft.ensureBuildTargets(defaultName: L10n.text("Main"), product: product)
        self.draft = draft
        refreshTextFields()
        errorMessage = nil
        isMenuPresented = false
        isPresented = true
    }

    func select(_ id: String) {
        do { try draft?.activateBuildTarget(id: id); refreshTextFields(); errorMessage = nil }
        catch { errorMessage = L10n.text("Could not select build target: \(Self.errorDetail(error))") }
    }

    func edit(_ update: (inout AdaProjectBuildTarget) -> Void) {
        guard var project = draft, let index = project.buildTargets.firstIndex(where: { $0.id == project.activeBuildTargetID }) else { return }
        update(&project.buildTargets[index])
        let target = project.buildTargets[index]
        target.apply(to: &project)
        draft = project
        errorMessage = nil
    }

    func add(copy: Bool = false) {
        guard var project = draft, var target = project.activeBuildTarget else { return }
        project.captureActiveBuildTarget()
        target.id = UUID().uuidString
        let baseName = copy ? L10n.text("\(target.name) Copy") : L10n.text("New Target")
        var name = baseName
        var suffix = 2
        while project.buildTargets.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        target.name = name
        if !copy { target.build.configuration = "debug" }
        project.buildTargets.append(target)
        project.activeBuildTargetID = target.id
        target.apply(to: &project)
        draft = project
        refreshTextFields()
        errorMessage = nil
    }

    func remove() {
        guard var project = draft, project.buildTargets.count > 1 else { return }
        project.buildTargets.removeAll { $0.id == project.activeBuildTargetID }
        guard let first = project.buildTargets.first else { return }
        project.activeBuildTargetID = first.id
        first.apply(to: &project)
        draft = project
        refreshTextFields()
        errorMessage = nil
    }

    private func refreshTextFields() {
        sceneText = editedTarget?.startupScene ?? ""
        argumentsText = editedTarget?.run.arguments.joined(separator: "\n") ?? ""
        resourceRootsText = editedTarget?.resourceRoots.joined(separator: ", ") ?? ""
        includedFilesText = editedTarget?.build.includedFiles.joined(separator: ", ") ?? ""
        excludedFilesText = editedTarget?.build.excludedFiles.joined(separator: ", ") ?? ""
        productText = editedTarget?.product ?? ""
    }

    static func errorDetail(_ error: any Error) -> String {
        if case let ProjectSystemError.invalidField(_, message) = error { return L10n.tr(message) }
        return L10n.tr(error.localizedDescription)
    }
}
