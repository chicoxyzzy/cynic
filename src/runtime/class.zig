//! Class runtime support — §15.7 ClassDefinitions.
//!
//! later scope: `class Name { constructor … methods … static
//! methods }` and `class Name extends Heritage { … }`. Builds the
//! constructor function, its prototype object, and wires both
//! prototype chains (instance methods + static methods). Lower
//! to a single `MakeClass k` op so the spec-faithful 30-step
//! abstract operation lives here in Zig — the alternative is
//! ~80 bytes of repeated property-write ops per class site.
//!
//! Out of scope at α (lands later / γ / later):
//! • Class fields (public & private)
//! • Private methods
//! • Static blocks
//! • Getters / setters
//! • `new.target`
//!
//! Spec: §15.7.14 OrdinaryClassDefinition.

const std = @import("std");

const ChunkMod = @import("../bytecode/chunk.zig");
const ClassTemplate = ChunkMod.ClassTemplate;
const MethodTemplate = ChunkMod.MethodTemplate;

const Realm = @import("realm.zig").Realm;
const Value = @import("value.zig").Value;
const JSObject = @import("object.zig").JSObject;
const JSFunction = @import("function.zig").JSFunction;
const Environment = @import("environment.zig").Environment;
const heap_mod = @import("heap.zig");

pub const ClassError = error{
    OutOfMemory,
    /// The heritage expression resolved to a non-callable (or
    /// callable but non-constructor) value. §15.7.14 step 5.
    HeritageNotConstructor,
    /// Class-definition evaluation observed user code (a computed
    /// key, a ToPrimitive coercion, a class-element initializer)
    /// that threw. The thrown value lives in
    /// `realm.pending_exception`; the caller surfaces it back into
    /// the interpreter's frame stack instead of synthesizing a
    /// generic error.
    Propagated,
};

/// Mirror of §15.7.14 OrdinaryClassDefinition.
///
/// Steps Cynic implements at later:
/// 1. Set `proto`, `superCtor` from the heritage value (if any).
/// 2. Allocate the prototype object: `proto = new Object()`
/// with `[[Prototype]] = parentProto`.
/// 3. Allocate the constructor function from the
/// `constructor_chunk`, mark it `is_class_constructor = true`,
/// `constructor_kind =.derived` if heritage is set.
/// 4. Wire `ctor.prototype = proto` and `proto.constructor = ctor`.
/// 5. Set `ctor.[[Prototype]] = parentCtor` (or
/// `%Function.prototype%` for non-derived).
/// 6. For each instance method: allocate as JSFunction, set
/// `home_object = proto`, install on `proto`.
/// 7. For each static method: allocate as JSFunction, set
/// `home_object = ctor.prototype` (so `super` from a static
/// method walks the static chain), install on `ctor`.
/// 8. Return the constructor as `acc`.
/// §15.7.14 step 31 — every evaluation of a ClassTail allocates
/// a fresh `[[PrivateBrand]]` for each `#x` declared in it. The
/// compile-time `template.private_prefix` (`"P{class_uid}#"`) is
/// shared by every evaluation of the same source-text class; the
/// runtime brand prefix here is a *per-evaluation* identity that
/// the runtime swaps in for the compile-time prefix when reading
/// or writing private slots. Two `f()` calls of a class-producing
/// factory therefore yield classes with distinct brand identities —
/// `A.read(new B())` raises TypeError per §7.3.27 PrivateElementFind.
///
/// Returns a `"B{n}#"` slice owned by the realm's class arena.
fn allocateBrandPrefix(realm: *Realm) ClassError![]const u8 {
    const n = realm.class_brand_counter;
    realm.class_brand_counter += 1;
    return std.fmt.allocPrint(realm.classAllocator(), "B{d}#", .{n}) catch return error.OutOfMemory;
}

/// Translate a compile-time-mangled private key (`"P0#x"`) into a
/// runtime-mangled key (`"B7#x"`) using the per-evaluation brand
/// prefix. The result is allocated in the realm's class arena —
/// it lives for the realm's lifetime so the heap-side
/// `private_properties` map can borrow the slice safely. Falls
/// through unchanged for non-private keys (Symbol-keyed methods,
/// numeric / string-literal keys), keeping the call site simple.
fn brandMangle(
    realm: *Realm,
    template_prefix: []const u8,
    runtime_prefix: []const u8,
    key: []const u8,
) ClassError![]const u8 {
    if (!std.mem.startsWith(u8, key, template_prefix)) return key;
    const suffix = key[template_prefix.len..];
    return std.fmt.allocPrint(realm.classAllocator(), "{s}{s}", .{ runtime_prefix, suffix }) catch return error.OutOfMemory;
}

