//
//  EnvironmentPropagationTests.swift
//  AdaEngine
//

@testable import AdaPlatform
@testable import AdaUI
@testable import AdaUtils
import Math
import Observation
import Testing

// MARK: - Test environment keys

private struct CounterKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private struct LabelKey: EnvironmentKey {
    static let defaultValue: String = ""
}

private struct TestThemePayload: Hashable, Sendable {
    var value: Int
}

private struct TestThemeKey: ThemeKey {
    static let defaultValue = TestThemePayload(value: 0)
}

extension EnvironmentValues {
    // The same-file view fixtures access these keys outside this extension.
    // swiftlint:disable:next strict_fileprivate
    fileprivate var testCounter: Int {
        get { self[CounterKey.self] }
        set { self[CounterKey.self] = newValue }
    }
    // swiftlint:disable:next strict_fileprivate
    fileprivate var testLabel: String {
        get { self[LabelKey.self] }
        set { self[LabelKey.self] = newValue }
    }
}

@Observable
@MainActor
private final class ObservableEnvironmentModel {
    var count: Int = 0
}

@MainActor
private final class RenderProbe {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}

@MainActor
private struct ObservableEnvironmentView: View {
    @Environment(ObservableEnvironmentModel.self) private var model

    let probe: RenderProbe

    var body: some View {
        probe.record(model.count)
        return Text("\(model.count)")
    }
}

// MARK: - Tests

@MainActor
@Suite("Environment propagation optimizations")
struct EnvironmentPropagationTests {
    init() async throws {
        try Application.prepareForTest()
    }

    // MARK: subscribedKeyIDs populated at init time

    @Test("@Environment records subscribed key at init time")
    func environmentCapturesSubscribedKeyIDs() {
        let wrapper = Environment(\.testCounter)
        #expect(wrapper.container.subscribedKeyIDs.contains(ObjectIdentifier(CounterKey.self)))
        #expect(!wrapper.container.subscribedKeyIDs.contains(ObjectIdentifier(LabelKey.self)))
    }

    @Test("@Environment for different keys stores distinct key IDs")
    func differentWrappersStoreDistinctKeyIDs() {
        let counterWrapper = Environment(\.testCounter)
        let labelWrapper = Environment(\.testLabel)
        #expect(counterWrapper.container.subscribedKeyIDs.contains(ObjectIdentifier(CounterKey.self)))
        #expect(labelWrapper.container.subscribedKeyIDs.contains(ObjectIdentifier(LabelKey.self)))
        #expect(counterWrapper.container.subscribedKeyIDs != labelWrapper.container.subscribedKeyIDs)
    }

    @Test("@Environment observable subscribes only to observable storage")
    func observableEnvironmentCapturesObservableStorageKeyID() {
        let recorder = EnvironmentKeyAccessRecorder()
        EnvironmentValues.$_recordKeyAccess.withValue(recorder) {
            _ = EnvironmentValues().observableStorage
        }

        let wrapper = Environment(ObservableEnvironmentModel.self)
        #expect(wrapper.container.subscribedKeyIDs == recorder.capturedKeys)
        #expect(!wrapper.container.subscribedKeyIDs.contains(ObjectIdentifier(CounterKey.self)))
    }

    @Test("Concurrent environment reads do not enter another task's key recorder")
    func keyRecorderIsTaskLocal() async {
        let recorder = EnvironmentKeyAccessRecorder()
        await EnvironmentValues.$_recordKeyAccess.withValue(recorder) {
            // A detached worker deliberately does not inherit this task-local recorder.
            let worker = Task.detached {
                for _ in 0..<1_000 { _ = EnvironmentValues().testLabel }
            }
            for _ in 0..<1_000 { _ = EnvironmentValues().testCounter }
            await worker.value
        }
        #expect(recorder.capturedKeys == Set([ObjectIdentifier(CounterKey.self)]))
    }

    // MARK: version guard

    @Test("updateEnvironment is a no-op when version is unchanged")
    func updateEnvironmentVersionGuard() {
        let tester = ViewTester {
            Text("hello").frame(width: 100, height: 40)
        }
        .setSize(Size(width: 120, height: 60))
        .performLayout()

        let root = tester.containerView.viewTree.rootNode
        let envBefore = root.environment
        root.updateEnvironment(envBefore)
        #expect(root.environment.version == envBefore.version)
    }

    // MARK: subscription filtering via hasChangedValues

    @Test("storage is skipped when only unsubscribed key changes")
    func storageSkippedForUnsubscribedKeyChange() {
        let subscribedIDs: Set<ObjectIdentifier> = [ObjectIdentifier(CounterKey.self)]

        var oldEnv = EnvironmentValues()
        oldEnv.testCounter = 5

        var newEnv = EnvironmentValues()
        newEnv.testCounter = 5     // unchanged
        newEnv.testLabel = "new"   // changed, but not subscribed

        let hasChanged = newEnv.hasChangedValues(forKeyIDs: subscribedIDs, comparedTo: oldEnv)
        #expect(!hasChanged, "Storage subscribed to CounterKey must not rebuild when only LabelKey changes")
    }

    @Test("storage is notified when subscribed key changes")
    func storageNotifiedForSubscribedKeyChange() {
        let subscribedIDs: Set<ObjectIdentifier> = [ObjectIdentifier(CounterKey.self)]

        var oldEnv = EnvironmentValues()
        oldEnv.testCounter = 5

        var newEnv = EnvironmentValues()
        newEnv.testCounter = 99

        let hasChanged = newEnv.hasChangedValues(forKeyIDs: subscribedIDs, comparedTo: oldEnv)
        #expect(hasChanged, "Storage subscribed to CounterKey must rebuild when CounterKey changes")
    }

