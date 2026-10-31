import Foundation

/// A named build/run configuration. Active settings are projected onto the existing
/// project fields so every build, Play, CLI and export consumer uses the same target.
public struct AdaProjectBuildTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var build: AdaProjectBuild
    public var run: AdaProjectRun
    public var runtime: AdaProjectRuntime
    public var startupScene: String?
    public var resourceRoots: [String]
    public var product: String?

    public init(id: String = UUID().uuidString, name: String, project: AdaProject, product: String? = nil) {
        self.id = id
        self.name = name
        self.build = project.build
        self.run = project.run
        self.runtime = project.runtime
        self.startupScene = project.runtime.entry.scene ?? project.editor.startupScene
        self.resourceRoots = project.paths.resourceRoots
        self.product = product
    }

    func apply(to project: inout AdaProject) {
        project.build = build
        project.run = run
        project.runtime = runtime
        project.editor.startupScene = startupScene
        project.paths.resourceRoots = resourceRoots
    }
}

extension AdaProject {
    public var activeBuildTarget: AdaProjectBuildTarget? {
        buildTargets.first { $0.id == activeBuildTargetID }
    }

    mutating func ensureBuildTargets(defaultName: String, product: String? = nil) {
        guard buildTargets.isEmpty else { return }
        var target = AdaProjectBuildTarget(name: defaultName, project: self, product: product)
        target.build.configuration = target.build.configuration ?? "debug"
        buildTargets = [target]
        activeBuildTargetID = target.id
        target.apply(to: &self)
    }

    /// Keep edits from ordinary Project Settings in their owning target before saving or switching.
    mutating func captureActiveBuildTarget() {
        guard let index = buildTargets.firstIndex(where: { $0.id == activeBuildTargetID }) else { return }
        let old = buildTargets[index]
        buildTargets[index] = AdaProjectBuildTarget(id: old.id, name: old.name, project: self, product: old.product)
    }

    /// Captures the outgoing target's settings, then installs the selected target's build and runtime settings.
    public mutating func activateBuildTarget(id: String) throws(ProjectSystemError) {
        guard buildTargets.contains(where: { $0.id == id }) else {
            throw .invalidField(path: "activeBuildTargetID", message: "The selected build target does not exist.")
        }
        captureActiveBuildTarget()
        activeBuildTargetID = id
        let target = activeBuildTarget
        target?.apply(to: &self)
    }

    /// Stable, filesystem-safe output folder; renaming a target does not overwrite another target's exports.
    var buildTargetExportSubdirectory: String? {
        activeBuildTarget.map { Data($0.id.utf8).map { String(format: "%02x", $0) }.joined() }
    }

    func includesSource(relativePath: String) -> Bool {
        let path = (paths.sources ?? "Sources") + "/" + relativePath
        func matches(_ entry: String) -> Bool {
            let prefix = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        return (build.includedFiles.isEmpty || build.includedFiles.contains(where: matches))
            && !build.excludedFiles.contains(where: matches)
    }
}

extension ProjectSystem {
    static func validateBuildTargets(_ project: AdaProject) throws(ProjectSystemError) {
        guard !project.buildTargets.isEmpty else {
            guard project.activeBuildTargetID == nil else {
                throw .invalidField(path: "activeBuildTargetID", message: "The selected build target does not exist.")
            }
            return
        }
        guard project.activeBuildTarget != nil else {
            throw .invalidField(path: "activeBuildTargetID", message: "Select an existing build target.")
        }
        var ids = Set<String>()
        var names = Set<String>()
        for target in project.buildTargets {
            guard !target.id.isEmpty, ids.insert(target.id).inserted else {
                throw .invalidField(path: "buildTargets.id", message: "Build target IDs must be unique and nonempty.")
            }
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, names.insert(name.lowercased()).inserted else {
                throw .invalidField(path: "buildTargets.name", message: "Give each build target a different, nonempty name.")
            }
            guard target.build.system == project.build.system else {
                throw .invalidField(path: "buildTargets.build.system", message: "Build targets must use the project's build system.")
            }
            if let configuration = target.build.configuration, !["debug", "release"].contains(configuration) {
                throw .invalidField(path: "buildTargets.build.configuration", message: "Choose Debug or Release.")
            }
            var candidate = project
            candidate.buildTargets = []
            candidate.activeBuildTargetID = nil
            target.apply(to: &candidate)
            try validate(candidate)
        }
    }
}
