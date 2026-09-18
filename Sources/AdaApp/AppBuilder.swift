//
//  AppBuilder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.05.2025.
//

import AdaECS
import AdaUtils
import Foundation
import Logging
import Tracing

// TODO: Do we need be a Main Actor???

/// A protocol that represents a world extractor.
/// Used to extract data from main world to subworlds.
public protocol WorldExctractor {
    /// Extract data from main world to subworld.
    /// - Parameters:
    ///   - mainWorld: The main world.
    ///   - world: The subworld.
    func exctract(from mainWorld: World, to world: World) async
}

/// A class that represents a collection of worlds.
@MainActor
public final class AppWorlds {
    @_spi(Internal)
    public let executionID = UUID()

    /// Source attached to diagnostic logs emitted by this runtime, including child tasks.
    public var runtimeLogSource = "Editor"

    /// Assign on the root of an embedded game. Nested worlds inherit its profiling context.
    public var profilingTargetID: String?

    #if ENABLE_RUN_IN_CONCURRENCY
        public typealias ApplicationRunnerBlock = () async -> Void
    #else
        public typealias ApplicationRunnerBlock = () -> Void
    #endif

    /// The main world.
    public var main: World

    /// The subworlds.
    var subWorlds: [String: AppWorlds]

    /// The world extractor.
    nonisolated(unsafe) var worldExctractor: (any WorldExctractor)?

    /// The plugins.
    @usableFromInline
    var plugins: ContiguousArray<any Plugin> = []

    /// Names of installed plugins.
    @usableFromInline
    var installedPlugins: [String: String] = [:]

    private var activeUpdates = 0
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []

    private var pluginDepth = 0

    /// The runner.
    var runner: ApplicationRunnerBlock?

    /// The flag that indicates if the app is configured.
    var isConfigured: Bool = false

    /// Default scheduler that will run first in ``update()`` method
    public var updateScheduler: SchedulerName?

    let logger: Logger

    /// Initialize a new instance of `AppWorlds` with the given main world and subworlds.
    /// - Parameters:
    ///   - mainWorld: The main world.
    ///   - subWorlds: The subworlds.
    public init(
        main: World,
        subWorlds: [String: AppWorlds] = [:]
    ) {
        self.main = main
        self.subWorlds = subWorlds
        self.logger = Logger(label: "org.adaengine.AdaApp.\(main.name ?? "UnknownWorld")")
    }
}

extension AppWorlds {
    /// Set the world extractor.
    /// - Parameter exctractor: The world extractor.
    public func setExctractor(_ exctractor: any WorldExctractor) {
        unsafe self.worldExctractor = exctractor
    }

    /// Set the runner.
    /// - Parameter block: The runner.
    public func setRunner(_ block: @escaping ApplicationRunnerBlock) {
        self.runner = block
    }

    /// Executes a synchronous tooling operation between frame updates.
    /// Call on the root AppWorlds so subworld schedulers and extraction are also covered.
    /// Do not call from a running system: it would wait for its own frame to finish.
    public func withWorldAccess<T>(_ operation: @MainActor () throws -> T) async throws -> T {
        while activeUpdates > 0 {
            await withCheckedContinuation { updateWaiters.append($0) }
        }
        try Task.checkCancellation()
        return try operation()
    }

    /// Updates this world and its subworlds, serializing concurrent frame requests.
    public func update() async throws {
        while activeUpdates > 0 {
            await withCheckedContinuation { updateWaiters.append($0) }
        }
        try Task.checkCancellation()
        activeUpdates += 1
        defer {
            activeUpdates -= 1
            if activeUpdates == 0 {
                let waiters = updateWaiters
                updateWaiters.removeAll(keepingCapacity: true)
                for waiter in waiters { waiter.resume() }
            }
        }
        try await withExecutionContext {
            let worldName = main.name ?? "UnknownWorld"
            let framePacing = main.getResource(ApplicationFramePacing.self)
            let profileEntityCount = profilingTargetID != nil && AdaTrace.isEnabled ? main.entities.entities.count : nil
            try await AdaTrace.span(lazyName: "AppWorlds.update") { span in
                if span.isRecording {
                    var attributes = span.attributes
                    attributes["ada.profile.category"] = "frame"
                    attributes["ada.world.name"] = worldName
                    if let profileEntityCount {
                        attributes["ada.profile.entities"] = profileEntityCount
                    }
                    if let framePacing {
                        attributes["ada.frame.target_fps"] = framePacing.maximumFramesPerSecond
                        attributes["ada.frame.budget_ms"] = framePacing.minimumFrameDuration * 1_000
                    }
                    span.attributes = attributes
                }
                try await self.updateFrameContents()
            }
        }
    }

