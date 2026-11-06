# OG Script: Language Reference

OG Script (OGS in the code, `src/script/ogs/`) is the built-in scripting language of OpenGorky. This reference describes the language as it is **implemented** (lexer, parser, linker, runtime, built-in function table). Where the design promises more, the text is marked "Planned".

Every example below has been checked against the current implementation: parsed and linked by the OGS parser and linker, and the examples with a result have also been run in the runtime. The invisible `<!-- check: … -->` comments before code blocks are the markup for this check.

## Contents

1. [What OG Script is](#1-what-og-script-is)
2. [Where code lives and how it is loaded](#2-where-code-lives-and-how-it-is-loaded)
3. [Lexical structure](#3-lexical-structure)
4. [Values and types](#4-values-and-types)
5. [Variables](#5-variables)
6. [Expressions and operators](#6-expressions-and-operators)
7. [Control flow](#7-control-flow)
8. [Functions](#8-functions)
9. [Modules and namespaces](#9-modules-and-namespaces)
10. [Components and traits](#10-components-and-traits)
11. [Data blocks](#11-data-blocks)
12. [Rules files: call rows](#12-rules-files-call-rows)
13. [Built-in traits: engine events and decisions](#13-built-in-traits-engine-events-and-decisions)
14. [Battle and game variables](#14-battle-and-game-variables)
15. [Scripted abilities: a full example](#15-scripted-abilities-a-full-example)
16. [Built-in functions](#16-built-in-functions)
17. [Errors and diagnostics](#17-errors-and-diagnostics)
18. [Determinism](#18-determinism)
19. [What the language does not have](#19-what-the-language-does-not-have)
20. [OG Script and Classic](#20-og-script-and-classic)
21. [Differences from the Classic language: table](#21-differences-from-the-classic-language-table)

---

## 1. What OG Script is

Gorky 17 has its own scripting language. These are the `.lev .ftr .hro .wpn .itm .are .aba .ba .act .obs .pth .s .ss` files; this reference calls that language **Classic**. OG Script is the language of the OpenGorky engine itself:

- **Brace syntax, like Classic**, but without its bugs: proper `!=` and `<=`, short-circuit `and`/`or`, `%`, `while`/`for` loops.
- **Dynamic typing**: `nil`, `bool`, `int`, `float`, `string`, object references, lists, maps. Types on variables and parameters are optional. If a type is given, the value is converted to it.
- **Named and optional arguments**: `fighter::Damage(who, 5, kind: "fire", from: host)`.
- **Components**, like MonoBehaviour in Unity. A script is a `component Name for fighter { … }`: it is attached to a host object, each attachment has its own `param` and `var` values, and the engine calls its event-handler methods.
- **Modules are declared in code** (`module a::b { … }`, `use a::b;`) and do not depend on file names.
- **Case-sensitive** (with one caveat about object variables, §5.4).

One program runs both languages: the importer translates Classic code into the same intermediate representation (IR, `src/script/ir.zig`) as OG Script, and it is executed by the same runtime (`src/script/runtime.zig`). How Classic code is displayed and saved through OG Script is described in §20.

A short example: a component returns part of the damage taken to the attacker.

<!-- check: link -->
```ogs
// Returns part of the damage taken to the attacker.
component Reflect for fighter {
    param int pct = 30 "Percent to return";

    fn OnHit(attacker, weapon, amount) {
        if (attacker != nil and attacker != host) {
            fighter::Damage(attacker, amount * pct / 100, from: host, kind: "reflect");
        }
        // Without return the handler returns nil: the damage to the host is unchanged.
    }
}
```

## 2. Where code lives and how it is loaded

OG Script works only in an **OpenGorky project**, not in a Classic project (the original game and its mods for the original exe). A project is a folder:

| Path | Contents |
|---|---|
| `opengorky.mod` | manifest: `format = ogs`, `engine`, `id`, `title`, `base`, `language`, `game` — path to the installed game (`$OPENGORKY_GAME` takes precedence) |
| `src/game.ogs` | the `game` block (campaign, squad) and game hooks: `for game` components (§13.5) |
| `src/rules/*.ogs` (`fighters`, `attacks`, `resist`, `ai`, `fx`, `ui`, `battle`…) | call rows of the rules tables: `Resist(fighter = 125, …);` (§12) |
| `src/characters/`, `looks/`, `weapons/`, `items/` | archetypes: data blocks (§11) |
| `src/locations/<level>/level.ogs`, `objects.ogs`, `logic.ogs`, `<component>.ogs` | a location: the `level` block (camera, hero placement, fields), its objects, its code: the `level` block's own code lives in `logic.ogs` (`level "01_port" { fn OnStart() { … } }` — another part of the same block, `injects` go there too); every object with code and every area trigger has its own component in its own file next to it (`box_01_itm.ogs`, `fight2_place.ogs`, module `locations::<level>`, `_` before a leading digit; this is how the converter writes it). The engine does not look up level code by name: what a level runs is written in its block. `logic.ogs` is optional: a level without code works; the editor creates it on the first trigger or exit |
| `src/battles/<battle>/battle.ogs` | a battle as a single text: the `battle` block (fields, fighters and objects, own `fn` code, `injects`) and the components of its `battles::<battle>` namespace |
| `src/components/**/*.ogs` | components and functions: `for fighter` scripted abilities (§15) and other code |
| `src/scenes/`, `dialogs/`, `texts/` | scenes, dialogs, UI texts (`UiText`; names and descriptions are the `name` and `examine` fields of entities) — UTF-8 |
| `src/assets/` | your own and modified assets by logical path (`levels/01_port/walk.wm`, `sounds/door.wav`); everything else is read from the installed game. The editor also saves edits of installed-game assets here (walkability map, areas, paths, battle grid, sound) — the game itself is not changed |
| `dist/<id>.ogp` | the built package for players (`gorky-tool build`, "Play") |
| `.og/history/`, `.og/testkit.txt` | editor files: save history and test kit; not included in the build or package |
| `.gitignore` | `dist/` and `.og/` are kept out of git (written by the converter; the editor appends `.og/` when it creates `.og/`) |

OG Script does not read a Classic project: it has no hooks, no scripted abilities and no rules rows on top of the built-in ones. To get an OpenGorky project, a Classic game is converted into a new folder: `gorky-tool convert <game> <folder>`.

Loading rules (`ogs/link.zig`, `loaders/ogs.zig`, `state/hooks.zig`, `loaders/rules_text.zig`):

- **File names and extensions mean nothing.** The reader loads all `.ogs` files from `src/` (except `src/assets/`) or from the package into one program; functions and components are keyed by namespace path (`abilities::Rage`), not by file. The layout above is the OG writer's convention. The file only matters for error messages (`file:line`).
- **A level is several texts in its folder.** A `level "x" { … }` / `battle "x" { … }` block may be written across several files (the writer puts a location's fields in `level.ogs`, objects in `objects.ogs`, code in `logic.ogs`; a battle is written as a single `battle.ogs`); before linking this is one block: the parts in file-path order, with their fields, variables, components, objects and own code combined (`script/ogs/levels.zig`). A field, variable, component or object in two parts, or own code in two parts, is an error naming both files: `battle b: fighter x is in battles/b/battle.ogs and battles/b/objects.ogs`.
- **File order does not matter.** All texts are parsed first, then the whole program is linked at once. A hook in `game.ogs` can call a function from `components/abilities.ogs` and vice versa.
- Rules tables start **empty**: the project has no built-in exe rows; the converter wrote them out (§12).
- A text with a parse error is not added at all; `file:line: message` is written to the log.
- A text that parsed but failed to link (unknown function, error in a data block, wrong sigil…) is also dropped entirely: none of its functions or components are in the program, and they are not attached to the game or fighters. The remaining texts are relinked without it, so a text that called a function of the dropped one is dropped next. Each error is written to the log. The build (`gorky-tool build`) finds such errors before the game runs.

## 3. Lexical structure

### 3.1 Encoding and characters

Source is read as bytes. Identifiers are ASCII only: `[A-Za-z_][A-Za-z0-9_]*`. Any bytes are allowed inside strings and comments; write non-ASCII text in UTF-8. Spaces, tabs, newlines and the byte `0x1A` (DOS end of file) are skipped.

Caveat: the code editor currently shows rules files as the game's 8-bit text, so non-ASCII labels in `param … "Label"` look garbled in the code window but display correctly in the "Extra abilities" block. For the same reason, the templates the editor writes are ASCII only.

### 3.2 Comments

`// to end of line` and `/* block comment, may span several lines */`. Block comments do not nest. An unclosed `/*` is an `UnterminatedComment` error.

### 3.3 Case

Case matters everywhere: in keywords, local variables, functions, components, methods and built-in functions (`print`, but `fighter::Damage`). `Run` and `run` are different methods, `X` and `x` are different locals. The exception is object variables (§5.4).

### 3.4 Keywords

```
module use component trait fn param var if else while for in return break continue
and or not nil true false host self super is attach native
```

`struct` and `enum` at the start of a declaration (followed by a name) open a struct or an enum (§10.6, §10.7); elsewhere they are ordinary words.

`native` is written only in the engine prelude (`engine.ogs`); in any other text it is the parse error `native is the engine's (engine.ogs)`.

A keyword cannot be used as the name of a local, parameter, field, function or component. Type names (`int`, `float`, `string`, `bool`, `object`, `fighter`…) are not keywords. The path `classic::` is taken by the Classic compatibility module (§20.1): `classic::x(…)` is always its form; you cannot declare your own functions in `classic`.

### 3.5 Numbers

- Integers: decimal digits, `0`…`2147483647` (i32). Larger is an `integer too large` error. Negative numbers come from unary minus.
- Floats (f32): `2.5`, `1e3`, `2.5e-1`, `4E+2`. A digit is required after the point: `1.` is `1` followed by a dot, `.5` is not a number. `1..5` is a range, not a float.
- There are no hexadecimal literals and no `_` separators.

### 3.6 Strings

In double quotes, on one source line: a newline inside a literal is an `UnterminatedString` error. Escapes:

| Written | Value |
|---|---|
| `\"` | quote |
| `\\` | backslash |
| `\n` | newline |
| `\t` | tab |
| `\` + any other character | stays as written, both characters: `"weapons\x"` is `weapons\x` |

So write game paths with a double backslash: `"weapons\\bottle"`. Otherwise `"weapons\napalm"` turns into a newline.

### 3.7 Punctuation

```
( ) { } [ ] , ; . .. : :: @ ~
= += -= == != < <= > >= + - * / % ! && ||
```

A single `&` or `|` is an `UnexpectedChar` error.

<!-- check: run ["weapons\bottle", "He said: "Fire!"", "weapons\x", 1000, 0.25, 400] -->
```ogs
component Lexemes {
    fn run() {
        /* Block
           comment */
        var path = "weapons\\bottle";        // \\ is a single backslash
        var quote = "He said: \"Fire!\"";
        var raw = "weapons\x";               // unknown \x stays as is
        return [path, quote, raw, 1e3, 2.5e-1, 4E+2];
    }
}
```

<!-- check: error expected ] -->
```ogs
// Error: 0x1 is 0 followed by the name x1, not a hexadecimal number.
fn f() { return [0x1]; }
```

## 4. Values and types

| Kind | Literal | Description |
|---|---|---|
| `nil` | `nil` | "no value". Returned by `@name` with no object, a missing object field, a missing map key |
| `bool` | `true`, `false` | boolean |
| `int` | `42` | 32-bit signed integer; overflow wraps, as in the exe |
| `float` | `2.5` | 32-bit floating point (f32) |
| `string` | `"text"` | immutable byte string |
| `ref` | `@grandma`, `host`, `self` | reference to a world object or a component instance |
| `list` | `[1, "a", nil]` | immutable list |
| `map` | `{"hp": 10, 2: "two"}` | immutable map; keys can be any value, order is insertion order |

**Truthiness** (in `if`, `while`, `and`, `or`, `!`): `nil`, `false`, `0`, `0.0` and `""` are false. Everything else is true, including `"0"`, an empty list and any reference.

**Comparisons (`== != < <= > >=`) and logical operations (`and`, `or`, `!`, `not`) return `bool`**: `(1 < 2) == true` is true. `bool` is not a number: in arithmetic and in `< <= > >=` it causes a runtime error, and `true == 1` is false (different kinds). To get a number from a `bool`, convert it: `var int n = x > 0;` gives 1 or 0 (§4.1).

Built-in functions that answer yes/no (`object::Exists`, `hero::AnyInArea`, `fighter::IsAlive`…, with result `bool` in §16) also return `bool` in OG Script: `hero::AnyInArea("a") == true` works. In Classic the same functions still return `int` 1/0, as in the exe. Built-in flags (`noBlend`, `reverse`, `loop`…) can be passed as `true`/`false`: the function receives them as 1/0 (§8.1).

<!-- check: run [true, true, false] -->
```ogs
component Ask {
    fn run() {
        var a = hero::AnyInArea("no_such_area") == false;  // true: the answer is a bool
        var b = !object::Exists("no_such_object");           // true
        var c = fighter::IsAlive("x");                 // false: outside battle
        return [a, b, c];
    }
}
```

### 4.1 Type conversion

A variable, parameter or field can have a type. Every assigned value is then converted to it by the exe's rules (`Value.convert`):

| Type | Result |
|---|---|
| `int` | a number is truncated toward zero (`3.7` → 3, `-1.9` → -1); `bool` → 0/1; **string → 0** (as in the exe); `nil`, reference, list → 0 |
| `float` | a number as is; a string is parsed (`"2.5"` → 2.5, garbage → 0) |
| `string`, `object` | a number is printed (`5` → `"5"`, `2.5` → `"2.500000"`); reference → object name; `nil` → `""`; `bool` → `"true"`/`"false"` |
| `bool` | truthiness |
| any other word (`fighter`, `item`, `sound`…) or no type | the value is stored as is |

Initial value without `= …`: `int` 0, `float` 0.0, `string`/`object` `""`, `bool` `false`; untyped and everything else `nil`.

The built-in `str(x)` (§16.1) also turns any value into a string: `str(5)` is `"5"`, `str(2.5)` is `"2.500000"`, `str(nil)` is `"nil"`. There is no implicit conversion: `"hp: " + 5` is a runtime error; write `"hp: " + str(5)`.

<!-- check: run [3, 3.5, -1, 0, "Gorky", true, false, true, "5", 2] -->
```ogs
component Values {
    fn run() {
        var a = 7 / 2;            // 3: integer division
        var b = 7 / 2.0;          // 3.5: a float is involved, computed in float
        var c = -7 % 3;           // -1: sign of the dividend, as in C
        var d = 1 / 0;            // 0: integer division by zero
        var s = "Gor" + "ky";   // concatenation of two strings
        var e = 1 == 1.0;         // true: numbers compare by value
        var f = "1" == 1;         // false: different kinds
        var g = (1 < 2) == true;  // true: comparison yields bool
        var string t = 5;         // "5": converted to the variable's type
        var int n = 2.9;          // 2
        return [a, b, c, d, s, e, f, g, t, n];
    }
}
```

### 4.2 Values in save games

A save game records the variables (`var`) of the world objects of all visited locations with their current values — of any kind: number, string, `bool`, `nil`, list, map, struct value (a map of its fields, §10.6), reference, including inside lists and maps at any depth. After loading, a variable has the value it had when saved, not the value from the block.

- **A reference** is written as the location and object name (for a component instance, `host#Component`): `@"01_port::ponton"`. A reference to a hero or a hero's item is written without a location, `@"sullivan"`: they travel with the squad and exist in every location. On load the reference again points to the object with that name in the loaded location: `w == @Sullivan` is true after loading. If the object was deleted in the game, the reference stays (a deleted object still exists in the world). If the location has no object with that name (the file was edited, the object removed from the blocks), the value is `nil`; inside a list or map it is `nil` at that position. A reference without a location (a save from an older engine version) points to an object of the loaded location.
- **A reference to an object in another location.** A value leaves its location — in a hero's variable when the squad moves on — and in the new location the reference is "remote": it remembers the location and name, survives further transitions, saving and loading, is equal (`==`) to another reference to the same object, but a field or method accessed through it yields `nil` (`x.hp`, `x.name`, `x.Open()`), assigning to a field is not allowed (script error), and built-in functions receive the name of an object that is not here. To check: `object::IsHere(x)` (§16.2) is `false` for a remote reference and `true` for an object of this location. When the squad returns to that location, the reference is live again: the same object, in the state it had (`@Sullivan.o_pal == @ponton`, `object::IsHere(@Sullivan.o_pal)` — both `true`). When printed, a remote reference looks like `@01_port::ponton`.
- **Maps and struct values** are new values after loading: equal to the old ones in content but not identical (`==` on maps is by identity, §10.6).
- **Component instance variables** (fields and `param` of a component attached to an object by an `attach` block, or of a block's own code, §14) are saved the same way, with their object. On load they go to the instance of that component on the same object; if the object no longer has that component (the code changed), its values are dropped with a warning in the log, and the component gets default values. Scripted abilities from the `Abilities` row are not saved: they live for one battle (attached anew in each), and you cannot save during a battle.
- **Squad transitions between locations.** A hero and their items are separate objects in each location, created anew from blocks; on a transition (into a battle, out of a battle, and when returning to an already visited location) they receive the previous values: the hero's variables (except position), plus the variables of their component instances and those instances' subscriptions — as in a save. Values of a component that the object does not have in the new location are dropped silently (like a variable the object does not have). Subscriptions of hero and hero-item instances that these objects had in the new location (made when it was created, or left over from a previous visit) are replaced by the transferred ones — in their original order, after the location's own subscriptions. Battle scripted abilities are not transferred (§10.1).
- **Subscriptions** (`events::Subscribe`, §14.1) are saved with the location in subscription order: after loading, the same instances hear the event in the same order, and subscriptions that objects made anew while the location was being created (`OnCreate`) are replaced by the saved ones (subscriptions of `game` components are not saved: they are created anew with each location). A subscription of an instance that does not exist on load (no object, or the object lacks that component), or to a method the component no longer has, is dropped with a warning in the log.

In the save file (`src/save.zig`) such a value is a line `var <name> v:<literal>`, an OG Script literal on one line:

```
var waves v:[{"turn": 3, "spawn": [{"who": "characters::grandma_child", "tile": [5, 2]}]}]
var target v:@"01_port::grandma"
var rage v:@"01_port::grandma#Rage"
var buddy v:@"ovitz"
var none v:nil
```

Instance variables are `var` lines after a `comp <Component>` line inside an object; subscriptions are `sub <host#Component> <method> <event>` lines at the end of the location:

```
obj 01_port 01_port level 1 0 0 0
var first i:1
comp Counter
var count i:7
var who v:@"01_port::ponton"
sub 01_port#Counter OnPing og_ping
```

A float in a literal always has a point (`3.0`); strings are quoted with `\\`, `\"`, `\n`, `\r`. A file with such lines (or with `comp`, `sub` lines) starts with `OGSAVE 2` (an older engine version refuses to load it instead of misreading it); without them it starts with `OGSAVE 1`, like Classic saves, byte for byte as before.

## 5. Variables

### 5.1 Locals

```
var name;
var name = expression;
var type name;
var type name = expression;
```

The type is one word before the name (`var int left;`). Locals are visible from the declaration to the end of the function.

**Blocks do not create scopes**, as in Classic: each name in a function has one slot. A repeated `var x` in another block is the same variable (the declaration sets its initial value again). A `for` loop variable is also an ordinary local of the function.

### 5.2 Parameters

Function parameters are locals too (§8).

### 5.3 Component fields and host variables

In a component method, a name that is not a local is looked up **at run time**: first an instance field (`param`/`var`), then a host variable. If neither exists, it is the runtime error `no field or host variable x`. More in §10.

In a free function (not in a component) such a name is the parse error `unknown name x`.

### 5.4 Case of object variables

Instance fields and host variables are stored in the engine's object variables, which are case-insensitive: `host.HP` and `host.hp` are the same variable. So two fields of one component that differ only in case are a parse error (`field X declared twice`).

### 5.5 Assignment

`target = expression;`, `target += expression;`, `target -= expression;` are **statements, not expressions**: they have no value and cannot be written inside an expression. The target is a local, a field or a host variable (`left = 2;`), or an object field through a reference (`host.hp -= 5;`, `self.count = 0;`, `@grandma.hp = 10;`). You cannot assign to a list or map element (§19). With `+=`/`-=` the target is read once. The assigned value is converted to the target's type (§4.1).

## 6. Expressions and operators

### 6.1 Precedence

From strongest to weakest. All binary operators are left-associative.

| Level | Operators |
|---|---|
| 1 (postfix) | `a.b`, `a.f(…)`, `a[k]`, call `f(…)` |
| 2 (unary) | `-x`, `!x`, `not x` |
| 3 | `*`, `/`, `%` |
| 4 | `+`, `-` |
| 5 | `<`, `<=`, `>`, `>=` |
| 6 | `==`, `!=` |
| 7 | `and`, `&&` |
| 8 | `or`, `\|\|` |

Operands are evaluated left to right.

### 6.2 Arithmetic: `+ - * / %`

- Both operands are numbers. If both are `int`, the result is a wrapping `int` (i32). If at least one is `float`, the result is `float`.
- `/` on integers truncates toward zero (`-7 / 2` → -3). Integer division by 0 gives 0; `x / -1` gives `-x` with wrapping. Dividing a `float` by 0 gives ±infinity or NaN.
- `%` on integers is the remainder with the sign of the dividend, as in C; `x % 0` and `x % -1` give 0. With `float` it is the `fmod` remainder.
- `+` on two strings concatenates them.
- Any other combination is a **runtime error**: string + number, `bool` in arithmetic, `nil`, etc. The message looks like `40 add "!"` (§17).

### 6.3 Comparisons

- `==` and `!=` accept any values. Numbers compare by value (`int` with `float` as float), strings by content, `bool` with `bool`, `nil == nil`, references by object, lists and maps by identity (the same literal in the same evaluation). Values of different kinds are not equal: `"1" == 1`, `nil == 0` and `true == 1` give `false`.
- `< <= > >=` work only on numbers (`bool` is not a number either), otherwise a runtime error. With NaN they behave as on x87: `<` is false, `>` and `>=` are true. `a <= b` is evaluated as `b >= a`.
- The result is `bool`.

### 6.4 Logic

- `a and b` (`&&`), `a or b` (`||`) **short-circuit**: the right side is evaluated only if needed. The result is a `bool` based on the operands' truthiness (§4), not the operand's value: `nil or 5` gives `true`, not 5.
- `!x`, `not x` give `true` if `x` is false, otherwise `false`.

### 6.5 Unary minus

Only on a number (`-x` on a string or `nil` is a runtime error). Negating the smallest integer (−2147483648) wraps to itself.

### 6.6 Access: `.`, `[]`, `@`

- `@name` is the world object with that object name (case-insensitive lookup), otherwise `nil`. A name that is not an identifier is written as a string: `@grandma`, `@"01pr_garcia1"`. World objects appear and disappear at run time, so the name after `@` is not checked at load time: it is a reference, not a sigil (§6.8). Built-in functions accept a reference wherever they expect an object name.
- `obj.field` — `obj` must be a reference, otherwise the error `… is no object` (including for `nil`). If the object has such a variable, its value. Otherwise a computed field of a fighter host in battle (`side`, `alive`, `tile`, `asleep`, `second_turn`, `avenging`, §13.3). Otherwise **`nil`, no error**.
- `obj.name` is a computed field of any reference: the object's name as a string (`level.name`, `host.name`, `@"01pr_garcia1".name` is `"01pr_garcia1"`). An object variable named `name` does not shadow it. The field is read-only: `host.name = "x";` is the runtime error `host.name is read-only`.
- `obj.f(args)` is the function `f` of the object's script: a component instance method or a function of the object's Classic script. If there is no such function, it is the runtime error `X has no function f`. For OGS methods the case of the name must match exactly.
- `list[i]` is the element at index from 0; an index out of range or not an `int` is a runtime error. `map[k]` is the value of the key equal to `k` by `==`, otherwise `nil`. Strings and other values cannot be indexed.

### 6.7 List and map literals

`[a, b, c]`, `{key: value, …}`. Keys and values are any expressions, evaluated anew each time. A trailing comma after the last element is allowed. An empty map `{}` in an expression is a map, while `{` at the start of a statement is a block.

### 6.8 Sigils: checked strings

`~letter"string"` is a string that names a level, scene, sound… At run time a sigil's value is an **ordinary string** (`~l"01_port"` is `"01_port"`), so built-in functions and Classic behave as before. A sigil is checked when the whole program is linked (§2): anything missing is a load error `file:line`.

| Sigil | Names | Declared in the program by |
|---|---|---|
| `~l` | level or battle | `level`, `battle` block |
| `~e` | scene | `scene` block |
| `~d` | dialog | `dialog` block |
| `~c` | character (archetype) | `fighter` block |
| `~i` | item | `item` block |
| `~w` | weapon | `weapon` block |
| `~k` | look (model and animations) | `look` block |
| `~s` | sound | — |
| `~a` | asset (path) | — |
| `~t` | UI text | — |

- The name is looked up among program blocks of the right kind (by path; a top-level block at the root, by name). If there is no such block, the host checks the name. The editor (code check) knows the game's levels, scenes and sounds: `~l"nowhere"` gives `no level nowhere`. The engine currently checks only program blocks; the rest will be checked once the OG project reader exists.
- A built-in function parameter can be declared with a kind: `level::Load(level)`, `level::LoadAfterBattle(level)`, `scene::Start(scene)`, `scene::StartNext(scene)`, `sound::Play(sound, ?int)`. A sigil of another kind there is a link error. A plain string works there, but the editor suggests a sigil (a note, not an error).
- World objects are not among the sigils: use `@name` and `@"name"` for them (§6.6).
- Classic does not know sigils: printing and exporting to Classic write a plain string.

<!-- check: run ["01_port", "door"] -->
```ogs
level "01_port" { }
component Go {
    fn run() { return [~l"01_port", ~s"door"]; }   // the values are plain strings
}
```

<!-- check: error level::Load: argument 1 is a level, not a sound -->
```ogs
fn f() { return level::Load(~s"door"); }
```

<!-- check: error unknown sigil ~q -->
```ogs
fn f() { return ~q"x"; }
```

## 7. Control flow

```
if (condition) body
if (condition) body else body
while (condition) body
for name in list body
for name in start..end body
for (name in …) body
break;
continue;
return;
return expression;
{ statements }
```

- A body is a `{ … }` block or a single statement. `else if` is an `else` with a single `if` statement.
- Parentheses around the condition are required in `if` and `while`, not in `for`.
- `for x in list` iterates over list elements. `for k in map` iterates over keys in insertion order. Any other value is the runtime error `for over …`.
- `for i in a..b` iterates over integers from `a` to `b - 1`. The bounds are evaluated once and must be `int`.
- `break` and `continue` apply to the nearest loop. Outside a loop the parser does not forbid them, but they simply stop the function (result `nil`). Do not write this.
- `return;` returns `nil`. **A function that reaches its end without `return` also returns `nil`.** An event handler that returns `nil` changes nothing (§13.2).
- Extra `;` are allowed everywhere, so an old-style `};` after a block is also accepted.

<!-- check: run [19, 3, "hpap"] -->
```ogs
component Loops {
    fn run() {
        var total = 0;
        for i in 0..10 {
            if (i % 2 == 0) continue;
            if (i > 7) break;
            total += i;                 // 1 + 3 + 5 + 7 = 16
        }
        var n = 0;
        while (n < 3) n += 1;
        for w in ["a", "b", "c"] total += 1;
        var keys = "";
        for k in {"hp": 10, "ap": 4} keys = keys + k;
        if (total > 100) {
            return "many";
        } else if (total > 10) {
            return [total, n, keys];
        } else return nil;
    }
}
```

## 8. Functions

```
fn name(parameters) { body }
```

A parameter is written as `name`, `name: type`, `name = default` or `name: type = default`. The type converts the passed value (§4.1).

- **A default** is evaluated in the called function at call time and sees the preceding parameters: `fn f(x, by = 2, plus = by + 1)`.
- **A call**: positional arguments first, then named ones — `name = value` or `name: value`, both forms are equivalent. A positional argument after a named one is a parse error.
- **Linking checks** every OGS function call: the number of positional arguments does not exceed the number of parameters; a named argument names an existing parameter; no parameter is given twice; every parameter without a default has a value.
- If the engine calls a handler with more arguments than it has parameters, the extra ones are dropped. If with fewer, the missing ones get their default or the type's initial value.
- A free function (at the top level or in a `module`) does not see `host`, `self` or fields. Any OGS code can call it, while the engine calls only component methods.
- Recursion is allowed. Call depth is limited to 64: beyond that it is a `StackOverflow` error and the call is aborted.
- Call limits: at most 32 positional and 16 named arguments; more is a runtime error.

### 8.1 Calling a built-in function

- Built-in functions live in reserved packages (`fighter::Damage`, `sound::Play`, §16); only the core is at the root: `print`, `str`, `EqualsIgnoreCase`. A built-in is called by its full path or by opening its package with `use fighter;` (§8.2), with exactly its case. A Classic name (`FighterDamage`) does not work in OG Script: link error `unknown function FighterDamage (did you mean fighter::Damage)`.
- The number of positional arguments is not checked, as in Classic: the built-in decides itself what to do with missing ones.
- Named arguments are accepted only by built-ins whose signature names its parameters — OpenGorky-only functions (`fighter`, `battle`, `events`, §16.11–16.13). A named argument's value is placed at the parameter's position, so **all positions before it must be filled**: `fighter::Damage(a, 5, from: host)` is an error (`kind` is skipped), while `fighter::Damage(a, 5, kind: "", from: host)` is not.
- A built-in called from a component method (or from a function it called) gets the host as the "calling object". For example, `sound::Play("a")` plays where the fighter stands, not the component; the host's name is `host.name` (OG Script has no Classic `GetName` function).
- A reference in a built-in's argument is turned into the object's name (for a component instance, `self`, into its host's name), except for `any` parameters: there it stays a reference. So `fighter::Popup(host, "…")` and `fighter::Popup(host.name, "…")` are equivalent, as are `fighter::SetTarget(avenger, killer)` and `fighter::SetTarget("grandma", "Sullivan")`. The value returned by `battle::SpawnEnemy` is already a name.
- `true`/`false` in a built-in's argument are turned into 1/0 (that is how Classic built-ins take flags), except for `any` parameters (`battle::SetVar("x", true)` stores a `bool`).
- If a built-in fails, it is a runtime error (`fighter::Damage: …`): the call is aborted, like any other. In Classic its result is 0 and a warning is written to the log.

### 8.2 How the name `f(…)` is resolved

Linking (`ogs/link.zig`) looks for the function in this order:

1. a method of the own component;
2. a function of the own namespace;
3. a function or built-in of a namespace opened with `use` (`use fighter;` opens a built-in package; if two match, it is an error);
4. a function of the root namespace;
5. a root built-in — the core: `print`, `str`, `EqualsIgnoreCase` (exact spelling).

A full name `a::b::f(…)` names exactly that function, `fighter::SetHp(…)` the built-in of the `fighter` package. If nothing is found, it is the link error `unknown function f`; if `f` is the Classic name of a built-in, the error suggests its path: `unknown function FighterSetHp (did you mean fighter::SetHp)`. Your own function may have the same name as a built-in (`fn Emit()` at the root): without a package, yours is called; the built-in is reached by the path `events::Emit`.

<!-- check: run [23, 34, 20, 11] -->
```ogs
fn scale(x, by: int = 2, plus = by + 1) {
    return x * by + plus;
}

component Calc {
    fn run() {
        // 10*2+3, 10*3+4, 10*2+0, 1*5+6
        return [scale(10), scale(10, 3), scale(10, plus: 0), scale(x: 1, by: 5)];
    }
}
```

Built-ins by path or through `use` of their package:

<!-- check: link -->
```ogs
module boss {
    use fighter;
    component Tough for fighter {
        fn OnSpawn() {
            SetHp(host, host.max_hp * 2);           // fighter::SetHp via use
            fighter::Popup(host, "Not so easy!");
            sound::Play("boss_laugh");              // package not opened: full path
        }
    }
}
```

<!-- check: error unknown function FighterSetHp (did you mean fighter::SetHp) -->
```ogs
fn f() { return FighterSetHp("Sullivan", 1); }
```

## 9. Modules and namespaces

```
module a::b { items }
use a::b;
a::b::f(…)
```

- The top of a text is the root namespace (path `""`). `module x { … }` defines namespace `x`. Nested blocks compose the path: `module a { module b { … } }` is `a::b`. Every prefix of a path also counts as a namespace (`use a;` is valid if `a::b` exists).
- `use path;` opens a namespace's names for **this block** (and only for calls from it). The namespace must exist when the text is linked: `use` of a namespace from a text loaded later is the error `use x: no such namespace`.
- The same path (`lib::id`, `abilities::Rage`) cannot be defined twice, neither in one text nor in different ones: `X is defined twice`.
- `::` always means a path, and `.` always means a field. So parsing is unambiguous without knowing all modules.
- Components are named the same way: `Rage` is looked up in its own namespace, in namespaces opened by `use`, and at the root. In rules rows (`scripts = list(…)`) the caller's namespace is unknown, so they use the root name (`Reflect`) or the full path (`abilities::Rage`).
- **Reserved packages.** `object sound actor path level hero scene gui item battle fighter events` are built-in function packages (§16), `classic` holds Classic forms (§20.1), `foundation` holds engine declarations (below). A mod cannot declare a namespace with such a first segment: `module fighter { … }` and `module classic::x { … }` are the link error `fighter: reserved package`. `use fighter;` opens a built-in package like an ordinary namespace.
- **`foundation` is the engine's namespace.** Everything the engine declares in OGS (the `engine.ogs` prelude) lives in `foundation`: built-in traits (host kinds `Fighter`, `Level`, `Battle`, `Game`…, roles `Hero`, `Enemy`, markers `Monitor`…), the enums `Side`, `ItemPlace`, `ItemKind`, `WeaponKind`, `Resistance`, `Effect`, `Gender`, `AiMode` and the structs `Place`, `Camera`, `AiProfile`, `Speed`, `Idle`, `Slot`. In **code** (function bodies, component and trait headers, parameter types) the prefix is required: `foundation::Side::enemy`, `trait Shielded: foundation::Fighter`, `x is foundation::Hero`, `x.as(foundation::Hero)`, `param foundation::Side side`. `use foundation;` in a block opens the bare names: `Side::enemy`, `: Fighter`. A bare name without it is a link error with a hint: `no trait Hero (Hero is foundation's: write foundation::Hero, or use foundation;)`, `no enum Side (…)`, `unknown function Place (…)`. The own namespace and `use` are searched first, so project names do not clash with the engine's: your own `enum Side` or `trait Enemy` in a module are ordinary declarations. **Data** is written briefly: where the type is known from the schema or field (`place = hand`, `placement = [Place(who = @Sullivan, tile = [1, 1])]`, `camera = Camera(…)`, `ai = AiProfile(…)`, `Wave(side = enemy)`), a bare name is the engine type. The words after `for` — a host kind in lowercase (`for fighter`) or a role (`for Hero`) — also need no prefix: this is not a trait reference but a header word.

<!-- check: error fighter: reserved package -->
```ogs
module fighter { fn Heal() { return 1; } }
```

<!-- check: run [3, 0, 3, 8] -->
```ogs
module lib::math {
    fn twice(x) { return x * 2; }
    fn id(x) { return x; }
}

module game {
    use lib::math;
    fn id(x) { return 0; }                  // own namespace before an opened one
    component Demo {
        fn twice(x) { return 3; }           // component method before everything
        fn run() { return [twice(1), id(2), lib::math::id(3), lib::math::twice(4)]; }
    }
}
```

## 10. Components and traits

```
component Name [for host1, host2, …] [: Trait1, Trait2, …] {
    param [type] name [= default] ["label"];
    var [type] name [= default];
    fn method(…) { … }
}
```

- **Hosts** after `for` are lowercase host kinds (`fighter`, `level`, `battle`, `area`, `item`, `weapon`, `actor`, `obstacle`, `anim`, `active_anim`, `path`, `game`, `object`) or a role (`Hero`, `Enemy`). Any other word is a link error `C for x: no such host kind`; a capitalized host kind (`for Battle`) is the error `C for Battle: a host kind is lowercase: write for battle` (there are no synonyms). Currently the engine attaches components to a fighter (`fighter`, `Hero`, `Enemy`, scripted abilities, §13) and to the game (`game`, hooks, §13.5). Level, battle and world-object events (§13.4) are called on components attached to those objects; attaching them from data blocks will be done by the OG project reader. A component without `for` is attached to a fighter, but **not** to the game. `for fighter` means "implements the built-in trait `Fighter`" (§10.4).
- **Traits** after `:` are what the component implements (§10.4).
- **`param`** is an attachment setting. Rules rows set it (`Reflect(pct = 50)`), and the editor shows it in the "Extra abilities" block. The string after the default is the field label in the editor.
- **`var`** is instance state. The editor does not show it.
- **Methods** are instance functions. Methods named after events (`OnHit`…) are called by the engine; the rest are helpers, called from code (`bump()`, `self.bump()`).
- Method names are unique (case-sensitive); field names are case-insensitive.

### 10.1 Instance

Attaching a component to a host creates an **instance**, a separate object: its variables are the component's fields, and the host is its owner. A host's instances are kept in attachment order, and the engine calls their handlers in that order.

On attachment, fields get their values in declaration order: the parameter passed by the attachment, otherwise the default, otherwise the type's initial value. A default is any expression. It sees the fields above it and the host's variables, and can call functions. A parameter the component does not have is an attachment error `C has no param p`.

How long an instance lives:

- a fighter's scripted ability (the `scripts` field of an `Abilities` row) is attached **anew each time the fighter enters a battle**: at the start of every battle its `var`s are back to their defaults;
- native abilities (§13.2) and components from a data block's `attach` live as long as the object: the battle does not remove them;
- `for game` components are attached once, when the world loads.

### 10.2 `host`, `self` and names in methods

| Form | What it is |
|---|---|
| `host` | reference to the host (the fighter; for `for game`, the game object) |
| `self` | reference to the instance itself |
| `x` | local → instance field → host variable; otherwise a runtime error |
| `self.x` | instance field; if absent, `nil` |
| `host.x` | host variable; if absent, a computed battle field (`side`, `alive`, `tile`, `asleep`, `second_turn`, `avenging`); if absent, `nil` |
| `host.name`, `self.name` | the object's name as a string, read-only (§6.6) |
| `x = v`, `host.x = v` | assign to an existing variable; if there is none, a runtime error |
| `bump()` | a method of the own component (bound statically) |
| `self.bump()`, `@obj.f()` | an object's function looked up by name at runtime |

`host` and `self` outside a component are a parse error.

<!-- check: run [11, 13, 38, "hero"] -->
```ogs
component Counter for fighter {
    param int step = 1 "Step";
    var int count = step * 10;              // the default sees the fields above
    fn bump(times = 1) {
        for i in 0..times count += step;
        host.hp -= step;                    // host variable
        return self.count;
    }
    // The host has hp = 40, side = "hero": the result is [11, 13, 38, "hero"].
    fn run() { return [bump(), self.bump(times: 2), host.hp, host.side]; }
}
```

<!-- check: run ["host", true] -->
```ogs
component Named {
    // The host in this example is named "host"; any reference has a name.
    fn run() { return [host.name, @host.name == host.name]; }
}
```

<!-- check: fault host.name is read-only -->
```ogs
component Rename {
    fn run() { host.name = "x"; }
}
```

### 10.3 Parameters in the editor

A character's "Extra abilities" block shows the parameters of attached abilities as fields: `int`/`float` are steppers, `bool` is a checkbox, `fighter` is a pick from the battles' fighters, `string` is a text field. The field label is the string from the `param` declaration.

Components attached in a block (`attach C(…)`) are shown by the editor on the block's page, with parameters by type: an enum is a drop-down list, `character` is a pick from the project's characters, a struct is field by field, `list<Struct>` is element by element (`+ Wave`, "Remove"), and `int`, `float`, `string`, `list<int>` (tile `[5, 2]`) are OG Script text. This is how a battle's `Reinforcements` waves are edited (§10.9).

A parameter of type `fighter`, `object`, `item` or `weapon` is given in a rules row by **object name** (`Avenger(avenger = "grandma")`). On attachment the name becomes a reference to the object, or `nil` if the object does not exist or is of a different kind (`grandma` is not a fighter).

### 10.4 Traits

```
trait Name [: Super1, Super2, …] {
    fn required(parameters);                 // no body: required
    fn withDefault(parameters) { body }      // default body
}
```

A trait is an interface with default bodies. A trait has no state (`var`): `var` in it is the parse error `a trait has no state (var): only param and fn`. A trait does have attachment parameters (`param`); everyone who implements it gets them (§10.5). The component holds the state, and the default bodies work through the trait's required methods and parameters. Trait names are looked up the same way as components (§9): own namespace, `use`, root.

**Built-in traits** live in the `foundation` namespace (§9): host kinds (`Object Level Battle Area Item Weapon Actor Fighter Obstacle Anim ActiveAnim Path Game`), roles (`Hero`, `Enemy`) and marks (`Monitor NoKillCredit Immobile StartsUnseen Leaves NoHands DoubleStrike`). Code refers to them as `foundation::Fighter` or, after `use foundation;`, `Fighter`; your own trait or component with the same name is not an error but a different name. Only the engine grants a role, so it is written after `for` (`component Medic for Hero`), not after `:`. `for fighter, Hero` is the error `Hero already means fighter`. A component without `for` takes its host kind from its traits (`component MirrorShield : Reflective`, where `trait Shielded: foundation::Fighter`).

**What a default body sees.** `host` is the host, `self` is the component instance. A call to a trait method (its own or a supertrait's) is **virtual**: the component's version runs if it defines one. A bare name that is not a local is the error `a trait has no fields: x (add fn x(); and define it in the component)`. A host variable is written explicitly: `host.hp`.

**The method table** is built once, at link time:

1. A method written in the component itself always wins.
2. Otherwise the body comes from the most specific trait. Trait `A` is more specific than `B` if `B` is a supertrait of `A`.
3. If two unrelated traits provide bodies, the component must define the method itself. A diamond is not a conflict.
4. A required method with no implementation is an error.
5. The same name in two traits and in the component has the same number of parameters.

`super.f(…)` inside method `f` calls the body the component would have gotten without its own `f` (in a trait body, the body from its supertraits). For a built-in event the default body is "no answer": `super.OnHit(…)` gives `nil`. `Trait::f(self, …)` calls the trait's body of `f` explicitly. The first argument is the instance, and at runtime it is checked that it implements the trait.

**Queries:**

| Form | What it gives |
|---|---|
| `x is T` | `true` if `T` is the kind of object `x` or a supertrait of that kind (`Fighter`, `Actor`, `Object` for a fighter), a role it currently has, a mark of its active component; or if `x` is a component instance that implements `T`, or an object to which such a component is attached |
| `x.as(T)` | `x` if `x is T`, otherwise `nil`; for a component trait, `x.as(T).f(…)` is `f` of the first such component |
| `x.get(T)` | the first component attached to `x` that implements `T`, or `nil`; `T` can also be the name of a native component (`host.get(Guard)`, §13.2) |
| `x.all(T)` | a list of all such components in attachment order |

`as`, `get` and `all` are language operations when the argument is a capitalized name (a trait), not a local. `get`/`all` of a role or host kind is the error `get(foundation::Hero): a role is not a component trait (host.as(foundation::Hero))`.

**A trait type** on an attachment parameter (`param Shielded ward`) and on a function parameter (`fn f(x: Shielded)`): the value is a reference to an object for which `is Shielded` holds. A lowercase host kind works the same way: `param fighter avenger`, `fn f(x: item)` accept only a fighter and only an item. A mismatched attachment parameter becomes `nil` (logged: `Bodyguard.ward: grandma is not Shielded (nil)`); a mismatched function argument is the runtime error `f: x is not Shielded`. `nil` is always allowed.

**Engine events are methods of built-in traits.** Linking checks the component's methods and trait bodies against the methods of its built-in traits: the event's parameter count (`OnHit takes 3 parameters (attacker, weapon, amount), not 2`); a component cannot define an engine method (`native`); an event without a host is an error (`Lexemes: OnHit is an engine event: name the host (for fighter)`). A name that looks like an event (`OnHitt`) gives the warning `OnHitt: no event of fighter (OnHit?)`. A role method on a `host` of another kind is an error: check the role and cast to it (`host.as(foundation::Hero)`).

Example: a shield, reflection, conflicting bodies, a mixin, a role component and a trait parameter.

<!-- check: link -->
```ogs
module abilities {
    use foundation;                                 // Fighter, Hero: engine names
    // Shield: absorbs damage while it has charge. State lives in the component.
    trait Shielded: Fighter {
        fn capacity();                              // required: how much is left
        fn spend(amount);                           // required: deduct
        fn absorb(amount) {                         // default
            var taken = amount;
            if (taken > capacity()) taken = capacity();
            spend(taken);
            return amount - taken;
        }
        fn OnHit(attacker, weapon, amount) {        // mixin: engine event
            return absorb(amount);
        }
    }

    // Reflects the absorbed damage back.
    trait Reflective: Shielded {
        fn reflect_pct();
        fn OnHit(attacker, weapon, amount) {
            var rest = super.OnHit(attacker, weapon, amount);    // Shielded.OnHit
            if (attacker != nil and attacker != host)
                fighter::Damage(attacker, (amount - rest) * reflect_pct() / 100, kind: "reflect", from: host);
            return rest;
        }
    }

    trait Armored: Fighter {
        fn absorb(amount) { if (amount > 2) return amount - 2; return 0; }
    }

    component EnergyShield for fighter : Shielded {
        param int charge = 20 "Shield charge";
        fn capacity() { return charge; }
        fn spend(amount) { charge -= amount; }
    }

    component MirrorShield : Reflective {            // host comes from Shielded: Fighter
        param int charge = 10 "Charge";
        param int pct = 50 "Percent to reflect";
        fn capacity() { return charge; }
        fn spend(amount) { charge -= amount; }
        fn reflect_pct() { return pct; }
    }

    // absorb exists in Shielded and in Armored: the component must define it itself.
    component Bulwark for fighter : Shielded, Armored {
        var int charge = 15;
        fn capacity() { return charge; }
        fn spend(amount) { charge -= amount; }
        fn absorb(amount) { return Armored::absorb(self, Shielded::absorb(self, amount)); }
    }

    // A mixin with no state of its own.
    trait Explodes: Fighter {
        fn blast();
        fn OnDeath(killer) {
            if (killer != nil and killer.alive) fighter::Damage(killer, blast(), kind: "explosion", from: host);
        }
    }
    component Barrelman for fighter : Explodes { fn blast() { return 12; } }

    // Only while the host is a hero.
    component Medic for Hero {
        param int heal = 5 "Heal at the start of its turn";
        fn OnTurnStart(side, turn) { if (side == host.side) host.hp += heal; }
        fn OnLevelUp(level) { heal += 1; }
    }

    // Trait parameter: the inspector offers only fighters with a shield.
    component Bodyguard for fighter {
        param Shielded ward "Whom to shield";
        fn OnTurnStart(side, turn) {
            if (side != host.side or ward == nil or not ward.alive) return;
            for s in ward.all(Shielded) if (s.capacity() == 0) fighter::Popup(ward, "Shield empty");
            if (ward is Hero and ward.as(Hero).party_slot() == 0) fighter::Popup(host, "Covering the leader");
        }
    }
}
```

A virtual call, `super`, the full form and queries at runtime:

<!-- check: run [30, 3, true, true] -->
```ogs
trait Stepper {
    fn step();                              // required
    fn bump(x) { return x + step(); }       // step() is the component's version
}

component Twice : Stepper {
    fn step() { return 2; }
    fn bump(x) { return super.bump(x) * 10; }
    fn run() { return [bump(1), Stepper::bump(self, 1), host is Stepper, host.get(Stepper) == self]; }
}
```

<!-- check: error Bulwark: absorb has defaults in Shielded and Armored: define it -->
```ogs
trait Shielded: foundation::Fighter { fn absorb(amount) { return amount; } }
trait Armored: foundation::Fighter { fn absorb(amount) { return 0; } }
component Bulwark for fighter : Shielded, Armored { }
```

<!-- check: error host.inventory(): host is fighter, inventory is Hero's (if (host is foundation::Hero) host.as(foundation::Hero).inventory()) -->
```ogs
component Greedy for fighter { fn OnSpawn() { var xs = host.inventory(); } }
```

The built-in traits, their methods and types are declared in OGS itself, in the repository's `foundation/` folder (`traits.ogs`, `types.ogs`, `hosts.ogs`); the engine reads them on first access (`src/script/traits.zig`, `src/script/hosts.zig`), and there is no copy in Zig. The text of the traits and types is the prelude `engine.ogs` (namespace `foundation`), the first text of the program. Only there are built-in declarations allowed: `role trait Hero : Fighter "…"`, `mark trait Monitor`, `trait Level : Object for level`, and for a method `[native] [live] [rule] fn Name(parameter "meaning") "when" [default "no answer"] { default body }` (each text in English: OG Script has one documentation language). The editor shows engine declarations in Help (F1), in go-to-definition and in hints as `foundation::…`, read-only; the asset tree shows only the project's traits.

The `foundation` namespace next to your own names:

<!-- check: run ["left", "enemy", true] -->
```ogs
enum Side { left, right }                           // own enum: the name is not taken by the engine
component Mixed for fighter {
    fn run() { return [Side::left, foundation::Side::enemy, host is foundation::Fighter]; }
}
```

<!-- check: error no trait Hero (Hero is foundation's: write foundation::Hero, or use foundation;) -->
```ogs
component C for fighter { fn f() { return host is Hero; } }
```

**Roles.** Only the engine grants and removes them (`world/party.zig syncRoles`):

- **`Hero`** is held by a party hero (one on the heroes panel): from the start of a location, on joining the party (`hero::SetInParty(h, 1)`, in Classic `HERO_EnableEnumerate(h, 1)`, `SETHERO`), and after loading a save. In a battle it is also held by any fighter on the heroes' side, including an ally outside the party (the singer on the barge); such an ally loses the role at the end of the battle. Leaving the party removes the role.
- **`Enemy`** is held by a fighter on the enemies' side while a battle is on: it is granted on entering the battle (after its components are attached, before `OnSpawn`) and removed at the end of the battle, before the `OnBattleEnd` hook.

A `for Hero` or `for Enemy` component is always attached to the fighter, but is **active only while the host has the role**: an inactive one receives no events, is not visible to `is`/`get`/`all`, its marks have no effect, and its `var`s are kept. When the role is granted, the engine calls `OnRoleGained(role)` on the components that are now active (the newly active ones among them); when it is removed, `OnRoleLost(role)` on those still active. `role` is the string `"Hero"` or `"Enemy"`. If the role was already there before attachment (a party hero enters a battle), `OnRoleGained` is not called.

**Engine methods of roles** (the prelude's `native fn`) are executed by the engine and are read-only; they are called through the role: `if (x is foundation::Hero) x.as(foundation::Hero).party_slot()`. On an object without the role the call is the runtime error `party_slot: kid is not Hero`.

<!-- traits-doc: roles -->
| Method | What it gives |
|---|---|
| `Hero.inventory()` | the hero's items, in world order |
| `Hero.equipped(place)` | what is in hand (hand) or worn (armor), or nil |
| `Hero.party_slot()` | the place on the panel from 0; nil outside the party |
| `Hero.skill(weapon)` | the skill level with a weapon |
| `Enemy.ai_profile()` | the fighter's AiProfile name |
| `Enemy.forced_target()` | the target it is forced on, or nil |
| `Enemy.reward()` | the experience for killing it, by the engine's rules |
<!-- /traits-doc -->

The `experience` and `level` fields exist on any fighter: `host.experience`.

### 10.5 Trait parameters

```
trait Name { param [type] name [= default] ["label"]; … }
```

A trait can declare an attachment parameter. Every component that implements the trait (directly or through a subtrait) gets it: the parameter is placed among the instance fields before the component's own fields (the most general trait's parameters first), and it is set by `attach`, rules rows and the editor, like the component's own `param`. A component can declare a `param` with the same name to change the default (and the label); a `var` with that name is the error `C: n is a param of T`. A default body sees its trait's parameter by name, like a field.

<!-- check: run [true, false, 5] -->
```ogs
trait Paced {
    param int every = 2 "Every Nth turn";
    fn due(n) { return n % every == 0; }        // the trait parameter is an instance field
}
component Slow : Paced { param int every = 3; }  // own default
component Probe : Paced {
    fn run() { return [due(4), due(3), every + 3]; }
}
```

### 10.6 Structs: `struct`

```
struct Name { type field [= default] ["label"]; … }
```

A struct is data only, with no methods (`fn` in it is the error `a struct is data: no fn`). A field type is required: a built-in one (`int`, `string`…), `character` (a fighter archetype), a trait (`foundation::Fighter`), another struct, an enum (§10.7) or a list `list<T>` (§10.8). A field without a default is required. Struct names, like everything else, follow namespaces (§9) and are case-sensitive.

- **A value** is written as a call with named fields: `Spawn(who = ~c"characters::grandma_child", tile = [5, 2])`. A positional argument is `S: a struct takes named fields (f = v)`, an unknown field is `S takes a, b, c`, a missing required one is `S needs a`, a field given twice is `S: a given twice`, a literal of the wrong type is `S.a: expected int`. All of these are link errors.
- **A field** is read with a dot: `w.turn`. An unknown one at runtime is the error `no field x`.
- At runtime a struct value is a dictionary of its fields (in declaration order); equality is by identity, as with dictionaries.
- `@name` in a field of type `object` or `string` is an object name (the object may not exist yet: `Place(who = @Medusa)`).
- **`character`** is a fighter archetype (a struct field or a component parameter, like `character fighter` of `battle::SpawnEnemy`): the value is `~c"characters::grandma_child"` (a `fighter` block of the project, checked at link time); in data, the block path without the sigil also works (`who = characters::grandma_child`). A string without `~c`, another sigil, a number or a list is the error `S.who: expected character (~c"…")`. At runtime the value is the path string. The editor offers a pick from the list of characters.

<!-- check: run [3, "enemy", [5, 2], 1] -->
```ogs
use foundation;
module characters { fighter grandma_child { } }
struct Spawn {
    character who "Who";
    list<int> tile "Tile";
    int count = 1 "How many";
}
struct Wave {
    int turn "Turn";
    Side side = Side::enemy "Whose side";
    list<Spawn> spawn "Who appears";
}
component Waves {
    fn run() {
        var w = Wave(turn = 3, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [5, 2])]);
        return [w.turn, w.side, w.spawn[0].tile, w.spawn[0].count];
    }
}
```

<!-- check: error Wave needs turn -->
```ogs
struct Wave { int turn; }
fn f() { return Wave(); }
```

<!-- check: error Spawn.who: expected character (~c"…") -->
```ogs
struct Spawn { character who; }
fn f() { return Spawn(who = "grandma_child"); }
```

### 10.7 Enums: `enum`

```
enum Name { value ["label"], value [= number] ["label"], … }
```

A comma after the last value is allowed. The label is shown by the editor (in a drop-down list); the value's name is what gets stored. Labels of your own enums are shown as written (UTF-8); labels of prelude types (`foundation::Side`, `foundation::ItemPlace`…) are English (ASCII) in the prelude, and the editor shows them in the interface language (`src/editor/text.zig`, `prelude`): `Side` is "Heroes", "Enemies", "Civilians".

- **A value** is written `Side::enemy` (an engine enum is `foundation::Side::enemy`, or `Side::enemy` after `use foundation;`). Where the type is known, in data (a block field, an `attach` parameter, a struct record field), it can be written short: `Wave(side = enemy)`. In code it is always the full `Side::enemy`; a bare name where an enum is expected is the error `Wave.side: write Side::enemy`.
- At runtime the value is the string of its name: `str(Side::enemy)` is `"enemy"`. So it equals the string the engine passes (`OnTurnStart(side, …)`: `side == Side::enemy`; linking does not check an untyped parameter).
- `Side::from("enemy")` is the value by name, or `nil` if there is none.
- **Equality only**: `==`, `!=`. `<`, `>` on an enum is `Side: an enum compares with == and != only`; comparing two different enums is `comparing Side with Trigger`, an enum with a number is `comparing Side with a number`, with a string is `comparing Side with a string` (a literal `"enemy"`, `str(…)`, a parameter or field of type `string`; if you need a string, use `str(Side::enemy) == "enemy"`). These are link errors wherever the type is visible: a value `E::v`, `E::from(…)`, a parameter or field declared with that type.
- `= number` is what gets written into an engine object's integer field (`ItemPlace`: `hand = 11`). Your own enums do not need a number.

**Prelude types** (`engine.ogs`, namespace `foundation`, §9): `Side { hero, enemy, civilian }` are the battle sides; `ItemPlace`, `ItemKind` are an item's `place` and `kind` fields; `WeaponKind` is a weapon's `damage_kind` field (damage kind: `fire`, `bullet`, `melee`, `explosion`…); `Resistance` is resistances (`resist = [fire, gas]` of a `Resist` row, and on a fighter its `immunity = Resist(…)`: `fire electricity attract energy freeze tranq gas flammable`); `ArmorClass` is a monster's armor class (`armor = medium;`: `light medium heavy none`; for a hero `armor` is points, a number); `Effect` is hit effects (`effects = [sleep]` of a `WeaponClass` row: `burn freeze gas soak defend sleep bite`); `Gender` is an actor's `gender`; `AiMode` is a fighter's `ai_mode`; the structs `Place`, `Camera`, `AiProfile`, `Speed`, `Idle`, `Slot` are OG reader records (§11). In code: `foundation::Side::enemy`, `foundation::Place(…)` or `use foundation;`; in data, short (`place = hand`, `[Place(…)]`). Your own type with the same name (a project `enum Side`) is a different type and does not interfere with the engine.

<!-- check: run ["enemy", true, "hero", nil, true] -->
```ogs
use foundation;
enum Trigger {
    turn_start "Turn start",
    turn_end "Turn end",
    enemy_dies "Enemy death",
}
component Sides {
    fn run() {
        var t = Trigger::turn_end;
        return [Side::enemy, t != Trigger::turn_start, Side::from("hero"), Side::from("nobody"), Side::from("enemy") == Side::enemy];
    }
}
```

<!-- check: error comparing Side with Trigger -->
```ogs
enum Trigger { turn_start, turn_end }
fn f() { return foundation::Side::enemy == Trigger::turn_start; }
```

<!-- check: error comparing Side with a string -->
```ogs
fn f() { return foundation::Side::enemy == "enemy"; }
```

### 10.8 Typed lists: `list<T>`

The type of a parameter, field or function parameter can be `list<T>` (`list<int>`, `list<Wave>`, `list<list<int>>`). A `[…]` literal of such a value is checked at link time: every element is a `T` (a literal of the wrong type, a struct of another kind, or a word not in the enum is an error). A value computed at runtime is not checked. The list itself is immutable, as before.

<!-- check: error C.tiles: expected int -->
```ogs
component C { param list<int> tiles = [1, "two"]; }
```

### 10.9 Example: battle reinforcements, `Level.Placement()`

A battle component with a parameter that is a list of structs. The attachment in the battle block sets the waves as data; enum values are short (`side = enemy`) because the field type is known. In the OpenGorky project, `battle::SpawnEnemy` takes a fighter archetype (`~c"characters::grandma_child"`): the fighter is created from its block, with its nested weapons (object `grandma_child`, then `grandma_child_2`…). This example is in the test project (`src/tests/og/port`, scenario `regress.sh reinforce`).

<!-- check: link -->
```ogs
use foundation;                                     // Side is an engine enum
module characters { fighter grandma_child { } }

enum Trigger {
    turn_start "Turn start",
    turn_end "Turn end",
}
struct Spawn {
    character who "Who";
    list<int> tile "Tile";
}
struct Wave {
    Trigger when = Trigger::turn_start "When";
    int turn "Turn";
    Side side = Side::enemy "Whose side";
    list<Spawn> spawn "Who appears";
}

component Reinforcements for battle {
    param list<Wave> waves = [] "Waves";
    fn OnTurnStart(side, turn) { arrive(Trigger::turn_start, side, turn); }
    fn OnTurnEnd(side, turn) { arrive(Trigger::turn_end, side, turn); }
    fn arrive(when, side, n) {
        for w in waves
            if (w.when == when and w.turn == n and w.side == side)
                for s in w.spawn battle::SpawnEnemy(s.who, s.tile[0], s.tile[1]);
    }
}

battle "01__port_citadel" {
    attach Reinforcements(waves = [
        Wave(turn = 3, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [5, 2])]),
        Wave(turn = 5, side = enemy, spawn = [Spawn(who = ~c"characters::grandma_child", tile = [4, 2])]),
    ]);
}
```

**`Level.Placement()`** is a method of the level trait (and of battle): where the level's actors stand, a list of `Place`. The engine calls it once at level start, before `OnRestore` (`world/start.zig`), and places the actors according to the answer. The default body in the prelude is `return host.placement;` (the block's `placement` field). The level's code (its block's own code, `logic.ogs`) can answer with its own list; `super.Placement()` gives the default:

<!-- check: link -->
```ogs
battle "01__port_citadel" {
    fn Placement() {
        var all = super.Placement();                 // the block's placement field
        if (all == nil) return [foundation::Place(who = @Sullivan, tile = [1, 1])];
        return all;
    }
}
```

## 11. Data blocks

```
kind name [: archetype] { import block; injects Trait, …; field = value; attach Component(param = value); fn Event() { … } kind name { … } }
```

**`import block;`** — this block is the same game object as the named one (`import characters::c_nato;`; a level object is named by a string, `import "03_museum_forgotten/03mf_cardyellow";`; if the path holds several blocks besides this one, add the kind: `import characters::medusa<fighter>;` — without it the build lists the candidates): it takes that block's number, texts, rules rows and (for a module block) the values not given here: numbers and strings, `look`, enumeration words, `class`, `action`. There is no need to repeat them; to not take `look`, write `look = nil`. One per block. **`injects A, B;`** — traits of the block's own code; without `fn` the block gets their default methods (`weapon pistol { injects items::ItemClass; … }`).

**A block's own code** — `fn` directly in the block: `hero slavsky { look = looks::slavsky; fn OnCreate() { turn_speed = 0.2; } }`. This is the block's own component: its name is the block's name, its host is the block's kind (for `hero` — `fighter`), it is attached first, without `attach`; the block's variables and the host's fields are visible in it by name, as in any component. Instances and descendants (`fighter "05lc_nato1": characters::c_nato`) get it together with the archetype. `attach` is for shared components with parameters (`Reinforcements`, `Calm`). The converter writes Classic class code this way when the component has no traits and no fields of its own and nothing else attaches it; everything else (item and weapon components with the `items::ItemClass` trait, level objects) remains a component with `attach` for now.

These are declarative descriptions of entities: fields, attachments, nested blocks and (in `scene` and `dialog`) commands, with no statements. A block starts with two words in a row (kind and name) or with a word and a string: a name that is not an identifier is written as a string (`battle "01__port_citadel"`, `level "01_port"`).

- **Kind** — one of `fighter item weapon actor area anim active_anim level battle obstacle path look scene dialog speaker game`. Any other word — `unknown block kind X`.
- **Name** of a top-level block — a path in its namespace (`characters::grandma`). The same path of the same kind twice — `fighter characters::grandma is defined twice`. Blocks of different kinds may share a name: the battle and the dialog `01__port_citadel`.
- **Archetype** after `:` — a path to a block of the same kind: `fighter grandma_child1: characters::grandma_child`. If there is none — `no fighter characters::grandma_child`.
- **Nested blocks** — objects inside a battle, level or fighter, in order: `weapon gun: weapons::pistol { place = hand; }`. An archetype is a whole prototype: an instance also gets the nested blocks of its archetypes (the most distant first), and the object is named `<instance>_<name>` (the archetype's `weapon gun` on fighter `grandma_child1` is the object `grandma_child1_gun`). An own nested block of the same kind and name replaces the inherited one (and takes its object's name).
- **Fields** are checked against the schema of the kind's host (`src/core/schema.zig`: `fighter` — `fighter`, `battle` — `combatlevel`, `area` — `activearea`…). No such field — `fighter has no field hpp`. A value of the wrong type — `hp: expected int`: an `int` takes an integer (or `true`/`false`), a `float` takes a number, a `string` takes a string, a sigil or `@name`.
- **Enumerations**: `place` (`gone ground backpack hand armor party`) and an item's `kind` (`other ammo medicine armor`), a weapon's `damage_kind` — the damage type (`none fire freeze electricity teargas gas bullet melee tranq energy attract explosion flammable`), an actor's `gender` (`male female`), a fighter's `ai_mode` (`free target passive guard`) are written as words — these are values of the prelude enumerations `ItemPlace`, `ItemKind`, `WeaponKind`, `Gender` and `AiMode` (§10.7), and their numbers are what goes into the object's field; other numbers are allowed too. An unknown word — `place: ItemPlace has no value handd`.
- **Flags** — fields the exe reads as 0/1 (`shadows`, `boss`, a level's `perspective`, `movable`, `explosive`, `move_locked`, `attack_locked`, `outside_party`, `resist_*`, `visible`, `secondary`, `long_attack`, `hint_hidden`, `examine_hidden`, `one_shot`), are written `true`/`false`; the object's field gets 1/0 (a number is allowed too). Field names are English words in `snake_case`; for game objects these are the fields of its base classes under new names (`charSize` — `footprint_tiles`, `aicAttack` — `ai_attack_weight`, `prGas` — `resist_gas`…): only the Classic reader and writer know the old names.
- **References**: a path to a block as a value. A schema reference field requires a block of its own kind: `blast_weapon = weapons::barrel_blast` (a weapon), otherwise `blast_weapon: no weapon weapons::x`. A path anywhere else in data must name some block of the program, otherwise `no block speakers::HQ`.
- **Weapon ammo** — a reference to an item archetype: `ammo = ~i"items::riffleammo";` (only the `~i` sigil, otherwise `ammo: expected an item (~i"…")`; no such item — a sigil error). A weapon that is used up itself (a grenade) — `thrown = true;` (only `true`/`false`, otherwise `thrown: expected true or false`); neither — no ammo needed. `ammo` is not written as a number in OG Script: the project reader itself puts a number into the weapon object's `ammo` field — the `classic_id` of the item from `ammo` (its own field or that of the nearest archetype), `-1` for `thrown = true`, `0` for `thrown = false`; the core counts ammo by it. The converter writes an `ammo` reference instead of a positive Classic `ammoUsed`, `thrown = true` instead of `-1`, and writes nothing for zero.
- **Weapon hit effects** — weapon fields (in Classic this is the `FxAs` rules row; OpenGorky has none): `effects_from` — all effects (flash, projectile, hit) of another weapon of the game, `flash_from`, `launch_from`, `hit_from` — a single stage (`-1` — none), `hit_sound = "s_expl1";` — the hit sound (takes precedence over `WeaponSound`). A stage value is a reference to a weapon archetype `~w"weapons::rocket_launcher"` (otherwise `effects_from: expected a weapon (~w"…") or a classic_id`) or a classic_id (a number with no block may only be the number of a built-in effect or of a `WeaponFx` row, otherwise a warning: `hit_from = 5555: no block has that classic_id, nor is it a built-in effect (WeaponFx): the stage shows nothing` in `gorky-tool build`, and the same in Russian on the editor's "Problems" tab); the project reader puts the number into the object. Stages take precedence over `effects_from`, and the fighter's `MonsterAttack` row takes precedence over weapon fields. The converter moves each `FxAs` row into weapon fields: a row keyed by classic_id goes to every weapon block with its own `classic_id` of that number, a row keyed by class goes to its archetype (`as` → `effects_from`, `flash`/`launch`/`hit` → `…_from`, `sound` → `hit_sound`); a number that belongs to exactly one archetype is written as a reference. An `FxAs` row is not read in an OpenGorky project (warning).

<!-- check: link -->
```ogs
module weapons {
    weapon riffle_fire {
        effects_from = ~w"weapons::riffle";
        launch_from = ~w"weapons::rocket_launcher";
        flash_from = -1;
        hit_sound = "s_expl1";
    }
}
```

- **Entity texts**: `name = "Grandma";` — its name in the game (the hint on an area), `examine = "…";` — what examining it says (an item, weapon, area). Only a string (`name: expected a text ("…")`). The project reader puts them into the core's texts by the block's `classic_id` (its own or its archetype's) over the `UiText`/`Examine`/`AreaExamine` rows of the same number; they do not become an object variable. The converter writes them to every block with its own `classic_id` (an instance without its own number gets the archetype's texts); interface words and numbers that belong to no block stay as `UiText` rows. Items, weapons, obstacles, actors and level areas sharing one `classic_id` (two or more) are instances of one archetype (see below), so their text is written once, on the archetype; the editor edits a number's text on all blocks that own it.
- **Archetype names** — without the kind prefix of the Classic file name: `classes\cw_axe.s` → `weapons::axe`, `ci_food.s` → `items::food`, `ca_riffleammo.s` → `items::riffleammo`, the battle device `ft_time_bomb.ss` → `characters::time_bomb` (prefixes `cw_ ci_ ca_ ft_ wp_`). A name already taken in the namespace (by a hero, by a class earlier in the archive, by another archetype) is replaced with a synonym (`box` → `crate`), otherwise with the next name from the candidate list (below), and only then gets `_2`, `_3`… — the converter writes a report line about it (`archetype items::box taken, named items::crate`). Code and rules name an archetype by path: `item::NewWeapon("01p_axe1", "weapons::axe")`; a battle device is a field of the archetype itself: `fighter time_bomb { device = Device(kind = time_bomb, prefix = "TimeBomb", timer = 2); }`.
- **Monster archetypes** are extracted by the converter from the Classic `ft_*.ss` and `wp_*.ss` fragments (`ft_garcia.ss` → `characters::garcia`, `wp_garcialong.ss` → `weapons::garcialong`): a field that all instances set moves to the archetype with the majority value (more than half), variables and the component do so when they are the same for all; an instance writes only what is its own (`fighter "01bg_garcia1": characters::garcia { tile = [6, 22]; }`). A weapon that is the same for all instances and comes right after the fighter (`<fighter>_<x>`) becomes a nested block of the archetype (`weapon la: weapons::garcialong { }`): the reader makes it the object `<instance>_la` right after the fighter, as in Classic.
- **Level object archetypes**: level objects of kind `item`, `weapon`, `obstacle`, `actor`, `area` without an archetype that share one `classic_id` (greater than zero, two objects or more) are likewise folded by the converter into an archetype `items::…`, `weapons::…`, `obstacles::…`, `actors::…`, `areas::…` (file `src/<namespace>/<name>.ogs`) — by the "all of them, majority value" rule; the position (`x y z angle approach_x approach_y approach_angle pos_x pos_y`) and the map area `areaName` always stay with the instance. The name is the first free one of: the common beginning of the object names without the level prefix, the `_itm`/`_are` suffix and digits (`03mf_matrix`, `04c_matrix` → `items::matrix`; the majority's name if it starts the same way: `exit2city`, `exit_two2city` → `areas::exit2city`), the common ending (`01pr_mcrate1`, `03lr_wcrate2` → `obstacles::crate`), the majority's name (`01ps_exit2port` ×5, `worker_exit_are` → `areas::exit2port`), the majority's model (`mesh = "nato"` → `actors::nato`), `<kind>_<number>` (`areas::area_233`). A taken name is first replaced with a synonym: the level boxes `box_01_itm`, `box_02_itm` → `box`, taken by the class `ci_box.s` (it holds the box code) → `items::crate`: `item box_01_itm: items::crate { x = 1964.6157; … attach locations::_01_port::box_01_itm(); }`. Texts (`name`, `examine`) and `classic_id` are written once, on the archetype: `obstacle crate { classic_id = 1017; name = "Crate"; attach crate(); }`, instance `obstacle "01pr_mcrate1": obstacles::crate { var string mesh = "skrzynia_metalowa"; … tile = [8, 18]; }`.
- **Heroes** — `hero` blocks: the starting party (Classic `gamestart\*.hro`: `hero sullivan`, listed in `party` of the `game` block) and level heroes (a location's `.hro`: `bt` in the port, `kozov` in the city) — characters `characters::<name>` (`characters/bt.ogs`: description and component); on the level only where they stand: `hero bt: characters::bt { x = 1140.0; … }`. Hero objects live across locations (a shared hero list, as in the exe), even outside the party. `fighter` — all other fighters (monsters, enemies). A fighter's archetype may also be a hero: `fighter x: characters::sullivan` — an opponent made from a hero (the test room, a fighter placed by the editor); for a path with both blocks (`fighter medusa` and `hero medusa`) the instance takes the block of its own kind.
- **Shared class code** — traits. A class file that others include (`#include Item.s`, `ci_box.s`) and that has functions becomes a trait with default bodies (`items::ItemClass`, `items::Box` — in the archetype's file next to its block and component; without an archetype — `classes::<Name>`); the object's component implements it and holds only its own code: `component box_01_itm for item : items::Box, items::ItemClass { fn OnCreate() { … } fn OnFirstOpen(hero = nil) { … } }`. A trait is made only if it gives each such object the Classic behavior (all have the same version of each function of the file, the same number of parameters, and the file's words mean the same thing); otherwise the code stays in the component. A function nobody calls (`dump()` from `gameobject.s`) and empty events that the engine calls only if they exist (`fn OnCamera() { }`) are not written.
- **Action** of an item and of an area (its menu entry) — the name of an `Action` rules row, as a word (action names are identifiers, like weapon classes): `action = Take;`; for an area `action1 = Down;`… — the following menu entries (the elevator's second button). Without a row — the words: `none` (a click just walks to the object; Classic `0`) and `walk` (an exit without the examine menu; an area with `WalkPath` leads along the path; Classic `-1`). OG Script accepts no numbers or strings: `action: expected an action's name (Take), none or walk`. The project reader puts the row's number into the object's field (`classic_id`, Classic `funcID`), and the core finds the action by it; no row with that name — the load error `no rules Action X`. Only built-in `Action` rows have a `classic_id` (it selects the menu text from `string.tab`); the reader gives a new project row a free number, and its menu text is its name (or `text`). The converter writes the row's name as a word instead of the `funcID`/`funcID1` number, and `-1`/`0` as words; a box (`.obs_i`) keeps its number in the variable `var int action` — its code changes it.
- **Weapon class** — the name of the `WeaponClass`/`Pattern` rules rows, as a word: `class = pistol;` (likewise `attack_zone = shotgun;` — whose range and hit tiles to use). A number — `class: expected a weapon class's name (pistol)`. The project reader puts the class number into the object's field (Classic `classType`): the row's `classic_id` (for built-in classes), a free number for a new name, one for both `WeaponClass` and `Pattern`; no row with that name — the load error `no rules WeaponClass X`. The exe's class names are the `WeaponClass` tags in `src/battle/weapon_class.zig` (`pistol`, `rifle`, `melee`, `garcia_long`…).
- **Records** `Name(field = value, …)` — data (`points = [Point(name = "p1", x = 512, y = 388)]`), with named fields only: `Point: a record takes named fields (f = v)`. If `Name` is a declared struct (§10.6: your own or the prelude's — `Place`, `Camera`, `Speed`, `Idle`, `Slot`), this is its value: field names and types are checked; for others they are not.
- **Placement, look, camera are data** (the OG project reader reads them when a level starts, `src/world/start.zig`, as Classic does with `PlaceActor`, `act_*.ss`, `initCamera()`):
  - `look = looks::grandma;` on an actor or fighter — a `look` block (otherwise `look: no look …`). Its fields `mesh`, `portrait`, `turn_speed` go beneath the fields of the archetype and the instance; `walk = [Speed(anim, speed)]`, `idles = [Idle(state = 0, anim, weight)]`, `slots = [Slot(state = 0, name, anim)]` correspond to `ActorSetWalkSpeed`, `RegisterIdleAnimation`, `RegisterAnimation`; a hero also has `not_in_place = ["…"]` and `reference = "…"` — `NotInPlaceAnimation`, `ReferenceAnimation` of its `postinit()`. With no own `look`, the nearest archetype's is used.
  - `tile = [x, y]` (or `[x, y, direction]` in eighths of a turn) on a fighter, actor or obstacle (`obstacle`) in a battle — its tile (`PlaceActor(name, x, y, dir)`); only its own, not the archetype's.
  - `at = [x, y, angle]` on an actor or obstacle in a battle — a place on the grid in fractions of a tile and an angle in degrees (`battle::PlaceProp`, `PlaceCombatActor`: this is how logs and pipes stand between tiles); a disabled object is placed too, as with that call.
  - `camera = Camera(perspective = true, eye_x = …, target_z = …, fov = 48, floor_z = …)` on `level`/`battle` — the level camera's fields (`perspective near_plane far_plane ortho_rotation_radians eye_x eye_y eye_z target_x target_y target_z fov floor_z camera_scale aspect_ratio camera_bank`; the debug triangle `ctrlPoint1X` … `ctrlPoint3Z` is Classic-only: nobody reads it, OG does not carry it over).
  - `placement = [Place(who = @Sullivan, tile = [1, 1]), Place(who = @Sullivan, at = "capt_start1", point = 0)]` on `level`/`battle` — placement before `OnRestore`: on a tile or on an area's point (`floor = 1` — the map's second floor). First `placement`, then the `tile` of nested blocks, then their `at`. The same happens on every return to a saved location (before its `OnRestore`, as Classic runs `restore()` again). The converter moves here the unconditional `PlaceActor`/`PlaceCombatActor` calls with constant arguments from the `restore()` of a battle and of a location (up to the first other instruction; `AIEnemyAppear` does not interrupt; `PlaceActor` on an area point becomes a `Place` in `placement`); the rest stay as `OnRestore` code — the count is in the output of `gorky-tool convert`: `battle placing as data N (left code M), location placing as data N (left code M)`. The field's type is the prelude's `list<Place>`; the engine takes the placement with a single call of the level method `Placement()` (§10.9): without an override this is just the `placement` field.
  - `entry = "capt_start";` on `level` — the entry point: on every entry into the location and every return to it, the selected hero stands on the point of this area (point 0, floor 0) — right after `placement` and `tile`, before `OnRestore`, like the Classic call `PlaceActor(GUI_GetSelectedHero(), "capt_start", 0)` at the start of `restore()` (the camera jumps to the hero; a disabled or absent hero is left alone). Only a string (`entry: expected a point's name ("capt_start")`). The converter moves such a call into `entry` if everything before it in `restore()` has already become data; placement after it stays as code — the count `entry points as data N` is in the output of `gorky-tool convert` (9 in the game). The editor writes it on the location page ("Hero entry": the level's areas).
  - Errors — `file:line`: `tile: expected [x, y] or [x, y, direction]`, `entry: expected a point's name ("capt_start")`, `camera: Camera takes perspective, …`, `placement: Place needs who`. The build (`gorky-tool build`) also checks the `idles`/`slots` animations against the model `models/<mesh>.ani`: `look grandma: no animation throw in models/grandma.ani`.
- **`var int ponton = 1;`** in a block — an object variable of its own beyond the schema fields (a Classic class variable): it is declared with its type before the block's fields; a schema field's name cannot be declared this way (`fighter has field hp: no var of that name`). OpenGorky-only fields (`explodable`, `ai`, `attack_zone`…) exist on an object only if the block or an archetype sets them: without them the engine does the same as Classic (a barrel explosion by `classic_id`). A monster's resistances and armor class are only its `immunity = Resist(…)`: the fighter has no separate fields (the converter moves the `resist`, `armor_class` fields of the Classic generic fighter into it).
- **Level trigger** — a variable of the `level` block plus a code block: `var bool ready_trigger1 = true;` in `level.ogs` (it is visible in the level's "Fields") and, in `OnUpdate()` of the level block's own code (the `level "x" { … }` part in `logic.ogs`), `if (ready_trigger1 and hero::AnyInArea("trigger1")) { ready_trigger1 = false; … }` — fires once. This is what the editor writes (new trigger area). The converter moves a Classic trigger (`var int readyF01 = 1;`) into a level component named after the area, in its own file (`fight2_place.ogs`: `component fight2_place for level { fn fight2_place() { if (readyF02 and hero::AnyInArea("fight2_place")) { … } } }`, attached in `level.ogs`), and `OnUpdate()` calls it at the original place: `host.fight2_place();` — the same checks in the same order. **Disabling a block** ("Disable block" in the trigger window) sets its variable's initial value to `false` (`0`): the block never runs, and the code is neither changed nor commented out; "Enable" restores `true` (`1`). A block without such a variable (its `if` does not start with `name and …`) or with a variable that the code sets back to non-zero somewhere cannot be disabled this way — only by editing the code.
- **`attach`** — a component by the block's namespace, with only named parameters that the component has: `no component X`, `X has no param p`.
- **`enabled = false;`** in a `scene` block — the scene is disabled: starting it (`scene::Start`, `StartNext`, a scene after a scene) does nothing, like a Classic scene whose start calls are commented out. Without the field (or with `true`) it is enabled. The editor writes it with the "Scene enabled" checkbox. OG has no short variant of a scene (the Classic "skip": a scene reduced to the calls that change the game): a scene is either played in full or disabled with `enabled = false`.
- **Commands** — calls in `scene` and `dialog` blocks (`actor::WalkTo(@Sullivan, "p1");`, `Line(…);`): data, positional arguments are allowed. In other blocks — the parse error `commands are in scene and dialog blocks only`. Scene commands are written in OG Script style, `namespace::Name` (table below, `core/scene.zig` `commands`); a Classic name (`WALKTO`) is read too, with Classic-style arguments. The code editor shows each command's parameters and what it does. Arguments by kind:
  - actor and object — a reference `@Sullivan`, `@gate1`, `@"01p_shotgun"`; the selected hero — `@hero::selected`, the hero of the last action — `@hero::last_action` (in Classic `#HERO_SELECTED`, `#LAST_ACTION_HERO`);
  - time — in seconds (`scene::Wait(0.5)`, `camera::Move("cam_1", 1.3, 1.5)`; the engine counts in ticks of 1/30 s and in hundredths, `scene::Wait(0.33)` is 10 ticks), zoom — as a factor 1.0–2.0;
  - flags — `true`/`false` (`object::Enable(@gate1, true)`, `actor::Weapon(@Ovitz, "riffle", true)` — in both hands);
  - on/off pairs — one command with `true`/`false` as the last argument: `camera::Panorama`, `camera::Auto`, `gui::Cutscene`, `gui::Input`, `actor::Idle`, `area::Walkable`;
  - dialog, level, scene, sound — by sigil: `dialog::Open(~d"port-arriving")`, `level::Load(~l"01_port")`, `scene::Add(~e"port-deska")`, `sound::Play(~s"wheel")`; a scene point, animation, area, music — by string.
  The build (`gorky-tool build`) checks commands: an unknown command, an argument of the wrong kind (`actor::Place: argument 1: expected @name (an actor)`), a pair without `true`/`false`, a state outside 0–9 are errors; things missing from the project are warnings, and the scene goes on, as in Classic: `no block @Tratigne in the project`, `no point "p2" in the scene's points`, `dialog::Say(9): dialog museum-roof has 9 lines`, `no animation touch in models/Sulivan.ani (@Sullivan's look)`. An object created by code (`sound::NewAmbient("04ce_winda_snd", …)`) counts as existing. The converter writes scenes this way; a command the exe does not have (`DIALOG_CLOSE`: there it is a "Syntax error" and the line does not run) is dropped, with a line in the output of `gorky-tool convert`. A long list of records (`points = [Point(…), …]`) is written one record per line.

| OG Script | Classic | What it does |
|---|---|---|
| `hero::PlaceAll(area, floor)` | `PLACEHEROES` | Places the whole party in the area. |
| `actor::WalkTo(actor, point)` | `WALKTO` | Queues a walk to the point; at the end turns to the point's angle. Does not wait — follow it with actor::Wait. |
| `actor::Place(actor, point)` | `PLACE` | Immediately places the actor at the point, facing its angle. |
| `scene::NoSkip()` | `NO_SKIP` | The scene cannot be skipped (space does nothing). |
| `actor::Morph(actor, class)` | `ACTOR_MORPH` | Turns the actor into another class (morph). |
| `camera::Shake(seconds)` | `EARTHQUAKE` | Shakes the camera for that many seconds. |
| `music::Play(music)` | `MP3_PLAY` | Starts music; the previous music returns after the scene. |
| `music::Fade()` | `MP3_FADE` | Fades the music out. |
| `gui::Input(on)` | `GUI_DISABLE` / `GUI_ENABLE` | Player input is on (true) or off (false: no clicks, no interface). |
| `gui::Credits()` | `GUI_CREDITS` | Shows the credits. |
| `gui::Menu()` | `GUI_MENU` | Exits to the main menu. |
| `gui::Cutscene(on)` | `GUI_CUTSCENE` / `GUI_NORMAL` | Cutscene mode (true: the player only watches and can skip) or normal control again (false). |
| `gui::EndDemo()` | `GUI_ENDDEMO` | The end-of-demo screen. |
| `gui::GameOver()` | `GUI_GAMEOVER` | The game-over screen. |
| `actor::SetState(actor, state)` | `ACTORSETSTATE` | Sets the actor's state (0 — standing, 1 — with a weapon…): its idle and walk. |
| `video::Play(video, x, y, double)` | `PLAYAVI` | Plays a video full screen (double — at twice the size). |
| `actor::Wait(actor)` | `WAITFORACTOR` | Waits until the actor's queue (walking, animations) is empty. |
| `fx::Weapon(actor, on)` | `FX_WEAPON` | The muzzle flash of the actor's weapon: 1 — on, 0 — off. |
| `fx::Voltage(actor)` | `VOLTAGE` | Electric sparks on the actor (Medusa). |
| `fx::Rocket(actor, x, y, z, weapon)` | `ROCKET` | A rocket flies from the actor's hands to the world point x, y, z: the launch of weapon `weapon` (OpenGorky; in Classic — of the rocket launcher). |
| `actor::Attack(actor)` | `ATTACK` | The actor fires the item in hand. Does not wait. |
| `actor::UseAnimation(actor, anim)` | `USEANIMATION` | A use animation (lever, door). |
| `actor::FastAnimation(actor, anim)` | `FAST_ANIMATION` | Sets the animation immediately, bypassing the queue. |
| `actor::Animation(actor, anim, count, back)` | `ANIMATION` | Queues an animation (count times; back = true — backwards). Does not wait. |
| `actor::SystemAnimation(actor, anim)` | `SYSTEMANIMATION` | A system animation of the actor. |
| `object::Call(object, function)` | `GO_RUNFUN` | Calls an object's function by name. |
| `scene::Signature(frame)` | `SIGNATURE_ON` | Shows the dated caption (a frame of intro.spr) at the bottom of the screen. |
| `scene::SignatureOff()` | `SIGNATURE_OFF` | Hides the dated caption. |
| `object::Impulse(object, time)` | `IMPULSEOBJECT` | Pushes an object (lever, console) and waits for it. |
| `anim::Move(anim, x, y, speed)` | `ABA_MOVE` | Moves a level bitmap animation. |
| `anim::Position(anim, x, y)` | `ABA_POS` | Puts a bitmap animation in place. |
| `anim::State(anim, state)` | `ABA_STATE` | Sets a bitmap animation's state (playing, stopped). |
| `anim::Wait(anim)` | `WAITFORANIMATION` | Waits until a bitmap animation finishes. |
| `scene::Wait(seconds)` | `DELAY` | Waits that many seconds. |
| `level::Load(level)` | `LOADLEVEL` | Loads a level (a battle — the fight begins). |
| `level::Back()` | `PREVLEVEL` | Returns to the previous level. |
| `dialog::Open(dialog)` | `DIALOG_INIT` | Opens a dialog (`~d"name"`: dialogs/<name>.ogs): its lines for dialog::Say. |
| `dialog::Say(line)` | `DIALOG_DISPLAY` | Speaks line n of the open dialog with voice-over and waits for it. |
| `dialog::Show(line)` | `DIALOG_SHOW` | Shows line n without waiting. |
| `camera::Panorama(on)` | `PANORAMA_OFF` / `PANORAMA_ON` | Black bars at the top and bottom (true — cinema) or none (false: they retract 2 pixels per tick; waits). |
| `camera::Auto(on)` | `AUTOCAMERA_ON` / `AUTOCAMERA_OFF` | The camera follows the party (true) or stays where camera::Move puts it (false). |
| `object::Enable(object, on)` | `DISABLEOBJECT` | Enables (true — this is how scene actors appear) or disables (false) an object. |
| `object::Delete(object)` | `DELETEOBJECT` | Removes an object from the level. |
| `actor::Idle(actor, on)` | `IDLE_OFF` / `IDLE_ON` | The actor plays idle animations (true) or stops (false). |
| `item::Give(actor, item)` | `ASSIGN_ITEM` | Gives the actor an item. |
| `actor::IdleAnimation(actor, anim)` | `IDLE_ANIMATION` | Sets the actor's idle animation (queued). |
| `actor::WalkAnimation(actor, anim, speed)` | `WALK_ANIMATION` | Sets the actor's walk animation and speed (queued). |
| `screen::FadeIn()` | `FADE_IN` | Fades in from black (10 ticks) and waits. |
| `screen::Black()` | `FADE_BLACK` | The screen turns black at once. |
| `screen::FadeOut()` | `FADE_OUT` | Fades out to black (10 ticks) and waits. |
| `actor::WalkOnTrack(actor, track)` | `WALK_ON_SCENERY_TRACK` | Leads the actor along a level path. |
| `actor::GoDown(actor, z, speed)` | `ACTOR_GOINDOWN` | Lowers (or raises) the actor to height z and waits. |
| `camera::Zoom(zoom, seconds)` | `ZOOM` | Camera zoom 1.0–2.0 over that many seconds (0 — immediately). |
| `camera::Move(point, seconds, zoom)` | `DOLLY` | Moves the camera to the point over that many seconds, zoom 1.0–2.0. |
| `actor::Weapon(actor, weapon, two_hands)` | `WEAPON` | Puts a weapon in the actor's hand (two_hands = true — in both hands); with no weapon — removes it. |
| `sound::Play(sound)` | `SOUND` | Plays a sound. |
| `area::Walkable(area, on)` | `ALLOW_WALK_IN_AREA` / `FORBID_WALK_IN_AREA` | The area can be walked in (true) or not (false). |
| `scene::Add(scene)` | `ADDONSCRIPTLET` | A scene that starts after this one. |
| `hero::SetInParty(hero, on)` | `SETHERO` | The hero joins the party (true) or leaves (false). |
| `hero::StopAll()` | `STOP_HEROES` | The party stops and looks around (fightlook). |
| `area::WalkableAt(area, floor, on)` | `WALKAREA` | Enables (true) or disables (false) a walk area of the map. |
- Kinds without a schema in the core (`path scene dialog speaker game`): field names are not checked yet; references, records and sigils in them are checked. `look` has a schema of its own (not an exe base class): `mesh portrait turn_speed walk idles slots not_in_place reference`.

<!-- check: link -->
```ogs
module weapons { weapon pistol { place = hand; max_damage = 10; } }
module characters {
    fighter grandma { name = "Grandma"; hp = 200; accuracy = 90; blast_weapon = weapons::pistol; attach Calm(by = -1); }
}
component Calm for fighter { param int by = 0; }

battle "01__port_citadel" {
    grid_columns = 10;
    fighter grandma_child1: characters::grandma {
        hp = 50;
        weapon gun: weapons::pistol { place = hand; }
    }
}

scene "port-arriv_at_port" {
    points = [Point(name = "suliv_p1", x = 512, y = 388, angle = 1.57)];
    actor::WalkTo(@Sullivan, "suliv_p1");       // commands are data, not code
    actor::Wait(@Sullivan);
}

dialog "01__port_citadel" { Line(text = "Over.", voice = ~s"01__port_citadel_hq2"); }
```

<!-- check: link -->
```ogs
module looks {
    look grandma {
        mesh = "grandma";
        walk = [Speed(anim = "walk", speed = 3.6)];
        idles = [Idle(state = 0, anim = "ryk", weight = 100)];
        slots = [Slot(state = 0, name = "long_attack", anim = "atak")];
    }
}
module characters {
    fighter grandma { look = looks::grandma; hp = 200; weapon gun: weapons::pistol { place = hand; } }
}
module weapons { weapon pistol { max_damage = 10; } }

battle "01__port_citadel" {
    camera = Camera(perspective = true, eye_x = -3.135, eye_y = 1.651, eye_z = 12.766, target_x = -10.367, target_y = -5.308, target_z = 8.261, fov = 48, floor_z = -1.89);
    placement = [Place(who = @Sullivan, tile = [1, 1])];
    fighter grandma: characters::grandma { tile = [2, 9]; }             // the weapon is the archetype's grandma_gun
}
level "01_port" { placement = [Place(who = @Sullivan, at = "capt_start1")]; }
```

<!-- check: error tile: expected [x, y] or [x, y, direction] -->
```ogs
battle b { fighter f { tile = [2]; } }
```

<!-- check: error placement: Place needs who -->
```ogs
battle b { placement = [Place(tile = [1, 1])]; }
```

<!-- check: error name: expected a text ("…") -->
```ogs
fighter grandma { name = 7; }
```

<!-- check: error fighter has no field hpp -->
```ogs
fighter grandma { hpp = 200; }
```

<!-- check: error place: ItemPlace has no value handd -->
```ogs
weapon gun { place = handd; }
```

Data blocks of an OpenGorky project (`format = ogs`) are read by the OG reader: archetypes become core records, `level`/`battle` become level objects in order (fields: schema → look → archetypes → instance, then `attach`), scenes and dialogs become blocks of their own. In the rules files of a Classic project a data block is skipped with the warning `data blocks are not read`.

The editor edits project blocks directly in `src/`: a character, weapon or item has a block page (fields per the kind's schema, attached components, nested weapons and items, look), a battle or location block is edited on its page, a battle's fighter when it is selected on the map. An edit writes **only the changed statement** (`hp = 40;`, `attach …;`, a nested block): the rest of the file's text and comments stay byte for byte. The "×" next to a field removes it from the block — the archetype's or schema's value applies again. A deleted top-level block deletes its file on save. Rules rows (`rules/*.ogs`) are edited the same way — a row by its key.

**Planned:** schemas for the `scene`, `dialog`, `speaker`, `game` kinds.

### 11.1 Identity: a path instead of a number

In an OpenGorky project a block has no number: it is named by its path (`weapons::riffle`, `characters::sullivan`). The core needs a number — the project reader (`src/loaders/ogs.zig`) provides it: a block without `classic_id` gets a number computed from its path (stable, outside the Classic number range), an instance gets its archetype's number. The converter does not write `classic_id`; the field remains allowed for hand-assigned numbers.

- **A level object without an archetype** is named `"<level>/<name>"` (`"01_port/grandhand"`) — that is how rules rows, `import` and texts refer to it; it gets a number only if it has its own text (`name`, `examine`).
- **The same thing under different blocks** — `import`: a location actor and a battle fighter, a morph (`fighter "03ch_lilith_m" { import characters::lilith; … }`), weapons sharing a number in Classic. A block with `import` takes the number, texts and rules rows of the main block; a rules row keyed by any of them applies to all. A level object is named by a string: `import "03_museum_forgotten/03mf_cardyellow";` (the battle's card is the same as the location's). The language has no `same_as` field (that is the engine-internal name of `import`): `same_as = …` is an error with a hint to write `import`.
- **`pickable = false;`** — the object cannot be selected with the cursor (decoration, a used box, an exit that is still closed; in Classic this is `classic_id = -1`). The core gives the object the number −1.
- **Party order** — the `party_order` field of the `game` block (`[characters::sullivan, characters::ovitz, …]`): whom to select when the selected hero drops out (in Classic — by number).
- **Shared party items** (the fist, the transmitter) — the archetypes `weapons::gs_fist_all`, `items::gs_transmitter_s`; their objects are in the `game` block: `weapon gs_fist_all: weapons::gs_fist_all {}`. An empty hand strikes with an ownerless weapon with `place = party` — it is also what draws the hand button's hint.
- **References in rules rows** — by path with a sigil: `MonsterAttack(fighter = ~c"characters::garcia", weapon = ~w"weapons::garcialong", …)`, in lists — in their places: `HiddenWeapons(hero = ~c"characters::hutchens", weapons = [~w"weapons::time_bomb", ~w"weapons::c_nato"])`, pairs — `Abilities(class = 17, pairs = [[~w"weapons::schizo1", ~w"weapons::schizo2"], …])`. A number in place of a reference is a Classic number: it remains where the thing has no block (Classic built-in effects).
- **Texts by path and by key**: `AreaExamine(id = "01_port_silos/01ps_trup1", text = "…")` — the text of an object that has no field of its own; interface texts are by key: `UiText(key = "miss", text = "Miss")` (keys are in `src/core/ui_text.zig`: `miss`, `luck`, `no_ammo`, `game_over`, `resist_fire`…). The row `UiText(id = N, …)` is the text of number N.
- **Code** compares the class, not the number: `object::GetClass(item) == "weapons::matrix"` (an object's class is its archetype's path; for a level object without an archetype — `"<level>/<name>"`). The converter rewrites `GetNameID(x) == N` this way: a number shared by several blocks becomes an `or`.
- **The scene command** `fx::Rocket(actor, x, y, z, ~w"weapons::rocket_launcher")` — whose rocket launch to use (without the fifth argument — the Classic rocket launcher's).

What the exe knows by name or number is data in the project: the `UiSounds` rows (`miss`, `blood` — one picked at random from a space-separated list; `walk_ok`, `walk_bad`, `inventory_open`, `inventory_close`, `silence`), `UiEffects` (morph sparks, the effect frame mesh, the explosion, marker and battle grid textures), `UiAssets` (interface sprites and fonts: panel, cursor, windows, inventory, safe, saves, credits; a font is the name `fonts/<name>.fnt`, a set is the base `<name>_1` with the language's letters), `Glow(fighter = ~c"characters::incubus")` (an actor's glow on its model's points), row fields (`Spin(…, anim = "obrot")` in `FighterStrike`, `effect` in `attach` and `cloud` — no default value). A panel button's hint is a text key: `PanelPlace(button = "inventory", …, hint = "hint_inventory")`; menu items are keys too (`menu_new_game`, `menu_back`…). The converter writes all of this from Classic's built-in values. Rules rows that name a number without a block (Classic weapons and fighters that are not in the game: Smoke Rider's second rocket 1004, the Cutter Pill bullet 89, the Shoggoth 117…) are not carried over by the converter. Likewise not carried over are texts without an owner (`UiText(id = 1004, text = "SmokeRider!!!!!!!")`) and traits nobody attaches (Classic shared class code whose values are already in block fields). A script's popup text is also by key: `actor::TextEffect(h, "no_ammo")`.

**Fighter classes are project names too.** `battle_class = smokerider` is the key of rules rows: `Abilities(class_name = "puppet", …)`, `AiProfile(class_name = "stinger", …)`. The core knows one class — `generic` (a fighter whose attacks, AI and resistances are its fields); the converter writes the other names from the Classic table, and a class of your own is just a new name. The profile that a `generic` fighter with `ai = focused` or `sleep_hunter` takes is an `AiProfile` row with `generic_ai = "focused"`. The exe's special evaluations (grandma's revenge, the Guard's hunting of sleepers, Schizo's "heroes only", Incubus's whole tiles) are code in the project: the converter writes the components `ai_scoring::Avenge`, `SleepHunter`, `HeroesOnly`, `WholeTile` (`components/ai_scoring/`), the row `AiScoring(…, occupant = "none", script = "ai_scoring::Avenge")` attaches its component to a fighter with this evaluation, and its `ScoreTile` scores the strike tiles. An evaluation of your own is a component of your own with `ScoreTile`. The AI's tile evaluation is also a data name: `AiProfile(scoring = "a")` names the row `AiScoring(eval = "a", …)`; its parts by meaning: `keep` (`all`, `by_health`, `first`, `free_arms`), `occupant` (`generic`, `a`, `no_lock`, `avenge`, `sleep_hunter`, `heroes_only`, `foes`, `none`), `tile` (`occupants`, `whole`), `wakeful`, `near`.

**Values in rules rows are OG-style.** A flag is `true`/`false`, a name from a set is a word (`effect = burn`, `kind = take`), a list of numbers is a list (`damage = [15, 10, 5]`); the old Classic forms (`1`, `"burn"`, `"15 10 5"`) are read too.

**A block's rules live in the block itself.** Rules rows that concern one character, weapon, item or battle are written as its fields; the loader itself makes rows keyed by this block from them (`loaders/rules_text.zig block_rows`), and a row with the same key in `rules/` writes its fields on top (this is how a mod overrides a block):

| Block | Field | Rules row |
|---|---|---|
| character | `report_icon = "garcia"` | `KillIcon(icon = …)` |
| character | `immunity = Resist(resist = [gas], armor = -2)` | `Resist` |
| character | `ai = AiProfile(lock = 7, …)` — on top of its `ai_profile` | `AiProfile` |
| character | `abilities = Abilities(…)` | `Abilities` |
| character | `class_ai = AiProfile(lock = 7, …)` — the class profile from the fighter's `battle_class`; fighters of one class share one (differing ones — a warning, the last one applies); the fighter's `ai` goes on top of it | `AiProfile(class_name = <battle_class>, …)` |
| character | `strikes = [MonsterAttack(weapon = ~w"…", anim = …, hit_delay = …), …]` | `MonsterAttack` |
| character | `strike_fx = [FighterFx(weapon = …, hit = …)]` | `FighterFx` |
| hero | `chatter = IdleChatter(dialog = "…")`, `hidden_weapons = [~w"…"]` | `IdleChatter`, `HiddenWeapons` |
| hero | `bonus = HealBonus(pct = 15)`, `extra_wait = true` | `HealBonus`, `WdelayHero` |
| character | `spins = [Spin(link = "pila lewa", at = 30, anim = "obrot")]` | `FighterStrike(spins)` |
| weapon | `skill_icon`, `weapon_sound` | `SkillIcon(icon)`, `WeaponSound(sound)` |
| weapon | `flags = WeaponFlags(no_counter = 1)`, `fx = WeaponFx(…)`, `hero_attack = HeroAttack(anim = …, wait = …)` | `WeaponFlags`, `WeaponFx`, `HeroAttack` |
| weapon | `class_zone = Pattern(rays = "…", effects = "…")` — the attack zone of the class from the weapon's `class` (like `class_rules`) | `Pattern(name = <class>, …)` |
| weapon | `class_rules = WeaponClass(effects = [sleep, burn], recharge = 4)` — `effects`: the states a hit inflicts, in order (Classic has a single `effect`) | `WeaponClass(name = <class>, effects = …)` |
| character | `immunity = Resist(resist = [attract, gas], armor = -2)` — resistances as a list of names: `fire electricity attract energy freeze tranq gas flammable` (synonyms `decoy`, `sleep`, `poison`…) | `Resist(fighter = …, resist = […])` |
| weapon | `class_rules = WeaponClass(recharge = 3, kind = "energy")` — the class row from the weapon's `class`; all weapons of one class share the same one (differing ones — the loader warns, the last one applies) | `WeaponClass(name = <class>, …)` |
| item | `medicine = Medicine(kind = "rage")` | `Medicine` |
| character | `class_abilities = Abilities(monitor = true, kill_credit = false)` — the class abilities from the fighter's `battle_class` (like `class_ai`); a battle's own fighter has `abilities = Abilities(invisible = true, leaves = true)` directly in its block in `battle.ogs` (a row by object name) | `Abilities(class_name = <battle_class>, …)`, `Abilities(fighter = "<object>", …)` |
| character, weapon | `device = Device(kind = time_bomb, prefix = "TimeBomb", timer = 2)` — the battle places this archetype as a device (`time_bomb`, `large_bomb`, `decoy`, `blast`) | `Device(archetype = <path>, …)` |
| game | `states = [StateEffect(effect = burn, turns = 3, damage = [15, 10, 5]), …]` — fighter states: how many turns and the damage per turn | `StateEffect` |
| game | `start = ~l"01_port"`, `leader = @Sullivan`, `intro`, `startup`, `menu_logo`, `credits`, `credits_video`, `start_area`, `start_point`, `start_scene = ~e"…"` — the start of a new game and the menu shell; the first on the party panel are the `party` heroes in `party_order` order. Without `start` the project does not build: `no game start: the game block needs start = ~l"…"` | `Campaign` |
| game | `intro = [Video(name = "introkon.avi", y = 60, double = true, caption = true)]`, `startup = [Video(name = "topware.avi", y = 80), "intro.avi"]` — videos and where to show them (`x`, `y`, `double`, `caption`; a bare name — in the corner, unscaled). The converter keeps only the videos present in the game's `avi/` folder (the exe shows those it finds) | `ExeVideo` |
| game | `music = Music(menu = "menu", credits = "credits", level_up = "…", battle_enter = "…", victory, game_over, statistics, battle = ["battle", "battle2"], boss = "battle3", enemy_suffix = "_enemy")` — all shell and battle music in one record | `ExeMusic`, `Campaign` (`menu_music`, `credits_music`) |
| game | `anims = Anims(fight_look = "fightlook", fight_look_two_handed = "g_fightlook", hide_back = "hide_back")` — animations the engine plays by itself (the hero selected in battle looks around, the weapon goes onto the back) | `ExeAnims` |
| game | `holds = Holds(one_hand = "one_hand", two_hands = "two_hands", back = "back")` — the model's hold points where the engine hangs the weapon | `HoldPoints` |
| level, battle | `music = "03_museum"` — the music of a level without its own `<level>.mp3` (Classic: the district prefix `03_museum_` for all its sublevels; the converter writes it to each such level) | `DistrictMusic(level = …)` |
| level, battle | `grid_floor = -30` | `GridFloor(z)` |
| character | `glow = Glow()` — the actor's glow (Incubus has it; `effect`, `links`, `size`, `rgb` are the record's fields) | `Glow` |
| scene | `repeat_trim = RepeatTrim(actor = "Slavsky", anim = "knee_idle")` — while the scene waits for the actor, repeats of this animation are cut short | `RepeatTrim` |
| speaker | `speaker HQ { portrait = "Head Quarters"; }` in `speakers.ogs` (`prefix = true` — any speaker whose name starts this way) — the portrait of a speaker with no actor on the level | `Speaker` |
| battle | `transform = Transform(who = "03ch_lilith1", into = ~c"03ch_lilith_m", idle = "dech", sound = …, delay = 100, dialog = …, dialog_delay = 80)` — by the battle's `mode`; `into` is a character block, the model (`anim`) defaults to its `mesh` | `Transform(mode = <mode>, …)` |

**AI profiles are blocks.** `ai/<name>.ogs`: `ai_profile garcia : monster { weapons = by_health; }` — its own fields on top of the base ones (`: monster`, `: generic`); a profile is reused only through inheritance. Numbers: `damage_bonus` (added to damage), `ally_penalty` (penalty for allies on the strike tile), `lock` (weight of the `AITargetLock` target), `monitor` (monitor weight), `decoy_pull`, `decoys`, `step_away`, `threat`, weights `attack_weight`… How it scores a strike tile is also its fields: `weapons` — what it plans with (`all`, `by_health` — the long weapon below half health, `first`, `free_arms`); `follow_lock = false` — the `AITargetLock` target is not prioritized (prioritized by default); `score = ai_scoring::Avenge` — a component whose `ScoreTile` scores the tiles instead of the usual formula (the game's special AIs: Grandma, the Guard, Schizo, Incubus — `ai_scoring::…` components); `wakeful = true` — plans even while asleep; `near = @grandma` — stays within 3 tiles of the object. OG Script has no `AiScoring` rows and no `scoring`, `scoring_rules`, `generic_ai` fields (an error with a hint). A fighter names its profile: `ai_profile = ai::garcia;` (its `ai = AiProfile(lock = 7)` goes on top of the profile); the game names the default profile for fighters without their own: `game gorky { ai_profile = ai::generic; }`. The converter makes `generic` from the shared Classic row, `monster : generic` from what all the others have in common, and one block per differing profile; it moves the Classic evaluation (`AiScoring`) into these fields (`no_lock` → `follow_lock = false`; `foes` → also `ally_penalty = 0`; "evaluation A" for a monster is the same as the usual one). A fighter with no differences from `monster` gets `ai_profile = ai::monster`.

A dialog in the middle of a battle (Classic `MidDialog` by levelMode) is battle code: the converter writes `fn OnEnemyTurnOver(turn) { if (turn == 2) { scene::Dialog(~d"03__museum_chopper2"); } }` into its block's own code. A dialog before a battle is the battle field `dialog = ~d"01__port_barge"`; it is played by `StartDialog()` from `OnShown`.

A record can be given as a list (`fx = [WeaponFx(who = ~c"…", …), WeaponFx(…)]`) if there are several rows. The interface canvas is `Canvas(width = 1280, height = 720);` in `ui.ogs` (without the row — 640×480, as in the exe): a logical frame that is scaled to the window. The world fills the whole canvas (more of the level is visible; a level smaller than the canvas is scaled up), and the exe's graphics keep their pixels: the 640×480 interface rectangle with the panel at the bottom sits at the bottom edge of the canvas, centered, with filler plates on either side of the panel; the menu, inventory, code lock and videos stay 640×480. The interface is `src/ui.ogs` next to `game.ogs` (panel buttons, windows, main menu, interface sounds and sprites); `rules/` holds only what does not belong to a single block. The game's rules are fields of the `game` block (`game.ogs`): experience per level, the hero strike for weapons without their own, formula numbers:

```
game gorky {
    exp_levels = [0, 220, 450, …];   // ExpLevel in level order
    crit_pm = 1200;                   // name of a special value (Value): kill_exp_pm, rage_pm, side_bonus, party_max…
    hero_attack = HeroAttack(anim = "attack_rifle", wait = 59);   // a keyless table row
    …
}
```

**Engine settings** (adjust.kdt names) are not a separate block but fields of what they configure (`src/rules/adjust_owners.zig`): interface settings are records in `ui.ogs` (`PopupColors(hp_loss = [247, 83, 16]);`, `PopupText`, `BattleColors`, `BattleGrid`, `MenuLight`, `CreditsColors`, `SafeLock`, `Cinema`), gameplay settings are fields of the `game` block (`motion = Motion(zoom_speed = 1.2)`, `sound = Sound(…)`, effects: `blood`, `sparks`, `particles`, `explosion`, `fire`, `shot_flash`, `shock`, `flame`, `rocket_trail`, `ball`, `grenade`, `morph`). An effect is a kind of engine effect: the game's value applies to all weapons with it, and a weapon block can set its own with the same records (`weapon napalm { flame = Flame(color = [255, 60, 0]); }` — `flame`, `rocket_trail`, `ball`, `grenade`, `shock`); the loader turns them into `Setting(…, weapon = ~w"…")`, and the engine takes the striking weapon's value, otherwise the game's. Only a field that differs from the engine's value is written; the defaults are the table `src/rules/adjust_defaults.zig` (as in the game's adjust.kdt), and code reads a setting only through it (`adjust.int("morf_sint")`; a name not in the table will not compile). The converter writes only the differences (Gorky 17 has none); names read only by Classic tables (`attack_grandma_delay`, `wdelay_pistol`…) do not get into the project — their values are already numbers in the blocks. Frame rate, shadows and dialog sound are the player's choice, not project data. There is no `settings` block. In the editor these are sections of the "Interface" and "Game" pages.

Class rows (`class_rules`, `class_zone`) can also be written by a block inside a level or battle — the converter puts them there only if no weapon block of the module has this class (`invisible_bite` on the weapon of battle `04__city_mfd`).

**Actions are blocks.** `action Open { label = "open"; on_exit = true; }` in `src/actions.ogs` (the converter writes all of the game's actions there) — without a number: the rules loader assigns numbers by name, and the menu item text is an interface text key (`label`); `kind = take` / `explore` (default `call`), flags `auto_open`, `on_exit`, `walk_click`. An `Action(name = "Open", …)` row in `rules/` is read too (on top of the block of the same name). The build checks the names on objects: `area door: action = Opne: no action Opne (an action block, walk, none)`. An object names an action by name (`action = Take`, `walk`, `none`), and so does code: `action = "Close";` (a string assigned to `action`/`action1`…`action9` is that action's number), `item::SetFuncID("tlen", "walk")`, comparison — `action == object::ActionId("walk")`.

**Weapon classes are names.** `WeaponClass(name = "pistol", …)` and `Pattern(name = "pistol", …)` are written without a number; a weapon names its class by name (`class = pistol`), and the rules loader assigns class numbers by their names. A new class is just a row with a new name.

**Hold points and engine animations are game fields.** `holds = Holds(one_hand = "one_hand", two_hands = "two_hands", back = "back")` — the model's (`.msh`) hold modes on which the engine hangs a weapon in one hand, in two hands and on the back; `anims = Anims(hide_back = …)` — including the animation used to put the weapon on the back. Without them the build reports an error (there are no built-in Classic values). The exe's animation slots (table `0x4280e0`, `stair_up` in the `stair_down` slot) do not exist in OpenGorky: a look binds any names to the model's animations, walk speed is set by name (`ActorSetWalkSpeed("walk_footbridge", …)` — for that one only), and if the model lacks a requested animation, the actor stands in its idle. Slots remain only in Classic.

### Block fields

Which fields a block of each kind takes is declared by the language itself — the engine file `foundation/hosts.ogs` (read-only in a project): `host fighter : actor { float accuracy = 0.0 "Chance to hit, %…"; … }` — the field's type, default and meaning (in English). A block gets the fields of its host and the host's parents. The editor shows a field's declaration and meaning when you hover over it in code and suggests unset fields at the start of a line inside a block. The engine schema (`src/core/schema.zig`) must match it: a test compares every field, its name and type, in both directions. The tables below are generated from `foundation/hosts.ogs` (`gorky-tool traits-doc docs/og-script.md`).

<!-- hosts-doc -->

**`host gameobject`**

| Field | Type | What it means |
|---|---|---|
| `classic_id` | `int` | The object's number in Classic: keys its texts (string.tab) and its rules rows. Unset: the converter assigns a free one when the object has its own text. |
| `name` | `string` | The object's name shown in the game (a hint over it, an inventory name). |
| `examine` | `string` | What examining the object says. |
| `pickable` | `bool` | false: the pointer ignores the object (decor, a used cover, an exit not yet open). Default true. |

**`host actor`** — over `gameobject`, blocks: `actor`

| Field | Type | What it means |
|---|---|---|
| `x` | `float` | Position on the level, world units. |
| `y` | `float` | Position on the level, world units. |
| `z` | `float` | Height on the level, world units. |
| `angle` | `float` | The direction the actor faces, radians. |
| `scale` | `float` | Model scale; 0 or less means 1. Read only for items lying on the ground. |
| `turn_speed` | `float` | How far the actor turns per tick, radians; 0 or less means 0.1. |
| `portrait` | `string` | The actor's portrait picture (the hero panel). |
| `mesh` | `string` | The actor's model file. |
| `gender` | `Gender` | male or female: women do not push objects, only men groan when healed. |
| `look` | `look` | The look block (looks::name) giving the model, portrait and animations; this block's own fields override it. Unset: the nearest archetype's. |
| `tile` | `any` | Battle grid tile the actor starts on: [x, y] or [x, y, direction]. |
| `at` | `any` | Where a prop stands on the battle grid: [x, y, angle] (grid units, whole numbers at a tile corner; degrees). |
| `report_icon` | `any` | Rules row KillIcon: its icon in the battle report when it is killed (report_icon = "nato_capitan_rap"); a fighter's or hero's own wins over this one. |

**`host fighter`** — over `actor`, blocks: `fighter`, `hero`

| Field | Type | What it means |
|---|---|---|
| `battle_class` | `any` | The fighter class by name (battle_class = smokerider; generic is 100): picks the class's abilities, AI profile and other rules rows keyed by class. Every block of one class shares the class rows (class_ai). |
| `report_icon` | `any` | Rules row KillIcon: the kill icon of the after-battle report (report_icon = "icon"). Empty: the fighter shows no icon there. |
| `immunity` | `any` | Rules row Resist: the monster's resistances and armour class (immunity = Resist(resist = [fire, gas], armor = -1)), the one place they are set. |
| `ai` | `any` | Two forms. A record is this fighter's AiProfile rules row over its class's (ai = AiProfile(attack_weight = 10, mode = ...)); a string is the generic fighter's strategy: standard (default), focused (damage only, ignores decoys), sleep_hunter (melee on sleepers, the other weapon on the awake) or stationary (never walks). |
| `class_ai` | `any` | Rules row AiProfile keyed by battle_class: the AI profile of the whole class (class_ai = AiProfile(lock = ..., ...)). Blocks of one class must write the same row; the later one wins. |
| `ai_profile` | `any` | A shared AI profile block (ai_profile = ai::garcia): its AiProfile row is applied first, this fighter's own ai row over it. |
| `abilities` | `any` | Rules row Abilities: special battle abilities over the ordinary fighter (abilities = Abilities(double_turn = true, immobile = true, ...)). Unset parts stay ordinary. |
| `glow` | `any` | Rules row Glow: the actor glows (glow = Glow(); effect, links, size, rgb as the record sets them; the Incubus's). |
| `class_abilities` | `any` | Rules row Abilities keyed by battle_class: the special abilities of the whole class (class_abilities = Abilities(monitor = true, kill_credit = false)). Blocks of one class must write the same row; the later one wins. |
| `device` | `any` | Rules row Device: the battle places this block as a device (device = Device(kind = time_bomb, prefix = "TimeBomb", timer = 2)): object <prefix><N>, a bomb explodes after timer enemy turns. |
| `strikes` | `any` | Rules rows MonsterAttack: the fighter's strike per weapon (strikes = [MonsterAttack(weapon = ..., anim = ..., hit_delay = ...)]; weapon 0 is any other). A fighter with any such row uses them instead of the HeroAttack table. |
| `strike_fx` | `any` | Rules rows FighterFx: the fighter's own strike effects per weapon (strike_fx = [FighterFx(weapon = 0, pre = ..., hit = ..., second = ...)]): pre replaces the weapon's, second is the second hit of a series. |
| `chatter` | `any` | Rules row IdleChatter: after some time without input the selected hero plays anim, then says dialog (chatter = IdleChatter(dialog = ..., anim = ...)). |
| `hidden_weapons` | `any` | Rules row HiddenWeapons: weapons the fighter cannot use or draw in hand (hidden_weapons = [weapons::x, ...]). |
| `spins` | `any` | Rules row FighterStrike: saws spun on the model's link points at a strike tick (spins = [Spin(link = "point", at = tick, anim = "obrot")]; Headnail). |
| `extra_wait` | `any` | Rules row WdelayHero as a flag: true makes the hero's HeroAttack waits take their extra ticks (McFadden, Hutchens). Default false. |
| `bonus` | `any` | Rules row HealBonus: character bonuses (bonus = HealBonus(pct = 15, hit = 0, damage = 0, walk = 0)): pct more healing, hit chance points, percent more damage, extra walk tiles. |
| `hp` | `int` | Current health points. The fighter dies at 0; healing is capped by max_hp. |
| `max_hp` | `int` | Maximum health: caps healing, sets the kill experience reward, and the AI switches weapons below half of it. |
| `walk_range` | `int` | Tiles the fighter may walk per battle turn (spent tiles are subtracted). A script's WalkRange can change it for the turn. |
| `accuracy` | `float` | Hit chance skill: with the target's footprint_tiles and rage it gives the chance to hit. |
| `luck` | `float` | A hero's critical hit chance in percent (two rolls under luck); monsters never crit. |
| `counter_attack` | `float` | A hero's counter-attack chance: scaled by the counter step, rolled against 1000 when an enemy hits it with a weapon in hand. 0: never. |
| `rage` | `int` | Hits taken so far toward rage; counts only if max_rage is above 0, resets when the fighter goes berserk. |
| `max_rage` | `int` | Hits after which the fighter goes berserk (more damage). 0: no rage. |
| `experience` | `int` | A hero's experience points; battle gains add to it and raise level past each threshold. |
| `level` | `int` | A hero's level: rises as experience passes the level thresholds, each step giving stat points. |
| `calmness` | `int` | Kept from the original; the port does not read it. |
| `footprint_tiles` | `int` | The fighter's size; a bigger one is easier to hit. |
| `movable` | `bool` | An obstacle a hero can push (a box or barrel). 0: fixed. |
| `explosive` | `bool` | A barrel: fire, bullets, energy or explosions blow it up with blast_weapon. 0: not explosive. |
| `blast_weapon` | `weapon` | The weapon whose blast an exploding barrel deals. |
| `ai_mode` | `AiMode` | Who the AI strikes and whether it moves: free (default), target (only its locked target), passive (skips its turn), guard (keeps near its guard point). An AiProfile mode overrides it. |
| `move_locked` | `bool` | The fighter cannot walk (wall bosses). A script may clear it. |
| `attack_locked` | `bool` | The fighter cannot attack or counter-attack. |
| `outside_party` | `bool` | A hero fighting on the heroes' side who is not in the party. |
| `ai_threat_weight` | `int` | AI tile scoring: weight of the threat foes pose to a tile. AiProfile threat_weight overrides it; all weights 0: defaults. |
| `ai_attack_weight` | `int` | AI tile scoring: weight of the damage it can deal from a tile. AiProfile attack_weight overrides it. |
| `ai_guard_distance_weight` | `int` | AI tile scoring: weight of the distance to its guard point (guard mode). AiProfile guard_distance_weight overrides it. |
| `ai_opponent_distance_weight` | `int` | AI tile scoring: weight of the distance to its foes. AiProfile opponent_distance_weight overrides it. |
| `armor` | `ArmorClass` | A monster's armour class: light, medium, heavy (the weapon's percent of each cuts its damage) or none; the larger of it and its immunity row's. A hero's: points taken off each hit (a number; the larger of it and its worn armour's). |
| `explodable` | `int` | An obstacle's own explosion switch: 1 a barrel whatever its class, its blast always shown; 0 never explodes. Unset: as explosive decides. |

**`host item`** — over `gameobject`, blocks: `item`

| Field | Type | What it means |
|---|---|---|
| `x` | `float` | Position of the item on the level, X in world units (used while it lies on the ground). |
| `y` | `float` | Position of the item on the level, Y in world units. |
| `z` | `float` | Height of the item on the level in world units. |
| `angle` | `float` | Rotation of the item's model on the ground, in radians. |
| `scale` | `float` | Size multiplier of the item's model; 0 or 1 is the model's own size. |
| `medicine` | `any` | Rules row Medicine keyed by this item: what using it does, medicine = Medicine(kind = rage) (heal rage calm ungas wake, or random = list(~i"items::x", ...)). None: a medicine just heals by hp. |
| `walk_block_radius` | `int` | Radius in background pixels around the item whose walk cells Item_DisableWalkCircle / Item_EnableWalkCircle block or open; below 2 they do nothing. |
| `owner` | `string` | Name of the actor carrying the item; empty: nobody's (lies on the level or in the party pool). |
| `icon` | `string` | Sprite of the item in the inventory and on the ground. |
| `mesh` | `string` | Model shown in the hand when equipped; empty: none (model-less monster weapons). |
| `use_anim` | `string` | Animation a scene's USEANIMATION plays for an actor using this item. |
| `approach_x` | `int` | Point a hero walks to before taking the item, X in background pixels; 0 with approach_y 0: the item's own position. |
| `approach_y` | `int` | Walk-to point, Y in background pixels (see approach_x). |
| `approach_angle` | `float` | Direction the hero faces at the walk-to point, in radians. |
| `place` | `ItemPlace` | Where the item is: gone, ground, backpack, hand, armor (worn) or party. Default ground. |
| `two_handed` | `int` | Held with both hands: 1 picks two-handed battle poses and pushing; 2 appears on monsters' weapons only. 0: one hand. |
| `kind` | `ItemKind` | Item kind: other, ammo, medicine or armor; decides how the inventory uses it. |
| `armor` | `int` | Worn armour's points taken off each hit its wearer takes; a hero uses the larger of his own armor and the worn item's. |
| `resist_fire` | `bool` | Worn armour protects its wearer from fire damage. |
| `resist_electricity` | `bool` | Worn armour protects its wearer from electricity. |
| `resist_decoy` | `bool` | Worn armour protects its wearer from decoys (attraction). |
| `resist_energy` | `bool` | Worn armour protects its wearer from energy weapons (ion rifle, blaster). |
| `resist_freeze` | `bool` | Worn armour protects its wearer from freezing. |
| `resist_sleep` | `bool` | Worn armour protects its wearer from sleep. |
| `resist_gas` | `bool` | Worn armour protects its wearer from gas. |
| `resist_flammable` | `bool` | Worn armour protects its wearer from flammable soaking. |
| `hp` | `int` | Health a medicine restores (capped at the target's max_hp). |
| `count` | `int` | Number in the stack: rounds in an ammo pack or uses of a stackable item. |
| `effect_power` | `int` | Kept from the original; the port does not read it. |
| `visible` | `bool` | Drawn on the level (0: hidden); Item_SetVisible sets it. |
| `action` | `any` | Action row run on a click: an action's name (Take), none (a click just walks there) or walk. |

**`host weapon`** — over `item`, blocks: `weapon`

| Field | Type | What it means |
|---|---|---|
| `class` | `any` | Weapon class by name (class = pistol): the key of its WeaponClass and Pattern rows, i.e. its battle behaviour, reach and hit tiles. |
| `secondary` | `bool` | The backup weapon: the AI uses it only while its fighter is below half health (and the main one above). |
| `max_damage` | `int` | Damage of a full hit; a tile of the reach takes its percent of it before armour and defence. |
| `min_damage` | `int` | Kept from the original; the port does not read it. |
| `range` | `int` | Kept from the original; the port does not read it (reach comes from the class's Pattern row). |
| `max_range` | `int` | Kept from the original; the port does not read it. |
| `blast_radius` | `int` | Kept from the original; the port does not read it (hit tiles come from the Pattern row). |
| `move_penalty` | `float` | Kept from the original; the port does not read it. |
| `accuracy_bonus` | `int` | Kept from the original; the port does not read it. |
| `long_attack` | `bool` | A generic fighter strikes with its long_attack animation instead of short_attack. |
| `bonus_experience` | `int` | Experience a hero gets on top for a hit with this weapon. |
| `light_armor_pct` | `int` | Percent of the damage that passes light armour (class 0). |
| `medium_armor_pct` | `int` | Percent of the damage that passes medium armour (class 1). |
| `heavy_armor_pct` | `int` | Percent of the damage that passes heavy armour (class 2). |
| `attack_zone` | `any` | Another weapon class whose reach and hit tiles this weapon uses (attack_zone = shotgun); none: its own class's. |
| `effects_from` | `any` | Game weapon whose strike effects (flash, projectile, hit, sound) it shows: ~w"weapons::rocket_launcher" or a classic_id; 0: its own. |
| `explodable` | `int` | As a barrel's blast weapon: 1 shows its blast whatever the weapon, 0 never; unset: as the original (only weapon 1002). |
| `skill_icon` | `any` | Rules row SkillIcon: its icon in the weapon skills window, skill_icon = "pistol"; none: not listed there. |
| `weapon_sound` | `any` | Rules row WeaponSound: the sound at the hit, weapon_sound = "shot". |
| `flags` | `any` | Rules row WeaponFlags: flags = WeaponFlags(no_counter = true, shock, sparks, silent_frames); none: all off. |
| `fx` | `any` | Rules row WeaponFx: what its strike shows by stage, fx = WeaponFx(flash = [...], hit = [...], launch = ...). |
| `hero_attack` | `any` | Rules row HeroAttack: a hero's strike with it, hero_attack = HeroAttack(anim = "shoot", wait = 10); none: the default row. |
| `class_rules` | `any` | Rules row WeaponClass of its class: class_rules = WeaponClass(rolls_to_hit = true, effect = burn, recharge = 1, kind = napalm). |
| `flame` | `any` | Its own flame look (Flame(add, color, color_new, range, scale)): the flames it makes take these over the game's flame. |
| `rocket_trail` | `any` | Its rockets' own trail (RocketTrail(length, period, size, size_fade, fade, spread, back)) over the game's. |
| `ball` | `any` | Its energy ball's own countdown and scale (Ball(countdown, scale)) over the game's. |
| `grenade` | `any` | Its throw's own angle (Grenade(angle)) over the game's. |
| `shock` | `any` | Its shock's own time and light (Shock(time, light_range, light_level)) over the game's. |
| `device` | `any` | Rules row Device: the battle places this block as a device (device = Device(kind = blast, prefix = "TimeBombExplode")): a bomb's blast weapon. |
| `class_zone` | `any` | Rules row Pattern of its class: reach and hit tiles, class_zone = Pattern(rays = "...", effects = "..."). |
| `flash_from` | `any` | Weapon whose flash stage (muzzle flash, beam) it shows instead; -1: none; 0: from effects_from. |
| `launch_from` | `any` | Weapon whose projectile stage it shows instead; -1: none; 0: from effects_from. |
| `hit_from` | `any` | Weapon whose hit effects it shows instead; -1: none; 0: from effects_from. |
| `hit_sound` | `string` | Sound at the hit instead of WeaponSound's; empty: WeaponSound's. |
| `damage_kind` | `WeaponKind` | Damage kind (fire, freeze, electricity, gas, bullet, melee...) checked against the target's resistances. |
| `ammo` | `item` | Item it fires: ammo = ~i"items::riffleammo"; each shot takes one from the hero's packs. None: needs no ammo. |
| `thrown` | `bool` | true: the weapon is itself thrown and used up (grenades, knives) instead of taking ammo. |

**`host obstacle`** — over `gameobject`, blocks: `obstacle`

| Field | Type | What it means |
|---|---|---|
| `tile` | `any` | Battle grid tile the obstacle stands on: [x, y] or [x, y, direction]. |
| `at` | `any` | Where the obstacle stands on the battle grid: [x, y, angle] (grid units, whole numbers at a tile corner; degrees). |

**`host activearea`** — over `gameobject`, blocks: `area`

| Field | Type | What it means |
|---|---|---|
| `areaName` | `string` | Name of the level area (.are polygon) this object is; clicks inside it reach the object. |
| `isLevelSwitch` | `int` | Above 0: the area is an exit; using it calls LevelSwitch and Area.OnExit. 0: an ordinary area. |
| `action` | `any` | The area's first action (Take, walk, none...); the action menu starts with it. |
| `hint_hidden` | `bool` | true hides the area's hint text and marker; default false. |
| `examine_hidden` | `bool` | true: examining the area says nothing; default false. |
| `action1` | `any` | The area's second action in the menu (lift buttons); none by default. |
| `action2` | `any` | The area's third action in the menu; none by default. |
| `action3` | `any` | The area's fourth action in the menu; none by default. |

**`host bitmapanimation`** — over `gameobject`, blocks: `anim`

| Field | Type | What it means |
|---|---|---|
| `pos_x` | `int` | Screen X of the animation on the background, pixels. |
| `pos_y` | `int` | Screen Y of the animation on the background, pixels. |
| `frames_per_second` | `int` | Playback speed, frames per second; 0 means 15. |
| `frame` | `int` | Current frame, from 0; reset to 0 at start, advanced by the engine and looped. |
| `sprite` | `string` | Sprite file with the animation frames. |
| `depth_sprite` | `string` | Depth (z-buffer) sprite of the frames, so actors can pass behind; empty: none. |
| `prev_frame` | `int` | Previous frame from the original script. No reader in OpenGorky. |

**`host activebitmapanimation`** — over `bitmapanimation`, blocks: `active_anim`

| Field | Type | What it means |
|---|---|---|
| `state` | `int` | Door-like state: 0 closed, 1 opening, 2 open, 3 closing; an impulse reverses it. Default 0. |
| `one_shot` | `bool` | true: play once while opening, then return to state 0 (explosion, dust); default false. |

**`host level`** — over `gameobject`, blocks: `level`

| Field | Type | What it means |
|---|---|---|
| `perspective` | `bool` | Camera kind: true is a perspective camera from eye/target/fov, false (default) the orthographic view. |
| `near_plane` | `float` | Scene depth of the near plane; near_plane minus far_plane is the depth span the viewer fits walk depth with. |
| `far_plane` | `float` | Scene depth of the far plane; see near_plane. |
| `ortho_rotation_radians` | `float` | Rotation of the isometric view, radians. Written by the converter; no reader in OpenGorky yet. |
| `eye_x` | `float` | Perspective camera eye position, X (world units). |
| `eye_y` | `float` | Perspective camera eye position, Y (world units). |
| `eye_z` | `float` | Perspective camera eye position, Z (world units). |
| `target_x` | `float` | Point the perspective camera looks at, X. |
| `target_y` | `float` | Point the perspective camera looks at, Y. |
| `target_z` | `float` | Point the perspective camera looks at, Z. |
| `fov` | `float` | Field of view of the perspective camera. |
| `actor_scale` | `float` | Scale of actor models on this level; 0 uses the engine default, battles derive it from the grid cell size. |
| `speed_scale` | `float` | Flight speed of rockets launched by scenes outside battle; 0 or less means 1. |
| `floor_z` | `float` | Floor height the perspective camera projects onto. |
| `camera_scale` | `float` | Scale of the perspective projection to the background picture. |
| `aspect_ratio` | `float` | Aspect ratio applied to the perspective camera. |
| `camera_bank` | `float` | Roll (bank) of the perspective camera. |
| `progress` | `int` | Level progress counter scripts raise, lower, set and read (level builtins); starts at 0. |
| `mode` | `int` | Level mode number (levelMode): battle rules Transform and MidDialog and fighters' goes-first pick their rows by it. |
| `shadows` | `bool` | true draws simple shadows under actors on a location (never in battle); default false. |
| `boss` | `bool` | true plays the boss battle music on this level; default false. |
| `camera` | `Camera` | The level camera as one Camera record (its fields above); only the fields given are set. |
| `placement` | `list<Place>` | List of Place records: where actors stand when the level is restored (the old PlaceActor calls). |
| `entry` | `string` | Area point where the selected hero stands on entering the level ("capt_start"); empty: no placement. |
| `dialog` | `dialog` | The level's own dialog (~d"01__port_barge"): what its code plays as scene::Dialog(host.dialog), a battle's before the fight; empty: none. |
| `grid_floor` | `any` | Rules row GridFloor: floor height z of the battle grid on this level (a battle, or a location that becomes one). |
| `music` | `any` | Rules row DistrictMusic: the music track this level plays when it has no <level>.mp3 of its own (music = "03_museum"). |

**`host combatlevel`** — over `level`, blocks: `battle`

| Field | Type | What it means |
|---|---|---|
| `transform` | `any` | Rules rows Transform: a fighter's transformation in this battle, keyed by level mode. |
| `grid_columns` | `int` | Grid columns from the original script. No reader: the grid comes from the .cm map. |
| `grid_rows` | `int` | Grid rows from the original script. No reader: the grid comes from the .cm map. |
| `grid_origin_x` | `float` | Grid center X. No reader: the grid comes from the .cm map. |
| `grid_origin_y` | `float` | Grid center Y. No reader: the grid comes from the .cm map. |
| `grid_origin_z` | `float` | Grid center Z. No reader: the grid comes from the .cm map. |
| `grid_rotation_radians` | `float` | Grid rotation, radians. No reader: the grid comes from the .cm map. |
| `grid_width` | `float` | Grid width. No reader: the grid comes from the .cm map. |
| `grid_height` | `float` | Grid height. No reader: the grid comes from the .cm map. |
| `turn` | `int` | Current battle turn number, set by the engine; MidDialog rules fire on it. |
| `enemies_killed` | `int` | Enemies killed in this battle so far; the engine counts it, starts at 0. |

**`host look`**, blocks: `look`

| Field | Type | What it means |
|---|---|---|
| `mesh` | `string` | The model file; the actor's own mesh overrides it. |
| `portrait` | `string` | The portrait picture; the actor's own portrait overrides it. |
| `turn_speed` | `float` | Turn speed, radians per tick; the actor's own value overrides it. |
| `walk` | `list<Speed>` | Walk speeds per animation: [Speed(anim, speed)], world pixels per tick (ActorSetWalkSpeed). |
| `idles` | `list<Idle>` | Idle animations: [Idle(state, anim, weight)], picked at random by weight (RegisterIdleAnimation). |
| `slots` | `list<Slot>` | Named animation slots: [Slot(state, name, anim)] binds a logical name to a model animation (RegisterAnimation). |
| `not_in_place` | `list<string>` | Hero only: animations that move the hero (NotInPlaceAnimation). |
| `reference` | `string` | Hero only: the reference animation (ReferenceAnimation). |

<!-- /hosts-doc -->

## 12. Rules files: call rows

Any project file is OG Script text; its **top-level calls** (in any `module` block) are rows of rules tables. The OG writer puts them into `src/rules/<table>.ogs`. This is data: it is neither executed nor linked.

- A row is a call with a table name and only named arguments `field = value`. A positional argument is a row error.
- Values are literals: numbers (including negative ones), strings, `list(…)`, nested record calls (`Look(sprite = "smoke2", …)`).
- Tables start empty (the project has no built-in exe rows: the converter has written them). A row with the key of an already read row (files are read by path) overrides only the fields it writes; the rest stay from the first one.
- The key `fighter`, `weapon`, `hero`, `item` can name an archetype instead of a classic_id: `fighter = ~c"characters::garcia"`, `weapon = ~w"weapons::garcialong"` (the row applies to an object whose archetype is this block, and takes precedence over a number; the converter writes this when the number belongs only to objects of these archetypes: one row per archetype). An archetype path as a string or an object name works too: `fighter = "characters::hornet"`, `fighter = "04mf_invisible1"` (an object name takes precedence over everything). `Abilities` and `AiProfile` rows keyed by `class` (battle class) are likewise written by the converter as a fighter row with `class = 0`, if the class belongs only to these archetypes and they have no row of their own: `AiProfile(fighter = ~c"characters::garcia", class = 0, scoring = "garcia", …)`. A fighter's `AiProfile` row, like a class row, applies only to an enemy (a non-enemy gets the class 0 row); rows for classes 9 and 14 stay keyed by class — the generic fighter takes them by its `ai` field (`focused`, `sleep_hunter`).
- Values that name an entity by classic_id can also be an archetype reference: in `MonsterAttack` — `strike = ~c"characters::medusa"` (whose own effects the strike has) and `effects_from`, `flash_from`, `launch_from`, `hit_from` = `~w"weapons::rocket_launcher"` (whose effects); the core takes this archetype's `classic_id`. A number works too (`-1`: none; a number that belongs to no block may, for stages, only be the number of a built-in effect or of a `WeaponFx` row, otherwise a warning, as for the weapon field). The converter writes a reference when the number belongs to exactly one archetype. The same goes for the weapon field `effects_from = ~w"weapons::rocket_launcher";` (or a classic_id): the project reader puts the number into the object.

Scripted abilities are attached with the `scripts` field of the `Abilities` row (a character's `abilities` field or a row in `src/rules/`): `list(Component(param = literal, …), …)`. Components are attached in list order; unnamed parameters get their defaults. Parameters are `int`, `float`, `bool` or string literals.

<!-- check: link -->
```ogs
// src/rules/fighters.ogs
Abilities(fighter = ~c"characters::hornet", class = 0, double_turn = 1);
Abilities(fighter = "grandma_child", class = 0, scripts = list(Avenger(avenger = "grandma")));
Abilities(fighter = "grandma", class = 0, scripts = list(GrandmaRage(), abilities::Rage(below_pct = 30, factor = 2.5)));
Resist(fighter = 125, resist = [fire, gas]);
Resist(fighter = ~c"characters::grandma", resist = [attract, gas], armor = -2);
```

The `fighter` key of an `Abilities` row is a classic_id, an archetype (`~c"characters::grandma"`), an archetype path as a string (`"characters::hornet"`) or the name of an object on the level (`"grandma"`).

## 13. Built-in traits: engine events and decisions

All engine events and decision points are methods of built-in traits (§10.4): a host-kind trait (`Fighter`, `Level`, `Battle`, `Game`…), a role (`Hero`, `Enemy`) or a mark. They are declared in `foundation/traits.ogs` (which is also the `engine.ogs` prelude) and read by `src/script/traits.zig`; the call points in battle are in `src/combat/events.zig`, and the walk over components is in `src/script/dispatch.zig`. A method is called only in an OpenGorky project, and only on a host where at least one attached component implements it.

### 13.1 Catalog

The catalog is generated from `foundation/traits.ogs` (`gorky-tool traits-doc docs/og-script.md`; `regress.sh traitsdoc` checks that it matches the declarations): the text between the `traits-doc` markers is not edited by hand. "Rule" is how the components' answers are combined (§13.2), "No answer" is what the engine does if nobody answered, and "Classic" is the original game's script function that the converter turns into this method (Classic calls it at the same point). A role method (`Hero`, `Enemy`) is called only while the fighter has that role. Object arguments are references: `weapon` is a reference to the weapon object, and its variables are read as `weapon.name`.

<!-- traits-doc: traits -->
| Trait | Kind | Supertraits | What it is |
|---|---|---|---|
| `Object` | host kind | — | Any object of the world. |
| `Level` | host kind | `Object` | A location (and a battle, through Battle). |
| `Battle` | host kind | `Level` | A battle; its components are the battle level's. |
| `Game` | host kind | — | The one game object (outside the location): the project's components for game (game.ogs). |
| `Area` | host kind | `Object` | An active area of a location. |
| `Item` | host kind | `Object` | An item (in the world or carried). |
| `Weapon` | host kind | `Item` | A weapon. |
| `Anim` | host kind | `Object` | A bitmap animation of a location. |
| `ActiveAnim` | host kind | `Anim` | An active bitmap animation. |
| `Path` | host kind | — | A path actors walk (no core schema: outside Object). |
| `Actor` | host kind | `Object` | An actor (a character or a thing with a model). |
| `Obstacle` | host kind | `Actor` | An obstacle (a box, a barrel): a neutral fighter in a battle, without Fighter's events. |
| `Fighter` | host kind | `Actor` | A fighter. |
| `Hero` | role | `Fighter` | A role: a fighter in the party, or on the heroes' side in a battle. |
| `Enemy` | role | `Fighter` | A role: a fighter on the enemies' side in the current battle. |
| `Monitor` | mark | `Fighter` | A strike only deals damage: no back bonus, last attacker, reaction or blood; the AI weighs it by its profile's monitor. |
| `NoKillCredit` | mark | `Fighter` | Killing it gives no experience bonus and no report line. |
| `Immobile` | mark | `Fighter` | Never walks. |
| `StartsUnseen` | mark | `Fighter` | Starts the battle unseen and cannot be pointed at. |
| `Leaves` | mark | `Fighter` | Leaves the field after every enemy round. |
| `NoHands` | mark | `Fighter` | Neither gives nor takes items; no fist. |
| `DoubleStrike` | mark | `Fighter` | Strikes one tile twice with a weapon pair. |
<!-- /traits-doc -->

<!-- traits-doc: catalog -->
**`Object`** (`for object`) — Any object of the world.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnCreate()` | the object is made, after its block's values (.var); the level after its other objects; an item or weapon after OnClassInit; a battle device, a spawned object | all | — | `init` |

**`Level`** (`for level`): `Object` — A location (and a battle, through Battle).

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnCamera()` | before the level's OnCreate; the camera is made from its fields after it | all | — | `initCamera` |
| `OnRestore()` | after every OnCreate of a new location and each time the party comes back | all | — | `restore` |
| `OnStart()` | once for every new object, after OnRestore | all | — | `post_init` |
| `OnUpdate()` | every tick | all | — | `update` |
| `OnShown()` | at the end of every load, new or returned to | all | — | `after_select_gui` |
| `OnEnter()` | the party arrives at the location, after OnShown | all | — | — |
| `OnAfterBattle(battle)` | the party is back after winning battle `battle` (its name) | all | — | `AfterBattle` |
| `Placement()` | the level is placed, before OnRestore: where its actors stand (a list of Place) | first answer | the level's placement field | — |

**`Battle`** (`for battle`): `Level` — A battle; its components are the battle level's.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnEnemiesAppear()` | the battle begins, and each enemy turn ends | all | — | `CombatEnemiesAppear` |
| `OnEnemyTurnOver(turn)` | right after OnEnemiesAppear at an enemy turn's end | all | a mid-battle dialogue (MidDialog) | — |
| `OnTurnStart(side, turn)` | a side's turn begins, after the fighters' events | all | — | — |
| `OnTurnEnd(side, turn)` | a side's turn ends (side "hero" or "enemy"), after the fighters' | all | — | — |
| `OnTick()` | every battle tick | all | a transformation (Transform) | — |
| `OnAttack(attacker, weapon, victims)` | a strike reached its targets, before the roll | all | Transform on the first hero hit | — |
| `OnResist(target, kind, amount)` | a target resists a damage kind, after its Fighter.OnResist: the damage it takes anyway | chain | 0: no damage | — |
| `OnDamage(attacker, target, weapon, amount)` | a strike's damage after OnStrike and OnHit: the damage dealt | chain | the engine's damage | — |
| `OnVar(name, value)` | a battle variable changed, after the fighters' | all | — | — |
| `Outcome()` | the battle's end is checked: "won" or "lost" ends it so, another answer keeps it going, nil leaves it to the engine | first answer | lost when a hero dies, if Value(lose_on_hero_death) | — |
| `OnBattleEnd(won)` | the battle is over (won: true or false) | all | — | — |

**`Game`** (`for game`) — The one game object (outside the location): the project's components for game (game.ogs).

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnDamage(attacker, target, weapon, amount)` | a strike's damage after armour, defence and freezing, after Battle.OnDamage (combat/strike.zig): return the damage dealt | chain | the engine's damage | — |
| `OnResist(target, kind, amount)` | after Battle.OnResist, the target resists the damage kind ("fire", "bullet", "energy", "freeze", "gas", "electricity", "explosion"...; built-in: no damage): return the damage it takes anyway | chain | 0: no damage | — |
| `OnTurnStart(side, turn)` | a side's battle turn begins, after Battle.OnTurnStart (side "hero" or "enemy") | all | — | — |
| `OnBattleEnd(won)` | the battle is over, after Battle.OnBattleEnd (won true: every enemy down, false: lost) | all | — | — |
| `OnItemUse(user, item, target)` | a hero uses an item (medicine on a hero, an item on an object): return true when the hook did it (the built-in use is skipped) | handled | the built-in use | — |
| `OnLevelEnter(level)` | the party arrives at a location (made or entered again), after Level.OnEnter | all | — | — |
| `OnTurnEnd(side, turn)` | a side's battle turn ends, after Battle.OnTurnEnd (side "hero" or "enemy") | all | — | — |

**`Area`** (`for area`): `Object` — An active area of a location.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnStart()` | once for every new object, after the level's OnRestore | all | — | `post_init` |
| `Accepts(item, user)` | its examine menu opens: may `user` use `item` (a use_item_N) on it? false drops the row | veto | the items of its accepts list | — |
| `OnAction(name, hero)` | a hero chose action `name`, before the method of that name | handled | the method named `name` (Open, Take...), if any | — |
| `OnExit()` | a hero takes the exit | all | — | `LevelSwitch` |
| `OnCode(code)` | a safe's code was entered | all | — | `CheckCode` |
| `OnUseItem(item, user)` | an item was used on it | all | — | `UseItem` |
| `OnFirstOpen(hero)` | a box area is explored for the first time | all | the contents of its contents field | `post_init_box` |
| `OnEnter(hero)` | a hero walked into its polygon (checked after the objects' tick, heroes in party order) | all | — | — |
| `OnLeave(hero)` | a hero walked out of its polygon | all | — | — |

**`Item`** (`for item`): `Object` — An item (in the world or carried).

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnClassInit()` | the item is being made, before OnCreate | all | — | `class_init` |
| `OnStart()` | once for every new object, after the level's OnRestore | all | — | `post_init` |
| `Accepts(item, user)` | its examine menu opens: may `user` use `item` (a use_item_N) on it? false drops the row | veto | the items of its accepts list | — |
| `OnAction(name, hero)` | a hero chose action `name`, before the method of that name | handled | the method named `name`, if any | — |
| `CanTake(hero)` | before the take action | veto | may | — |
| `OnTaken(hero)` | after the take action (ammo merged) | all | — | — |
| `CanGive(from, to)` | one hero gives it to another | veto | may, unless either is NoHands | — |
| `OnUse(user, target)` | this item is used, before Game.OnItemUse | handled | the built-in use | — |
| `OnUseItem(item, user)` | another item was used on it | all | — | `UseItem` |
| `OnFirstOpen(hero)` | a box is explored for the first time | all | the contents of its contents field | `post_init_box` |

**`Weapon`** (`for weapon`): `Item` — A weapon.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `CanAim(user, tile)` | each aim candidate at tile [x, y], the player's and the AI's (a hot point, counted like ScoreTarget): false drops it | veto | the weapon's Pattern | — |
| `HitChance(user, target, chance)` | the hit roll, first in the chance's chain | chain | the hit chance and the hero's bonus | — |
| `BaseDamage(user, target, amount)` | the roll's damage to each target, before defence, the back bonus and armour | chain | pct x max_damage / 100 and the skill, luck and rage rolls | — |
| `RechargeTurns(user, turns)` | after a shot | chain | the WeaponClass recharge | — |
| `OnFired(user, tile)` | a round was spent | all | — | — |

**`Anim`** (`for anim`): `Object` — A bitmap animation of a location.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnRestore()` | after the level's OnRestore | all | — | `restore` |
| `OnUpdate()` | every tick | all | — | `update` |
| `CanRender()` | after OnRestore and every tick: is it drawn? | veto | drawn | `allowRender` |

**`ActiveAnim`** (`for active_anim`): `Anim` — An active bitmap animation. No methods of its own.

**`Path`** (`for path`) — A path actors walk (no core schema: outside Object).

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnNode(no, dir, walker)` | actor `walker` passed point `no` (dir 1: forward, 0: backwards) | all | — | `NodeResponse` |

**`Actor`** (`for actor`): `Object` — An actor (a character or a thing with a model).

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnActorReady()` | right after the actor's OnCreate | all | the idles of stances 7/8 copy 0/1 | `additionalIdleAnims`, `postinit` |
| `OnStart()` | once for every new object, after the level's OnRestore; not for heroes brought along | all | — | `post_init` |
| `OnUpdate()` | every tick | all | — | `update` |
| `OnUseItem(item, user)` | an item was used on the actor | all | — | `UseItem` |

**`Obstacle`** (`for obstacle`): `Actor` — An obstacle (a box, a barrel): a neutral fighter in a battle, without Fighter's events. No methods of its own.

**`Fighter`** (`for fighter`): `Actor` — A fighter.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `OnSpawn()` | the fighter enters the battle (its scripted abilities are attached anew for each battle) | all | — | — |
| `OnTurnStart(side, turn)` | a side's turn begins (side "hero" or "enemy"; every fighter hears both sides') | all | — | — |
| `OnTurnEnd(side, turn)` | a side's turn ends (side "hero" or "enemy"; every fighter hears both sides') | all | — | — |
| `OnHit(attacker, weapon, amount)` | the fighter is struck for `amount` after armour and defence: return the damage it takes | chain | — | — |
| `OnStrike(target, weapon, amount)` | the fighter strikes `target` for `amount` (before the target's OnHit): return the damage dealt | chain | — | — |
| `OnDeath(killer)` | the fighter dies (killer: the one who hit it last, or nil) | all | — | — |
| `OnAllyDeath(dead, killer)` | a fighter of its side dies | all | — | — |
| `OnVar(name, value)` | a battle variable changed (BattleSetVar, BattleAddVar) | all | — | — |
| `CanWalk()` | asked at each side's turn start: return false and it does not walk this turn | veto | walks | — |
| `CanBeStruck(from_tile)` | may it be struck from tile from_tile ([x, y])? false: the strike misses | veto | open | — |
| `CanDie(killer)` | a blow of any kind (a strike, FighterDamage, a state, a bomb) would bring its health to 0 (killer as OnDeath's): false and it stays at 1 | veto | dies | — |
| `OnRoleGained(role)` | a role was granted (the mask is up to date) | all | — | — |
| `OnRoleLost(role)` | a role was taken away | all | — | — |
| `WalkRange(range)` | each side's turn start, after CanWalk: its walk range this turn | chain | walk_range | — |
| `TurnPriority(side)` | the AI side's order: a stable sort, highest first | sum | 0 | — |
| `ExtraAction()` | after an action: a second one this turn? | first answer | no | — |
| `StandAngle(after_move)` | where to face: at the start and after its own move | first answer | the nearest opponent | — |
| `OnMoveEnd()` | an AI fighter's own move ends | all | — | — |
| `CanUse(weapon)` | the AI picks the weapons it plans with | veto | may | — |
| `CanPush()` | a push | veto | may, unless the gender is female | — |
| `OnDodge(attacker)` | closed to the attacker's tile: it dodges before the shot | all | — | — |
| `HitChance(target, weapon, chance)` | the chance as the attacker, after Weapon.HitChance | chain | — | — |
| `ChanceToBeHit(attacker, weapon, chance)` | the chance as the target, after the attacker's | chain | — | — |
| `GuardDamage(attacker, weapon, amount)` | the target, before the back bonus and armour | chain | unchanged | — |
| `Armor(attacker, weapon, armor)` | the target's armour class | chain | its own, worn or the table's | — |
| `OnResist(kind, amount)` | the target resists a damage kind, before Battle.OnResist (**not called yet**) | chain | 0 | — |
| `OnDamageDealt(target, weapon, lost)` | the attacker, when the damage is above 0: lost is the health the target lost | all | — | — |

**`Hero`**: `Fighter` — A role: a fighter in the party, or on the heroes' side in a battle.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `CanSelect()` | outside a battle: may the hero be selected (portrait, keys)? | veto | may | — |
| `ExperienceGain(amount)` | a strike's experience goes into experience | chain | 1.75 x the health lost (+ the kill bonus); below 0: 0, experience never drops | — |
| `OnLevelUp(level)` | a new level | all | — | — |
| `OnSkillUp(weapon, level)` | a weapon's skill grows | all | — | — |
| `CounterChance(attacker, chance)` | the counter-attack roll, its conditions met (chance against rand() % 1000) | chain | — | — |
| `CanCarry(item)` | before Item.CanTake | veto | may | — |
| `OnPickUp(item)` | after Item.OnTaken | all | — | — |

**`Enemy`**: `Fighter` — A role: a fighter on the enemies' side in the current battle.

| Method | When | Rule | No answer | Classic |
|---|---|---|---|---|
| `PreferTarget()` | the AI's plan begins: the answer is its forced target this turn | first answer | — | — |
| `ScoreTarget(occupant, weapon, score)` | the AI scores the fighter on a strike's tile (a hot point: the calls per plan go to the battle log) | chain | the Scoring score | — |
| `AiProfile()` | the AI's plan begins: an AiProfile(...) record whose fields given go over its profile and scoring this plan (scoring by name, keep, occupant, tile, wakeful, near, the weights and constants) | first answer | the rules' profile | — |
| `ScoreTile(tile, occupant, weapon, here, aim, damage, pct)` | the AI scores a strike's hit tile [x, y] (occupant: the fighter there or nil) from tile `here` aiming at `aim`, the weapon's damage and the tile's pct: the answer in place of its scoring's occupant (a hot point) | first answer | the scoring's occupant | — |
| `KillReward(killer, amount)` | the kill's experience bonus (not with NoKillCredit) | chain | kill_exp_pm x max_hp | — |

<!-- /traits-doc -->

### 13.2 How results are combined

Each method of a built-in trait has one of six rules (the word before `fn` in `foundation/traits.ogs`, `all` by default; `src/script/dispatch.zig` carries them out):

<!-- traits-doc: rules -->
- **`all`** (`OnCreate`, `OnCamera`, `OnRestore`, `OnStart`, `OnUpdate`, `OnShown`, `OnEnter`, `OnAfterBattle`, `OnEnemiesAppear`, `OnEnemyTurnOver`, `OnTurnStart`, `OnTurnEnd`, `OnTick`, `OnAttack`, `OnVar`, `OnBattleEnd`, `OnLevelEnter`, `OnExit`, `OnCode`, `OnUseItem`, `OnFirstOpen`, `OnLeave`, `OnClassInit`, `OnTaken`, `OnFired`, `OnNode`, `OnActorReady`, `OnSpawn`, `OnDeath`, `OnAllyDeath`, `OnRoleGained`, `OnRoleLost`, `OnMoveEnd`, `OnDodge`, `OnDamageDealt`, `OnLevelUp`, `OnSkillUp`, `OnPickUp`): every component's handler runs in attach order; the result is not used.
- **`chain`** (`OnResist`, `OnDamage`, `HitChance`, `BaseDamage`, `RechargeTurns`, `OnHit`, `OnStrike`, `WalkRange`, `ChanceToBeHit`, `GuardDamage`, `Armor`, `ExperienceGain`, `CounterChance`, `ScoreTarget`, `KillReward`): each result, as an int, becomes the last argument (amount, chance…) for the next component; the last one's is the answer. A change is a battle log line (`OnHit X <- Y: 12 -> 0`).
- **`veto`** (`Accepts`, `CanTake`, `CanGive`, `CanAim`, `CanRender`, `CanWalk`, `CanBeStruck`, `CanDie`, `CanUse`, `CanPush`, `CanSelect`, `CanCarry`): the first false answer is no, and nobody after it is asked. Nobody said no: yes. Nobody answered: the engine's behaviour.
- **`first`** (`Placement`, `Outcome`, `ExtraAction`, `StandAngle`, `PreferTarget`, `AiProfile`, `ScoreTile`): the first answer (not nil) is the answer, and nobody after it is asked.
- **`handled`** (`OnItemUse`, `OnAction`, `OnUse`): the first true answer means done: nothing after it runs and the engine's own action is skipped.
- **`sum`** (`TurnPriority`): the int answers add up.
<!-- /traits-doc -->
- **`nil` means "change nothing".** A handler without `return` (or with `return;`) returns `nil`, and such a result is skipped as if there were no handler: the chain goes on with the previous `amount`, and the question stays unanswered (`CanWalk` does not forbid, `CanBeStruck` does not close). Only an explicitly returned value changes anything. That is why an `OnHit` that leaves the damage alone need not write `return amount;`.
- A component without a handler is skipped. A handler with a runtime error is written to the log (`file:line: message (Component.Event)`) and changes nothing: the chain goes on with the previous `amount`.

The hit chance goes through one chain across three hosts: the weapon's `Weapon.HitChance`, the attacker's `HitChance`, the target's `ChanceToBeHit`. No point spends extra `rand()` rolls: chance, damage and scoring change numbers but not the number of rolls, so `nil` everywhere plays the battle exactly as with no components. A method is called only on a host where at least one component implements it: in Classic and in a battle without abilities, the points cost nothing.

**Note:** "no answer" is only `nil`. Any other value counts as an answer: `return 0;` in `OnHit` zeroes the damage, and a falsy `0`, `""` or `false` in `CanWalk` forbids walking.

Native abilities are a fighter's built-in components, one for each part of the `Abilities` row (`Guard`, `OpenFrom`, `Arms`, `Stand`, `DoubleTurn`, `GoesFirst`, `Heals`, `Avenger`, `NoPush`, `BattleOnly` and the marks `Monitor`, `NoKillCredit`, `Immobile`, `StartsUnseen`, `Leaves`, `NoHands`, `DoubleStrike`; the code is in `src/core/natives.zig` and `src/combat/natives.zig`). They exist in Classic too: the reader attaches them when the object is created, and they live along with it. They come first in the component list, so they answer at the same points before the scripted ones: a scripted ability sees the damage after the native `Guard`, and a death after the native `Avenger`. A mark is seen by `host is Monitor`. A native component cannot be attached by name from code: it is turned on by a field of the `Abilities` row. A native component's parameters are its instance variables (`Guard`: `div`, `min`, `cone`; `Stand`: `angle`, `after_move`; `OpenFrom`: `right`, `ahead`, `dodge`; the full list is in `src/core/natives.zig params` and on the component's page in the editor). Attaching takes them from the `Abilities` row, and the engine reads them on every call, so a script can change them. The instance is obtained the same way as a scripted one: `host.get(Guard)`; `host is Guard` and `host.all(Guard)` work too. A native component's name is not a trait: it cannot be named in `param`, `trait … : …` or `implements`. As a string it is given by `fighter::Native(host, "Guard")` (§16.12).

<!-- check: link -->
```ogs
// The front guard weakens with every hit, while the divisor is above 1.
component Cracks for fighter {
    fn OnHit(attacker, weapon, amount) {
        var g = host.get(Guard);
        if (g != nil and g.div > 1) g.div = g.div - 1;
    }
}
```

### 13.3 Computed fighter fields

In a battle, a fighter reference has fields that are not among its variables:

| Field | Value |
|---|---|
| `side` | `"hero"`, `"enemy"`, `"neutral"` (an obstacle), `"civilian"` (on nobody's side: `battle::SpawnCivilian`) |
| `alive` | `true` while the fighter is fighting |
| `tile` | the tile `[x, y]` (for a large fighter, the top-left one) |
| `asleep` | `true` while the fighter is asleep |
| `second_turn` | `true` on the second action of a turn (`Abilities double_turn`) |
| `avenging` | the fighter it is avenging (`Abilities avenger`: the killer of grandma's child), otherwise `nil` |

The fighter's variables from its scripts (`hp`, `max_hp`, `classic_id`…) are read as usual: `host.hp`, `attacker.max_hp`. Outside a battle there are no computed fields (`nil`).

<!-- check: link -->
```ogs
// Can only be hit from an adjacent tile (or closer than reach).
component CloseOnly for fighter {
    param int reach = 1 "From how far it can be hit";
    fn CanBeStruck(from_tile) {
        var dx = from_tile[0] - host.tile[0];
        var dy = from_tile[1] - host.tile[1];
        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        return dx <= reach and dy <= reach;
    }
}

// Never walks.
component Rooted for fighter {
    fn CanWalk() { return false; }
}
```

### 13.4 World, level and battle events

Methods of the built-in traits `Object`, `Level`, `Battle`, `Area`, `Item`, `Anim`, `Path`, `Actor` (`foundation/traits.ogs`) are called on an object's components at the same points where Classic calls a script function by name (the "Classic" column of the catalog, §13.1), right after it. The call points are in `src/world/start.zig`, `world/levels.zig`, `world/actions.zig`, `game/life.zig`, `inventory/`, `combat/turns.zig`; the walk is `state/hooks.zig on`.

`for battle` and `for level` components are components of the level object: in a battle, that is the battle level.

<!-- check: link -->
```ogs
// Sniper: more accurate against distant targets, the AI picks wounded ones.
component Sniper for fighter {
    param int bonus = 20 "Chance bonus";
    fn HitChance(target, weapon, chance) {
        var dx = target.tile[0] - host.tile[0];
        if (dx < 0) dx = -dx;
        if (dx > 3) return chance + bonus;
    }
    fn ScoreTarget(occupant, weapon, score) {
        if (occupant.side != host.side and occupant.hp * 2 < occupant.max_hp) return score * 2;
    }
}

// Arena: victory after five enemies are killed; until then the battle goes on, and a hero's death does not end it.
component Arena for battle {
    fn Outcome() {
        if (host.enemies_killed >= 5) return "won";
        return "on";
    }
}
```

### 13.5 The game: hooks in `game.ogs`

Every `for game` component of the project (the OG writer puts them in `src/game.ogs`; the reader takes them from any text) is attached, in order, to the world's game object. If there is no such component, there is no game object. The engine calls their methods, the methods of the built-in trait `Game` (§13.1: "game hooks"), in its decisions; the combining rules are as in §13.2, and objects are passed **by reference**. In `OnResist` the damage kind is a string (`"fire"`, `"bullet"`, `"energy"`, `"freeze"`, `"gas"`, `"electricity"`, `"explosion"`…).

Order at one point: the level's components (`Battle`, §13.4), then the `for game` components. This is one chain: the previous result reaches the next one as `amount`. A component method that returned `nil` (no `return`) changes nothing, as in §13.2. A hook has no object of its own, so `host` is the game object with no variables. Keep state in the component's `var`.

A Classic project has no hooks: a level script (`.lev`) function of the same name is not treated as a hook.

<!-- check: link -->
```ogs
// src/game.ogs
component Hooks for game {
    var int turns;
    fn OnTurnStart(side, turn) { turns = turn; }
    fn OnDamage(attacker, target, weapon, amount) {
        if (object::GetClass(weapon) == "weapons::riffle") return amount * 2;   // rifles hit twice as hard
    }                                                             // everything else: nil, damage unchanged
    fn OnItemUse(user, item, target) { return false; }            // false: the built-in use
}

component Hardcore for game {
    // Gas breaks through resistance by half.
    fn OnResist(target, kind, amount) {
        if (kind == "gas") return amount / 2;
        return 0;
    }
}
```

## 14. Battle and game variables

**Battle variables** are a "name → value" dictionary that lives until the end of the battle:

| Function | What it does |
|---|---|
| `battle::GetVar(name)` | the value; `nil` if not set |
| `battle::SetVar(name, value)` | sets the value and calls `OnVar(name, value)` on every living fighter with components (in roster order); returns `value` |
| `battle::AddVar(name, delta)` | (the value or 0) + `delta`, then as `battle::SetVar`; returns the new value. The addition here follows Classic rules: a string in it counts as 0 |

Outside a battle these functions do nothing (`nil`/0). The value can be anything; the battle log gets `var name = value`. Only fighters hear `OnVar`.

**Instance variables** are a component's `var`s; they live along with the instance (§10.1). For components of heroes and their items, they move with the party to the next location and are written to the save (§4.2): this is the place for a hero's state across the whole game.

**Planned:** level and game variables (`Level.vars`, `Game.vars`, written to the save) and `OnVar` on the battle level's components. For now, state that outlasts a battle can only be kept in the Classic level counter `level::GetAdvVar`/`level::SetAdvVar` (`LEVEL_GetAdvVar`/`LEVEL_SetAdvVar`) and in the `var`s of `for game` components.

### 14.1 Component events: `events::Subscribe`, `events::Emit`

Components on different objects exchange events without shared variables: one sends an event (`events::Emit`), and those subscribed to it (`events::Subscribe`) hear it. An event is just a name string; it does not need to be declared.

| Function | What it does |
|---|---|
| `events::Subscribe(event, handler)` | from a component method: **this instance** hears `event` with its method `handler`. `true`: subscribed now; `false`: already was (same instance, event and method), nothing changes |
| `events::Unsubscribe(event, ?handler)` | removes the instance's subscriptions to `event` (with `handler`, only that one); returns how many were removed |
| `events::Emit(event, …)` | immediately calls the handlers of all subscribers in subscription order and passes them the remaining arguments; returns how many handlers were called |

- **Handler** is the name of a method of the calling component, as a string (the language has no function values, §19). A string literal is checked at binding: if the method does not exist, the error is `events::Subscribe: Grandma has no method OnChildDie`; a call outside a component or trait method (in a free function) gives `events::Subscribe: call it in a component's method`. In a trait body the name is looked up among the trait's methods. A name computed at run time is checked on subscription: runtime error `events::Subscribe: NoSuchMethod`.
- **Arguments** of `events::Emit` after the event name arrive as they are: a reference stays a reference, `true` is a `bool` (§8.1), up to 31 in total. The handler drops extra ones; missing ones get their default or `nil` (§8). The handler's result is not used.
- **Order.** Subscribers are called in subscription order (not attach order). Those who are subscribed when `events::Emit` started, and have not unsubscribed before their turn, hear it; a subscription made during dispatch takes effect from the next `events::Emit`. A runtime error in a handler is written to the log (§17.3), and the other subscribers are still called.
- **Nesting.** A handler may itself call `events::Emit`. More than 8 nested `events::Emit` calls is the runtime error `events::Emit: EmitTooDeep`: only the handler that made the call is aborted.
- **How long a subscription lives.** It belongs to the instance and disappears when the instance is detached from its host: scripted abilities of the `Abilities` row, attached anew on entering a battle (§10.1), subscribe anew. A host removed from the world (a disabled object) hears no events. **A dead fighter stays subscribed** while its component is attached (in a battle, until the battle ends): if this matters, the handler checks `host.alive`.
- **Where.** There is one bus per script runtime of the loaded location: it works in a battle (a battle is a location `NN__*`) and on a level, for any components.
- **Battle log.** Every `events::Emit` in a battle writes the line `emit name n=handlers`, after the lines of the handlers themselves.
- **Saving and travel.** A location's subscriptions are saved and are the same after loading, in the same order (§4.2). Subscriptions of components of heroes and their items travel with the party from location to location (§4.2): in the new location, the event is heard by the hero's instance that subscribed in the previous one. Subscriptions of battle scripted abilities are not saved (you cannot save during a battle, and after a battle they subscribe again in `OnSpawn`).

Example: Grandma's children report their death; Grandma subscribes when she enters the battle, sets herself on the killer, and after `rage_at` deaths flies into a rage and unsubscribes: nobody hears the third child's death anymore (`emit child_died n=0`). The `regress.sh events` scenario plays it in a real battle, `01__port_citadel`.

<!-- check: link -->
```ogs
component GrandmaChild for fighter {
    fn OnDeath(killer) { events::Emit("child_died", host, killer); }
}
component Grandma for fighter {
    param int rage_at = 2 "Children before rage";
    var int lost = 0;
    fn OnSpawn() { events::Subscribe("child_died", "OnChildDied"); }
    fn OnChildDied(child, killer) {
        lost += 1;
        if (killer != nil and host.alive) fighter::SetTarget(host, killer);
        if (lost >= rage_at) {
            fighter::AddState(host, "rage", turns: 99);
            events::Unsubscribe("child_died");                  // no longer listens
        }
    }
}
```

In the converted game, Grandma and her children already have their own rows by archetype (`characters::grandma`, `characters::grandma_child`: the converter writes class 7 and 8 rows this way, §12), and a fighter row takes precedence over a class row, so the abilities are added to those rows, under the same key (the editor's "+ ability" does the same):

<!-- check: link -->
```ogs
Abilities(fighter = ~c"characters::grandma", class = 0, first_in_mode = 2, scripts = list(Grandma()));
Abilities(fighter = ~c"characters::grandma_child", class = 0, avenger = "grandma", scripts = list(GrandmaChild()));
```

<!-- check: error events::Subscribe: Grandma has no method OnChildDie -->
```ogs
component Grandma for fighter {
    fn OnSpawn() { events::Subscribe("child_died", "OnChildDie"); }
    fn OnChildDied(child, killer) { }
}
```

## 15. Scripted abilities: a full example

Below are four abilities that the `regress.sh scripted` scenario tests in the real battles `01__port_park` and `01__port_citadel` of the converted game. Put them in any source file of the project, for example `src/components/abilities.ogs`:

<!-- check: abilities -->
```ogs
component Reflect for fighter {
    param int pct = 30 "Percent to return";
    fn OnHit(attacker, weapon, amount) {
        if (attacker != nil and attacker != host) fighter::Damage(attacker, amount * pct / 100, from: host, kind: "reflect");
    }
}
component Invulnerable for fighter {
    param int turns = 2 "Invulnerable turns";
    var int left;
    fn OnSpawn() { left = turns; }
    fn OnTurnStart(side, turn) { if (side == host.side and left > 0) left -= 1; }
    fn OnHit(attacker, weapon, amount) { if (left > 0) return 0; }
}
component Avenger for fighter {
    param fighter avenger "Who avenges me";
    param string counter = "grandma_kids";
    fn OnDeath(killer) {
        if (avenger != nil and avenger.alive and killer != nil) fighter::SetTarget(avenger, killer);
        battle::AddVar(counter, 1);
    }
}
component GrandmaRage for fighter {
    param string kids_counter = "grandma_kids"; param int rage_at = 2;
    fn OnVar(name, value) { if (name == kids_counter and value >= rage_at) fighter::AddState(host, "rage", turns: 99); }
}
```

Then attach them with `Abilities` rows (for example in `src/rules/abilities.ogs`). Grandma and her children already have their own rows by archetype, so their abilities are added to those rows under the same key, as in §14.1 (a class row `class = 7` would not be attached: the fighter's own row takes precedence):

<!-- check: link -->
```ogs
Abilities(fighter = "01pr_garcia1", class = 0, scripts = list(Reflect(pct = 50), Invulnerable(turns = 1)));
Abilities(fighter = ~c"characters::grandma_child", class = 0, avenger = "grandma", scripts = list(Avenger(avenger = "grandma")));
Abilities(fighter = ~c"characters::grandma", class = 0, first_in_mode = 2, scripts = list(GrandmaRage()));
```

What happens in battle:

- **Reflect.** When Garcia is hit, `OnHit` deals half of the damage to the attacker (`fighter::Damage` hits immediately and bypasses `OnHit`, so reflected damage is not reflected back; `from: host` makes Garcia the killer if the attacker dies). Garcia still takes his own damage in full: there is no `return`, so the handler returns `nil` and the damage is unchanged.
- **Invulnerable.** `OnSpawn` sets the counter. `OnTurnStart` arrives on both sides' turns, so the handler compares `side == host.side`: the counter decreases only at the start of the fighter's own turn. While the counter is above zero, `OnHit` returns 0; after that it returns `nil` (damage unchanged). Attached after Reflect, Invulnerable receives the `amount` left over after Reflect — the order in the list matters.
- **Avenger + GrandmaRage (a counter in a battle variable).** When a child dies, it sets Grandma on the killer (`fighter::SetTarget`) and adds 1 to the battle variable `grandma_kids`. Every change is broadcast through `OnVar`. When the counter reaches `rage_at`, Grandma goes into a rage for 99 actions. `avenger.alive` is a computed field (§13.3). If there is no `grandma` object, `avenger` is `nil`.

The editor currently opens an OpenGorky project read-only: the "Extra abilities" block and the "+ new ability" button will return together with OG project editing.

### 15.1 A boss with phases: `CanDie`, `battle::SpawnEnemy`, `fighter::Transform`

"The final boss is reborn: other bosses rise in his place; kill them and they give him their life; and this happens twice." The `regress.sh phoenix` scenario plays it in the real battle `01__port_park` of the converted game (the Phoenix is `01pr_garcia1`): two rebirths, then death; the same `seed` gives the same log. The guards and the new form are fighter archetypes (`characters::hornet`, `characters::garcia`); the converted game does not have them yet (its level objects are its own, without archetypes), so the scenario builds them from the level's hornet and Garcia.

<!-- check: link -->
```ogs
// Phoenix: a lethal blow does not kill him while phases remain. He drops to 1 HP,
// becomes unreachable and does not act, and the phase's guards rise around him; when all of them
// are dead, he rises with full health — in a new form, if one is set.
component Phoenix for fighter {
    param int phases = 2 "Times to rise again";
    param int guards = 2 "Guards per phase";
    param string guard1 = "characters::hornet" "First phase guards (fighter archetype)";
    param string guard2 = "characters::garcia" "Second phase guards";
    param string form1 = "" "Look after the first phase (archetype; empty: unchanged)";
    param string form2 = "" "Look after the second phase";
    var int phase = 0;
    var int left = 0;                                   // living guards of the phase

    fn CanDie(killer) {
        if (left > 0) return false;                     // stays down while guards live
        if (phase >= phases) return nil;                // phases exhausted: dies
        phase += 1;
        var cls = guard1;
        if (phase > 1) cls = guard2;
        var x = host.tile[0];
        var y = host.tile[1];
        for d in [[-2, 0], [2, 0], [0, -2], [0, 2], [-2, -2], [2, 2], [-2, 2], [2, -2], [-3, 0], [3, 0]] {
            if (left >= guards) break;
            var g = battle::SpawnEnemy(cls, x + d[0], y + d[1]);
            if (g != nil) {
                battle::SetVar("guard_" + g, phase);      // whose guard this is
                left += 1;
            }
        }
        if (left == 0) return nil;                      // no room for guards
        fighter::Popup(host, "Rise, guards!");
        return false;
    }
    fn OnAllyDeath(dead, killer) {
        if (left == 0 or battle::GetVar("guard_" + dead.name) != phase) return;
        left -= 1;
        if (left > 0) return;
        var form = form1;
        if (phase > 1) form = form2;
        if (form != "") fighter::Transform(host, form);
        fighter::SetHp(host, host.max_hp);                // the guards gave him their life
        fighter::Popup(host, "I am back!");
    }
    fn CanBeStruck(from_tile) { if (left > 0) return false; }
    fn CanWalk() { if (left > 0) return false; }
    fn CanUse(weapon) { if (left > 0) return false; }
}
```

<!-- check: link -->
```ogs
Abilities(fighter = "01pr_garcia1", class = 0, scripts = list(Phoenix(form1 = "characters::hornet")));
```

- **`CanDie`** is asked when a blow of any kind would bring health down to 0. While the guards are alive, the Phoenix answers `false` and stays at 1 HP: this way he cannot be finished off by fire or a bomb. A new phase starts in the same query. When the phases run out, it returns `nil`, and he dies as usual (`OnDeath`, reward).
- **`battle::SpawnEnemy`** places guards around him on the enemy side; an occupied tile or a tile outside the grid gives `nil`, and the Phoenix tries the next one. The guard's name is stored in the battle variable `guard_<name>`: this lets `OnAllyDeath` tell his own guards from other enemies. A guard gets the weapons of a fighter of the same class (here the level's hornets and Garcia) and the abilities of its own `Abilities` row.
- **Inactive** while down: `CanBeStruck` closes him to blows and to AI targeting, and `CanWalk` and `CanUse` keep him from moving and attacking.
- **Rebirth**: when the last guard of a phase dies, `fighter::Transform` runs (if a form is set), then `fighter::SetHp` restores health to `max_hp`. The transformation finishes after `morf_life2` ticks: the new class's `init()` sets its values (`max_hp` is the new one), while health stays at what the script set. Scripted abilities are taken from the `Abilities` row of the new form; `Phoenix` is in both (the row belongs to the object `01pr_garcia1`), so it stays as it was — with its own `phase` and `left`.
- Built-in functions are passed `host` itself: where an object name is expected, a reference becomes a name (§8.1).

**Limitations.** The model of a fighter placed or transformed mid-battle is loaded on first display (not on entering the location): a frame may stall. A large fighter (2×2, 3×3) that did not have enough room stays in the world as a disabled object.

### 15.2 Escort: `battle::SpawnCivilian`, `battle::Lose`

"A refugee appears next to Sullivan. He is on nobody's side: enemies attack him, and the hero may hit him too. If the refugee dies, the battle is lost." A civilian fighter (`civilian`) does not affect the outcome of the battle by default: the battle is won by killing the enemies even if he is alive, and is not lost if he dies. Here his own `OnDeath` declares the defeat.

<!-- check: link -->
```ogs
// Refugee: his death is a defeat.
component Escorted for fighter {
    fn OnDeath(killer) { battle::Lose(); }
}
// The hero places the refugee on an adjacent free tile when entering the battle.
component Escort for fighter {
    param string refugee = "characters::refugee" "Whom to escort (fighter archetype)";
    fn OnSpawn() {
        var x = host.tile[0];
        var y = host.tile[1];
        for d in [[1, 0], [-1, 0], [0, 1], [0, -1]] {
            if (battle::SpawnCivilian(refugee, x + d[0], y + d[1]) != nil) return;
        }
    }
}
```

<!-- check: link -->
```ogs
Abilities(fighter = "sullivan", class = 0, scripts = list(Escort()));
Abilities(fighter = ~c"characters::refugee", class = 0, scripts = list(Escorted()));
```

- **`battle::SpawnCivilian`** places a fighter on neither side. Without `ai` (or with `ai: "dummy"`) he stands still and does nothing; with `ai: "normal"` he acts during the enemies' turn under his class's AI and attacks both heroes and enemies.
- **`battle::Lose`** ends the battle in defeat, the same way the heroes' death does: at the next end-of-battle check, after the current action. `battle::Win` likewise ends it in victory.
- A helper controlled by the player is placed with `battle::SpawnHero`: he can be selected and moved like a hero, but he does not join the party and stays at the location after the battle.

If a summoned hero should not die but only drop out, his `CanDie` refuses death and puts him to sleep (`fighter::AddState` has no `"delirium"` state — the closest is `"sleep"`):

<!-- check: link -->
```ogs
// Summoned helper: does not die but falls asleep for three turns with 1 HP.
component Summoned for fighter {
    fn CanDie(killer) {
        fighter::SetHp(host, 1);
        fighter::AddState(host, "sleep", turns: 3);
        return false;
    }
}
```

## 16. Built-in functions

The table is `src/builtins.zig`: 141 entries, each with a Classic name (the exe name, which Classic scripts use) and an OG Script name. In OG Script, built-ins live in 12 reserved packages (134 functions), and the root holds a core of three (`print`, `str`, `EqualsIgnoreCase`); three Classic functions are not needed in OG Script (§16.14). Descriptions are in `src/editor/api.zig`. A signature is written the way the table prints it: `result(parameter types)`, where `?` marks an optional parameter and `any` means any value (including the result of a script function). A `bool` result is a yes/no answer: `true`/`false` in OG Script, `int` 1/0 in Classic (§4).

- **Name.** In OG Script a built-in is called through its package: `fighter::SetHp(host, 1)`, or the package is opened: `use fighter;` and then `SetHp(host, 1)` (§8.2). A Classic name (`FighterSetHp`) in OG Script is a link error with a hint about the path. Classic scripts use the exe names, as before; translation between Classic and OG Script (the OG Script view in the editor, §20) maps names using this same table.
- The types in a signature are documentation. They are not yet checked on calls from OGS (**planned**: checking at link time). The number of arguments is not checked either (§8.1). The exception is the kind types `level`, `scene`, `sound`: they are strings, and a sigil of another kind there is a link error (§6.8). The `method` type is the name of a method of the calling component and is checked at link time (§14.1). A final parameter `type name...` takes all arguments from its position onward (`events::Emit`).
- Parameter names exist only for OpenGorky-only functions (the signature names the parameters). Only these functions accept arguments by name.
- Most functions are functions of the original game, with its behavior. Many of them are meant for Classic object creation events (registering animations) or for an actor's command queue. In battle handlers, the meaningful packages are mainly `battle`, `fighter` and `events`.
- Where an object name is expected, you can pass a reference (`host`, `@grandma`, `attacker`).

### 16.1 Root: the core

No package; usable in any code.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `print` | `print` | `int(string)` | Writes each argument to the engine log along with the name of the calling object. Returns 0. |
| `str` | `str` | `string(any)` | OpenGorky only. The value as text, for string concatenation: a number as a string variable would take it (`5` → `"5"`, `2.5` → `"2.500000"`), `true`/`false`, `nil` → `"nil"`, a reference — the object's name, a list or dictionary — as written (`[1, "a"]`). |
| `EqualsIgnoreCase` | `EqualsIgnoreCase` | `bool(string a, string b)` | OpenGorky only. True if the strings are equal ignoring case (Latin letters). `==` in OG Script is case-sensitive; in Classic this kind of comparison is done by `s_stricmp`. |

### 16.2 `object` — Objects

Any object by name: whether it exists, enable, disable, delete, its classic_id and class, calling its function. Where Classic writes `"this"`, OG Script writes `host`.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `object::Exists` | `IsObject` | `bool(string)` | True if an object with this name exists. |
| `object::IsHere` | `IsHere` | `bool(any x)` | OpenGorky only. True if `x` is a reference to an object of this location (including a deleted one); false for a reference to an object of another location (§4.2) and for a non-reference. |
| `object::GetNameID` | `GetNameID` | `int(string)` | Returns the object's classic_id (heroes: 20 Sullivan, 21 Ovitz, 22 Trantigne, 24 Lucy); "this" is the caller. Returns -1 if the object does not exist. |
| `object::GetClass` | `GetClass` | `string(string)` | OpenGorky only. The object's class as the rules name it (in an OpenGorky project, the archetype path: "weapons::riffle", "characters::hornet"), for hooks; "" if the object does not exist. |
| `object::Enable` | `EnableObject` | `int(string)` | Enables the given object (it is active and visible again). |
| `object::Disable` | `DisableObject` | `int(string)` | Disables the given object; it stays on the level and can be enabled again. Classic `Disable()` in an actor script is `object::Disable(host)` (§16.14). |
| `object::Delete` | `DeleteObject` | `int(string)` | Disables the given object and marks it deleted. |
| `object::Impulse` | `ABA_Impulse` | `int(string)` | Starts a one-shot playback of an active bitmap animation object (a lever, a puff of smoke). Does nothing for other objects. |
| `object::Call` | `GO_RunFun` | `any(string, string)` | Calls a function of an object (extra arguments are passed on), including objects of other loaded levels. Returns the function's result or 0. |

### 16.3 `sound` — Sound

Sounds and ambient.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `sound::Play` | `PlaySound` | `int(sound, ?int)` | Plays a sound at the calling object's position; a nonzero loop makes it loop. |
| `sound::PlayRandom2D` | `PlayRandomSound2D` | `int(int, int, string, ?int)` | Plays a random sound from a comma-separated list (up to 10) at background point (x, y). With chance > 0 it plays only with probability 1/chance. |
| `sound::NewAmbient` | `Ambient_New` | `int(string, int, int, string)` | Creates an ambient object: a looping sound at background point (x, y). Does nothing if an object with this name already exists. |

### 16.4 `actor` — Actor

Actor: registering the model and animations (creation events), the command queue, state, attachment and link points. Functions without an actor argument act on `host` (the exe has no form for another actor).

Model and animations (on `host`, usually in creation events):

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `actor::RegisterAnimation` | `RegisterAnimation` | `int(int, string, string)` | Maps a logical animation name to an actual animation for state 0..8 of the current actor. |
| `actor::RegisterIdleAnimation` | `RegisterIdleAnimation` | `int(int, string, int)` | Adds an idle animation to the current actor for state 0..8 with a random-selection weight. Without a weight nothing is registered. |
| `actor::NotInPlaceAnimation` | `NotInPlaceAnimation` | `int(string)` | Marks an animation of the current actor as displacing (not in place): its offsets are measured from the reference animation. |
| `actor::ReferenceAnimation` | `ReferenceAnimation` | `int(string)` | Sets the reference animation of the current actor; offsets of not-in-place animations are measured from its first frame. |
| `actor::RegisterExtraBody` | `RegisterExtraBody` | `int(int, int, string)` | Gives the current actor an extra body: a mesh drawn at the actor's position, in slot 0…3 (replacing the previous one); with still 0 the actor's animations play on it, otherwise it holds the first frame. Types are strictly int, int, string. Not used in the game's scripts. |
| `actor::SetWalkSpeed` | `ActorSetWalkSpeed` | `int(string, float)` | Sets the current actor's movement speed for a walk animation, in world pixels per tick; speed must be a float. |
| `actor::ModifyScale` | `ActorModifyScale` | `int(float)` | Multiplies the current actor's model scale by k. |
| `actor::SetModelOffset` | `SetActorAddVariables` | `int(string, float, float, float)` | Sets the offset of the actor's model from its position; only the axes passed as float are changed. |
| `actor::SetModelAngle` | `AdjustAngle` | `int(float)` | Sets the orientation correction of the current actor's model in degrees; float only. |
| `actor::InitState` | `SetActorState` | `int(int)` | Sets the current actor's state (selects its animation set). |

Control and the command queue (the actor is an argument):

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `actor::Place` | `PlaceActor` | `int(string, string, int, ?int)` | Places an enabled actor at point index of an area (the angle comes from the point), on floor 0 or 1; the form actor::Place(name, x, y[, dir]) places it on battle grid tile (x, y), dir in eighths of a turn. Returns 1 if placement happened. |
| `actor::SetAnimation` | `Actor_SetAnimation` | `int(string, string, ?int)` | Queues a one-shot animation for the actor after its current commands; "idle" is the idle of the current state. noBlend = 1 means no blending with the previous animation. |
| `actor::SetAsyncAnimation` | `Actor_SetAsyncAnimation` | `int(string, string, ?int, ?int)` | Queues a one-shot animation for the actor without waiting for it to finish; reverse plays it from the last frame. noBlend = 1 means no blending with the previous animation. |
| `actor::SetState` | `Actor_SetState` | `int(string, int, ?int)` | Sets the actor's state and, if the actor is not busy, picks a new idle. flag = 1 means the next animation is not blended. |
| `actor::QueueState` | `Actor_QueueState` | `int(string, int)` | Adds a stance change to the actor's command queue; in battle 0 and 1 become 7 and 8, and stance 4 also removes meshes from link points. Not used in the game's scripts. |
| `actor::TextEffect` | `Actor_TextEffect` | `int(string, any)` | Shows popup text from string.tab with number text (or by a UI text key: `"no_ammo"`) above a placed actor (like "No ammo" in battle) and plays battle_noammo. |
| `actor::InArea` | `ActorInArea` | `bool(string, string)` | True if the actor's background position is inside the area. |
| `actor::Stop` | `StopActor` | `int(string)` | Stops the actor: clears the command queue, the path and the current command. |
| `actor::Vibrato` | `Vibrato` | `int(string, float, float)` | Makes the actor sway with the given amplitude and phase step per tick; both must be floats. |
| `actor::WalkOnTrack` | `WalkOnSceneryTrack` | `int(string, string, ?float, ?int)` | Places the actor at point start of area track at the given height and leads it along the remaining points at walking speed, turning along the way. |
| `actor::SetFloor` | `SetActorMap` | `int(string, int)` | Puts the actor on floor 1 (.wm2) if floor is 1, otherwise on floor 0 (.wm). |
| `actor::QueueDelay` | `Actor_QueueDelay` | `int(string, int)` | Adds a pause of ticks ticks to the actor's command queue. |
| `actor::QueueJustifyPosition` | `Actor_QueueJustifyPosition` | `int(string)` | When the actor's command queue reaches this entry, shifts the actor by the offset of the displayed pose from the last frame of the current animation; the next animation starts without blending. |
| `actor::QueuePlace` | `Actor_QueuePlace` | `int(string, string, int)` | When the actor's command queue reaches this entry, places the actor at point index of the area (floor 0) and drops the rest of the queue; the next animation starts without blending. |
| `actor::QueueCall` | `Actor_QueueGOScriptFunc` | `int(string, string, string)` | When the actor's command queue reaches this entry, calls a script function of the object named like the actor. |
| `actor::Call` | `Actor_GORunFun` | `any(string, string, string)` | Immediately calls a script function of the object named like the actor (not through the queue). |
| `actor::PutBackItem` | `ActorPutBackItem` | `int(string)` | Queues putting a two-handed weapon from the hands onto the back: "hide_back", meshes are removed from link points, the weapon goes to "back", stance 0. Does nothing without a two-handed item in hand. Not used in the game's scripts. |
| `actor::PutFrontItem` | `ActorPutFrontItem` | `int(string)` | Queues taking a two-handed weapon from the back: after animation blending, meshes are removed from link points, stance 1, "hide_back" in reverse without waiting, 30 ticks, the weapon goes to "two_hands". Not used in the game's scripts. |

Attachment and link points:

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `actor::AttachByLink` | `AttachActorsByLink` | `int(string, string, string)` | Attaches the actor to a link point of the parent's mesh, and it moves together with the parent. Does nothing if the point does not exist. |
| `actor::Attach` | `AttachActors` | `int(string, string, float, float, float, float)` | Attaches the actor to the parent with the given offset, and it moves together with the parent: a and b horizontally in the parent's axes, c vertically, in world units; angle is added to the parent's angle. All four must be floats. Not used in the game's scripts. |
| `actor::DetachAllFrom` | `DetachActorsFrom` | `int(string)` | Detaches all actors attached to the parent and resets their model offsets. |
| `actor::LinkRider` | `LinkActor` | `int(string, string)` | The actor rides the calling object at this link point of its mesh and is drawn together with it in its own animations (Smoke Rider pilots). |
| `actor::ShowLinkMesh` | `ActivateLink` | `int(string, string, ?int)` | Shows a mesh at a link point of the current actor (Headnail's saws). The port ignores the third argument. |
| `actor::HideLinkMesh` | `DeactivateLink` | `int(string)` | Removes the mesh from a link point of the current actor (the reverse of actor::ShowLinkMesh). Not used in the game's scripts. |
| `actor::ShowItemInHand` | `Actor_ActivateLink` | `int(string, string)` | Shows an item's mesh in the actor's hand (point two_hands for two-handed items, otherwise one_hand). |
| `actor::HideAllLinkMeshes` | `Actor_DeactivateAllLinks` | `int(string)` | Removes all meshes attached to the actor's link points. |

### 16.5 `path` — Path scripts

Path script (`.pth`) functions: they act on the path node's actor — not on `host`, and without an actor argument. In a project a location's walk paths (stairs, ladders, a plank: the route between two cells of the walk grid that the walk takes through the path's points) are `path` blocks inside its level block, in the location's `paths.ogs`: `link` — the start and end cells, `points` — `PathPoint(x, y, angle, z)` records (background x, y, the angle the walker turns to, the height), and its code in the block: `fn OnNode(no, dir, walker)` runs when an actor passes point `no` (`dir` 1 forward, 0 back). The engine reads the paths from these blocks only (not the game's `.ap`) and makes a path's object at its first point passed; the converter writes them of the level's `<level>.ap` and `<path>.pth`, the editor's Paths tool edits them.

```ogs
level "01_port" {
    path deska {
        link = [182, 22, 189, 11];
        points = [
            PathPoint(x = 1460, y = 180, angle = 0.0, z = 135),
            PathPoint(x = 1516, y = 92, angle = 0.0, z = 135),
        ];
        fn OnNode(no, dir, walker) {
            if (dir == 1 and no == 0) path::SetWalkAnimation("walk_footbridge");
            if (dir == 1 and no == 1) path::SetWalkAnimation("walk");
        }
    }
}
```

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `path::SetWalkAnimation` | `ActorSetWalkAnimation` | `int(string, ?int)` | Path script: the actor walks the rest of the path with this animation at its speed; a nonzero reverse plays it backwards (going down stairs). |
| `path::Animation` | `ActorAnimation` | `int(string, ?int, ?int, ?int)` | Path script: a one-shot animation; movement waits for it to finish; reverse = 1 plays it backwards. a = 1 means no blending into it, b = 1 no blending into the next one. |
| `path::AsyncAnimation` | `ActorAsyncAnimation` | `int(string, ?int, ?int, ?int)` | Path script: a one-shot animation without stopping movement; flags as in path::Animation. |
| `path::QueueWalkAnimation` | `ActorQueueWalkAnimation` | `int(string, ?int, ?int, ?int)` | Path script: sets a one-shot animation for the next path segment; a = 1 means no blending, reverse = 1 plays it backwards. |
| `path::AsyncWalkAnimation` | `ActorAsyncWalkAnimation` | `int(?int, ?int)` | Path script: immediately starts the walk animation (the one set by path::QueueWalkAnimation, if any, otherwise the current one) without stopping movement. a = 1 means no blending into it, b = 1 no blending into the next one. |
| `path::AdjustAngle` | `ActorAdjustAngle` | `int()` | Path script: turns the actor to the angle of the current path point (at the end of the path, the last point). |
| `path::EnableRotation` | `ActorEnableRotation` | `int(int)` | Path script: 0 — the actor does not turn toward path points, 1 — it turns again. |
| `path::DisableInterpolation` | `ActorDisableInterpolation` | `int()` | Path script: the next animation starts without blending from the previous one. |
| `path::WaitForAnimation` | `ActorQueueWaitForAnimation` | `int(?string)` | Path script: movement along the path waits for the current one-shot animation to finish. The optional name only lets the queue continue in the same tick if it was exactly this animation that finished. |
| `path::WaitForInterpolation` | `ActorQueueWaitForInterpolation` | `int()` | Path script: movement waits for animation blending to finish. |
| `path::Delay` | `ActorDelay` | `int(int)` | Path script: pauses the actor for ticks ticks. Classic `ActorQueueDelay` is the same function (the same exe handler). |

### 16.6 `level` — Level

Level: loading, the level counter (progress), the walk map, floors, global strings.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `level::GetName` | `GetLevel` | `string()` | OpenGorky only. The current level's name ("05_laboratory"), for hooks. |
| `level::Load` | `LEVEL_Load` | `int(level)` | Queues a transition to the given level. Some subsequent calls within the same script invocation (scene::FadeIn, hero::PlaceAll, hero::DisableOthers) are deferred and take effect on the new level. |
| `level::LoadAfterBattle` | `LEVEL_LoadAB` | `int(level)` | Same as level::Load, but the new level then receives AfterBattle(name of the previous level), as after a battle. |
| `level::IncAdvVar` | `LEVEL_IncAdvVar` | `int()` | Adds 1 to the level's progress counter (progress of the level object, saved with it). |
| `level::DecAdvVar` | `LEVEL_DecAdvVar` | `int()` | Subtracts 1 from the level's progress counter (progress). |
| `level::GetAdvVar` | `LEVEL_GetAdvVar` | `int()` | Returns the level's progress counter (progress), 0 if there is no level object. |
| `level::SetAdvVar` | `LEVEL_SetAdvVar` | `int(int)` | Sets the level's progress counter (progress). |
| `level::SetGlobalString` | `SetGlobalStringVariable` | `int(string, string)` | Does nothing in the port: the game's scenes read only #HERO_SELECTED and #LAST_ACTION_HERO, and these come from the world state. |
| `level::ForbidWalk` | `ForbidWalkInArea` | `int(string, ?int)` | Closes walk map cells inside the zone's polygon on floor 0 (.wm) or 1 (.wm2). |
| `level::AllowWalk` | `AllowWalkInArea` | `int(string, ?int)` | Opens walk map cells inside the zone's polygon on floor 0 (.wm) or 1 (.wm2). |
| `level::TestFloorChange` | `TestActorMapChange` | `int(string, int)` | Heroes standing in the zone move to floor 0 (.wm) or 1 (.wm2). Called from the level's update() every tick. |

### 16.7 `hero` — Party

The hero party: the selected hero, who is in the party, enabling and placing heroes, whether any hero has something.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `hero::AnyInArea` | `HeroInArea` | `bool(string)` | True if at least one enabled and placed hero stands inside the zone's polygon (by background point). |
| `hero::GetSelected` | `GUI_GetSelectedHero` | `string()` | Returns the name of the currently selected hero. |
| `hero::InParty` | `GUI_IsHero` | `bool(string)` | True if the hero is in the party (on the panel) and enabled. |
| `hero::SetInParty` | `HERO_EnableEnumerate` | `int(string, int)` | The hero joins the party (1) or leaves it (0); outside_party is set to the opposite value. |
| `hero::EnableAll` | `EnableHeroes` | `int()` | Enables all heroes without the outside_party flag (party members). |
| `hero::DisableOthers` | `DisableHeroes` | `int()` | Disables all party heroes except the selected one. Right after level::Load it acts on the new level. |
| `hero::PlaceAll` | `PlaceHeroes` | `int(string, ?int)` | Places the heroes in the zone on floor 0 or 1 and moves the camera immediately. Returns 1; after level::Load it acts on the new level. |
| `hero::AnyHasItem` | `AnyHero_HaveItem` | `bool(string)` | True if the item's owner is a party hero. |
| `hero::AnyHasAmmo` | `AnyHero_HaveAmmoForWeapon` | `bool(string)` | True if any party hero has ammo for the weapon (the same check as in item::HasAmmo). |

### 16.8 `scene` — Scenes and video

Everything that plays "like a movie": scenes, dialogs, video, fades, the caption.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `scene::Start` | `StartScriptlet` | `int(scene)` | Immediately starts the scene (scriptlet) with this name. |
| `scene::StartNext` | `SetAddonScriptlet` | `int(scene)` | If a scene is playing, queues this scene after it (replacing one already queued); otherwise starts it immediately. |
| `scene::Dialog` | `DialogInit` | `int(dialog)` | Shows the whole dialog, line by line: `scene::Dialog(~d"lab-after_teleport")` is a `dialog` block of the project (the build checks that it exists). Classic writes `DialogInit("name", "file.dlg")`; nobody reads the name, and OG Script does not have it. A level's own dialog is `scene::Dialog(host.dialog)`, the `dialog` field of its block (for a battle, the pre-fight dialog, `StartDialog()`). |
| `scene::PlayVideo` | `AVI_Play` | `int(string, int, int, int)` | Plays a video (for example, before a boss fight) at screen position (x, y); double 1 shows it at double size. |
| `scene::Signature` | `Signature` | `int(int)` | Shows the date caption (a frame of intro.spr) at the bottom of the screen; -1 removes it. |
| `scene::FadeIn` | `FadeIn` | `int()` | Fades the screen in from black. After level::Load it acts on the new level. |

### 16.9 `gui` — Interface

Interface modes: panorama, scene mode, mode selection.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `gui::Panorama` | `GUI_Panorama` | `int(int)` | Turns panorama mode on (nonzero) or off (0). |
| `gui::SetMode` | `GUI_Disable` | `int(int)` | 0 restores normal mode, 1 turns off the panorama, 2 turns on scene mode (no control, automatic camera). |
| `gui::SelectMode` | `GUI_SelectMode` | `int(string)` | "GUI_Staging" starts a battle with the enemies' turn (they enter the field); "GUI_SafeBox" opens the safe's combination lock for the calling zone. |

### 16.10 `item` — Items and weapons

Items and weapons. Where Classic writes `"this"`, OG Script writes `host`.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `item::New` | `Item_New` | `int(string, string, ?string, ?int)` | Creates an item of this class. A string third argument is the owner, a number is the count; the fourth argument, if present, is the count (for example, the number of rounds). |
| `item::NewWeapon` | `Weapon_New` | `int(string, string, ?string, ?int)` | Creates a weapon of this class. A string third argument is the owner, a number is the count; the fourth argument, if present, is the count. |
| `item::Animation` | `Item_Animation` | `int(string, string, int)` | Plays an animation of the item's model once and holds the last frame; reverse 1 plays it backwards (a box closes with "box" reversed). |
| `item::SetPos` | `Item_SetPos` | `int(string, float, float, float)` | Moves the item to world coordinates. Another form (item, "area", point, z): places it at a point of the zone's polygon (-1 = the control point) on the floor, raised by z. |
| `item::SetAngle` | `Item_SetAngle` | `int(string, float)` | Sets the item's rotation angle in radians. |
| `item::SetNameID` | `Item_SetNameID` | `int(string, int)` | Sets the item's classic_id (name/type identifier). |
| `item::GetNameID` | `Item_GetNameID` | `int(string)` | Returns the item's classic_id, or -1 if the object does not exist or is not an item. |
| `item::SetPlace` | `Item_SetPlace` | `int(string, int)` | Sets the item's place; 0 (ground) for an owned item removes the owner, and a hero holding it in hand is left without a weapon. |
| `item::GetPlace` | `Item_GetPlace` | `int(string)` | Returns the item's place (0 = ground), or -1 if the object does not exist or is not an item. |
| `item::SetVisible` | `Item_SetVisible` | `int(string, int)` | Shows (1) or hides (0) the item. |
| `item::SetFuncID` | `Item_SetFuncID` | `int(string, any)` | Sets the item's action: the name of an Action rules row ("Close", "walk", "none") or its number (its action field). |
| `object::ActionId` | `ActionId` | `int(string)` | OpenGorky only (the original exe has no such function), for comparing the action field: the action number by Action row name ("walk" −1, "none" 0), 0 if there is no such row. |
| `item::GetType` | `Item_GetType` | `int(string)` | Returns the item's kind (`kind`; for a weapon, `damage_kind`, as in the exe), or -1 if the object does not exist or is not an item. |
| `item::EnableWalkCircle` | `Item_EnableWalkCircle` | `int(string)` | Makes .wm cells within the item's walk_block_radius walkable (in background pixels, if at least 2). |
| `item::DisableWalkCircle` | `Item_DisableWalkCircle` | `int(string)` | Closes .wm cells within the item's walk_block_radius (in background pixels, if at least 2). |
| `item::HasAmmo` | `Actor_HaveAmmoForWeapon` | `bool(string, string)` | True if the actor has an item whose classic_id equals the weapon's ammo and whose count is above 0. |

### 16.11 `battle` — Battle

The battle as a whole: tiles, turns, the bomb, battle variables, spawning fighters, victory and defeat. Functions without an original Classic name are OpenGorky only; outside battle they do nothing and return 0 or `nil`.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `battle::PlaceProp` | `PlaceCombatActor` | `int(string, float, float, float)` | Places a battle object at a fractional grid tile (not snapped to the tile center), rotated by angle degrees. Returns 1 on success, otherwise 0. |
| `battle::IsFreeTile` | `AIFreeTile` | `bool(int, int)` | True if the battle grid tile is inside the grid, walkable and free (false outside battle). |
| `battle::GetTurnNo` | `AIGetTurnNo` | `int()` | Returns the current battle turn number, 0 outside battle. |
| `battle::Nearest` | `BattleNearest` | `any(list, string)` | OpenGorky only (the original exe has no such function), for fighter evaluation: returns the living fighter of the side nearest to the tile (dx² + dy²), nil if there is none. |
| `battle::EndTurn` | `EndTurnGlobal` | `int()` | Ends the current side's turn in battle. |
| `battle::PutLargeTimeBomb` | `PutLargeTimeBomb` | `int(int, int)` | Places a large time bomb on a battle tile; after 6 enemy turns it explodes and everyone dies. Returns 1 if placed, 0 if the tile is off the map. |
| `battle::GetVar` | `BattleGetVar` | `any(string name)` | The value of a battle variable (nil if not set); battle variables live until the end of the battle. |
| `battle::SetVar` | `BattleSetVar` | `any(string name, any value)` | Sets a battle variable; every fighter's OnVar(name, value) hears it. |
| `battle::AddVar` | `BattleAddVar` | `any(string name, any delta)` | Adds to a battle variable and returns the new value; every fighter's OnVar(name, value) hears it. |
| `battle::SpawnEnemy` | `BattleSpawnEnemy` | `any(character fighter, int x, int y)` | Puts a new fighter into the battle on free tile (x, y) (for a large fighter, its top-left tile). `fighter` is a class key as the rules name it (`"ft_hornet"`: the fighter that includes this script, like a level fighter), or a `.ftr` file; in an OpenGorky project, a fighter archetype (`~c"characters::grandma_child"`, §10.9): the object of its block with its nested weapons, named after the last part of the path. The object is named after it (`ft_hornet`, `ft_hornet_2`…). The fighter gets the native and scripted abilities of its `Abilities` row and `OnSpawn`, like a fighter entering battle. Weapons come from the `weapons` field (`"a.wpn, b.wpn"`); if it is absent, copies of the weapons of the first fighter of the same class in the world; if there is none, only `MonsterAttack` rows with `give`. Returns the object name or `nil`: outside battle, no such class, the tile is outside the grid or occupied. The fighter is on the enemy side and acts under AI, like any enemy. |
| `battle::SpawnHero` | `BattleSpawnHero` | `any(character fighter, int x, int y)` | Like `battle::SpawnEnemy`, but the fighter is on the heroes' side and is controlled by the player: it can be selected and given a turn like a hero (its death, like a hero's death, is a defeat). It does not join the party: after the battle it stays at the location. |
| `battle::SpawnCivilian` | `BattleSpawnCivilian` | `any(character fighter, int x, int y, ?string ai)` | Like `battle::SpawnEnemy`, but the fighter is on nobody's side (`side` is `"civilian"`): both heroes and enemies attack it, and it does not count toward victory or defeat (a script can declare the outcome: `battle::Lose`, §15.2). `ai`: `"dummy"` (default) — stands still and does nothing; `"normal"` — acts on the enemies' turn under its class's AI and attacks both heroes and enemies. Any other value gives `nil`. |
| `battle::Lose` | `BattleLose` | `int()` | The battle ends in defeat, as when the heroes die (game over): at the next end-of-battle check (after the current action). 1; 0 outside battle. |
| `battle::Win` | `BattleWin` | `int()` | The battle ends in victory, as when the last enemy dies: at the next end-of-battle check (after the current action) — reward, `OnBattleEnd`. 1; 0 outside battle. |

### 16.12 `fighter` — Fighter

A single fighter: health, level, skills, AI, damage, states, transformation. OpenGorky-only functions have named parameters (§8.1); outside battle they do nothing and return 0 or `nil`.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `fighter::GetHp` | `FighterGetHp` | `int(string)` | Returns the fighter's current hit points (0 if the object is not found). |
| `fighter::SetHp` | `FighterSetHp` | `int(string, int)` | Sets the fighter's hit points. Only an integer is accepted; there is no upper limit. OpenGorky: a call from OG Script in battle is written to the battle log (`name: hp set N`); a call from Classic is not. |
| `fighter::SetLevel` | `FighterSetLevel` | `int(string, int)` | Sets the fighter's level and experience equal to that level's threshold. |
| `fighter::SetWeaponSkill` | `FighterSetWeaponSkillLevel` | `int(string, int, int)` | Sets the fighter's skill level with the weapon of this classic_id; adds the skill if there is none. |
| `fighter::Appear` | `AIEnemyAppear` | `int(string, int, int, int, int)` | The enemy is placed on tile (x0, y0), often beyond the edge of the grid, and at the start of battle walks to (x1, y1). |
| `fighter::LockTarget` | `AITargetLock` | `int(string, string)` | The fighter attacks only this target (sets ai_mode 1). |
| `fighter::GuardTile` | `AIGuardPoint` | `int(string, int, int)` | The fighter holds battle tile (x, y) (sets ai_mode 3). |
| `fighter::SetTarget` | `FighterSetTarget` | `int(string who, string target)` | The fighter's AI attacks the target first (like Grandma attacking her child's killer). |
| `fighter::Damage` | `FighterDamage` | `int(string who, int amount, ?string kind, ?string from)` | Deals damage to the fighter immediately, ignoring armor and OnHit (reflected damage is not reflected back). `from` is on whose behalf (that fighter becomes the killer); `kind` is written to the battle log. |
| `fighter::GetLastAttacker` | `FighterGetLastAttacker` | `any(string who)` | The fighter that hit it last, or nil. |
| `fighter::Native` | `FighterNative` | `any(string who, string name)` | OpenGorky only. The fighter's native component with this name (`"Guard"`, `"Stand"`…) or nil; its parameters are its variables: `fighter::Native(host, "Guard").div = 4` changes the defense from that moment on (§13.2). In and out of battle. |
| `fighter::AddState` | `FighterAddState` | `int(string who, string state, ?int turns)` | Gives the fighter a state: `"sleep"`, `"freeze"`, `"burn"`, `"gas"`, `"soak"`, `"defend"` for `turns` turns, `"rage"` for `turns` actions (default 1). Returns 1 if done, 0 if there is no such state. Only the counter is set, without the effect's pose, sound and caption. |
| `fighter::Side` | `FighterSide` | `string(string who)` | "hero", "enemy", "neutral" (an obstacle), "civilian" (on nobody's side) or "" (not in battle). |
| `fighter::IsAlive` | `FighterAlive` | `bool(string who)` | True while the fighter is in battle. |
| `fighter::Popup` | `FighterPopup` | `int(string who, string text)` | Text popping up above the fighter, like "Miss". |
| `fighter::Transform` | `FighterTransform` | `int(string who, string into, ?string anim, ?string idle, ?sound sound)` | The fighter transforms into class `into` — a class key as the rules name it (`"ft_hornet"`), or a class file (`.mtm`, `.ftr`) — the same way as the battle's `Transform` row: `moveLock` and `attackLock` and the glow are removed; after `morf_life2` ticks come the new class's values (its `init()`: `hp`, `max_hp`…) and model `anim` (empty means the class's model), then the `idle` animation plays once, with sound `sound`. The health the fighter has at the end of the transformation (including health set by `fighter::SetHp` after `fighter::Transform`) is kept; `max_hp` and the rest come from the new class. Native and scripted abilities are taken from the `Abilities` row of the new class: the old scripted abilities that are not in it are detached, new ones are attached, and one present in both stays as it was (with its variables). Returns 1; 0 if there is no such fighter or class. |

### 16.13 `events` — Events

The event bus between components (§14.1). OpenGorky only.

| OG Script | Classic | Signature | What it does |
|---|---|---|---|
| `events::Emit` | `Emit` | `int(string event, ?any args...)` | OpenGorky only. Calls the handlers of the event's subscribers in subscription order with the remaining arguments (as is); returns how many were called. No deeper than 8 nested levels; in battle, writes a log line `emit name n=…`. |
| `events::Subscribe` | `Subscribe` | `bool(string event, method handler)` | OpenGorky only. From a component method: this instance hears the event through its method `handler` (§14.1). `method` is the name of a method of the calling component and is checked at link time. |
| `events::Unsubscribe` | `Unsubscribe` | `int(string event, ?method handler)` | OpenGorky only. Removes the calling instance's subscriptions to the event (with `handler`, only that one); returns how many were removed. |

### 16.14 Classic only

These original functions have no OG Script name: the same thing is done differently. Classic scripts call them as before; translation from Classic to OG Script writes the replacement, and the reverse translation writes the Classic call again.

| Classic | Signature | What it does | In OG Script |
|---|---|---|---|
| `GetName` | `string()` | Returns the name of the object whose script is running. | `host.name` (§6.6) |
| `Disable` | `int()` | Disables the current actor (the one whose script is running). Does nothing for an object that is not an actor. | `object::Disable(host)` in an actor script; for a non-actor, translation drops the call (in the exe it does nothing) |
| `s_stricmp` | `int(string, string)` | Compares strings ignoring case. Returns 0 if equal, otherwise the difference of the first differing characters (or of the lengths). | `EqualsIgnoreCase(a, b)` for equality (`bool`); OG Script does not provide the character difference, so translation leaves the `s_stricmp` call as is |

## 17. Errors and diagnostics

There are three kinds of errors. The language has no exceptions and no way to catch errors.

### 17.1 Parse errors

The lexer and the parser stop at the first error. A diagnostic is a line and a message. Text with a parse error is not loaded at all; the log gets `file:line: message`. Common messages:

| Message | Cause |
|---|---|
| `UnexpectedChar`, `UnterminatedString`, `UnterminatedComment` | lexical (§3) |
| `unknown name x` | unknown name in a free function (in a component it is a runtime error) |
| `host outside a component`, `self outside a component` | `host`/`self` in a free function |
| `a positional argument after a named one` | `f(a: 1, 2)` |
| `lists and maps are read-only (v1)` | `xs[0] = 1` |
| `cannot assign to this` | assignment to a call, a literal, etc. |
| `field X declared twice (names apart only by case clash)` | a component field repeated, ignoring case |
| `method X defined twice`, `parameter X twice` | duplicates |
| `integer too large` | literal outside i32 |
| `expected a declaration or a call` | something other than `module`, `use`, `component`, `fn`, a data block or a call at the top level |
| `attach takes named parameters (p = value)` | `attach Rage(30)` |
| `unknown sigil ~q`, `expected a string after the sigil` | sigil (§6.8) |
| `commands are in scene and dialog blocks only` | a call inside a block of another kind (§11) |
| `unknown classic::x`, `classic::x takes N arguments` | a `classic::` module form (§20.1) |
| `unexpected if`, etc. | a keyword where a value is expected |
| `expected …` | syntax |

### 17.2 Link errors

These are checked when the whole program is linked (§2). The message includes the file and line.

| Message | Cause |
|---|---|
| `unknown function f` | neither a function nor a builtin (case matters) |
| `unknown function FighterSetHp (did you mean fighter::SetHp)` | the Classic name of a builtin: in OG Script it lives in a package (§16) |
| `fighter: reserved package` | a module is named after a builtin package or `classic` (§9) |
| `f takes N arguments` | more positional arguments than parameters |
| `f has no parameter p` / `builtin F has no parameter p` | a named argument with no such parameter; for a builtin without names in its signature, any named argument |
| `f: p given twice` | a parameter is given twice |
| `f: no value for p` | a parameter without a default has no value |
| `F: the arguments before a named one are needed` | a builtin call skips a position before a named argument |
| `X is defined twice` | one path is defined twice |
| `use x: no such namespace` | `use` of a namespace that does not exist (or is not loaded yet) |
| `f is in more than one used namespace` | `f` exists in two namespaces opened with `use` |
| `F: argument N is a level, not a sound` | a sigil of another kind for a builtin's parameter (§6.8) |
| `events::Subscribe: C has no method h`, `events::Subscribe: call it in a component's method` | the event handler is not a method of the calling component or trait; subscribing outside a method (§14.1) |
| `no level x`, `no scene x`… | a sigil names something that does not exist (§6.8) |
| `unknown block kind X`, `X has no field f`, `f: expected int`, `f: no value w` | a data block checked against its schema (§11) |
| `no fighter a::b`, `f: no weapon a::b`, `no block a::b` | archetype, reference field, path in data (§11) |
| `R: a record takes named fields (f = v)` | a record with a positional argument (§11) |
| `no component X`, `X has no param p` | `attach` in a data block |
| `C: no f() (required by T)` | a required trait method is not defined (§10.4) |
| `C.f takes N parameters (as T.f), not M` | parameter count differs from the trait |
| `C: f has defaults in A and B: define it` | two unrelated default bodies |
| `super.f: defaults in A and B: write A::f(self, …)` | `super` is ambiguous |
| `super.f outside a method that overrides f` | `super` is not in a method `f` that overrides a trait method |
| `OnHit takes 3 parameters (attacker, weapon, amount), not 2` | an engine event with a different parameter count |
| `trait T: OnDeath is an engine event: name the host (trait T: foundation::Fighter)`, `C: OnHit is an engine event: name the host (for fighter)` | an engine event in a trait or component without a host |
| `a trait has no fields: x (add fn x(); and define it in the component)` | a bare name in a trait body |
| `Hero is a role the engine grants: write for Hero` | a role after `:` |
| `C for level: T is for fighter` | the component's host does not fit the trait |
| `inventory is the engine's (Hero): a component can't define it` | a component defines an engine method |
| `host.inventory(): host is fighter, inventory is Hero's (…)` | a role method on a `host` of another kind |
| `T is both a trait and a module` | a trait and a module with the same path |
| `trait a::T is defined twice` | a trait is defined twice |
| `trait A: a trait can't be its own supertrait (A: B: A)` | a supertrait cycle |
| `get(Rage): Rage is a component, not a trait`, `no trait X` | not a trait |
| `no trait Hero (Hero is foundation's: write foundation::Hero, or use foundation;)`, `no enum Side (…)`, `no type Side (…)`, `unknown function Place (…)` | an engine name in code without `foundation::` and without `use foundation;` (§9) |
| `foundation: reserved package` | a module named after an engine namespace |
| `Hero already means fighter`, `C for x: no such host kind`, `C for Battle: a host kind is lowercase: write for battle` | names and hosts of builtin traits |

The code check in the editor parses and links the rules file together with the other loaded texts, just as the engine does, but marks only errors in its own file. It checks level, scene and sound sigils against the game, and marks a plain string passed to a kind parameter with the note "write `~l"…"`". It also checks the names and parameter counts of `On…`/`Can…` methods of `for fighter` components against the event table, and the methods of `for game` components against the hooks.

<!-- check: error unknown name x -->
```ogs
fn f() { return x; }
```

<!-- check: error fighter::Damage: the arguments before a named one are needed -->
```ogs
component Bad for fighter {
    fn OnHit(attacker, weapon, amount) {
        fighter::Damage(attacker, 5, from: host);   // kind is missing
    }
}
```

<!-- check: error builtin sound::Play has no parameter loop -->
```ogs
fn f() { return sound::Play("door", loop: 1); }
```

<!-- check: error lists and maps are read-only (v1) -->
```ogs
fn f() { var xs = [1, 2]; xs[0] = 5; return xs; }
```

### 17.3 Runtime errors

A runtime error aborts the current handler call (together with all nested calls). The location and text of the error are recorded. The event dispatcher and the hooks write `file:line: message (Component.Event)` to the log and carry on: that handler's result is ignored, and the chain continues with the previous `amount`. Currently the log line is written on every call, not once per location.

| Message | Cause |
|---|---|
| `no field or host variable x` | a name in a method that is neither a field nor a host variable (read or assignment) |
| `X has no variable y` | `obj.y = v`, and the object has no `y` |
| `X.name is read-only` | `obj.name = v` (§6.6) |
| `nil is no object`, `5 is no object` | `.field` or `.f()` on something that is not a reference |
| `40 add "!"`, `nil lt 3`, etc. | an operation on values of unsuitable kinds: left operand, operation, right operand |
| `-"x"` | unary minus on something that is not a number |
| `index 5 of a list of 2`, `"s"[0]` | index out of the list, indexing something that is neither a list nor a map |
| `for over 5`, `a range is of ints: 1..2.5` | `for` over something that is not a list/map, a range not made of integers |
| `X has no function f` | `obj.f()` with no such function |
| `C has no param p` | attaching with a parameter that does not exist |
| `f: too many named arguments` | more than 16 named arguments |
| `StackOverflow` | call depth over 64 |
| `events::Emit: EmitTooDeep`, `events::Subscribe: NoSuchMethod`, `events::Subscribe: NotInComponent` | more than 8 nested `events::Emit`; the computed handler name is not a method of the component; subscribing from outside a component (§14.1) |

<!-- check: fault 40 add "!" -->
```ogs
component Broken {
    fn run() { return host.hp + "!"; }      // number + string: no implicit conversion
}
```

The correct way is to convert the number to a string explicitly:

<!-- check: link -->
```ogs
component Fixed {
    fn run() { return str(host.hp) + "!"; } // "40!"
}
```

## 18. Determinism

OpenGorky battle logs are compared byte for byte, so the language is deterministic:

- the language has no random functions, clocks or system time. The only randomness among the builtins is in functions of the original (`sound::PlayRandom2D`), which use the same `rand()` stream as the exe;
- handlers are called in the order the components were attached, fighters in roster order;
- maps are iterated in insertion order;
- numbers are wrapping i32 and f32, as in the exe; float → int conversion truncates, like `_ftol`.

**Planned:** `Random(n)` on the game's shared `rand()` stream.

## 19. What the language does not have

- **Coroutines and waiting** (`wait`, `yield`, timers): a handler runs to completion at once. Deferred work is done by actor queues (`Actor_Queue…`) and scenes.
- **Mutable containers**: a list or map element cannot be assigned, nor can one be added. Lists and maps are literals and temporary values.
- **String and list functions**: length, substring, search, `int()`. A string from a value comes from `str(x)` (§16.1) or a typed variable (§4.1).
- Block scopes, closures, functions as values, lambdas.
- Exceptions and `try`.
- `#include` and `#inherit`: modules, `use` and components replace them.
- Object lookup: `Find`, `FindAll`, `host.Call` (**planned**). There are `@name` and trait queries `is`, `as`, `get`, `all` (§10.4).
- `Battle`, `Level`, `Game` objects with fields (`Battle.turn`, etc.): builtins are used instead (`battle::GetTurnNo()`, `level::GetName()`) (**planned**).
- The operators `*=`, `/=`, `++`, `--`, the ternary operator, `switch`, bitwise operations.
- Type checking of builtin function arguments (**planned**).
- Level and game variables (**planned**, §14).

## 20. OG Script and Classic

Both languages compile to the same IR. They are connected as follows:

- The **importer** (`src/script/classic/import.zig`) translates Classic functions into IR on their first call. The exe's behavior is preserved: where the importer cannot prove that a regular node behaves the same, it emits an exe-quirk node (in text, `classic::*`). All 1089 game scripts run only through the IR, and battle logs match the original.
- **Printing Classic code as OG Script** (`src/script/ogs/print.zig`): the imported IR is printed as OGS text, with exe quirks as calls to the `classic::` module. Builtins get their OG Script names from the §16 table (`src/script/classic/rename.zig`): `FighterSetHp` → `fighter::SetHp`, `"this"` → `host`, `GetName()` → `host.name`, `DisableObject(x)` → `object::Disable(x)`, `Disable()` in an actor script → `object::Disable(host)` (for a non-actor the call is dropped with a log entry: in the exe it does nothing), `ActorDelay` and `ActorQueueDelay` → `path::Delay`. In the other direction (the OGS parser, then the same table) the names become exe names again, and a call is written the way the function wrote it (`DISABLEOBJECT`, `ActorQueueDelay`); a new one gets the canonical name (`DisableObject`, `ActorDelay`). The OGS parser reads this text back into the same IR. This is verified on every function in the game (`gorky-tool roundtrip`, the "printed as OGS and read back" step).
- The **exporter** (`src/script/classic/export.zig`) writes IR changes back into the Classic source text. Untouched text stays byte for byte; a changed node is reprinted in the original's style, within its own bytes only. Every written function is imported again and must yield the same IR. The exporter rejects nodes that Classic does not have (named arguments, `+=`, `host`, `@name`, loops…) with `error.NotClassic`: nothing is silently lost.
- **Converting a Classic project into an OpenGorky mod is one-way**: the project stays the same, the exporter changes (Classic → mod), and from then on code is written in OG Script. A mod does not turn back into Classic.
- **Code translation** (`src/script/classic/ogsify.zig`, `gorky-tool convert <game> --code [--stats]`): the functions of each Classic script become methods of a component `for` its host kind (`component _01_port for level { … }`), and base class functions become components of the `base` module. Unlike the printing above, this is real OG Script with its own semantics: the converter knows the types of class variables and builtin results and emits a regular node wherever the value is provably the same: a class variable becomes a field, `this` becomes `host.name`, the truthiness of an `int` and of a yes/no result stays as is, strings become `false`, `==`, arithmetic and number comparisons become regular operators (where the order of operand effects does not matter), `HeroInArea(…) == 1` becomes `hero::AnyInArea(…)`, `s_stricmp(a, b) == 0` becomes `EqualsIgnoreCase(a, b)`, and `&&`/`||` with side effects puts both sides into temporary `var`s (right side first), then uses `and`/`or`. Exe events get method names (`init` → `OnCreate`, `NodeResponse` → `OnNode` with the missing parameters added); a function without `return` whose value is read gets `return 0;`. An assignment to an undeclared variable is dropped (the exe skips it), and so is a call to a function that does not exist (its arguments stay for their side effects). Everything else becomes `classic::` forms (§20.1). Verification: all game functions parse and link as one program, each runs both as Classic IR and as the translation on the same inputs (arguments, object variables and builtin results come from a seed), and the result, variables and builtin calls match.

Currently, in a Classic project the editor edits the model (fields, animations, inventory) through the exporter and shows code as Classic text. **Planned** (Classic project code is shown and edited in OG Script, and export must produce valid Classic): an OGS code editor for Classic projects, lowering of OGS constructs that have a Classic equivalent, OGS highlighting and navigation.

### 20.1 The `classic::` module

A compatibility module: the same implementation of exe quirks (`src/script/exe.zig`) under an honest name. Its calls appear in printed Classic code and, after a project is converted, wherever equivalence with plain OG Script is not proven. Do not write them in new code. The set is closed; `classic::` has no other functions. Arguments are evaluated **right to left**, as in the exe.

| Form | What it reproduces |
|---|---|
| `classic::add sub mul div lt gt ge (a, b)` | exe arithmetic and comparisons: a string is 0 in integer arithmetic and parsed in float arithmetic |
| `classic::eq(a, b)` | exe `==`: on truncated integers, two strings are always "equal" |
| `classic::ne(a, b)` | exe bug: `!=` adds |
| `classic::le(a, b)` | exe bug: `<=` works like `>=` |
| `classic::and(a, b)`, `classic::or(a, b)` | no short-circuit evaluation, exe truthiness |
| `classic::neg(x)`, `classic::not(x)`, `classic::truthy(x)` | minus (a string is parsed), `!` and exe truthiness: a float is truncated (`0.5` is false), a string is false |
| `classic::name("x")` | a Classic name at runtime: local → object variable → `this` → scene object name → 0 |
| `classic::maybe("x")` | a local declared on only some paths |
| `classic::fail("ScriptNotFound", "file", line, "message")` | an `#include` that failed to load: an error at the same point |

<!-- check: link -->
```ogs
// This is what a printed Classic function looks like.
fn init(who, n) {
    var int k;
    if (classic::truthy(n)) {
        k = classic::add(n, 1);
    } else k = classic::ne(k, 2);
    classic::name("state") = k;
    return sound::Play("a", 800) + k;
}
```

## 21. Differences from the Classic language: table

| | Classic (`.s`, `.ss`, `.lev`…) | OG Script |
|---|---|---|
| Name case | insensitive | sensitive (except object variables) |
| Function | `function f(int a, string b) { … };` | `fn f(a, b: int = 2) { … }` |
| Declaration | `int x;`, type required | `var x;`, `var int x = 1;` |
| Types | `int float string object` | plus `nil bool list map ref` |
| Arguments | positional only | positional, named, optional with a default |
| Strings | no escapes | `\" \\ \n \t` |
| `==` | on truncated integers (`1.5 == 1`), two strings are always equal | by value and kind |
| `!=` | exe bug: adds | regular |
| `<=` | works like `>=` | regular |
| `&&`, `\|\|` | both sides, right to left | short-circuit (`and`, `or` too) |
| Result of comparisons and logic | `int` 0/1 | `bool` |
| Builtin names | exe names, flat (`FighterSetHp`) | packages (`fighter::SetHp`, `use fighter;`), core at the root (§16) |
| Yes/no builtin result (`HeroInArea`, `hero::AnyInArea`…) | `int` 1/0 | `bool` |
| Function without `return` | returns 0 | returns `nil`; an event handler returning `nil` changes nothing |
| Operand order | right to left | left to right |
| Truthiness | `toInt != 0`: `0.5` is false, any string is false | false: `nil false 0 0.0 ""` |
| String in arithmetic | 0 | runtime error; `+` of two strings concatenates |
| String + number | in arithmetic the string is 0 | runtime error, no implicit conversion: `str(host.hp) + "!"` |
| Object name | `GetName()` of the caller | `obj.name` on any reference (read-only), `host.name` |
| `%` | no | yes |
| Loops | no | `while`, `for … in`, `break`, `continue` |
| `+=`, `-=` | no | yes |
| Lists, maps | no | literals `[…]`, `{…}` |
| Unknown name | silently 0 / scene object name | parse error (in a function) or runtime error (in a component) |
| Unknown function | silently 0 (counter) | link error |
| Assignment to an undeclared variable | skipped | runtime error |
| Runtime errors | none: everything is "silent" | abort the handler, written to the log |
| Objects | a name string; `a.b` is a single name | `@name`, `@"name"`, `host`, `self`, `obj.field`, `obj.f()` |
| Level, scene, sound names | a string, unchecked | sigil `~l"01_port"`: checked at load time (§6.8) |
| Entity data | assignments in `init()`, `.var`, `#include` | data blocks checked against a schema (§11) |
| Structure | class = file, `#inherit`, `#include` | components on hosts; modules and `use`; files mean nothing |
| Events | functions by exe names (`init`, `update`, `UseItem`…) | component methods per the event table (§13) |
| Call depth | unlimited (recursion breaks the exe's stack) | 64 |

