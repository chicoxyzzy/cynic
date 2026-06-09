# Zig idioms in Cynic

Pinned to a specific 0.17-dev SHA — see `.minimum_zig_version`
in `build.zig.zon`. [anyzig](https://github.com/marler8997/anyzig)
(via Homebrew) reads that field to dispatch the local `zig`
binary to the right compiler, so `which zig` is the anyzig shim
and `zig version` reports whatever the zon pins. CI uses
`xyzzylabs/setup-zig` with no explicit `version:`, so it resolves
the same field; keep the zon pin as the single source of truth.
The master parser is strict in ways the previous release isn't
(see "Array repeat" below for an example that ate a debug
session).

Things that surface during contribution:

## Allocators

- **`std.heap.DebugAllocator`**, not `GeneralPurposeAllocator`.
  The rename happened in 0.13 / 0.14; the old name is gone.
- Per-parse arena: `var arena: std.heap.ArenaAllocator =
  .init(gpa); defer arena.deinit();`. Every parser AST node
  lives in the arena; freeing the arena frees the entire tree
  at once.
- `errdefer` to undo allocation when an early return is
  possible.

## I/O

- **`std.Io.Dir` / `std.Io.File`** — not `std.fs`. Open dirs
  with `std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true })`.
- **`std.Io.Clock.now(.awake, io)`** — monotonic; for elapsed
  time. `.real` for wall-clock seconds. `std.time.milliTimestamp`
  and `std.time.timestamp` are gone.
- **Directory walking**: `try corpus.walk(gpa)` returns a walker
  with `next(io)`.
- The `Io` capability is passed in via `std.process.Init`.

## Argv & process

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // skip binary path
    //...
}
```

`std.process.argsWithAllocator` is gone.

## Collections

- **`std.ArrayListUnmanaged(T) = .empty`**, not `.{}`. Same for
  `std.HashMapUnmanaged`.
- Append: `try list.append(arena, item);` — the arena is the
  allocator, passed per-call.
- Convert to slice: `try list.toOwnedSlice(arena)`.

## Array repeat

- **`@splat(value)`** to fill a fixed-size array with a single
  value:
  ```zig
  const slots: [N]T = @splat(.{ .name = "" });
  ```
  Use this — not the older `[_]T{value} ** N`. The legacy
  `**` form parses as two `*` tokens in master Zig and the
  parser rejects `}} ** N` because the whitespace around the
  first `*` is asymmetric (`}` left, `*` right, no space).
  `@splat` is the spec-blessed replacement and has none of the
  parse-edge surprises.

## Strings

- **`std.mem.trimEnd`**, not `trimRight` (0.13+ rename).
- **`std.mem.eql(u8, a, b)`** for byte equality.
- **`std.mem.startsWith(u8, s, prefix)`**, **`endsWith`**,
  **`indexOf`**, **`indexOfScalar`**.
- Multiline string literals: lines start with `\\`. **No** escape
  processing — `\\u0065` is the seven literal bytes
  `e`, not the codepoint. Use this for golden-test
  expectations.
- Regular string literals: `"\u{0065}"` (curly-braced) —
  `"e"` is a Zig parse error.

## Comptime

- **`inline for (@typeInfo(E).@"enum".field_names)`** to walk every
  variant of an enum at comptime. Cynic uses this in
  `Code.errorClass`'s pinning test.
- **`comptime f: fn (...) ...`** parameters in generic helpers
  — see `runOne` in `tools/test262.zig`.

## Errors

- **Inferred error sets cycle** when two functions call each
  other and both return `!T`. Break the cycle by giving one an
  *explicit* error set: `const WriterError =
  std.mem.Allocator.Error;` then `fn writeBlock(...)
  WriterError!void`. See `src/ast/printer.zig`.
- `_ = err;` inside a `catch |err|` triggers "error set is
  discarded". Use `catch { ... }` (no error capture) when you
  don't need the value.

## Capture-name shadowing

Inside `switch`, `if`, `for`, the capture name (`|x|`) lives in
the same scope as outer params. Shadow warnings are errors. Pick
distinct names: a function param `tok` plus a switch capture
`|sup|` (not `|tok|`).

## UTF-8

- **`std.unicode.utf8ByteSequenceLength(b0)`** for the lead
  byte's intended length.
- **`std.unicode.utf8Decode(slice[0..len])`** for codepoint
  extraction.
- The lexer's `peekUtf8` wraps both. Whitespace classes
  (Space_Separator) and line-terminator classes (LS, PS) live
  in `isUnicodeWhitespace` / `isUnicodeLineTerminator` in
  `src/lexer/lexer.zig`.

## Build

`build.zig` follows the pinned 0.17-dev shape: `b.createModule`,
`b.addExecutable({ .name, .root_module })`, `b.addRunArtifact`,
`b.step`. Argument forwarding via `run.addPassthruArgs();`.

`zig build run -- parse foo.js` forwards args after `--`. Same
for `test262`, `gen-unicode`.

## Test discipline

- One `test "..."` block per behavior. Tests live in the same
  file as the production code (Zig convention).
- Top-level `test {}` block in `tools/test262.zig` exists only
  to force `zig build test` to walk the helper modules:
  `_ = frontmatter; _ = skip_rules;`.
