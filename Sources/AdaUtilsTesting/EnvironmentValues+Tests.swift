//
//  EnvironmentValues+Tests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 12.12.2025.
//

#if canImport(Testing) && compiler(>=6)
    import AdaUtils
    import Testing

    @_documentation(visibility: private)
    public struct _EnvironmentTrait: TestScoping, TestTrait, SuiteTrait {
        let updateValues: @Sendable (inout EnvironmentValues) -> Void

        @TaskLocal static var isRoot = true

        public var isRecursive: Bool { true }
        public func provideScope(
            for _: Test,
            testCase _: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await withEnvironmentValues {
                if Self.isRoot {
                    $0 = EnvironmentValues()
                }
                updateValues(&$0)
            } operation: {
                try await Self.$isRoot.withValue(false) {
                    try await function()
                }
            }
        }
    }

    extension Trait where Self == _EnvironmentTrait {
        /// A trait that quarantines a test's environments from other tests.
        ///
        /// When applied to a `@Suite` (or `@Test`), the environments used for that suite (or test)
        /// will be kept separate from any other suites (and tests) running in parallel.
        ///
        /// It is recommended to use a base `@Suite` to apply this to all tests. You can do this by
        /// defining a `@Suite` with the trait:
        ///
        /// ```swift
        /// @Suite(.environments) struct BaseSuite {}
        /// ```
        ///
        /// Then any suite or test you write can be nested inside the base suite:
        ///
        /// ```swift
        /// extension BaseSuite {
        ///   @Suite struct MyTests {
        ///     @Test func login() {
        ///       // EnvironmentValues accessed in here are independent from 'logout' tests.
        ///     }
        ///
        ///     @Test func logout() {
        ///       // EnvironmentValues accessed in here are independent from 'login' tests.
        ///     }
        ///   }
        /// }
        /// ```
        public static var environments: Self {
            Self { _ in }
        }

        /// A trait that overrides a test's or suite's environments.
        ///
        /// Useful for overriding a environments in a test.
        ///
        /// ```swift
        /// @Test(.environments {
        ///   $0.ecs.useSystemDependencies = false
        /// })
        /// func feature() {
        ///   // ...
        /// }
        /// ```
        ///
        public static func environments(
            _ updateValues: @escaping @Sendable (inout EnvironmentValues) -> Void
        ) -> Self {
            Self(updateValues: updateValues)
        }
    }
#endif
