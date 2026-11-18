import AdaNavigation
import AdaNavigationBaking
import Math
import Testing

@Suite("Navigation mesh baking and Detour queries")
struct NavigationTests {
    @Test("A baked floor gives a direct path and projects to the surface")
    func directPath() async throws {
        let mesh = try await makeMesh(.floor())
        let path = try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9])
        #expect(path.status == .complete)
        #expect(path.points.count == 2)
        #expect(!path.corridor.isEmpty)
        #expect(abs(path.length - Vector3(8, 0, 8).length) < 0.01)
        #expect(path.points.allSatisfy { abs($0.y) < 0.2 })
        #expect(mesh.data.polygonCount > 0)
    }

    @Test("Coincident endpoints produce a finished route without a movement request")
    func coincidentEndpoints() async throws {
        let mesh = try await makeMesh(.floor())
        let path = try await mesh.findPath(from: [5, 0, 5], to: [5, 0, 5])
        #expect(path.status == .complete)
        #expect(path.length < 0.001)
        var follower = NavigationPathFollower()
        follower.follow(path)
        #expect(try follower.update(position: [5, 0, 5], deltaTime: 1.0 / 60) == .zero)
        #expect(follower.state == .arrived)
    }

    @Test("A traversable slope preserves surface heights in the resulting path")
    func slopedSurface() async throws {
        var geometry = Geometry()
        geometry.quad([0, 0, 0], [0, 0, 10], [10, 5, 10], [10, 5, 0])
        let settings = NavigationBakeSettings(agent: .init(maximumClimb: 0.3), cellSize: 0.1, cellHeight: 0.05)
        let mesh = try await makeMesh(geometry, settings: settings)
        let path = try await mesh.findPath(from: [1, 0.5, 1], to: [9, 4.5, 9])
        #expect(path.status == .complete)
        let start = try #require(path.points.first)
        let end = try #require(path.points.last)
        #expect(abs(start.y - 0.5) < 0.2)
        #expect(abs(end.y - 4.5) < 0.2)
    }

    @Test("Funnel corners route around a hole instead of crossing it")
    func hole() async throws {
        let mesh = try await makeMesh(.ring())
        let path = try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6])
        #expect(path.status == .complete)
        #expect(path.points.count >= 4)
        #expect(path.length > 10)
        for (start, end) in zip(path.points, path.points.dropFirst()) {
            for sample in 0...100 {
                let point = start + (end - start) * (Float(sample) / 100)
                #expect(!(point.x > 4 && point.x < 8 && point.z > 4 && point.z < 8))
            }
        }
    }

    @Test("Disconnected islands fail unless partial paths were requested")
    func disconnected() async throws {
        let mesh = try await makeMesh(.islands())
        await #expect(throws: NavigationError.unreachable) {
            try await mesh.findPath(from: [2, 0, 2], to: [10, 0, 2])
        }
        var options = NavigationQueryOptions()
        options.allowsPartialPath = true
        let path = try await mesh.findPath(from: [2, 0, 2], to: [10, 0, 2], options: options)
        #expect(path.status == .partial)
        let endpoint = try #require(path.points.last)
        #expect(endpoint.x < 4)
        #expect(endpoint.x > 2)
    }

    @Test("Projection does not confuse overlapping floors")
    func stackedFloors() async throws {
        var geometry = Geometry.floor()
        geometry.floor(x: 0...10, z: 0...10, y: 4)
        let mesh = try await makeMesh(geometry)
        let bottom = try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9])
        #expect(bottom.points.allSatisfy { $0.y < 0.2 })
        let top = try await mesh.findPath(from: [1, 4, 1], to: [9, 4, 9])
        #expect(top.points.allSatisfy { $0.y > 3.9 })
        await #expect(throws: NavigationError.unreachable) {
            try await mesh.findPath(from: [1, 0, 1], to: [9, 4, 9])
        }
    }

    @Test("Start and target outside the projection box produce distinct errors")
    func projectionErrors() async throws {
        let mesh = try await makeMesh(.floor())
        await #expect(throws: NavigationError.startOutsideMesh) {
            try await mesh.findPath(from: [50, 0, 50], to: [9, 0, 9])
        }
        await #expect(throws: NavigationError.targetOutsideMesh) {
            try await mesh.findPath(from: [1, 0, 1], to: [9, 10, 9])
        }
    }

    @Test("A mesh baked for a large agent excludes a narrow passage")
    func clearance() async throws {
        var corridor = Geometry()
        corridor.floor(x: 0...10, z: 0...1)
        let small = NavigationBakeSettings(agent: .init(radius: 0.1), cellSize: 0.05, cellHeight: 0.05)
        let mesh = try await makeMesh(corridor, settings: small)
        let path = try await mesh.findPath(from: [1, 0, 0.5], to: [9, 0, 0.5])
        #expect(path.status == .complete)
        let large = NavigationBakeSettings(agent: .init(radius: 0.6), cellSize: 0.05, cellHeight: 0.05)
        await #expect(throws: NavigationError.emptyMesh) {
            try await makeMesh(corridor, settings: large)
        }
    }

    @Test("A low downward-facing ceiling removes the floor below it")
    func lowCeiling() async throws {
        var geometry = Geometry.floor()
        geometry.quad([0, 1.2, 0], [10, 1.2, 0], [10, 1.2, 10], [0, 1.2, 10])
        await #expect(throws: NavigationError.emptyMesh) {
            try await makeMesh(geometry)
        }
    }

    @Test("Steep surfaces are excluded by the configured slope")
    func steepSlope() async throws {
        var geometry = Geometry()
        geometry.quad([0, 0, 0], [0, 0, 10], [5, 10, 10], [5, 10, 0])
        await #expect(throws: NavigationError.emptyMesh) {
            try await makeMesh(geometry)
        }
    }

    @Test("Invalid triangles and nonfinite geometry are rejected before native access")
    func invalidGeometry() async throws {
        await #expect(throws: NavigationError.invalidGeometry) {
            try await NavigationMeshBaker.bake(vertices: [], indices: [])
        }
        await #expect(throws: NavigationError.invalidGeometry) {
            try await NavigationMeshBaker.bake(vertices: [[0, 0, 0], [0, 0, 1], [1, 0, 0]], indices: [0, 1, .max])
        }
        await #expect(throws: NavigationError.invalidGeometry) {
            try await NavigationMeshBaker.bake(vertices: [[.nan, 0, 0], [0, 0, 1], [1, 0, 0]], indices: [0, 1, 2])
        }
    }

    @Test("Grid budgets and invalid agent settings fail without a huge allocation")
    func invalidSettings() async throws {
        var settings = NavigationBakeSettings()
        settings.maximumGridCells = 10
        await #expect(throws: NavigationError.invalidSettings) {
            try await makeMesh(.floor(), settings: settings)
        }
        settings = NavigationBakeSettings(agent: .init(radius: 2, height: 1))
        await #expect(throws: NavigationError.invalidSettings) {
            try await makeMesh(.floor(), settings: settings)
        }
    }

    @Test("Invalid query limits and coordinates cannot reach Detour")
    func invalidQuery() async throws {
        let mesh = try await makeMesh(.floor())
        var options = NavigationQueryOptions()
        options.maximumNodes = Int.max
        await #expect(throws: NavigationError.invalidQuery) {
            try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9], options: options)
        }
        await #expect(throws: NavigationError.invalidQuery) {
            try await mesh.findPath(from: [.infinity, 0, 1], to: [9, 0, 9])
        }
        for count in 0..<4 {
            options.maximumNodes = count
            await #expect(throws: NavigationError.invalidQuery) {
                try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9], options: options)
            }
        }
    }

    @Test("Search exhaustion and output capacity have distinct outcomes")
    func limits() async throws {
        let mesh = try await makeMesh(.ring())
        var options = NavigationQueryOptions()
        // Warm the larger pool first; shrinking must still honor the new budget.
        _ = try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6])
        options.maximumNodes = 4
        await #expect(throws: NavigationError.searchLimitReached) {
            try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6], options: options)
        }
        options.allowsPartialPath = true
        let partial = try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6], options: options)
        #expect(partial.status == .searchLimitReached)
        options = NavigationQueryOptions()
        options.maximumWaypoints = 2
        await #expect(throws: NavigationError.pathCapacityExceeded) {
            try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6], options: options)
        }
        options = NavigationQueryOptions()
        options.maximumPolygons = 1
        await #expect(throws: NavigationError.pathCapacityExceeded) {
            try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6], options: options)
        }
    }

    @Test("Concurrent requests share one actor-owned query safely")
    func concurrentQueries() async throws {
        let mesh = try await makeMesh(.ring())
        try await withThrowingTaskGroup(of: NavigationRoute.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6])
                }
            }
            for try await path in group {
                #expect(path.status == .complete)
                #expect(path.points.count >= 4)
            }
        }
    }

    @Test("A follower traverses every turn and stops at the destination")
    func followPath() async throws {
        let mesh = try await makeMesh(.ring())
        let path = try await mesh.findPath(from: [1, 0, 6], to: [11, 0, 6])
        var follower = NavigationPathFollower()
        follower.follow(path)
        var position = try #require(path.points.first)
        for _ in 0..<1200 {
            let velocity = try follower.update(position: position, deltaTime: 1.0 / 60)
            #expect(velocity.length <= follower.maximumSpeed + 0.001)
            position += velocity / 60
            #expect(!(position.x > 4 && position.x < 8 && position.z > 4 && position.z < 8))
        }
        #expect(follower.state == .arrived)
        #expect((position - Vector3(11, position.y, 6)).length <= follower.arrivalTolerance + 0.001)
        #expect(try follower.update(position: position, deltaTime: 1.0 / 60) == .zero)
    }

    @Test("A follower reports a stuck character and can accept a replacement path")
    func stuckAndReplace() async throws {
        let mesh = try await makeMesh(.floor())
        let path = try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9])
        var follower = NavigationPathFollower()
        follower.stuckTimeout = 0.5
        follower.follow(path)
        for _ in 0..<60 {
            _ = try follower.update(position: [1, 0, 1], deltaTime: 1.0 / 60)
        }
        #expect(follower.state == .blocked)
        #expect(try follower.update(position: [1, 0, 1], deltaTime: 1.0 / 60) == .zero)
        follower.follow(path)
        #expect(try follower.update(position: [1, 0, 1], deltaTime: 1.0 / 60).length > 0)
        follower.cancel()
        #expect(follower.state == .idle)
        #expect(follower.path == nil)
        #expect(try follower.update(position: [1, 0, 1], deltaTime: 1.0 / 60) == .zero)
    }

    @Test("Reaching a partial endpoint never reports arrival at the goal")
    func partialEndpoint() async throws {
        let mesh = try await makeMesh(.islands())
        var options = NavigationQueryOptions()
        options.allowsPartialPath = true
        let path = try await mesh.findPath(from: [2, 0, 2], to: [10, 0, 2], options: options)
        var follower = NavigationPathFollower()
        follower.follow(path)
        let endpoint = try #require(path.points.last)
        #expect(try follower.update(position: endpoint, deltaTime: 1.0 / 60) == .zero)
        #expect(follower.state == .partialEnd)
    }

    @Test("Horizontal proximity on another floor does not report arrival")
    func wrongFloorArrival() async throws {
        let mesh = try await makeMesh(.floor())
        let path = try await mesh.findPath(from: [1, 0, 1], to: [9, 0, 9])
        var follower = NavigationPathFollower()
        follower.follow(path)
        _ = try follower.update(position: [9, 4, 9], deltaTime: 1.0 / 60)
        #expect(follower.state == .following)
        #expect(throws: NavigationError.invalidQuery) {
            try follower.update(position: [9, 0, 9], deltaTime: 0)
        }
    }
}

