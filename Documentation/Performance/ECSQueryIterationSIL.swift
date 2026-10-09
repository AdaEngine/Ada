import AdaECS

public struct SILPosition: Component { public var x: Int; public var y: Int }
public struct SILVelocity: Component { public var x: Int; public var y: Int }

@inline(never)
public func sumPositions(_ query: Query<SILPosition, SILVelocity>) -> Int {
    var checksum = 0
    query.forEach { position, velocity in checksum &+= position.x &+ velocity.x }
    return checksum
}
