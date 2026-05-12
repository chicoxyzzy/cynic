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
pub fn buildClass(
    realm: *Realm,
    template: *const ClassTemplate,
    captured_env: ?*Environment,
    heritage_v: ?Value,
) ClassError!Value {
    // 1. Heritage check — if `extends X`, X must be a constructor.
    var parent_ctor: ?*JSFunction = null;
    var parent_proto: ?*JSObject = null;
    if (heritage_v) |hv| {
        if (hv.isNull()) {
            // `extends null` — proto chain ends at null, and the
            // constructor still inherits from %Function.prototype%.
            parent_ctor = null;
            parent_proto = null;
        } else if (heap_mod.valueAsFunction(hv)) |fn_obj| {
            parent_ctor = fn_obj;
            // Read parent.prototype — if it's an object, use it
            // as the prototype's [[Prototype]]. If it's null, the
            // instance proto chain ends at null. Anything else
            // (e.g. `Foo.prototype = 42`) is rejected by the
            // spec; we approximate by treating it as null.
            const parent_proto_v = fn_obj.get("prototype");
            if (heap_mod.valueAsPlainObject(parent_proto_v)) |po| {
                parent_proto = po;
            }
        } else {
            return error.HeritageNotConstructor;
        }
    }

    // 2. Allocate the prototype object.
    const proto = try realm.heap.allocateObject();
    proto.prototype = parent_proto orelse realm.intrinsics.object_prototype;

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
    if (parent_ctor != null) ctor.constructor_kind = .derived;
    // Wire the ctor's [[Prototype]] for `Function.prototype.call`/`apply`/`bind`.
    ctor.proto = realm.intrinsics.function_prototype;
    ctor.source = template.source;
    // The constructor itself is a "method" of the class — its
    // home object is the prototype object, so `super(...)` /
    // `super.method()` inside the constructor body resolve.
    ctor.home_object = proto;

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
        // was `[expr]`, evaluate the key chunk to get the
        // runtime key. Otherwise use the static `m.name`.
        const runtime_name = try resolveComputedKey(realm, optChunkPtr(&m.key_chunk), m.name, captured_env, proto);
        // §15.7 — private method `.name` is the bare `#method`,
        // not the class-identity-prefixed mangled key. Strip
        // the `P<uid>#` prefix used for the slot lookup. The
        // accessor `get / set` prefix is added below per kind.
        const display_name = if (std.mem.startsWith(u8, runtime_name, template.private_prefix))
            runtime_name[template.private_prefix.len - 1 ..]
        else
            runtime_name;
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            display_name,
            false,
            captured_env,
        );
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
            const ak: ObjMod.AccessorKind = switch (m.kind) {
                .method => .none,
                .getter => .getter,
                .setter => .setter,
            };
            private_methods[pm_idx] = .{ .name = m.name, .init_fn = fn_obj, .accessor_kind = ak };
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
            const runtime_name = try resolveComputedKey(realm, optChunkPtr(&ft.key_chunk), ft.name, captured_env, proto);
            const init_fn: ?*JSFunction = if (ft.init_chunk) |*c|
                try realm.heap.allocateFunction(c, 0, runtime_name, false, captured_env)
            else
                null;
            if (init_fn) |fp| {
                fp.home_object = proto;
                fp.proto = realm.intrinsics.function_prototype;
            }
            inits[i] = .{
                .name = runtime_name,
                .init_fn = init_fn,
                .is_private = std.mem.startsWith(u8, runtime_name, template.private_prefix),
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
        const runtime_name = try resolveComputedKey(realm, optChunkPtr(&m.key_chunk), m.name, captured_env, proto);
        // §15.7 — bare `#method` for private static .name.
        const display_name = if (std.mem.startsWith(u8, runtime_name, template.private_prefix))
            runtime_name[template.private_prefix.len - 1 ..]
        else
            runtime_name;
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            display_name,
            false,
            captured_env,
        );
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
                try ctor.private_properties.put(realm.allocator, runtime_name, heap_mod.taggedFunction(fn_obj));
            } else {
                try ctor.set(realm.allocator, runtime_name, heap_mod.taggedFunction(fn_obj));
                try ctor.property_flags.put(realm.allocator, runtime_name, static_method_flags);
            },
            .getter => if (is_priv_static) {
                const entry = try ctor.private_accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
            } else {
                // §17 static accessor on a class constructor —
                // landed in the JSFunction's `accessors` map
                // (added in the JSFunction-accessors commit).
                const entry = try ctor.accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
                try ctor.property_flags.put(realm.allocator, runtime_name, static_accessor_flags);
            },
            .setter => if (is_priv_static) {
                const entry = try ctor.private_accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
            } else {
                const entry = try ctor.accessors.getOrPut(realm.allocator, runtime_name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
                try ctor.property_flags.put(realm.allocator, runtime_name, static_accessor_flags);
            },
        }
    }

    // 8. Static fields — evaluate each init with this=ctor and
    // install on ctor. §15.7.10 step 1 ClassInitialization.
    const interpreter = @import("interpreter.zig");
    const ctor_value = heap_mod.taggedFunction(ctor);
    for (template.static_fields) |*ft| {
        const runtime_name = try resolveComputedKey(realm, optChunkPtr(&ft.key_chunk), ft.name, captured_env, proto);
        var v: Value = Value.undefined_;
        if (ft.init_chunk) |*c| {
            const init_fn = try realm.heap.allocateFunction(c, 0, runtime_name, false, captured_env);
            init_fn.home_object = proto;
            init_fn.proto = realm.intrinsics.function_prototype;
            const outcome = interpreter.callJSFunction(realm.allocator, realm, init_fn, ctor_value, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            switch (outcome) {
                .value, .yielded => |val| v = val,
                .thrown => v = Value.undefined_,
            }
        }
        if (std.mem.startsWith(u8, runtime_name, template.private_prefix)) {
            // §15.7 — `static #x = expr` lands in the
            // constructor's private slot, not the regular
            // property bag.
            try ctor.private_properties.put(realm.allocator, runtime_name, v);
        } else {
            try ctor.set(realm.allocator, runtime_name, v);
        }
    }

    // 9. Static blocks — run with this=ctor. §15.7.13.
    for (template.static_blocks) |*c| {
        const blk_fn = try realm.heap.allocateFunction(c, 0, null, false, captured_env);
        blk_fn.home_object = proto;
        blk_fn.proto = realm.intrinsics.function_prototype;
        const outcome = interpreter.callJSFunction(realm.allocator, realm, blk_fn, ctor_value, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OutOfMemory,
        };
        _ = outcome; // discarded — static blocks return undefined
    }

    return heap_mod.taggedFunction(ctor);
}

