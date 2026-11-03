import AdaScriptCompilerCore
import Testing

@Suite("AdaScript style checks")
struct AdaScriptLintTests {
    @Test("Compact code reports the problems from an agent-written script")
    func compactCode() {
        let issues = AdaScriptLinter.lint(source: """
            class Horde {
                func move(row,dt) {
                    var s=row.agent;var c=row.controller;
                    if(s.progress<0.3) c.speed+=dt;
                }
                func update(context) {}
            }
            class Other {}
            """)
        #expect(Set(issues.map(\.rule)) == [
            .operatorSpacing, .commaSpacing, .controlKeywordSpacing, .statementNewline, .declarationSpacing,
        ])
        #expect(issues.filter { $0.rule == .declarationSpacing }.map(\.range.start.line) == [5, 7])
        #expect(issues.filter { $0.rule == .operatorSpacing }.count == 4)
    }

    @Test("Readable code has no style issues")
    func readableCode() {
        #expect(AdaScriptLinter.lint(source: """
            @system(id: "horde")
            class Horde {
                func move(row, dt) {
                    var s = row.agent;
                    var speed = -1.0;
                    if (s.progress < 0.3 && !s.blocked) speed += dt;
                    row.controller.speed = speed;
                }

                func update(context) {}
            }

            class Other {}
            """).isEmpty)
    }

    @Test("Binary operators are checked as whole tokens", arguments: [
        "=", "+", "-", "*", "/", "%", "==", "!=", "===", "!==", "<", ">", "<=", ">=", "&&", "||",
        "&", "|", "^", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "~=",
    ])
    func operators(_ symbol: String) {
        for expression in ["a\(symbol)b", "a \(symbol)b", "a\(symbol) b"] {
            let issues = AdaScriptLinter.lint(source: expression)
            #expect(issues.map(\.rule) == [.operatorSpacing], Comment(rawValue: expression))
            #expect(issues.first?.range.end.utf16Column == issues.first.map { $0.range.start.utf16Column + symbol.utf16.count })
        }
        #expect(AdaScriptLinter.lint(source: "a \(symbol) b").isEmpty)
    }

    @Test("Unary operators, scientific notation and member access stay clean", arguments: [
        "var speed = -1.0;", "var speed = +1.0;", "return -speed;", "var active = !paused;",
        "var mask = ~bits;", "var speed = a + -b;", "var speed = a * -b;", "var step = 1e-3;",
        "row.transform.position[0] = -1;", "func value() -> Int { return -1; }",
        "for (var i in start ..< end) {}", "for (var i in start ... end) {}",
        "for (var i in 0..<count) {}", "for (var i in 0...10) {}",
        "var speed = /* comment */ -1;", "move(a /* comment */, b);",
        "var p = [1,];",
    ])
    func unaryOperators(_ source: String) {
        #expect(AdaScriptLinter.lint(source: source).isEmpty)
    }

    @Test("Strings, escaped quotes and nested comments are opaque")
    func stringsAndComments() {
        #expect(AdaScriptLinter.lint(source: #"""
            // var x=1;var y=2; if(x<y) {}
            /* class A {}class B {} /* a+=1 */ */
            var text = "a=b;c,d if(x) \"quoted\"";
            var single = 'x=y;z';
            """#).isEmpty)
    }

    @Test("For headers keep their semicolons", arguments: [
        "for (var i = 0; i < 10; i += 1) {}",
        "for (var row in rows) { row.speed = 0; }",
    ])
    func forHeaders(_ source: String) {
        #expect(AdaScriptLinter.lint(source: source).isEmpty)
    }

    @Test("Block comments do not conceal adjacent statements or binary subtraction")
    func commentsBetweenTokens() {
        #expect(AdaScriptLinter.lint(source: "var a = 1; /* next */ var b = 2;").map(\.rule) == [.statementNewline])
        #expect(AdaScriptLinter.lint(source: "a /* operand */ -b").map(\.rule) == [.operatorSpacing])
        #expect(AdaScriptLinter.lint(source: "consume(func() { var a = 1;var b = 2; });").map(\.rule) == [.statementNewline])
    }

    @Test("Commas and labelled arguments", arguments: ["func move(a,b) {}", "var p = [0,1,2];", "move(a , b);", "@system(id:\"a\") class A {}"])
    func separators(_ source: String) {
        #expect(!AdaScriptLinter.lint(source: source).isEmpty)
    }

    @Test("Declaration spacing includes annotations and documentation")
    func annotatedDeclarations() {
        let compact = "class First {}\n// The next type\n@component\nstruct Second {}"
        #expect(AdaScriptLinter.lint(source: compact).map(\.rule) == [.declarationSpacing])
        let spaced = "class First {}\n\n// The next type\n@component\nstruct Second {}"
        #expect(AdaScriptLinter.lint(source: spaced).isEmpty)
        #expect(AdaScriptLinter.lint(source: "func first() {}\nfunc second() {}").map(\.rule) == [.declarationSpacing])
        #expect(AdaScriptLinter.lint(source: "class First {}class Second {}").map(\.rule) == [.declarationSpacing])
    }

    @Test("LF, CRLF and CR share UTF-16 diagnostic positions", arguments: ["\n", "\r\n", "\r"])
    func sourcePositions(_ newline: String) throws {
        let source = ["// Привет", "var text = \"👋\";var speed=1;"].joined(separator: newline)
        let issues = AdaScriptLinter.lint(source: source)
        let statement = try #require(issues.first { $0.rule == .statementNewline })
        #expect(statement.range.start == AdaScriptSourcePosition(line: 1, utf16Column: 16))
        let assignment = try #require(issues.first { $0.rule == .operatorSpacing })
        #expect(assignment.range.start == AdaScriptSourcePosition(line: 1, utf16Column: 25))
    }

    @Test("Incomplete documents can be checked while typing", arguments: ["", "// comment", "class", "func f(", "class A { func f() { var x=", "var x = \"unterminated"])
    func incompleteSources(_ source: String) {
        _ = AdaScriptLinter.lint(source: source)
    }
}