private func makeMesh(
    _ geometry: Geometry,
    settings: NavigationBakeSettings = NavigationBakeSettings()
) async throws -> NavigationMesh {
    let data = try await NavigationMeshBaker.bake(vertices: geometry.vertices, indices: geometry.indices, settings: settings)
    return try NavigationMesh(data: data)
}

private struct Geometry {
    var vertices: [Vector3] = []
    var indices: [UInt32] = []

    mutating func quad(_ a: Vector3, _ b: Vector3, _ c: Vector3, _ d: Vector3) {
        let offset = UInt32(vertices.count)
        vertices += [a, b, c, d]
        indices += [0, 1, 2, 0, 2, 3].map { offset + $0 }
    }

    mutating func floor(x: ClosedRange<Float>, z: ClosedRange<Float>, y: Float = 0) {
        quad(
            [x.lowerBound, y, z.lowerBound],
            [x.lowerBound, y, z.upperBound],
            [x.upperBound, y, z.upperBound],
            [x.upperBound, y, z.lowerBound]
        )
    }

    static func floor() -> Self {
        var result = Self()
        result.floor(x: 0...10, z: 0...10)
        return result
    }

    static func ring() -> Self {
        var result = Self()
        result.floor(x: 0...4, z: 0...12)
        result.floor(x: 8...12, z: 0...12)
        result.floor(x: 4...8, z: 0...4)
        result.floor(x: 4...8, z: 8...12)
        return result
    }

    static func islands() -> Self {
        var result = Self()
        result.floor(x: 0...4, z: 0...4)
        result.floor(x: 8...12, z: 0...4)
        return result
    }
}