    @Test("empty subscribedIDs guard short-circuits to always update")
    func subscriptionFilterEmptySubscribesAll() {
        let subscribedIDs: Set<ObjectIdentifier> = []

        var oldEnv = EnvironmentValues()
        var newEnv = EnvironmentValues()
        newEnv.testLabel = "x"

        // ViewNode.updateEnvironment: if empty → always update (guard short-circuits)
        let shouldUpdate = subscribedIDs.isEmpty
            || newEnv.hasChangedValues(forKeyIDs: subscribedIDs, comparedTo: oldEnv)
        #expect(shouldUpdate)
    }

    @Test("equivalent theme assignment does not bump environment version")
    func equivalentThemeAssignmentDoesNotBumpVersion() {
        var theme = Theme()
        theme[TestThemeKey.self] = TestThemePayload(value: 7)

        var env = EnvironmentValues()
        env.theme = theme

        let version = env.version
        env.theme = theme

        #expect(env.version == version)
    }

    @Test("changed theme assignment bumps environment version")
    func changedThemeAssignmentBumpsVersion() {
        var theme = Theme()
        theme[TestThemeKey.self] = TestThemePayload(value: 7)

        var env = EnvironmentValues()
        env.theme = theme

        var changedTheme = theme
        changedTheme[TestThemeKey.self] = TestThemePayload(value: 8)

        let version = env.version
        env.theme = changedTheme

        #expect(env.version == version + 1)
    }

    @Test("root environment merges keyboard occlusion into bottom safe area")
    func rootEnvironmentMergesKeyboardOcclusionIntoBottomSafeArea() {
        let tester = ViewTester {
            EmptyView()
        }

        tester.containerView.safeAreaInsets = EdgeInsets(top: 12, leading: 8, bottom: 34, trailing: 6)
        tester.containerView.keyboardOccludedHeight = 301
        tester.performLayout()

        let safeAreaInsets = tester.containerView.viewTree.rootNode.environment.safeAreaInsets
        #expect(safeAreaInsets.top == 12)
        #expect(safeAreaInsets.leading == 8)
        #expect(safeAreaInsets.bottom == 301)
        #expect(safeAreaInsets.trailing == 6)
    }

    @Test("keyboard occlusion does not shrink platform safe area")
    func keyboardOcclusionDoesNotShrinkPlatformSafeArea() {
        let tester = ViewTester {
            EmptyView()
        }

        tester.containerView.safeAreaInsets = EdgeInsets(top: 10, leading: 0, bottom: 34, trailing: 0)
        tester.containerView.keyboardOccludedHeight = 12
        tester.performLayout()

        let safeAreaInsets = tester.containerView.viewTree.rootNode.environment.safeAreaInsets
        #expect(safeAreaInsets.bottom == 34)
    }

    @Test("overlay title bar does not reserve root safe area")
    func overlayTitleBarDoesNotReserveRootSafeArea() {
        let configuration = UIWindow.Configuration(
            frame: Rect(x: 0, y: 0, width: 400, height: 300),
            titleBar: UIWindow.TitleBar(
                background: .transparent,
                reservesSafeArea: false,
                dragRegionHeight: 52
            )
        )
        let window = UIWindow(configuration: configuration)
        let container = UIContainerView(rootView: EmptyView())
        container.frame = Rect(x: 0, y: 0, width: 400, height: 300)
        window.addSubview(container)

        container.safeAreaInsets = EdgeInsets(top: 52, leading: 0, bottom: 24, trailing: 0)
        container.layoutSubviews()

        let environment = container.viewTree.rootNode.environment
        #expect(environment.safeAreaInsets.top == 0)
        #expect(environment.safeAreaInsets.bottom == 24)
        #expect(environment.navigationBarChromeInsets.top == 52)
    }

    @Test("equivalent observable storage assignment does not bump environment version")
    func equivalentObservableStorageAssignmentDoesNotBumpVersion() {
        let model = ObservableEnvironmentModel()

        var storage = ObservableStorageEnvironment()
        storage.insertValue(model)

        var env = EnvironmentValues()
        env.observableStorage = storage

        let version = env.version
        env.observableStorage = storage

        #expect(env.version == version)
    }

    @Test("replacing observable object bumps environment version")
    func replacingObservableObjectBumpsVersion() {
        let model = ObservableEnvironmentModel()
        let replacement = ObservableEnvironmentModel()

        var storage = ObservableStorageEnvironment()
        storage.insertValue(model)

        var env = EnvironmentValues()
        env.observableStorage = storage

        var replacementStorage = ObservableStorageEnvironment()
        replacementStorage.insertValue(replacement)

        let version = env.version
        env.observableStorage = replacementStorage

        #expect(env.version == version + 1)
    }

    @Test("@Environment observable invalidates when an observed property changes")
    func observableEnvironmentTriggersRecomposeOnMemberMutation() async {
        let model = ObservableEnvironmentModel()
        let probe = RenderProbe()

        let tester = ViewTester {
            ObservableEnvironmentView(probe: probe)
                .environment(model)
        }
        .setSize(Size(width: 120, height: 60))
        .performLayout()

        let initialRenderCount = probe.values.count
        #expect(initialRenderCount > 0)
        #expect(probe.values.last == 0)

        model.count = 1
        for _ in 0..<10 {
            await Task.yield()
            if probe.values.count > initialRenderCount {
                break
            }
        }

        #expect(probe.values.count > initialRenderCount)
        #expect(probe.values.last == 1)
        withExtendedLifetime(tester) {}
    }
}