    private func updateFrameContents() async throws {
        guard isConfigured else {
            return
        }
        guard let updateScheduler else {
            assertionFailure("Update scheduler is empty")
            return
        }

        let simulationControl = main.getOrInitRefResource(SimulationControl.self) {
            SimulationControl()
        }
        let shouldRunMainWorld: Bool
        switch simulationControl.wrappedValue.mode {
        case .running:
            shouldRunMainWorld = true
        case .paused:
            if simulationControl.wrappedValue.pendingStepCount > 0 {
                simulationControl.wrappedValue.pendingStepCount -= 1
                shouldRunMainWorld = true
            } else {
                shouldRunMainWorld = false
            }
        }

        if shouldRunMainWorld {
            await main.runScheduler(updateScheduler)
        }

        for world in self.subWorlds.values {
            unsafe await world.worldExctractor?.exctract(from: main, to: world.main)
            try await world.update()
        }

        main.clearTrackers()
    }

    /// Get the subworld builder by name.
    /// - Parameter name: The name of the subworld.
    /// - Returns: The subworld builder.
    public func getSubworldBuilder(by name: AppWorldName) -> AppWorlds? {
        self.subWorlds[name.rawValue]
    }

    public func getWorldBuilder(by name: AppWorldName) -> AppWorlds? {
        if name == .main {
            return self
        }
        return self.getSubworldBuilder(by: name)
    }

    public func allWorldNames() -> [AppWorldName] {
        [.main]
            + self.subWorlds.keys
            .sorted()
            .map(AppWorldName.init(rawValue:))
    }

    /// Add a new subworld.
    /// - Parameter subworld: The subworld.
    /// - Parameter name: The name of the subworld.
    public func addSubworld(_ subworld: consuming AppWorlds, by name: AppWorldName) {
        self.subWorlds[name.rawValue] = subworld
    }

    /// Removes a subworld registered with ``addSubworld(_:by:)``.
    @discardableResult
    public func removeSubworld(by name: AppWorldName) -> AppWorlds? {
        subWorlds.removeValue(forKey: name.rawValue)
    }

    /// Add a plugin to the app.
    /// - Parameter plugin: The plugin to add.
    /// - Returns: The app builder.
    @inlinable
    @discardableResult
    public func addPlugin<T: Plugin>(_ plugin: T) -> Self {
        if let pluginName = self.installedPlugins[plugin.pluginIdentifier] {
            assertionFailure("Plugin \(pluginName) already installed")
            return self
        }

        self.plugins.append(plugin)
        return self
    }

    /// Insert plugin to specific index.
    @inlinable
    @discardableResult
    public func insertPlugin<T: Plugin, C: Plugin>(_ plugin: T, after pluginType: C.Type) -> Self {
        if let pluginName = self.installedPlugins[plugin.pluginIdentifier] {
            assertionFailure("Plugin \(pluginName) already installed")
            return self
        }

        guard let findPluginIndex = self.plugins.firstIndex(where: { type(of: $0) == pluginType }) else {
            assertionFailure("Can't find plugin with type \(pluginType)")
            return self
        }
        self.plugins.insert(plugin, at: findPluginIndex + 1)
        return self
    }

    /// Setup plugins.
    public func build() async throws {
        try await withExecutionContext {
            await self.setupPlugins(self.plugins[...])
            assert(self.pluginDepth == 0, "Plugins installed recursevly")

            for subWorld in self.subWorlds.values {
                try await subWorld.build()
            }

            /// Wait until all plugins is loaded
            while !self.plugins.allSatisfy({ $0.isLoaded(in: self) }) {
                await Task.yield()
            }

            self.plugins.forEach { $0.finish(for: self) }
            self.isConfigured = true
        }
    }

    /// Executes synchronous work in this world's task-local runtime context.
    @_spi(Internal)
    public func withExecutionContext<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try RuntimeLogStore.$currentSource.withValue(runtimeLogSource) {
            try AppWorldsExecutionContext.$currentID.withValue(executionID) {
                try AdaTrace.$profileTargetID.withValue(profilingTargetID ?? AdaTrace.profileTargetID) {
                    try AdaTrace.$profileFrameRoot.withValue(profilingTargetID != nil, operation: operation)
                }
            }
        }
    }

    /// Executes asynchronous work in this world's task-local runtime context.
    @_spi(Internal)
    public func withExecutionContext<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
        try await RuntimeLogStore.$currentSource.withValue(runtimeLogSource) {
            try await AppWorldsExecutionContext.$currentID.withValue(executionID) {
                try await AdaTrace.$profileTargetID.withValue(profilingTargetID ?? AdaTrace.profileTargetID) {
                    try await AdaTrace.$profileFrameRoot.withValue(profilingTargetID != nil, operation: operation)
                }
            }
        }
    }
}