/// §13.2.5 — evaluate a ComputedPropertyName chunk and coerce
/// the result via ToPropertyKey into a borrowed string slice
/// suitable for use as a property key. Caller passes a JSObject
/// (the prototype or constructor) on which to anchor the heap-
/// allocated key string so it survives GC for the lifetime of
/// the class. When `key_chunk` is null, returns `fallback`
/// unchanged.
/// Convert `*const ?Chunk` to `?*const Chunk` — needed because
/// `?T` doesn't auto-promote and we want a pointer into the
/// owning MethodTemplate / FieldTemplate (not a stack copy).
fn optChunkPtr(opt: *const ?ChunkMod.Chunk) ?*const ChunkMod.Chunk {
    if (opt.*) |*c| return c;
    return null;
}

fn resolveComputedKey(
    realm: *Realm,
    key_chunk: ?*const ChunkMod.Chunk,
    fallback: []const u8,
    captured_env: ?*@import("environment.zig").Environment,
    anchor: *JSObject,
) !([]const u8) {
    const chunk_ptr = key_chunk orelse return fallback;
    const interpreter = @import("interpreter.zig");
    const heap_mod_ = @import("heap.zig");
    // `allocateFunction` stores the chunk pointer; it must
    // outlive the JSFunction. Pass through the
    // MethodTemplate's / FieldTemplate's owning chunk directly
    // instead of a stack copy (which would dangle the moment
    // this function returned).
    //
    // `is_arrow=true` skips the auto-allocated prototype JSObject
    // — this ephemeral function is never user-visible and only
    // exists to evaluate the key expression. Without this every
    // computed-key resolution costs 2 heap objects (JSFunction +
    // its prototype) that pile up under heavy class-creation
    // loops and pressure both the GC and libc malloc.
    const ks_fn = try realm.heap.allocateFunction(chunk_ptr, 0, null, true, captured_env);
    ks_fn.proto = realm.intrinsics.function_prototype;
    // §13.2.5.5 PropertyDefinitionEvaluation step 1.b — an abrupt
    // completion from the key expression propagates up through
    // class-definition evaluation as a user-visible throw.
    const outcome = interpreter.callJSFunction(realm.allocator, realm, ks_fn, Value.undefined_, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Propagated,
    };
    const key_v = switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.Propagated;
        },
    };
    if (heap_mod_.valueAsSymbol(key_v)) |sym| {
        // Well-known symbols in Cynic carry their `@@`-prefixed
        // name as the description, so the description IS the
        // slot key. For user symbols without a description, fall
        // back to a synthetic id (we don't have one — the
        // fallback name keeps the engine moving).
        if (sym.description) |desc| return desc;
        return fallback;
    }
    const intrinsics = @import("intrinsics.zig");
    // §13.2.5.5 step 1.c — `ToPropertyKey(propName)` runs
    // ToPrimitive which can throw. Surface the thrown value back
    // via `realm.pending_exception` instead of silently coercing
    // to a fallback string.
    const s = intrinsics.stringifyArg(realm, key_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Propagated,
    };
    // §13.2.5 / §10.4.2 — anchor the heap-allocated key string
    // on the host object so the GC keeps it alive for as long
    // as the class prototype is reachable. Without anchoring,
    // a later GC cycle sweeps the JSString and the property
    // bag's borrowed `[]const u8` key slice dangles.
    anchor.key_anchors.append(realm.allocator, s) catch return fallback;
    return s.bytes;
}
