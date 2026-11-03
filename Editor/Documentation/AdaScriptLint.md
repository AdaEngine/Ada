# AdaScript style checks

Native Ada Studio checks `.ada` and `.gravity` source layout when it publishes language
diagnostics. Warnings appear in Problems and through `editor.gravity.diagnostics`,
with source `adascript-lint`. They update from the current document buffer and
clear when the code is corrected. They do not prevent Play or compilation.

The shared `AdaScriptLinter` in `AdaScriptCompilerCore` uses the language lexer
and declaration parser. Strings and comments are not checked as code; unary
operators and semicolons in `for` headers are allowed.

| Rule | Expected layout |
| --- | --- |
| `operator_spacing` | `speed += dt`, `progress < 1` |
| `comma_spacing` | `move(row, dt)`, `[0, 1, 2]` |
| `colon_spacing` | `@system(id: "game.move")` |
| `control_keyword_spacing` | `if (ready)`, `for (var row in query)` |
| `statement_newline` | Separate statements on separate lines |
| `declaration_spacing` | A blank line between types and between functions |

For example:

```adascript
class Movement {
    func move(row, dt) {
        var state = row.agent;
        state.progress += dt;
    }

    func update(context) {}
}
```

Desktop command-line validation checks saved project sources and `Tests/` after
the usual compiler and scene validation. It respects the active target's source
membership and excludes dependency libraries, hidden files and symbolic links.
No source files are rewritten.

```sh
adastudio validate --project /path/to/game --lint strict --format json
```

The default `--lint warning` includes style warnings and keeps exit code 0 for
an otherwise valid project. `--lint strict` returns exit code 3 when style issues
exist; diagnostics still have severity `warning`. `--lint off` skips style checks
for that CLI invocation. JSON diagnostics include `adascript-lint.<rule>` codes,
project-relative paths and one-based line/UTF-16 column positions.

Use strict validation in an agent's completion checks or a game project's CI.
Swift sources continue to use the repository's existing SwiftLint integration.