extension AppWorlds {
    private func setupPlugins(_ plugins: ContiguousArray<any Plugin>.SubSequence) async {
        var index = plugins.endIndex
        for plugin in plugins {
            self.pluginDepth += 1

            if let pluginName = self.installedPlugins[plugin.pluginIdentifier] {
                assertionFailure("Plugin \(pluginName) already setuped")
            }

            plugin.setup(in: self)

            while !plugin.isLoaded(in: self) {
                await Task.yield()
            }

            self.logger.debug("Plugin installed \(type(of: plugin))")

            /// If plugin add a new plugins, we should check it.
            if !self.plugins[index...].isEmpty {
                await setupPlugins(self.plugins[index...])
                index = self.plugins.endIndex
            }

            self.pluginDepth -= 1

            self.installedPlugins[plugin.pluginIdentifier] = String(reflecting: type(of: plugin))
        }
    }
}

// MARK: - World Proxy

extension AppWorlds {
    /// Add a system to the main world.
    /// - Parameters:
    ///   - system: The system to add.
    ///   - scheduler: The scheduler to run the system on.
    /// - Returns: The app builder.
    @inlinable
    @discardableResult
    public func addSystem<T: System>(
        _ system: T.Type,
        on scheduler: AdaECS.SchedulerName = .update
    ) -> Self {
        self.main.addSystem(system, on: scheduler)
        return self
    }

    /// Remove a system from the main world.
    /// - Parameters:
    ///   - system: The system to remove.
    ///   - scheduler: The scheduler to remove the system from.
    /// - Returns: The app builder.
    @inlinable
    @discardableResult
    public func removeSystem<T: System>(
        _ system: T.Type,
        on scheduler: AdaECS.SchedulerName = .update
    ) -> Self {
        self.main.removeSystem(system, on: scheduler)
        return self
    }

    @inlinable
    @discardableResult
    public func spawn(
        _ name: String = "",
        @ComponentsBuilder components: () -> ComponentsBundle
    ) -> Entity {
        return self.main.spawn(name, components: components)
    }

    @inlinable
    @discardableResult
    public func spawn<T: ComponentsBundle>(
        _ name: String = "",
        bundle: consuming T
    ) -> Entity {
        return self.main.spawn(name, bundle: bundle)
    }

    @inlinable
    @discardableResult
    public func spawn(_ name: String = "") -> Entity {
        return main.spawn(name)
    }

    /// Insert a resource to the world.
    /// - Parameter resource: The resource to insert.
    /// - Returns: The app builder.
    @inlinable
    @discardableResult
    public func insertResource<T: Resource>(_ resource: consuming T) -> Self {
        self.main.insertResource(resource)
        return self
    }

    /// Create a resource from world.
    /// - Parameter type: The resource type.
    /// - Returns: A resource instance.
    @inlinable
    @discardableResult
    public func createResource<T: Resource & WorldInitable>(_ type: T.Type) -> T {
        return self.main.createResource(of: type)
    }

    /// Create a resource from world.
    /// - Parameter type: The resource type.
    /// - Returns: A resource instance.
    @inlinable
    @discardableResult
    public func initResource<T: Resource & WorldInitable>(_ type: T.Type) -> Self {
        _ = self.main.createResource(of: type)
        return self
    }

    /// Create a resource from world.
    /// - Parameter type: The resource type.
    /// - Returns: A resource instance.
    @inlinable
    @discardableResult
    public func initResource<T: Resource & DefaultValue>(_: T.Type) -> Self {
        _ = self.main.insertResource(T.defaultValue)
        return self
    }

    /// Get resource from the world.
    /// - Parameter resource: The resource to insert.
    /// - Returns: The app builder.
    @inlinable
    public func getResource<T: Resource>(_ resource: T.Type) -> T? {
        return self.main.getResource(resource)
    }

    /// Get mutable resource from the world.
    /// - Parameter resource: The resource to insert.
    /// - Returns: The app builder.
    @inlinable
    public func getRefResource<T: Resource>(_ resource: T.Type) -> Ref<T> {
        self.main.getRefResource(resource)
    }
}

/// A protocol that represents a plugin for the app.
public protocol Plugin: Sendable {
    /// Stable identity used to distinguish multiple instances of one plugin type.
    var pluginIdentifier: String { get }

    /// Setup the plugin in the app.
    @MainActor
    func setup(in app: borrowing AppWorlds)

    /// Notify the plugin that the app is ready.
    @MainActor
    func finish(for app: borrowing AppWorlds)

    /// Check if the plugin is loaded. Used for async plugins.
    @MainActor
    func isLoaded(in app: borrowing AppWorlds) -> Bool

    /// Destroy the plugin.
    @MainActor
    func destroy(for app: borrowing AppWorlds)
}

extension Plugin {
    public var pluginIdentifier: String {
        String(reflecting: Self.self)
    }

    public func isLoaded(in _: borrowing AppWorlds) -> Bool {
        return true
    }

    public func finish(for _: borrowing AppWorlds) {}

    public func destroy(for _: borrowing AppWorlds) {}
}

public struct AppWorldName: Hashable, Equatable, RawRepresentable, CustomStringConvertible, Sendable {
    public let rawValue: String
    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let main = Self(rawValue: "Main")
}
