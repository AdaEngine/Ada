# Ada Script Basics

Learn the syntax of Ada Script before connecting a script to a scene or ECS
world. Ada Script files use the `.ada` extension. The examples on this page are
small pieces you can combine in one file; a game does not need a `main()`
function. Start with <doc:GettingStartedWithAdaScript> to run a complete system.

## A first look

```ada
// A class keeps state between calls.
class Counter {
    var value = 0;

    func increment() {
        value += 1;
        return value;
    }
}

var counter = Counter();
var first = counter.increment(); // 1
```

`//` starts a line comment; `/* ... */` surrounds a block comment. Braces
delimit blocks. Semicolons can separate statements and are used throughout
AdaEngine's examples. Names are case-sensitive: `Counter` and `counter` are
different names.

## Values and basic types

Ada Script is dynamically typed. A `var` holds a value, and later assignments
can replace it. Type annotations such as `var score: Int` describe an API and
support tooling. They are enforced only when strict type checking is enabled
for the project or source file; dynamic mode remains the default.

| Type | Example | What it represents |
| --- | --- | --- |
| `Bool` | `true`, `false` | A condition. |
| `Int` | `42`, `-3` | An integer. |
| `Float` | `3.5` | A fractional number. |
| `String` | `"player"` | Text. |
| `Null` | `null` | No value. |
| `List` | `[10, 20, 30]` | An indexed sequence, starting at index `0`. |
| `Map` | `["hp": 100, "mp": 20]` | Values looked up by key. Use `[:]` for an empty map. |
| `Range` | `0..<3`, `1...3` | An exclusive or inclusive integer range. |

```ada
var name = "Ada";
var lives: Int = 3;
var inventory = ["key", "torch"];
var healthByPlayer = ["ada": 100, "lee": 80];

inventory[0] = "map";
healthByPlayer["ada"] -= 10;

const startingLives = 3;
```

`const` declares a value you do not reassign. A list has a `count` property;
maps have `keys()` and `hasKey(key)`. A range `0..<3` visits `0`, `1`, and
`2`; `1...3` also includes `3`. Engine types such as `Vector3`, `Transform`,
and `Sprite` come from registered AdaEngine APIs rather than the basic language
types. Values passed to Swift or stored in ECS fields have narrower supported
types than arbitrary script values; see <doc:AdaScriptLanguage>.

## Functions

Declare a function with `func`, pass arguments in parentheses, and use
`return` to send a value back. A function without an explicit `return`
returns `null`.

```ada
func doubled(value) { return value * 2; }
var next = doubled(5); // 10
```

Parameters can have defaults and type annotations:

```ada
func addPoints(score: Int, bonus = 10) {
    return score + bonus;
}

var updated = addPoints(5); // 15
```

Annotations on parameters describe types for tooling; runtime calls still
need values of the form the function expects. A helper function is ordinary
code. An ECS callback such as `update(context)` runs only because its class is
registered as a system.

AdaScript provides `print(...)`, `put(...)`, `input(removeTrailingNewline = true)`,
`nanotime()`, and `exit(code = 0)` as free functions. They forward to the
corresponding `System` methods. `assert(condition, message = "Assertion failed")`
stops the current script with a diagnostic when its condition is false.
The `System` spellings remain available for existing scripts. Avoid `input`
and `exit` in game callbacks because they block for console input or terminate
the host process.

AdaScript also supports `Math.clamp`, `Math.saturate`, `Math.addVector`,
`Math.subtractVector`, `Math.scaleVector`, `Math.dot`, `Math.cross`,
`Math.length`, `Math.normalize`, `Math.distance`, `Math.lerpVector`, and
`Math.clampVector`. Vectors are lists of numbers;
`cross` requires three components. Matrices are nonempty lists of equal-length
rows. `Math.identityMatrix(size)`, `transposeMatrix(matrix)`,
`multiplyMatrix(left, right)`, and `transformVector(matrix, vector)` use row-major
order and treat vectors as columns:

```ada
var safeHealth = Math.clamp(120, 0, 100); // 100
var point = [3.0, 4.0, 1.0];
var translation = [[1.0, 0.0, 2.0], [0.0, 1.0, 5.0], [0.0, 0.0, 1.0]];
var moved = Math.transformVector(translation, point); // [5.0, 9.0, 1.0]
```

## Structs and classes

Use `struct` for a small value that should be copied on assignment. Use
`class` when several names should refer to the same mutable instance.

```ada
struct Point {
    var x = 0;
    var y = 0;
}

class Player {
    var health = 100;
}

var point = Point();
var otherPoint = point;
otherPoint.x = 5; // point.x stays 0

var player = Player();
var teammate = player;
teammate.health = 80; // player.health is now 80
```

