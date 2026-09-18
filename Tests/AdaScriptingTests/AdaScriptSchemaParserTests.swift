@testable import AdaScriptCompilerCore
import Testing

@Suite("Ada Script schema parser")
struct AdaScriptSchemaParserTests {
    @Test("Humanizes view titles without splitting acronyms")
    func humanizesViewTitles() {
        #expect(humanizedAdaScriptViewTitle("MainView") == "Main View")
        #expect(humanizedAdaScriptViewTitle("HUDView") == "HUD View")
        #expect(humanizedAdaScriptViewTitle("settings_panel") == "settings panel")
    }

    @Test("Parses component and resource primitive schemas")
    func parsesPrimitiveSchemas() throws {
        let schemas = try AdaScriptSchemaParser.parse(sources: [
            AdaScriptCompilerSource(
                path: "Data.ada",
                source: """
                @component(id: "game.health")
                struct Health {
                    @export var current = 100.0;
                    @export var maximum = 120;
                    @export var title = "Player";
                    @export var enabled = true;
                }

                @resource(id: "game.balance", autoInsert: true)
                struct GameBalance {
                    @export var gravity = 9.8;
                }
                """
            )
        ])

        #expect(schemas.count == 2)
        #expect(schemas[0].name == "Health")
        #expect(schemas[0].id == "game.health")
        #expect(schemas[0].kind == .component)
        #expect(schemas[0].fields.map(\.defaultValue) == [
            .double(100),
            .int(120),
            .string("Player"),
            .bool(true)
        ])
        #expect(schemas[1].kind == .resource(autoInsert: true))
    }

    @Test("Rejects duplicate stable identifiers")
    func rejectsDuplicateIDs() {
        #expect(throws: AdaScriptSchemaError.duplicateID("game.data")) {
            try AdaScriptSchemaParser.parse(sources: [
                AdaScriptCompilerSource(
                    path: "A.ada",
                    source: "@component(id: \"game.data\") struct A { @export var value = 1; }"
                ),
                AdaScriptCompilerSource(
                    path: "B.ada",
                    source: "@resource(id: \"game.data\") struct B { @export var value = 2; }"
                )
            ])
        }
    }

    @Test("Rejects fields without stable defaults")
    func rejectsUnsupportedDefaults() {
        #expect(throws: AdaScriptSchemaError.self) {
            try AdaScriptSchemaParser.parse(sources: [
                AdaScriptCompilerSource(
                    path: "Bad.ada",
                    source: "@component(id: \"bad\") struct Bad { @export var value = []; }"
                )
            ])
        }
    }

    @Test("Parses typed resource bindings from systems")
    func parsesResourceBindings() throws {
        let bindings = try AdaScriptSchemaParser.parseResourceBindings(sources: [
            AdaScriptCompilerSource(
                path: "Systems.ada",
                source: """
                @system
                class BalanceSystem {
                    @res
                    var balance: GameBalance;

                    @res(optional: true)
                    var debug: DebugSettings;

                    func update(context) {}
                }
                """
            )
        ])

        #expect(bindings == [
            AdaScriptResourceBinding(
                isOptional: false,
                propertyName: "balance",
                resourceName: "GameBalance",
                systemName: "BalanceSystem"
            ),
            AdaScriptResourceBinding(
                isOptional: true,
                propertyName: "debug",
                resourceName: "DebugSettings",
                systemName: "BalanceSystem"
            )
        ])
    }

    @Test("Infers deferred commands only for systems that use WorldContext")
    func parsesSystemCapabilities() throws {
        let capabilities = try AdaScriptSchemaParser.parseSystemCapabilities(sources: [
            AdaScriptCompilerSource(
                path: "Systems.ada",
                source: """
                @system
                class CleanupSystem {
                    func update(context) {
                        context.world.commands.despawn(42);
                    }
                }

                @system
                class ReadOnlySystem {
                    func update(context) {}
                }
                """
            )
        ])

        #expect(capabilities == [
            AdaScriptSystemCapabilities(systemName: "CleanupSystem", usesDeferredCommands: true),
            AdaScriptSystemCapabilities(systemName: "ReadOnlySystem", usesDeferredCommands: false)
        ])
    }

    @Test("Parses scriptable identity, aliases, version, and exported state")
    func parsesScriptables() throws {
        let schemas = try AdaScriptSchemaParser.parseScriptables(sources: [
            AdaScriptCompilerSource(
                path: "Player.ada",
                source: """
                @scriptable(
                    id: "game.player-controller",
                    version: 2,
                    aliases: ["PlayerController", "game.player"]
                )
                class PlayerController {
                    @export var speed = 8.0;
                    @component(required: true) var transform: Transform;
                    @res(optional: true) var input: Input;
                    var runtimeCache = 0;

                    func update(context) {
                        runtimeCache += 1;
                    }
                }
                """
            )
        ])

        #expect(schemas == [
            AdaScriptableSchema(
                aliases: ["PlayerController", "game.player"],
                bindings: [
                    AdaScriptableBinding(
                        kind: .component(required: true),
                        propertyName: "transform",
                        typeName: "Transform"
                    ),
                    AdaScriptableBinding(
                        kind: .resource(optional: true),
                        propertyName: "input",
                        typeName: "Input"
                    )
                ],
                fields: [AdaScriptSchemaField(defaultValue: .double(8), name: "speed")],
                id: "game.player-controller",
                name: "PlayerController",
                sourcePath: "Player.ada",
                version: 2
            )
        ])
    }
}

