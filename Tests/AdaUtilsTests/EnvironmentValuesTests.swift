@testable @_spi(Internal) import AdaUtils
import Testing

@Suite("EnvironmentValues versioning and key tracking")
struct EnvironmentValuesTests {
    private final class RefObject: @unchecked Sendable {}

    private struct IntKey: EnvironmentKey {
        static let defaultValue: Int = 0
    }

    private struct StringKey: EnvironmentKey {
        static let defaultValue: String = ""
    }

    private struct RefKey: EnvironmentKey {
        static let defaultValue: RefObject? = nil
    }

    // MARK: - Version tracking

    @Test("version starts at zero")
    func versionStartsAtZero() {
        let env = EnvironmentValues()
        #expect(env.version == 0)
    }

    @Test("version increments when value changes")
    func versionIncrementsOnChange() {
        var env = EnvironmentValues()
        env[IntKey.self] = 42
        #expect(env.version == 1)
    }

    @Test("version does not increment when same value assigned again")
    func versionStableOnSameValue() {
        var env = EnvironmentValues()
        env[IntKey.self] = 7
        let v1 = env.version
        env[IntKey.self] = 7
        #expect(env.version == v1)
    }

    @Test("version increments independently for each distinct key change")
    func versionIncrementsPerChange() {
        var env = EnvironmentValues()
        env[IntKey.self] = 1
        env[StringKey.self] = "hello"
        #expect(env.version == 2)
    }

    @Test("version does not increment when same reference is assigned again")
    func versionStableOnSameReference() {
        let object = RefObject()
        var env = EnvironmentValues()
        env[RefKey.self] = object

        let v1 = env.version
        env[RefKey.self] = object

        #expect(env.version == v1)
    }

    // MARK: - changedKeys

    @Test("changedKeys contains written key")
    func changedKeysContainsWrittenKey() {
        var env = EnvironmentValues()
        env[IntKey.self] = 99
        #expect(env.changedKeys.contains(ObjectIdentifier(IntKey.self)))
    }

    @Test("changedKeys does not grow on no-op write")
    func changedKeysStableOnNoOpWrite() {
        var env = EnvironmentValues()
        env[IntKey.self] = 5
        env[IntKey.self] = 5
        #expect(env.changedKeys.count == 1)
    }

    @Test("changedKeys accumulates multiple distinct key writes")
    func changedKeysAccumulatesDistinctKeys() {
        var env = EnvironmentValues()
        env[IntKey.self] = 1
        env[StringKey.self] = "x"
        #expect(env.changedKeys.count == 2)
    }

    // MARK: - merge

    @Test("merge bumps version only for changed keys")
    func mergeVersionOnlyForChangedKeys() {
        var base = EnvironmentValues()
        base[IntKey.self] = 10  // changedKeys gains IntKey, version = 1

        var patch = EnvironmentValues()
        patch[IntKey.self] = 10   // same value — no change in patch
        patch[StringKey.self] = "new"

        let vBefore = base.version  // 1
        base.merge(patch)

        // Only StringKey changed during the merge; version increments once.
        #expect(base.version == vBefore + 1)
        // changedKeys accumulates all ever-changed keys; StringKey is newly added.
        #expect(base.changedKeys.contains(ObjectIdentifier(StringKey.self)))
    }

    @Test("merge does not bump version for the same reference")
    func mergeVersionStableForSameReference() {
        let object = RefObject()

        var base = EnvironmentValues()
        base[RefKey.self] = object

        var patch = EnvironmentValues()
        patch[RefKey.self] = object

        let vBefore = base.version
        base.merge(patch)

        #expect(base.version == vBefore)
    }

    // MARK: - hasChangedValues

    @Test("hasChangedValues returns true when subscribed key differs")
    func hasChangedValuesDetectsChange() {
        var envA = EnvironmentValues()
        envA[IntKey.self] = 5

        var envB = EnvironmentValues()
        envB[IntKey.self] = 99

        let ids: Set<ObjectIdentifier> = [ObjectIdentifier(IntKey.self)]
        #expect(envB.hasChangedValues(forKeyIDs: ids, comparedTo: envA))
    }

    @Test("hasChangedValues returns false when subscribed key is unchanged")
    func hasChangedValuesNoFalsePositive() {
        var envA = EnvironmentValues()
        envA[IntKey.self] = 7
        envA[StringKey.self] = "hello"

        var envB = EnvironmentValues()
        envB[IntKey.self] = 7     // same
        envB[StringKey.self] = "world"  // different but not subscribed

        let ids: Set<ObjectIdentifier> = [ObjectIdentifier(IntKey.self)]
        #expect(!envB.hasChangedValues(forKeyIDs: ids, comparedTo: envA))
    }

    @Test("hasChangedValues with empty ids always returns false")
    func hasChangedValuesEmptyIDsReturnsFalse() {
        var envA = EnvironmentValues()
        envA[IntKey.self] = 1

        var envB = EnvironmentValues()
        envB[IntKey.self] = 2

        #expect(!envB.hasChangedValues(forKeyIDs: [], comparedTo: envA))
    }
}
