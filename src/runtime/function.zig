//! `JSFunction` — Cynic's runtime function object.
//!
//! Carries the per-instance state needed at call time: a pointer
//! to the function's compiled `Chunk` (the *template*), and (in
//! later) a captured environment for closures. later ships
//! without closures — function bodies can reference their own
//! params and locals only; cross-function references will emit
//! `UnresolvedReference`. The `captured_env` field is wired in
//! now so that pass B is purely additive.
//!
//! `JSFunction` is a heap object (mark-sweep tracked); the
//! template `Chunk` is OWNED by the enclosing chunk's
//! `function_templates` table — instances merely reference it.
//!
//! Spec anchor: §10.2 Function Objects, §15.2 FunctionDeclaration.

const std = @import("std");

const Chunk = @import("../bytecode/chunk.zig").Chunk;
const Environment = @import("environment.zig").Environment;
const JSObject = @import("object.zig").JSObject;
const PropertyFlags = @import("object.zig").PropertyFlags;
const Accessor = @import("object.zig").Accessor;
const Value = @import("value.zig").Value;

/// Discriminator for heap objects sharing the `Object` value tag.
/// First field of every callable / plain-object heap struct so
/// the interpreter can dispatch by reading the leading byte
/// after a `Value.asObject()`.
pub const HeapKind = enum(u8) {
    function = 0,
    object = 1,
    symbol = 2,
    bigint = 3,
};

/// `[[ConstructorKind]]` (§10.2.1). Distinguishes ordinary
/// functions (`base` — callable both as functions and via `new`)
/// from class-constructor functions (`derived` — must call
/// `super(...)` before `this`). later treats `derived` and
/// `base` identically at the call site; the precise `this`
/// initialization rules are later.
pub const ConstructorKind = enum(u8) {
    base,
    derived,
};

/// Signature for a host-implemented function. The realm gives the
/// callable access to the heap; arguments are read-only; the
/// return value lands in the caller's accumulator. Native fns
/// can throw via the Zig error union — `error.NativeThrew`
/// surfaces a runtime exception with a value the host must place
/// in `realm.heap.allocateString` before returning.
pub const NativeError = error{
    OutOfMemory,
    NativeThrew,
};

pub const NativeFn = *const fn (
    realm: *@import("realm.zig").Realm,
    this_value: @import("value.zig").Value,
    args: []const @import("value.zig").Value,
) NativeError!@import("value.zig").Value;