Classes can inherit from one parent class with `class Child : Parent`.
Both kinds of declaration can contain stored properties and methods. A plain
script `struct` is not automatically an ECS component or resource: use
`@component` or `@resource` and the supported exported field schema for that.
See <doc:AdaScriptECS>.

## Static members

An instance member belongs to one object. A `static` member belongs to the
declaration itself and is accessed through its type name:

```ada
class Difficulty {
    static var multiplier = 2;

    static func apply(baseScore) {
        return baseScore * multiplier;
    }
}

var points = Difficulty.apply(10); // 20
```

Use static state sparingly for gameplay. ECS components hold per-entity state,
and resources hold shared world state with an explicit lifecycle.

## Initialization and cleanup

`func init(...)` is called when a class or struct instance is created.
`func deinit()` runs when a class instance is reclaimed; its timing depends on
the script runtime, so it is not a reliable place for a gameplay event.

```ada
class TimerLabel {
    var title;

    func init(name) {
        title = name;
    }

    func deinit() {
        System.print("TimerLabel released");
    }
}

var label = TimerLabel("Countdown");
```

Neither method receives an ECS `context`. To initialize a world once, create
an `@system(scheduler: "startup")` class with `update(context)`. To react to
per-entity attachment or detachment, use a `@scriptable` class's
`ready(context)` or `destroy(context)`. There is currently no function-level
`@init` annotation. See <doc:AdaScriptAnnotations> for these lifetimes.

## Stored and computed properties

`var` inside a type is a stored property. A computed property runs `get` when
read and `set` when assigned. Inside `set`, `value` is the new value unless
you give the setter parameter another name.

```ada
class HealthBar {
    private var storedHealth = 100;

    var health {
        get { return storedHealth; }
        set (newHealth) {
            if (newHealth < 0) {
                storedHealth = 0;
            } else if (newHealth > 100) {
                storedHealth = 100;
            } else {
                storedHealth = newHealth;
            }
        }
    };
}

var bar = HealthBar();
bar.health = 120;
var visibleHealth = bar.health; // 100
```

A property with only `get` is read-only. These accessors are ordinary script
behavior. They do not by themselves export an Inspector property or define an
ECS field; `@export` on a supported stored field does that. See
<doc:AdaScriptAnnotations>.

## Conditions and loops

Use `if`, `else if`, and `else` to choose a branch. `&&`, `||`, and `!` combine
Boolean conditions.

```ada
func healthMessage(health) {
    if (health <= 0) {
        return "defeated";
    } else if (health < 25) {
        return "critical";
    } else {
        return "ready";
    }
}
```

Use `for (var item in collection)` for a list, range, or ECS query. `while`
checks before each iteration; `repeat ... while` checks after one iteration.
`break` ends a loop, and `continue` skips to its next iteration.

```ada
var total = 0;
for (var number in 1...3) {
    total += number; // 1 + 2 + 3
}

var attempts = 0;
while (attempts < 3) {
    attempts += 1;
}

repeat {
    attempts -= 1;
} while (attempts > 0);
```

`switch (value)` selects `case` branches and an optional `default`. Add
`break` to stop at the end of a case when no `return` exits it; execution can
otherwise continue into the next case.

```ada
func teamName(team) {
    switch (team) {
        case 1:
            return "blue";
        case 2:
            return "red";
        default:
            return "unknown";
    }
}
```

## Async functions and `await`

An `async func` may suspend at `await`. Awaiting an operation pauses that
script task while the game keeps updating. A synchronous callback starts an
async function with `Tasks.start(...)`:

```ada
async func announceLater() {
    await Time.sleep(1.0);
    System.print("One game-time second passed");
}

@system
class AnnouncementSystem {
    var started = false;

    func update(context) {
        if (!started) {
            started = true;
            Tasks.start(announceLater());
        }
    }
}
```

`update(context)`, scriptable callbacks, UI actions, and `body()` remain
synchronous. Do not keep `context`, query rows, resource views, or commands
across `await`: those values expire when the callback returns. Pass detached
values into the task. `Time.sleep` uses game time; `Time.sleepRealTime` uses a
monotonic clock. Read <doc:AdaScriptLanguage> for asset operations, save
results, cancellation, and task lifetimes.

## Annotations

Annotations begin with `@` and attach metadata to a declaration. They are
AdaEngine features, not ordinary function calls:

```ada
@component(id: "game.health")
struct Health {
    @export var current = 100;
}

@system(scheduler: "startup")
class CreatePlayer {
    func update(context) {
        context.world.spawn([Health(current: 100)]);
    }
}
```

`@component` tells AdaEngine to register data; `@export` gives a supported
field a default. `@system` registers an ECS callback. Other annotations define
queries, resources, scriptable behavior, views, editor tools, and multiplayer
messages. Arguments are constants or symbolic identifiers used during module
discovery. See <doc:AdaScriptAnnotations> for their valid targets, arguments,
defaults, and limitations.