pub fn buildClass(
    realm: *Realm,
    template: *const ClassTemplate,
    captured_env: ?*Environment,
    heritage_v: ?Value,
    /// Pre-computed `[expr]` key values, one per member with
    /// `computed_key_index >= 0`, in source order. Each value is
    /// already coerced via `to_property_key` so it's a string or
    /// symbol Value. Empty when the class has no computed keys.
    /// See `bytecode/compiler.zig::emitMakeClass` for the emit
    /// side; the interpreter's `.make_class` handler gathers
    /// these out of the register file before this call.
    computed_keys: []const Value,
    /// §15.7.14 ClassDefinitionEvaluation step 27.b — when the
    /// class has a name (`class C { … }` declaration *or* a
    /// `class C = class C { … }` named expression), the inner
    /// `classScopeEnvRec` slot for `C` must be initialised with
    /// the freshly-constructed constructor BEFORE static fields
    /// or static blocks run (steps 33-34). Without this, a
    /// static initializer that references `C` (e.g.
    /// `static foo = C.bar`) sees the binding in TDZ and throws
    /// ReferenceError.
    ///
    /// `captured_env` IS the inner classScopeEnvRec (depth 0
    /// from make_class's vantage). `null` here means the class
    /// is anonymous — skip the publish step.
    inner_class_slot: ?u8,
) ClassError!Value {
    // §15.7.14 step 31 — allocate the per-evaluation
    // [[PrivateBrand]] up front. `proto` and `ctor` both get the
    // same brand so instance and static private accesses route to
    // the same identity. The compile-time `template.private_prefix`
    // continues to live in the bytecode constants pool; the brand
    // is consulted only at install / lookup time.
    const brand_prefix = try allocateBrandPrefix(realm);
    // 1. Heritage check — if `extends X`, X must be a constructor.
    // `has_heritage` distinguishes `class C {}` (proto inherits
    // %Object.prototype%) from `class C extends null {}` (proto
    // inherits null, per §15.7.14 step 6.e.i).
    const has_heritage = heritage_v != null;
    var parent_ctor: ?*JSFunction = null;
    var parent_proto: ?*JSObject = null;
    if (heritage_v) |hv| {
        if (hv.isNull()) {
            // `extends null` — proto chain ends at null, and the
            // constructor still inherits from %Function.prototype%.
            parent_ctor = null;
            parent_proto = null;
        } else if (heap_mod.valueAsFunction(hv)) |fn_obj| {
            // §15.7.14 step 7 — superclass must be a constructor.
            // Arrow functions, generator functions, async functions,
            // and methods (no [[Construct]]) don't qualify. The
            // spec phrasing is IsConstructor(superclass).
            //
            // §10.4.1.2 BoundFunctionExoticObject — IsConstructor of
            // a bound function chains through to its [[BoundTargetFunction]]
            // (recursively). `(()=>{}).bind()` produces a bound
            // function whose target is the arrow → not a constructor.
            // Walk through bound_target so the IsConstructor check
            // sees the underlying function's flags. Without this,
            // `class C extends (()=>{}).bind() {}` passes the check
            // and then proceeds to step 7.e, which reads
            // `bound.prototype` — observable via an accessor and
            // mis-firing test262 fixtures that expect step 7's
            // TypeError to short-circuit the prototype lookup.
            var unwrapped: *JSFunction = fn_obj;
            while (unwrapped.bound_target) |tgt| unwrapped = tgt;
            if (!unwrapped.has_construct or unwrapped.is_arrow or unwrapped.is_generator or unwrapped.is_async) {
                return error.HeritageNotConstructor;
            }
            parent_ctor = fn_obj;
            // §15.7.14 step 7.e — \`Get(superclass, \"prototype\")\`
            // walks accessors. The parent may have an
            // \`Object.defineProperty(\..., 'prototype', { get(){} })\`
            // shape that observes a single read on every extends.
            // Use the accessor-aware path. A non-null, non-Object
            // result is a TypeError per step 7.h.
            const interp = @import("interpreter.zig");
            const parent_proto_v = if (fn_obj.ownAccessor("prototype")) |acc_pair| blk_acc: {
                if (acc_pair.getter) |getter| {
                    const recv = heap_mod.taggedFunction(fn_obj);
                    const outcome = interp.callJSFunction(realm.allocator, realm, getter, recv, &.{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.Propagated,
                    };
                    switch (outcome) {
                        .value, .yielded => |v| break :blk_acc v,
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.Propagated;
                        },
                    }
                }
                break :blk_acc Value.undefined_;
            } else if (fn_obj.prototype) |p| heap_mod.taggedObject(p) else Value.undefined_;
            if (heap_mod.valueAsPlainObject(parent_proto_v)) |po| {
                parent_proto = po;
            } else if (!parent_proto_v.isNull()) {
                // §15.7.14 step 7.h — \`prototype\` of the parent is
                // present but not Object or null → TypeError.
                // \`undefined\` is in scope here too: a bound function
                // has no own \`prototype\` slot and reading it returns
                // \`undefined\`, which is also not Object / null and so
                // must trip this branch (matches V8 / SpiderMonkey).
                realm.pending_exception = @import("intrinsics.zig").newTypeError(realm, "Class extends value's 'prototype' is not an object or null") catch return error.OutOfMemory;
                return error.Propagated;
            }
        } else {
            return error.HeritageNotConstructor;
        }
    }

    // 2. Allocate the prototype object.
    const proto = try realm.heap.allocateObject();
    // §15.7.14 step 31 — stamp the per-evaluation brand on the
    // prototype so the interpreter can translate a compile-time
    // private key into the runtime slot key when the executing
    // method's `home_object` is this prototype.
    proto.private_brand = brand_prefix;
    proto.private_compile_prefix = template.private_prefix;
    // §15.7.14 step 6 — `proto.[[Prototype]]` is:
    //   • parent.prototype, if `extends X`
    //   • null, if `extends null`
    //   • %Object.prototype%, if no heritage clause
    proto.prototype = if (parent_proto) |pp| pp else if (has_heritage) null else realm.intrinsics.object_prototype;

    // Pin `proto` (and shortly `ctor`) across the rest of class
    // construction. Computed-key evaluation re-enters the
    // interpreter via `callJSFunction`, which CAN trigger a GC.
    // Until ctor.prototype is wired and ctor itself is on the
    // accumulator at the call site, neither object is reachable
    // from JS-level roots — the HandleScope keeps them alive.
    var class_scope = try realm.heap.openScope();
    defer class_scope.close();
    try class_scope.push(heap_mod.taggedObject(proto));

    // 3. Allocate the constructor.
    const ctor = try realm.heap.allocateFunction(
        &template.constructor_chunk,
        template.constructor_param_count,
        template.name,
        false, // is_arrow
        captured_env,
    );
    // §15.7.7 FunctionLength — class constructor exposes
    // `C.length` as the count of params before the first one
    // with a default / rest / destructuring.
    if (template.constructor_spec_length != template.constructor_param_count) {
        try ctor.properties.put(realm.allocator, "length", @import("value.zig").Value.fromInt32(template.constructor_spec_length));
    }
    try class_scope.push(heap_mod.taggedFunction(ctor));
    ctor.is_class_constructor = true;
    // §15.7.14 step 31 — mirror the brand on the constructor so
    // static-private accesses (which route via `home_function`)
    // route to the same per-evaluation identity.
    ctor.private_brand = brand_prefix;
    ctor.private_compile_prefix = template.private_prefix;
    // §15.7.14 step 11 — when a ClassHeritage clause is present
    // (even `extends null`), the constructor's [[ConstructorKind]]
    // is "derived". That keeps the `this` binding uninitialized
    // entering the body (§10.2.2 step 7) so a derived ctor with
    // no `super()` call leaves `GetThisBinding` failing with
    // ReferenceError on body return.
    if (has_heritage) ctor.constructor_kind = .derived;
    // Wire the ctor's [[Prototype]] for `Function.prototype.call`/`apply`/`bind`.
    ctor.proto = realm.intrinsics.function_prototype;
    ctor.source = template.source;
    // The constructor itself is a "method" of the class — its
    // home object is the prototype object, so `super(...)` /
    // `super.method()` inside the constructor body resolve.
    ctor.home_object = proto;
    // §13.3.7.2 GetSuperConstructor — `super(...)` from the ctor
    // body walks `activeFunction.[[Prototype]]`, where the active
    // function is the constructor itself. Wiring `home_function`
    // here lets the interpreter route the lookup through the
    // ctor's own [[Prototype]] slot, so `Object.setPrototypeOf(C,
    // X)` retargets `super(...)` to `X` — matching V8 / SpiderMonkey
    // / JSC and unblocking test262
    // `language/expressions/super/call-proto-not-ctor.js`.
    ctor.home_function = ctor;

    // 4. ctor.prototype = proto, proto.constructor = ctor. The
    // auto-allocated `prototype` from `allocateFunction` would
    // have been a fresh object; replace it with our explicit
    // one so the prototype identity matches what we install
    // methods onto.
    ctor.prototype = proto;
    // §15.7.14 — `Class.prototype.constructor` is non-enumerable.
    try proto.setWithFlags(realm.allocator, "constructor", heap_mod.taggedFunction(ctor), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    // 5. extends linkage — ctor.[[Prototype]] = parentCtor.
    if (parent_ctor) |pc| {
        // ctor.proto chain goes through the parent constructor
        // so static-method inheritance works (`B.staticOfA()`
        // walks ctor.proto → A → A.proto → Function.prototype).
        // Implement by giving ctor a `proto` chain that goes
        // through the parent's *function-as-object* representation.
        // Our `JSFunction.proto` slot points at a JSObject. The
        // parent is a function — to walk through it we'd need
        // function-to-object lookup. Easiest: add a fresh
        // pass-through object whose own `.get` defers to the
        // parent function. But that's heavy; instead we simply
        // copy the parent's static-visible properties onto a
        // synthetic proto object. later takes the simpler path:
        // mark `ctor.parent_for_static = pc` and let property
        // reads on the constructor walk it. Plumbing that
        // through `JSFunction.get` is a small change — see
        // function.zig for the staticParent slot.
        ctor.static_parent = pc;
    }

    // 6. Install instance methods on the prototype. Methods
    // whose name begins with the class's `private_prefix` are
    // private — they go into a separate `private_method_inits`
    // list that the constructor's `init_instance_fields` op
    // copies into each instance's `private_properties`. Public
    // accessors (`get x() { … }` / `set x(v) { … }`) install
    // onto the prototype's `accessors` map; data methods install
    // as plain `properties` entries.
    var private_methods_count: usize = 0;
    for (template.instance_methods) |*m| {
        if (std.mem.startsWith(u8, m.name, template.private_prefix)) {
            private_methods_count += 1;
        }
    }
    const ObjMod = @import("object.zig");
    var private_methods: []ObjMod.FieldInit = if (private_methods_count > 0)
        try realm.classAllocator().alloc(ObjMod.FieldInit, private_methods_count)
    else
        &.{};
    var pm_idx: usize = 0;

    for (template.instance_methods) |*m| {
        // §13.2.5 ComputedPropertyName — if the method's key
        // was `[expr]`, the enclosing bytecode already evaluated
        // and `to_property_key`-coerced it into `computed_keys`
        // at `m.computed_key_index`. Otherwise (`< 0`) fall back
        // to the static `m.name` decoded at compile time.
        const resolved = try resolveComputedKey(realm, computed_keys, m.computed_key_index, m.name, proto);
        const runtime_name = resolved.name;
        // §15.7 — private method `.name` is the bare `#method`,
        // not the class-identity-prefixed mangled key. Strip
        // the `P<uid>#` prefix used for the slot lookup. The
        // accessor `get / set` prefix is added below per kind.
        // §10.2.5 SetFunctionName — Symbol keys carry a "[desc]"
        // / "" display name distinct from their property slot;
        // resolved.display_name folds that in.
        const base_display = if (std.mem.startsWith(u8, runtime_name, template.private_prefix))
            runtime_name[template.private_prefix.len - 1 ..]
        else
            resolved.display_name;
        // §10.2.5 SetFunctionName step 3.a — accessor functions
        // carry a `"get " | "set "` prefix in their `name`.
        const display_name = try maybePrefixAccessor(realm, m.kind, base_display, proto);
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            display_name,
            false,
            captured_env,
        );
        // §15.4.4 MethodDefinitionEvaluation → §10.2.10
        // OrdinaryFunctionCreate with FunctionKind = method (or
        // generator-method / async-method / accessor) — none of
        // these install a `prototype` own slot. `MakeMethod` only
        // wires [[HomeObject]]. Drop the auto-allocated prototype
        // that `allocateFunction` installs for non-arrow functions,
        // and turn off [[Construct]] so `new obj.method()` throws
        // (methods are non-constructors per §15.4 step 2).
        // Generator / async methods aren't constructors either —
        // §15.5 / §15.7 / §15.8 share the same MethodDefinition
        // gate. Class constructors take a separate path below
        // (§15.7.10 ClassDefinitionEvaluation) so this drop never
        // touches them.
        if (!m.is_generator and !m.is_async) {
            // Generators / async methods keep `prototype` — see
            // the wiring below.
            fn_obj.prototype = null;
        } else if (fn_obj.prototype) |gp| {
            // §27.5.1 / §27.6.1 — a class generator / async-generator
            // method's `.prototype` is an ordinary object whose
            // [[Prototype]] is %GeneratorPrototype% / %AsyncGenerator
            // Prototype%, with NO own `constructor` (matching the
            // `make_function` path for non-class generator function
            // expressions). `allocateFunction` allocated `gp` with a
            // default ctor + null [[Prototype]] — fix both here.
            _ = gp.properties.swapRemove("constructor");
            _ = gp.property_flags.swapRemove("constructor");
            const interp_mod = @import("interpreter.zig");
            gp.prototype = if (m.is_async)
                interp_mod.ensureAsyncGeneratorPrototype(realm) catch realm.intrinsics.object_prototype
            else
                interp_mod.ensureGeneratorPrototype(realm) catch realm.intrinsics.object_prototype;
        }
        fn_obj.has_construct = false;
        if (m.spec_length != m.param_count) {
            try fn_obj.properties.put(realm.allocator, "length", @import("value.zig").Value.fromInt32(m.spec_length));
        }
        fn_obj.home_object = proto;
        fn_obj.is_generator = m.is_generator;
        fn_obj.is_async = m.is_async;
        // §27.3 — `[[Prototype]]` of the method function points
        // at the matching variant prototype so
        // `Object.getPrototypeOf(fn).constructor` resolves to
        // GeneratorFunction / AsyncFunction / etc. when the
        // method body uses those forms.
        fn_obj.proto = if (m.is_generator and m.is_async)
            realm.intrinsics.async_generator_function_prototype orelse realm.intrinsics.function_prototype
        else if (m.is_generator)
            realm.intrinsics.generator_function_prototype orelse realm.intrinsics.function_prototype
        else if (m.is_async)
            realm.intrinsics.async_function_prototype orelse realm.intrinsics.function_prototype
        else
            realm.intrinsics.function_prototype;
        fn_obj.source = m.source;

        if (std.mem.startsWith(u8, m.name, template.private_prefix)) {
            // Private method / accessor — record in
            // private_method_inits so each new instance gets the
            // binding installed. Plain methods land in
            // `private_properties`; getter / setter halves land
            // in `private_accessors` and dispatch through the
            // function at access time.
            //
            // §15.7.14 step 31 — the slot key uses the
            // per-evaluation brand prefix, not the shared
            // compile-time prefix, so a second invocation of this
            // class factory installs slots at a different key.
            const slot_name = try brandMangle(realm, template.private_prefix, brand_prefix, m.name);
            const ak: ObjMod.AccessorKind = switch (m.kind) {
                .method => .none,
                .getter => .getter,
                .setter => .setter,
            };
            private_methods[pm_idx] = .{ .name = slot_name, .init_fn = fn_obj, .accessor_kind = ak };
            pm_idx += 1;
            continue;
        }

        // §15.7.10 ClassDefinitionEvaluation step 14 → §10.2.2
        // DefineMethod step 5 / §15.5.6.4 step 7: class methods
        // and accessors install with `{ writable: true,
        // enumerable: false, configurable: true }`. The default
        // `proto.set` lands data props at the all-true default
        // flags — visible as `enumerable: true` and trips the
        // `verifyProperty` fixtures.
        const method_flags: @import("object.zig").PropertyFlags = .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        };
        switch (m.kind) {
            .method => try proto.setWithFlags(realm.allocator, runtime_name, heap_mod.taggedFunction(fn_obj), method_flags),
            .getter => {
                const entry = try proto.accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
                try proto.property_flags.put(realm.allocator, runtime_name, .{
                    .writable = false,
                    .enumerable = false,
                    .configurable = true,
                });
            },
            .setter => {
                const entry = try proto.accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
                try proto.property_flags.put(realm.allocator, runtime_name, .{
                    .writable = false,
                    .enumerable = false,
                    .configurable = true,
                });
            },
        }
    }
    if (private_methods_count > 0) proto.private_method_inits = private_methods;

    // 6b. Compile instance-field initializers into JSFunctions
    // (each takes `this`, evaluates the init expression,
    // returns the result). Stored on the prototype so the
    // constructor's `init_instance_fields` op finds them.
    if (template.instance_fields.len > 0) {
        var inits = try realm.classAllocator().alloc(ObjMod.FieldInit, template.instance_fields.len);
        for (template.instance_fields, 0..) |*ft, i| {
            const resolved = try resolveComputedKey(realm, computed_keys, ft.computed_key_index, ft.name, proto);
            const runtime_name = resolved.name;
            const init_fn: ?*JSFunction = if (ft.init_chunk) |*c|
                try realm.heap.allocateFunction(c, 0, resolved.display_name, false, captured_env)
            else
                null;
            if (init_fn) |fp| {
                fp.home_object = proto;
                fp.proto = realm.intrinsics.function_prototype;
            }
            // §15.7.14 step 31 — for `#x` fields, swap the
            // compile-time prefix for the per-evaluation brand so
            // each instance lands its slot under a brand-unique
            // key. Public-named fields fall through unchanged.
            const is_private_field = std.mem.startsWith(u8, runtime_name, template.private_prefix);
            const slot_name = if (is_private_field)
                try brandMangle(realm, template.private_prefix, brand_prefix, runtime_name)
            else
                runtime_name;
            inits[i] = .{
                .name = slot_name,
                .init_fn = init_fn,
                .is_private = is_private_field,
            };
        }
        proto.instance_field_inits = inits;
    }

    // 7. Install static methods on the constructor.
    // Static `super` references go through ctor.[[Prototype]]
    // (the parent constructor). Mirror that by setting the
    // static method's home_object to the constructor itself
    // is wrong — the spec says §15.7.14 step 21 sets
    // `[[HomeObject]] = F` (the class). Functions can't be
    // home objects in our model (we typed home_object as
    // *JSObject); instead we'd need to walk through the
    // static_parent function. Defer: later leaves
    // home_object null on static methods, which means
    // `super.x` from inside a static method raises
    // "super used outside a method". Live with it for α —
    // test262 fixtures using `super` in static methods are a
    // small fraction of the class-test cluster.
    for (template.static_methods) |*m| {
        const resolved = try resolveComputedKey(realm, computed_keys, m.computed_key_index, m.name, proto);
        const runtime_name = resolved.name;
        // §15.7 — bare `#method` for private static .name.
        // §10.2.5 — Symbol-keyed static method names follow the
        // same "[desc]" / "" shape via resolved.display_name.
        const base_display = if (std.mem.startsWith(u8, runtime_name, template.private_prefix))
            runtime_name[template.private_prefix.len - 1 ..]
        else
            resolved.display_name;
        // §10.2.5 SetFunctionName step 3.a — accessor prefix.
        const display_name = try maybePrefixAccessor(realm, m.kind, base_display, proto);
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            display_name,
            false,
            captured_env,
        );
        // §15.4.4 MethodDefinitionEvaluation — static methods
        // (including their generator / async variants and the
        // accessor halves) all run through OrdinaryFunctionCreate
        // with FunctionKind = method / accessor, which produces a
        // non-constructor function with NO own `prototype` slot.
        // Drop the auto-allocated prototype that `allocateFunction`
        // installs for non-arrow functions; only the generator /
        // async forms re-install a %GeneratorPrototype%-shaped
        // `prototype` below via their `proto` wiring. Also turn
        // off [[Construct]] so `new C.staticMethod()` throws.
        if (!m.is_generator and !m.is_async) {
            fn_obj.prototype = null;
        } else if (fn_obj.prototype) |gp| {
            // §27.5.1 / §27.6.1 — static generator / async-generator
            // methods carry `.prototype` whose [[Prototype]] is
            // %GeneratorPrototype% / %AsyncGeneratorPrototype% and
            // which has no own `constructor`. Mirror the instance
            // gen-method path so `C.gen()` wrappers find `.next` via
            // the inherited chain.
            _ = gp.properties.swapRemove("constructor");
            _ = gp.property_flags.swapRemove("constructor");
            const interp_mod = @import("interpreter.zig");
            gp.prototype = if (m.is_async)
                interp_mod.ensureAsyncGeneratorPrototype(realm) catch realm.intrinsics.object_prototype
            else
                interp_mod.ensureGeneratorPrototype(realm) catch realm.intrinsics.object_prototype;
        }
        fn_obj.has_construct = false;
        if (m.spec_length != m.param_count) {
            try fn_obj.properties.put(realm.allocator, "length", @import("value.zig").Value.fromInt32(m.spec_length));
        }
        fn_obj.is_generator = m.is_generator;
        fn_obj.is_async = m.is_async;
        fn_obj.proto = if (m.is_generator and m.is_async)
            realm.intrinsics.async_generator_function_prototype orelse realm.intrinsics.function_prototype
        else if (m.is_generator)
            realm.intrinsics.generator_function_prototype orelse realm.intrinsics.function_prototype
        else if (m.is_async)
            realm.intrinsics.async_function_prototype orelse realm.intrinsics.function_prototype
        else
            realm.intrinsics.function_prototype;
        fn_obj.source = m.source;
        // §15.7.14 step 21 — HomeObject of a static method is the
        // class constructor itself (a function). Set
        // `home_function` so `super.x` from inside the static
        // method walks `ctor.proto` to reach the parent class.
        fn_obj.home_function = ctor;
        const is_priv_static = std.mem.startsWith(u8, runtime_name, template.private_prefix);
        // §15.7.14 step 31 — static private slots are also
        // brand-stamped per ClassTail evaluation. `slot_name` is
        // the runtime key; public names fall through unchanged.
        const slot_name = if (is_priv_static)
            try brandMangle(realm, template.private_prefix, brand_prefix, runtime_name)
        else
            runtime_name;
        // §15.7.14 step 18 — Class constructors carry a non-
        // configurable, non-writable `prototype` slot (§10.2.4
        // SetFunctionLength → §10.2.5 OrdinaryFunctionCreate).
        // PropertyDefinitionEvaluation for a static method named
        // `"prototype"` runs DefinePropertyOrThrow, which §10.1.6.3
        // ValidateAndApplyPropertyDescriptor rejects on a
        // non-configurable existing slot. Surface the spec's
        // TypeError before mutating the constructor.
        if (!is_priv_static and std.mem.eql(u8, runtime_name, "prototype")) {
            realm.pending_exception = try @import("intrinsics.zig").newTypeError(realm, "Cannot redefine non-configurable property 'prototype'");
            return error.Propagated;
        }
        // §15.7.10 / §10.2.2 — same descriptor flags as instance
        // methods: `{ writable: true, enumerable: false,
        // configurable: true }` for data; `{ writable: false,
        // enumerable: false, configurable: true }` for accessor.
        const static_method_flags: @import("object.zig").PropertyFlags = .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        };
        const static_accessor_flags: @import("object.zig").PropertyFlags = .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        };
        switch (m.kind) {
            .method => if (is_priv_static) {
                try ctor.private_properties.put(realm.allocator, slot_name, heap_mod.taggedFunction(fn_obj));
                // §7.3.30 PrivateSet step 4 — methods are read-only.
                try ctor.private_methods.put(realm.allocator, slot_name, {});
            } else {
                try ctor.set(realm.allocator, slot_name, heap_mod.taggedFunction(fn_obj));
                try ctor.property_flags.put(realm.allocator, slot_name, static_method_flags);
            },
            .getter => if (is_priv_static) {
                const entry = try ctor.private_accessors.getOrPut(realm.allocator, slot_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
            } else {
                // §17 static accessor on a class constructor —
                // landed in the JSFunction's `accessors` map
                // (added in the JSFunction-accessors commit).
                const entry = try ctor.accessors.getOrPut(realm.allocator, slot_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
                try ctor.property_flags.put(realm.allocator, slot_name, static_accessor_flags);
            },
            .setter => if (is_priv_static) {
                const entry = try ctor.private_accessors.getOrPut(realm.allocator, slot_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
            } else {
                const entry = try ctor.accessors.getOrPut(realm.allocator, slot_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
                try ctor.property_flags.put(realm.allocator, slot_name, static_accessor_flags);
            },
        }
    }

    // 8. Static fields — evaluate each init with this=ctor and
    // install on ctor. §15.7.10 step 1 ClassInitialization.
    const interpreter = @import("interpreter.zig");
    const ctor_value = heap_mod.taggedFunction(ctor);

    // §15.7.14 step 27.b — publish the constructor into the
    // inner classScopeEnvRec slot BEFORE static fields and
    // static blocks run. The inner binding is created
    // immutable; subsequent reads of `C` from inside a static
    // initializer (e.g. `static foo = C.bar`,
    // `static { C.bar = 1 }`) must see the constructor. Without
    // this, the binding stays in TDZ until the trailing
    // `sta_env` opcode after make_class returns, and the
    // initializer throws ReferenceError. The `captured_env` IS
    // the inner classScopeEnvRec at make_class time (the
    // compiler emits `make_environment 1; … make_class`).
    if (inner_class_slot) |slot| {
        if (captured_env) |env| {
            if (slot < env.slots.len) {
                env.slots[slot] = ctor_value;
            }
        }
    }
    // §15.7.14 step 34 — `For each element of staticElements in
    // List order` interleaves static fields and static blocks in
    // source order. `static_element_order` encodes the source-
    // order index list: high bit set → block index; clear → field
    // index. Without this, `static a=1; static {…} static b=2;`
    // would run field/field/block instead of field/block/field
    // (observable when the block reads or mutates a previously-
    // installed static field).
    for (template.static_element_order) |entry| {
        const is_block = (entry & 0x8000) != 0;
        const idx: usize = entry & 0x7FFF;
        if (is_block) {
            const c = &template.static_blocks[idx];
            const blk_fn = try realm.heap.allocateFunction(c, 0, null, false, captured_env);
            // §15.7.13 ClassStaticBlockDefinitionEvaluation step
            // 4 — MakeMethod(body, homeObject) where homeObject
            // is the class constructor F. The interpreter's
            // super_get dispatch keys off `home_object == null`
            // for the static path (same as static methods, see
            // step 21), so set ONLY `home_function = ctor`. Then
            // `super.x` inside the block walks ctor.proto =
            // parent ctor and reads the parent class's static
            // surface. Setting `home_object = proto` here would
            // route through the prototype chain (the wrong
            // surface — instance methods, not statics).
            blk_fn.home_function = ctor;
            blk_fn.proto = realm.intrinsics.function_prototype;
            const outcome = interpreter.callJSFunction(realm.allocator, realm, blk_fn, ctor_value, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            switch (outcome) {
                .value, .yielded => {},
                .thrown => |ex| {
                    // §15.7.13 ClassStaticBlock — abrupt completion
                    // aborts ClassDefinitionEvaluation; later
                    // elements (fields or blocks) must not run.
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
            continue;
        }
        const ft = &template.static_fields[idx];
        const resolved = try resolveComputedKey(realm, computed_keys, ft.computed_key_index, ft.name, proto);
        const runtime_name = resolved.name;
        var v: Value = Value.undefined_;
        if (ft.init_chunk) |*c| {
            const init_fn = try realm.heap.allocateFunction(c, 0, resolved.display_name, false, captured_env);
            // §15.7.14 step 34 / §15.4 — static field initializer
            // is a method whose [[HomeObject]] is the class
            // constructor F. Set ONLY `home_function = ctor` so
            // the super_get dispatch takes the static path
            // (`home_object == null` → walk
            // `home_function.proto` for `super.x`). Otherwise
            // `super.x` would route through the prototype chain
            // (instance surface) instead of the parent ctor's
            // own properties.
            init_fn.home_function = ctor;
            init_fn.proto = realm.intrinsics.function_prototype;
            const outcome = interpreter.callJSFunction(realm.allocator, realm, init_fn, ctor_value, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            switch (outcome) {
                .value, .yielded => |val| v = val,
                .thrown => |ex| {
                    // §15.7.14 step 34 / §10.2.1.3 — an abrupt
                    // completion during a static field initializer
                    // aborts ClassDefinitionEvaluation and propagates.
                    // Subsequent elements (fields or blocks) must
                    // NOT run.
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
        }
        if (std.mem.startsWith(u8, runtime_name, template.private_prefix)) {
            // §15.7 — `static #x = expr` lands in the
            // constructor's private slot, not the regular
            // property bag. §15.7.14 step 31 — key by the
            // per-evaluation brand prefix.
            //
            // §7.3.32 PrivateFieldAdd step 1 — the initializer
            // may have run `Object.preventExtensions(C)` mid-
            // evaluation (the static-private case of the
            // `nonextensible-applies-to-private` ES2022 fixture).
            // Check before installing.
            if (!ctor.extensible) {
                realm.pending_exception = try @import("intrinsics.zig").newTypeError(realm, "Cannot add private static field to non-extensible class");
                return error.Propagated;
            }
            const slot_name = try brandMangle(realm, template.private_prefix, brand_prefix, runtime_name);
            try ctor.private_properties.put(realm.allocator, slot_name, v);
        } else {
            // §15.7.14 step 18 — guard against `static prototype = …`
            // for the same reason as static methods: the class's
            // own non-configurable `prototype` slot rejects a
            // DefineOwnProperty.
            if (std.mem.eql(u8, runtime_name, "prototype")) {
                realm.pending_exception = try @import("intrinsics.zig").newTypeError(realm, "Cannot redefine non-configurable property 'prototype'");
                return error.Propagated;
            }
            try ctor.set(realm.allocator, runtime_name, v);
        }
    }

    return heap_mod.taggedFunction(ctor);
}

/// §10.2.5 SetFunctionName step 3.a — for a getter, return
/// `"get " ++ base`; for a setter, `"set " ++ base`; otherwise
/// return `base` unchanged. The composed string is anchored on
/// `anchor.key_anchors` so the GC keeps it alive while the
/// class is reachable. Falls back to `base` on OOM.
fn maybePrefixAccessor(
    realm: *Realm,
    kind: ChunkMod.MethodKind,
    base: []const u8,
    anchor: *JSObject,
) !([]const u8) {
    const prefix: []const u8 = switch (kind) {
        .method => return base,
        .getter => "get ",
        .setter => "set ",
    };
    const buf = realm.allocator.alloc(u8, prefix.len + base.len) catch return base;
    defer realm.allocator.free(buf);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], base);
    const owned = realm.heap.allocateString(buf) catch return base;
    anchor.key_anchors.append(realm.allocator, owned) catch {};
    return owned.bytes;
}

const ResolvedKey = struct {
    /// Property-bag slot (`@@iterator`, `<sym:N>`, or a string key).
    name: []const u8,
    /// §10.2.5 SetFunctionName-friendly display string. For a
    /// computed key that resolves to a Symbol with description
    /// `desc`, this is `"[" + desc + "]"`; for a Symbol with
    /// no description, it's the empty string. For a non-Symbol
    /// key it matches `name`.
    display_name: []const u8,
};

/// §13.2.5 — convert a pre-computed `[expr]` key value (already
/// `to_property_key`-coerced by the enclosing bytecode, so it's a
/// string or symbol Value) into a borrowed property-key slug plus
/// a §10.2.5 SetFunctionName-friendly display name. The caller
/// passes the anchor object (prototype or constructor) the heap-
/// allocated key string should attach to so the GC keeps it alive
/// for as long as the class is reachable. When `computed_key_index`
/// is negative, returns `fallback` (the static name from the
/// MethodTemplate / FieldTemplate).
fn resolveComputedKey(
    realm: *Realm,
    computed_keys: []const Value,
    computed_key_index: i16,
    fallback: []const u8,
    anchor: *JSObject,
) !ResolvedKey {
    if (computed_key_index < 0) return .{ .name = fallback, .display_name = fallback };
    const idx: usize = @intCast(computed_key_index);
    std.debug.assert(idx < computed_keys.len);
    const prim_v = computed_keys[idx];
    const heap_mod_ = @import("heap.zig");
    const intrinsics = @import("intrinsics.zig");
    if (heap_mod_.valueAsSymbol(prim_v)) |sym| {
        // §7.1.19 ToPropertyKey — every Symbol carries a stable
        // `prop_key` slug (`@@iterator` for well-known, `<sym:N>`
        // for user-allocated). The interpreter's computed-key
        // path stringifies via the same slug, so a class field /
        // method keyed by `[sym]` lands at the same slot that
        // `inst[sym]` reads. Falling back to `description` would
        // collapse `Symbol("x")` and the property `"x"` into one
        // slot and make `hasOwn(inst, sym)` miss.
        //
        // §10.2.5 SetFunctionName step 2 — for a Symbol key,
        // the function `.name` is `"[" + description + "]"`,
        // or `""` when description is undefined. Materialise
        // that here so methods keyed by `[sym]` carry the
        // spec-correct display name even though their slot is
        // the `prop_key` slug.
        const display: []const u8 = blk: {
            if (sym.description) |desc| {
                const buf = realm.allocator.alloc(u8, desc.len + 2) catch break :blk "";
                buf[0] = '[';
                @memcpy(buf[1 .. 1 + desc.len], desc);
                buf[1 + desc.len] = ']';
                // Anchor the heap-side display name so the
                // class GC root keeps it alive for the lifetime
                // of the class prototype.
                const owned = realm.heap.allocateString(buf) catch break :blk "";
                realm.allocator.free(buf);
                anchor.key_anchors.append(realm.allocator, owned) catch {};
                break :blk owned.bytes;
            }
            break :blk "";
        };
        return .{ .name = sym.prop_key, .display_name = display };
    }
    const s = intrinsics.stringifyArg(realm, prim_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Propagated,
    };
    // §13.2.5 / §10.4.2 — anchor the heap-allocated key string
    // on the host object so the GC keeps it alive for as long
    // as the class prototype is reachable. Without anchoring,
    // a later GC cycle sweeps the JSString and the property
    // bag's borrowed `[]const u8` key slice dangles.
    anchor.key_anchors.append(realm.allocator, s) catch return .{ .name = fallback, .display_name = fallback };
    return .{ .name = s.bytes, .display_name = s.bytes };
}