pub const JSFunction = struct {
    /// Discriminator — must remain the first field. Read by
    /// runtime checks like `valueAsFunction` to distinguish
    /// `JSFunction` from `JSObject` without a separate value tag.
    kind: HeapKind = .function,
    /// Bytecode + constants + handler table for the function body.
    /// Ownership lives on the enclosing chunk's
    /// `function_templates`; this is a non-owning reference.
    /// `null` for native (host-implemented) functions, in which
    /// case `native_callback` is non-null.
    chunk: ?*const Chunk = null,
    /// Native (Zig-side) callback — set for built-ins like
    /// `console.log`, `print`. The Call opcode short-circuits to
    /// this when present, bypassing frame allocation.
    native_callback: ?NativeFn = null,
    /// Number of declared parameters. The interpreter uses this
    /// to decide how many caller-supplied arguments to copy into
    /// the callee's first registers, padding with `undefined`
    /// when fewer are supplied (§10.2.3).
    param_count: u8,
    /// Display name (for `Function.prototype.name`, future stack
    /// traces). Anonymous functions store `null` and the host
    /// will infer "" / "<anonymous>" later. Backed by
    /// `name_string` (allocated in `heap.allocateFunction*`) so
    /// `JSFunction.get("name")` can return a `Value.fromString`
    /// without re-allocating from a `*const` receiver.
    name: ?[]const u8,
    /// Heap-owned JSString carrying the same bytes as `name`.
    /// Lifecycle is managed by the heap (sweep walks it through
    /// `strings`). `null` for anonymous functions.
    name_string: ?*@import("string.zig").JSString = null,
    /// §20.2.3.5 — borrowed slice of the original source spanning
    /// the FunctionExpression / FunctionDeclaration / ArrowFunction
    /// / MethodDefinition. Stamped from the template's `source`
    /// at `make_function` time. `null` for native, bound, and
    /// engine-synthesised functions — those fall back to the
    /// `function NAME() { [native code] }` placeholder.
    source: ?[]const u8 = null,
    /// Whether this is an arrow function. Affects `this` binding
    /// (§15.3 — arrows inherit `this` lexically) and self-binding
    /// rules (declarations / named function expressions get a
    /// self-binding inside their own scope; arrows don't).
    is_arrow: bool = false,
    /// Captured outer environment — the lexical environment in
    /// effect when this function instance was created. Closures
    /// over outer-scope bindings traverse this chain at call
    /// time. `null` for top-level scripts that don't yet have an
    /// environment (the interpreter passes the script's env on
    /// the very first call).
    captured_env: ?*Environment = null,
    /// §10.4.1 GetActiveScriptOrModule — the ModuleRecord this
    /// function was defined inside, captured at `make_function`
    /// time. Set to `realm.current_module` whenever the function
    /// is created during a module body's evaluation; `null` for
    /// functions defined in script-goal code or in native
    /// installer paths. Used by the `import_meta` opcode (and
    /// any future host-script-or-module dispatch) so that a
    /// function exported from module A and called from module B
    /// still reads A's `import.meta` (test262
    /// `language/expressions/import.meta/distinct-for-each-module.js`).
    /// The interpreter saves the caller's `current_module`
    /// before invoking a function and restores it on return.
    owning_module: ?*@import("module.zig").ModuleRecord = null,
    /// Lexical `this` capture for arrow functions (§15.3). Set
    /// at MakeFunction time to the creator frame's `this_value`,
    /// then plumbed through as the arrow's `this` at call time.
    /// Non-arrow functions ignore this slot — they receive `this`
    /// from the call site.
    captured_this: Value = Value.undefined_,
    /// Lexical `new.target` capture for arrow functions (§13.3.12 /
    /// §15.3.4 ArrowFunction.[[ThisMode]] = lexical). An arrow
    /// inherits its enclosing function's `new.target` so
    /// `new.target` inside an arrow body reads correctly when the
    /// outer function was invoked with `new`. Also used as the
    /// implicit NewTarget for a `super(...)` call performed from
    /// inside an arrow lexically enclosed by a derived-class
    /// constructor. Non-arrow functions ignore this slot.
    captured_new_target: Value = Value.undefined_,
    /// Method `[[HomeObject]]` (§10.2.5). Set on functions
    /// emitted as class methods, points at the prototype object
    /// that owns this method. `super.method()` reads this slot
    /// to find the parent prototype to look up on. `null` for
    /// non-method functions.
    home_object: ?*JSObject = null,
    /// `[[HomeObject]]` for static methods, where the home is
    /// the class constructor (a JSFunction) rather than the
    /// class prototype object. Cynic's `home_object` is typed
    /// `*JSObject`, so static methods need this parallel slot.
    /// `super.x` inside a static reads `home_function.proto`
    /// (the parent constructor) when this is set. Only one of
    /// `home_object` / `home_function` is set on any given fn.
    home_function: ?*@This() = null,
    /// Shared cell tracking `[[ThisBindingStatus]]` for an arrow's
    /// lexically enclosing derived-class constructor (§10.2.1.4 /
    /// §13.3.7). Set on arrows created inside a derived ctor body
    /// so a `super(...)` performed via the arrow — including from
    /// a fresh `runFrames` re-entry such as iterator `return()`
    /// during for-of close — can mark the outer ctor's super-
    /// called flag. `null` for arrows outside derived ctors and
    /// non-arrow functions. Lifetime: allocated on derived-ctor
    /// frame entry using the realm allocator, kept alive by the
    /// realm's `derived_ctor_cells` arena (cells live as long as
    /// the realm — small leak budget, simpler than GC tracking
    /// since both endpoints are short-lived in practice).
    super_called_cell: ?*bool = null,
    /// `[[ConstructorKind]]` (§10.2.1) — `base` (default) or
    /// `derived` (constructor of `class C extends …`). later
    /// treats both identically at the call site; the precise
    /// `this` initialization-order rules around `super(...)`
    /// land with full TDZ-on-this later.
    constructor_kind: ConstructorKind = .base,
    /// `[[ClassConstructor]]` flag (§15.7.14). `true` for the
    /// constructor of a `class …` declaration — rejects calling
    /// the function without `new` (TypeError per §15.7.14 step
    /// 1). `false` for plain functions which are callable both
    /// ways.
    is_class_constructor: bool = false,
    /// §17 — built-in function objects that are not identified
    /// as constructors don't have `[[Construct]]`. Defaults to
    /// `true` so user-declared functions and built-in
    /// constructors remain `new`-able; intrinsic installers
    /// (`installNativeMethod`, `installNativeMethodOnProto`)
    /// flip this to `false` for prototype methods and pure
    /// utility fns (`Object.keys`, `parseInt`, etc.). The
    /// `new_call` opcode and `Reflect.construct` consult it to
    /// decide whether to throw "is not a constructor".
    has_construct: bool = true,
    /// Native constructors that must validate their arguments
    /// (e.g. RangeError on `byteLength > maxByteLength`) BEFORE
    /// the spec's OrdinaryCreateFromConstructor step (which
    /// triggers a user-installed `prototype` getter on newTarget).
    /// When set, `constructValue` / `reflectConstruct` skip the
    /// proto lookup, stash newTarget on
    /// `realm.pending_native_new_target`, and invoke the native
    /// with `this_value = undefined`. The native runs validation,
    /// then calls `getPrototypeFromConstructor` itself.
    /// Set on ArrayBuffer / DataView constructors per §25.1.4.1
    /// / §25.3.2.1.
    defers_proto_lookup: bool = false,
    /// `function*` — calling allocates a `JSGenerator` instead
    /// of running the body. The generator's `.next()` method
    /// resumes the body via `interpreter.resumeGenerator`.
    is_generator: bool = false,
    /// `async function` — body always returns a Promise.
    is_async: bool = false,
    /// §10.4.1 BoundFunction — produced by `Function.prototype.bind`.
    /// Calling this function:
    /// 1. invokes `bound_target` with `this = bound_this`
    /// 2. prepended with `bound_args`, then the call site's args.
    /// `new boundFn(...)` constructs `bound_target` with the
    /// concatenated args (the bound `this` is ignored — §10.4.1.2).
    /// All three slots are `null` for non-bound functions; the
    /// interpreter checks `bound_target` first to route the call.
    bound_target: ?*JSFunction = null,
    bound_this: Value = Value.undefined_,
    bound_args: ?[]const Value = null,
    /// For `class B extends A { … }`, this points at `A` (the
    /// parent constructor) so `B.someStaticOfA()` resolves.
    /// `null` for non-derived classes / non-class functions.
    /// Walked by `JSFunction.get` after `properties` and
    /// `prototype`/`name` reflection but before the generic
    /// `proto` chain — static-method inheritance lives on this
    /// edge of the function-object graph. (§15.7.14 sets
    /// `ctor.[[Prototype]] = parentCtor` directly, but our
    /// `proto` slot points at a JSObject; this is the
    /// JSFunction-typed equivalent.)
    static_parent: ?*JSFunction = null,
    /// §28.2.2.1.1 `[[RevocableProxy]]` — the proxy captured by a
    /// `Proxy.revocable` revoke function. Non-null marks this
    /// function as a revocation closure: the interpreter's call
    /// dispatch flips the proxy's `proxy_revoked` flag instead
    /// of running the (placeholder) native body. Cleared to
    /// `null` after the first call so subsequent invocations
    /// no-op (spec step 1 — return undefined when [[RevocableProxy]]
    /// is null).
    revocable_proxy: ?*JSObject = null,
    /// Function-as-object: properties set via `fn.foo = bar`.
    /// Spec: §10.2 Function objects are ordinary objects too —
    /// they support arbitrary property assignment. Without this
    /// table, code like `Test262Error.prototype.toString = …`
    /// can't run, which gates harness/sta.js loading. Names are
    /// borrowed from the heap's strings list (same convention as
    /// JSObject); the value can reference any other heap object.
    properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Parallel map of non-default property flags — mirrors
    /// `JSObject.property_flags`. Lazy: only deviations from the
    /// all-true default land here. Built-in `name`/`length`/
    /// `prototype` slots get their flags synthesized by
    /// `flagsForOwn`; user overrides via `Object.defineProperty`
    /// drop into this map.
    property_flags: std.StringArrayHashMapUnmanaged(PropertyFlags) = .empty,
    /// §10.1.8 [[Get]] / §10.1.9 [[Set]] accessor descriptors on
    /// the function object itself. Mirrors `JSObject.accessors` —
    /// `Object.defineProperty(fn, key, {get, set})` lands here.
    /// Read paths (lda_property) and the §10.1.14
    /// GetPrototypeFromConstructor lookup in `constructValue` /
    /// `new_call` consult this map before the data property bag,
    /// per §10.1.8.1 OrdinaryGet step 4 (accessor descriptor wins).
    accessors: std.StringArrayHashMapUnmanaged(Accessor) = .empty,
    /// §15.7 static private slots — `class C { static #x = 1;
    /// static #y() {}; static get #z() {} }` lands here when the
    /// class constructor is built. Storage shape mirrors
    /// `JSObject.private_properties` / `JSObject.private_accessors`;
    /// `lda_private` / `sta_private` consult these when the
    /// receiver is the constructor function itself.
    private_properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    private_accessors: std.StringArrayHashMapUnmanaged(Accessor) = .empty,
    /// Names in `private_properties` whose [[Kind]] is "method"
    /// (§7.3.30 step 4) — writes to these throw TypeError. Plain
    /// data fields are absent from this set and remain writable.
    private_methods: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// §15.7.14 step 31 [[PrivateBrand]] — per-class-evaluation
    /// private-name prefix. See `JSObject.private_brand` for the
    /// design. Set on the class constructor at ClassTail
    /// evaluation; the interpreter consults this via
    /// `home_function` when a private read/write runs inside a
    /// static method body. Empty on non-class-related functions.
    /// Borrowed from the realm's class arena.
    private_brand: []const u8 = "",
    /// §15.7.14 step 11 PrivateBoundIdentifiers — compile-time prefix.
    private_compile_prefix: []const u8 = "",
    /// `Function.prototype` — the object that becomes the
    /// `[[Prototype]]` of instances created by `new f(…)`. Auto-
    /// allocated for non-arrow functions at construction time
    /// (per §10.2.4). Arrow functions don't have a `.prototype`
    /// slot. The prototype object's `.constructor` is wired back
    /// to the function so `(new F).constructor === F` (§20.2.4.1).
    prototype: ?*JSObject = null,
    /// The function's own `[[Prototype]]` — typically
    /// `%Function.prototype%`. Walked by property reads when an
    /// own property isn't present, so `fn.call` / `fn.apply` /
    /// `fn.bind` resolve through inheritance instead of being
    /// duplicated onto every function instance.
    proto: ?*JSObject = null,
    /// §10.2 Function objects are ordinary objects (§6.1.7) and
    /// participate in `Object.preventExtensions` / `Object.seal` /
    /// `Object.freeze`. Flipping this to `false` makes
    /// PrivateFieldAdd (§7.3.32 step 1) throw on `static #x = …`
    /// targeting this ctor, mirrors JSObject.extensible. Defaults
    /// to `true` — every function starts out extensible.
    extensible: bool = true,
    /// Mark-sweep bit, written by the heap during a collection
    /// cycle and reset to `false` after the sweep.
    marked: bool = false,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young function surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this function is in the heap's remembered set as a
    /// known old→young store source.
    in_remembered_set: bool = false,

    /// §10.1.11 OrdinaryOwnPropertyKeys — unified insertion-order
    /// list spanning `properties` and `accessors`, mirroring
    /// `JSObject.own_key_order`. See that field's doc for the
    /// rationale; the function-object branch matters because
    /// `Object.defineProperty(fn, "x", {get…})` followed by
    /// `fn.y = 1` must report `["x", "y"]` from
    /// `Object.getOwnPropertyNames(fn)`, not `["y", "x"]`.
    own_key_order: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        param_count: u8,
        name: ?[]const u8,
        is_arrow: bool,
        captured_env: ?*Environment,
    ) !*JSFunction {
        const f = try allocator.create(JSFunction);
        f.* = .{
            .kind = .function,
            .chunk = chunk,
            .native_callback = null,
            .param_count = param_count,
            .name = name,
            .is_arrow = is_arrow,
            .captured_env = captured_env,
            .captured_this = Value.undefined_,
        };
        return f;
    }

    /// Allocate a host-implemented function. `native_callback` is
    /// invoked directly by the Call opcode; the args slice points
    /// into the caller's register file (read-only). No frame is
    /// pushed for native calls.
    pub fn initNative(
        allocator: std.mem.Allocator,
        callback: NativeFn,
        param_count: u8,
        name: []const u8,
    ) !*JSFunction {
        const f = try allocator.create(JSFunction);
        f.* = .{
            .kind = .function,
            .chunk = null,
            .native_callback = callback,
            .param_count = param_count,
            .name = name,
            .is_arrow = false,
            .captured_env = null,
        };
        return f;
    }

    pub fn deinit(self: *JSFunction, allocator: std.mem.Allocator) void {
        self.properties.deinit(allocator);
        self.property_flags.deinit(allocator);
        self.accessors.deinit(allocator);
        self.private_properties.deinit(allocator);
        self.private_accessors.deinit(allocator);
        self.private_methods.deinit(allocator);
        self.own_key_order.deinit(allocator);
        if (self.bound_args) |a| allocator.free(a);
        allocator.destroy(self);
    }

    /// §10.1.11 — see `JSObject.recordKey`. Same contract.
    pub fn recordKey(
        self: *JSFunction,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !void {
        if (std.mem.startsWith(u8, key, "__cynic_")) return;
        // Reuse JSObject's canonical-integer-index check via the
        // shared helper.
        const obj_mod = @import("object.zig");
        if (obj_mod.JSObject.canonicalIntegerIndex(key) != null) return;
        for (self.own_key_order.items) |existing| {
            if (std.mem.eql(u8, existing, key)) return;
        }
        try self.own_key_order.append(allocator, key);
    }

    /// §10.1.11 — see `JSObject.forgetKey`.
    pub fn forgetKey(self: *JSFunction, key: []const u8) void {
        var i: usize = 0;
        while (i < self.own_key_order.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.own_key_order.items[i], key)) {
                _ = self.own_key_order.orderedRemove(i);
                return;
            }
        }
    }

    /// Set a property by name. Mirrors `JSObject.set`. The `key`
    /// slice must remain valid for the function's lifetime — the
    /// caller arranges that by passing a heap-owned string slice.
    /// `prototype` reflects onto the dedicated slot; reads of
    /// `prototype` see whatever object was last assigned. Other
    /// keys land in the generic property bag.
    ///
    /// Bypass form: doesn't honor writable=false; intended for
    /// internal installers. User-driven writes via the bytecode
    /// `sta_property` / `sta_computed` ops go through
    /// `setIfWritable` so non-writable assignments throw the
    /// strict-mode TypeError per §10.5.5.
    pub fn set(self: *JSFunction, allocator: std.mem.Allocator, key: []const u8, v: Value) !void {
        if (std.mem.eql(u8, key, "prototype")) {
            const heap_mod = @import("heap.zig");
            if (heap_mod.valueAsPlainObject(v)) |obj| {
                self.prototype = obj;
                return;
            }
            // Non-object.prototype: V8 silently keeps the previous
            // prototype (the assignment is observable only via the
            // property bag). We mirror that with a fallthrough.
        }
        try self.properties.put(allocator, key, v);
    }

    /// `[[Set]]` honoring §10.5.5 writability. Same contract as
    /// `JSObject.setIfWritable`: returns `false` if the own
    /// property exists and is non-writable. Mirrors the
    /// dedicated-slot updates that `setWithFlags` does for
    /// `name` / `prototype` so the slot stays in sync with the
    /// property bag entry.
    pub fn setIfWritable(self: *JSFunction, allocator: std.mem.Allocator, key: []const u8, v: Value) !bool {
        const flags = self.flagsForOwn(key);
        if (self.properties.contains(key) and !flags.writable) return false;
        // §10.2.4 — built-in constructors have a non-writable
        // `prototype` slot. The slot's "own" status comes from
        // `hasOwn` (which consults `self.prototype != null`), not
        // from `properties.contains`, so the writability gate has
        // to honor the synthesized descriptor too.
        if (std.mem.eql(u8, key, "prototype") and self.prototype != null and !flags.writable) {
            return false;
        }
        // Same special-cases as `set`.
        if (std.mem.eql(u8, key, "prototype")) {
            const heap_mod = @import("heap.zig");
            if (heap_mod.valueAsPlainObject(v)) |obj| {
                self.prototype = obj;
                return true;
            }
            // Non-object.prototype: silently no-op via the
            // dedicated slot, but still record the assigned
            // value in the bag so later reads see it.
        }
        if (std.mem.eql(u8, key, "name")) {
            if (v.isString()) {
                const s: *@import("string.zig").JSString = @ptrCast(@alignCast(v.asString()));
                self.name = s.flatBytes();
                self.name_string = s;
            } else {
                self.name = null;
                self.name_string = null;
            }
        }
        try self.properties.put(allocator, key, v);
        return true;
    }

    /// Set a property + override its descriptor flags. Used by
    /// `Object.defineProperty` against a function receiver. The
    /// caller is responsible for the `key` slice's lifetime
    /// (heap-owned). `name`/`length`/`prototype` updates their
    /// dedicated slot AND records the new flags so subsequent
    /// `flagsForOwn` reads see the override.
    pub fn setWithFlags(
        self: *JSFunction,
        allocator: std.mem.Allocator,
        key: []const u8,
        v: Value,
        flags: PropertyFlags,
    ) !void {
        // Slot updates first so reads see the new value.
        if (std.mem.eql(u8, key, "name")) {
            if (v.isString()) {
                const s: *@import("string.zig").JSString = @ptrCast(@alignCast(v.asString()));
                self.name = s.flatBytes();
                self.name_string = s;
            } else {
                self.name = null;
                self.name_string = null;
            }
        } else if (std.mem.eql(u8, key, "prototype")) {
            const heap_mod = @import("heap.zig");
            if (heap_mod.valueAsPlainObject(v)) |obj| {
                self.prototype = obj;
            }
        }
        try self.properties.put(allocator, key, v);
        // Mirror JSObject — only record non-default flags.
        const is_default = flags.writable and flags.enumerable and flags.configurable;
        if (is_default) {
            _ = self.property_flags.swapRemove(key);
        } else {
            try self.property_flags.put(allocator, key, flags);
        }
    }

    /// Read the (possibly defaulted) descriptor flags for an own
    /// property. `length` and `name` are stored as ordinary own
    /// properties in `property_flags` at allocation time, so they
    /// land via the map lookup. Only `prototype` synthesizes — its
    /// dedicated slot doesn't currently mirror into the property
    /// bag, so we hand back the §10.2.4 defaults
    /// (`{w:true, e:false, c:false}` for ordinary functions).
    /// User-installed overrides via `Object.defineProperty` win
    /// over the synthesized default.
    pub fn flagsForOwn(self: *const JSFunction, key: []const u8) PropertyFlags {
        if (self.property_flags.get(key)) |f| return f;
        if (std.mem.eql(u8, key, "prototype")) {
            // §10.2.4 — ordinary functions: `{w:true, e:false, c:false}`.
            // §17 — built-in constructors and `class C` constructors
            // ([[ConstructorKind]] = "derived"): `{w:false, e:false, c:false}`.
            // `is_class_constructor` is set both for `class …` literals and
            // by `installConstructor` for the built-ins.
            //
            // Non-constructor built-ins (`Math.abs`, `Array.prototype.map`,
            // arrow / concise-method functions, etc.) carry no `prototype`
            // slot at all (§10.2.4 only installs one for functions with
            // a `[[Construct]]`). The §10.2.4 synthesized descriptor only
            // applies to constructors that own the synthesized slot. If
            // the user later writes `Math.abs.prototype = 42`, the new
            // property is an ORDINARY own data property — fall through
            // to the all-true default.
            if (self.prototype == null) {
                return PropertyFlags.default;
            }
            return if (self.is_class_constructor)
                .{ .writable = false, .enumerable = false, .configurable = false }
            else
                .{ .writable = true, .enumerable = false, .configurable = false };
        }
        return PropertyFlags.default;
    }

    /// Get a property by name. `prototype` reflects from the
    /// dedicated slot when no own-property override exists; the
    /// class-static-inheritance edge (`static_parent`) is walked
    /// before the generic `proto` chain so subclasses see their
    /// parents' static methods; finally `proto` (the function-
    /// object [[Prototype]], typically `%Function.prototype%`)
    /// resolves inherited `.call` / `.apply` / `.bind`.
    pub fn get(self: *const JSFunction, key: []const u8) Value {
        if (self.properties.get(key)) |v| return v;
        if (std.mem.eql(u8, key, "prototype")) {
            if (self.prototype) |p| {
                const heap_mod = @import("heap.zig");
                return heap_mod.taggedObject(p);
            }
        }
        if (self.static_parent) |sp| {
            const v = sp.get(key);
            if (!v.isUndefined()) return v;
        }
        if (self.proto) |p| return p.get(key);
        return Value.undefined_;
    }

    pub fn hasOwn(self: *const JSFunction, key: []const u8) bool {
        if (self.properties.contains(key)) return true;
        if (self.accessors.contains(key)) return true;
        if (std.mem.eql(u8, key, "prototype") and self.prototype != null) return true;
        return false;
    }

    /// Own-property accessor lookup. Distinct from `JSObject`'s
    /// chain-walking `lookupAccessor` — function `[[Prototype]]`
    /// chain is `static_parent` → `proto`, neither of which is
    /// expected to host accessor descriptors today (built-in
    /// `%Function.prototype%` exposes only data properties).
    /// Spec anchor: §10.1.8.1 OrdinaryGet step 4.
    pub fn ownAccessor(self: *const JSFunction, key: []const u8) ?Accessor {
        return self.accessors.get(key);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Builder = @import("../bytecode/chunk.zig").Builder;

test "JSFunction: init / deinit round-trip" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const f = try JSFunction.init(testing.allocator, &chunk, 2, "add", false, null);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 2), f.param_count);
    try testing.expectEqualStrings("add", f.name.?);
    try testing.expect(!f.is_arrow);
    try testing.expect(f.captured_env == null);
}

