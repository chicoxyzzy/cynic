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

    // 3. Allocate the constructor.
    const ctor = try realm.heap.allocateFunction(
        &template.constructor_chunk,
        template.constructor_param_count,
        template.name,
        false, // is_arrow
        captured_env,
    );
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
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            m.name,
            false,
            captured_env,
        );
        fn_obj.home_object = proto;
        fn_obj.proto = realm.intrinsics.function_prototype;
        fn_obj.source = m.source;

        if (std.mem.startsWith(u8, m.name, template.private_prefix)) {
            // Private method — record in private_method_inits so
            // each new instance gets a binding. NOT installed on
            // the prototype's properties (that would let any
            // object access it via the chain).
            private_methods[pm_idx] = .{ .name = m.name, .init_fn = fn_obj };
            pm_idx += 1;
            continue;
        }

        switch (m.kind) {
            .method => try proto.set(realm.allocator, m.name, heap_mod.taggedFunction(fn_obj)),
            .getter => {
                const entry = try proto.accessors.getOrPut(realm.allocator, m.name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.getter = fn_obj;
            },
            .setter => {
                const entry = try proto.accessors.getOrPut(realm.allocator, m.name);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.*.setter = fn_obj;
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
            const init_fn: ?*JSFunction = if (ft.init_chunk) |*c|
                try realm.heap.allocateFunction(c, 0, ft.name, false, captured_env)
            else
                null;
            if (init_fn) |fp| {
                fp.home_object = proto;
                fp.proto = realm.intrinsics.function_prototype;
            }
            inits[i] = .{
                .name = ft.name,
                .init_fn = init_fn,
                .is_private = std.mem.startsWith(u8, ft.name, template.private_prefix),
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
        const fn_obj = try realm.heap.allocateFunction(
            &m.chunk,
            m.param_count,
            m.name,
            false,
            captured_env,
        );
        fn_obj.proto = realm.intrinsics.function_prototype;
        fn_obj.source = m.source;
        switch (m.kind) {
            .method => try ctor.set(realm.allocator, m.name, heap_mod.taggedFunction(fn_obj)),
            .getter, .setter => {
                // For now later treats static accessors as
                // regular methods — the function-object accessor
                // model isn't generalised yet. later.
                try ctor.set(realm.allocator, m.name, heap_mod.taggedFunction(fn_obj));
            },
        }
    }

    // 8. Static fields — evaluate each init with this=ctor and
    // install on ctor. §15.7.10 step 1 ClassInitialization.
    const interpreter = @import("interpreter.zig");
    const ctor_value = heap_mod.taggedFunction(ctor);
    for (template.static_fields) |*ft| {
        var v: Value = Value.undefined_;
        if (ft.init_chunk) |*c| {
            const init_fn = try realm.heap.allocateFunction(c, 0, ft.name, false, captured_env);
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
        try ctor.set(realm.allocator, ft.name, v);
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