extension AdaScriptSchemaParserTests {
    @Test("Parses AdaEditor tool metadata without executing source")
    func parsesTools() throws {
        let tools = try AdaScriptSchemaParser.parseTools(sources: [
            AdaScriptCompilerSource(
                path: "Editor/Tools/Formatter.ada",
                source: """
                @tool(
                    id: "com.example.formatter",
                    name: "Example Formatter",
                    version: "1.2.0",
                    api: 1,
                    platforms: ["macos", "ipados"],
                    permissions: ["editor.documents.read", "editor.documents.write"]
                )
                class ExampleFormatter {
                    func activate(editor) {
                        editor.addFormatter(id: "ada", languages: ["ada"], action: "format");
                    }
                }
                """
            )
        ])

        #expect(tools == [
            AdaScriptToolSchema(
                apiVersion: 1,
                className: "ExampleFormatter",
                id: "com.example.formatter",
                line: 9,
                name: "Example Formatter",
                permissions: [.documentRead, .documentWrite],
                platforms: [.macOS, .iPadOS],
                sourcePath: "Editor/Tools/Formatter.ada",
                version: "1.2.0"
            )
        ])
    }

    @Test("Rejects invalid and duplicate AdaEditor tool identities")
    func rejectsInvalidTools() {
        #expect(throws: AdaScriptSchemaError.self) {
            try AdaScriptSchemaParser.parseTools(sources: [
                AdaScriptCompilerSource(
                    path: "Invalid.ada",
                    source: "@tool(id: \"tool\", version: \"1\") class InvalidTool {}"
                )
            ])
        }
        #expect(throws: AdaScriptSchemaError.duplicateToolID("com.example.tool")) {
            try AdaScriptSchemaParser.parseTools(sources: [
                AdaScriptCompilerSource(path: "A.ada", source: "@tool(id: \"com.example.tool\") class A {}"),
                AdaScriptCompilerSource(path: "B.ada", source: "@tool(id: \"com.example.tool\") class B {}")
            ])
        }
    }

    @Test("Parses AdaUI view metadata")
    func parsesViews() throws {
        let schemas = try AdaScriptSchemaParser.parseViews(sources: [
            AdaScriptCompilerSource(
                path: "Views/Welcome.ada",
                source: """
                // Previewed in AdaEditor.
                @previewable(title: "Welcome Preview")
                @view(id: "game.welcome", title: "Welcome")
                class WelcomeView {
                    func body() {
                        Text("Hello");
                    }
                }

                @view
                class SettingsView {
                    func body() { EmptyView(); }
                }
                """
            )
        ])

        #expect(schemas == [
            AdaScriptViewSchema(
                className: "WelcomeView",
                id: "game.welcome",
                isPreviewable: true,
                line: 4,
                sourcePath: "Views/Welcome.ada",
                title: "Welcome Preview"
            ),
            AdaScriptViewSchema(
                className: "SettingsView",
                id: "SettingsView",
                isIDExplicit: false,
                isTitleExplicit: false,
                line: 11,
                sourcePath: "Views/Welcome.ada",
                title: "Settings View"
            )
        ])
    }

    @Test("Rejects @view on value types")
    func rejectsViewStruct() {
        #expect(throws: AdaScriptSchemaError.self) {
            try AdaScriptSchemaParser.parseViews(sources: [
                AdaScriptCompilerSource(path: "Invalid.ada", source: "@view struct InvalidView {}")
            ])
        }
    }

    @Test("Rejects @previewable without @view")
    func rejectsPreviewableNonView() {
        #expect(throws: AdaScriptSchemaError.self) {
            try AdaScriptSchemaParser.parseViews(sources: [
                AdaScriptCompilerSource(
                    path: "Invalid.ada",
                    source: "@previewable class InvalidPreview { func body() { Text(\"No\"); } }"
                )
            ])
        }
    }

    @Test("Lowers implicit view-builder blocks")
    func lowersViewBuilderBlocks() throws {
        let lowered = try AdaScriptViewBuilderLowerer.lower(
            source: """
            @view
            @previewable
            class CardView {
                func body() {
                    VStack(spacing: 12) {
                        Text("Title").fontSize(24);
                        HStack {
                            Text("Detail");
                            Spacer();
                        }
                    }.padding(16);
                }
            }
            """,
            path: "Card.ada"
        )

        #expect(lowered.contains("return adaUIBuilder.vStack().spacing(12)"))
        #expect(lowered.contains(".child(adaUIBuilder.text(\"Title\").fontSize(24))"))
        #expect(lowered.contains(".child(adaUIBuilder.hStack().child(adaUIBuilder.text(\"Detail\")).child(adaUIBuilder.spacer()))"))
        #expect(lowered.contains(".padding(16);"))
        #expect(!lowered.contains("VStack(spacing:"))
    }

    @Test("Rejects unsupported builder constructors")
    func rejectsUnsupportedViewConstructor() {
        #expect(throws: AdaScriptViewBuilderError.self) {
            try AdaScriptViewBuilderLowerer.lower(
                source: "@view class BadView { func body() { UnknownView(); } }",
                path: "Bad.ada"
            )
        }
    }

    @Test("Rejects view modifiers with missing arguments before preview evaluation")
    func rejectsViewModifierWithMissingArgument() {
        #expect(throws: AdaScriptViewBuilderError(path: "Main.ada", line: 1, message: "background requires 1 argument")) {
            try AdaScriptViewBuilderLowerer.lower(
                source: "@view class MainView { func body() { Text(\"Hello\").background(); } }",
                path: "Main.ada"
            )
        }
    }

    @Test("Lowers button actions into view instance methods")
    func lowersButtonActions() throws {
        let lowered = try AdaScriptViewBuilderLowerer.lower(
            source: """
            @view
            class CounterView {
                @state var label = "Before";

                func body() {
                    Button("Change") {
                        label = "After";
                    };
                }
            }
            """,
            path: "Counter.ada"
        )

        #expect(lowered.contains("return adaUIBuilder.button(\"Change\", \"__ada_view_action_0\")"))
        #expect(lowered.contains("func __ada_view_action_0()"))
        #expect(lowered.contains("label = \"After\";"))
    }

    @Test("Parses symbolic environment bindings")
    func parsesViewEnvironment() throws {
        let views = try AdaScriptSchemaParser.parseViews(sources: [
            AdaScriptCompilerSource(
                path: "Themed.ada",
                source: """
                @view
                class ThemedView {
                    @environment(colorScheme) var scheme;
                    @environment(scaleFactor) var scale: Float;
                    func body() { Text(scheme); }
                }
                """
            )
        ])

        #expect(views[0].environment == [
            AdaScriptViewEnvironmentBinding(key: "colorScheme", propertyName: "scheme"),
            AdaScriptViewEnvironmentBinding(key: "scaleFactor", propertyName: "scale")
        ])
    }

    @Test("Rejects bindings until nested script views can preserve identity")
    func rejectsBindingsWithoutNestedViews() {
        #expect(throws: AdaScriptSchemaError.self) {
            try AdaScriptSchemaParser.parseViews(sources: [
                AdaScriptCompilerSource(
                    path: "Child.ada",
                    source: "@view class ChildView { @binding var value; func body() { Text(value); } }"
                )
            ])
        }
    }
}