test "JSFunction: anonymous function has null name" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const f = try JSFunction.init(testing.allocator, &chunk, 0, null, true, null);
    defer f.deinit(testing.allocator);
    try testing.expect(f.name == null);
    try testing.expect(f.is_arrow);
}

test "JSFunction: flagsForOwn synthesizes prototype defaults" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // Ordinary function with a synthesized `prototype` slot:
    // §10.2.4 — `prototype` is { w:true, e:false, c:false }.
    // Use a zeroed JSObject as the slot tag — `flagsForOwn` only
    // null-checks the slot pointer, never dereferences it.
    var dummy_proto: JSObject = .{};
    const f = try JSFunction.init(testing.allocator, &chunk, 0, null, false, null);
    defer f.deinit(testing.allocator);
    f.prototype = &dummy_proto;
    const proto_flags = f.flagsForOwn("prototype");
    try testing.expectEqual(true, proto_flags.writable);
    try testing.expectEqual(false, proto_flags.enumerable);
    try testing.expectEqual(false, proto_flags.configurable);

    // No `prototype` slot at all (`Math.abs` shape — built-in
    // without [[Construct]]). The §10.2.4 synthesized descriptor
    // doesn't apply; a user write would create an ordinary
    // own property, so the defaults are all-true.
    const no_proto = try JSFunction.init(testing.allocator, &chunk, 0, null, false, null);
    defer no_proto.deinit(testing.allocator);
    const no_proto_flags = no_proto.flagsForOwn("prototype");
    try testing.expectEqual(true, no_proto_flags.writable);
    try testing.expectEqual(true, no_proto_flags.enumerable);
    try testing.expectEqual(true, no_proto_flags.configurable);

    // Other keys default to all-true.
    const other = f.flagsForOwn("foo");
    try testing.expectEqual(true, other.writable);
    try testing.expectEqual(true, other.enumerable);
    try testing.expectEqual(true, other.configurable);

    // Class / built-in constructor: §17 — `prototype` is non-writable.
    const cls = try JSFunction.init(testing.allocator, &chunk, 0, null, false, null);
    defer cls.deinit(testing.allocator);
    cls.is_class_constructor = true;
    cls.prototype = &dummy_proto;
    const cls_proto_flags = cls.flagsForOwn("prototype");
    try testing.expectEqual(false, cls_proto_flags.writable);
    try testing.expectEqual(false, cls_proto_flags.enumerable);
    try testing.expectEqual(false, cls_proto_flags.configurable);
}

test "JSFunction: setWithFlags overrides flagsForOwn" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const f = try JSFunction.init(testing.allocator, &chunk, 0, null, false, null);
    defer f.deinit(testing.allocator);

    try f.setWithFlags(testing.allocator, "x", Value.fromInt32(42), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });
    const flags = f.flagsForOwn("x");
    try testing.expectEqual(false, flags.writable);
    try testing.expectEqual(false, flags.enumerable);
    try testing.expectEqual(false, flags.configurable);
}

test "JSFunction: setIfWritable refuses non-writable own property" {
    var b = Builder.init(testing.allocator);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    const f = try JSFunction.init(testing.allocator, &chunk, 0, null, false, null);
    defer f.deinit(testing.allocator);

    try f.setWithFlags(testing.allocator, "ro", Value.fromInt32(1), .{
        .writable = false,
        .enumerable = true,
        .configurable = true,
    });
    const ok = try f.setIfWritable(testing.allocator, "ro", Value.fromInt32(99));
    try testing.expect(!ok);
    try testing.expectEqual(@as(i32, 1), f.get("ro").asInt32());
}
