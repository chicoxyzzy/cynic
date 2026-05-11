//! Opcode set for Cynic's bytecode.
//!
//! Cynic uses an Ignition-style register file with an implicit
//! accumulator (`acc`). Every binary opcode reads its left-hand
//! operand from a named register and its right-hand operand from
//! the accumulator, writing the result back to the accumulator.
//! Unary opcodes operate on the accumulator in place. Loads /
//! stores shuttle values between registers, the constant pool,
//! and the accumulator.
//!
//! later ships only the opcodes the expression-only compiler emits.
//! Statements, function calls, and object/property
//! ops extend this enum without renumbering existing
//! variants — disasm output for an later chunk stays stable.
//!
//! Operand encoding (little-endian on the wire):
//! `r:u8` — register index, max 255 per frame.
//! `k:u16` — index into `Chunk.constants`.
//! `i:i32` — Smi immediate (small-int fast path, §6.1.6.1).
//! `o:i16` — branch offset, signed, relative to the byte
//! immediately after the operand.
//!
//! See the [compiler-engineering handbook](../../docs/handbook/compiler-engineering.md)
//! for the design rationale (Ignition / Hermes lineage; why
//! register file + accumulator beats a pure stack here).

const std = @import("std");

pub const Op = enum(u8) {
    // ── Loads ────────────────────────────────────────────────────────────
    /// Load `undefined` into acc. Encoding: `[op]`.
    lda_undefined,
    /// Load `null` into acc.
    lda_null,
    /// Load `true` into acc.
    lda_true,
    /// Load `false` into acc.
    lda_false,
    /// `[op] [i:i32]` — load a Smi immediate into acc.
    lda_smi,
    /// `[op] [k:u16]` — load `Chunk.constants[k]` into acc.
    lda_constant,
    /// `[op] [r:u8]` — copy register `r` into acc.
    ldar,
    /// `[op] [r:u8]` — copy acc into register `r`.
    star,
    /// `[op] [src:u8] [dst:u8]` — copy register `src` into
    /// register `dst` without disturbing the accumulator. The
    /// compiler emits this for binding initialisers that don't
    /// otherwise materialise a value through acc.
    mov,
    /// Load the TDZ Hole sentinel into acc. Block-entry init for
    /// every `let`/`const` binding (§13.3.1).
    lda_hole,

    // ── Arithmetic (acc = reg OP acc) ────────────────────────────────────
    /// `[op] [r:u8]` — acc = reg + acc. §13.7.3.
    add,
    /// `[op] [r:u8]` — acc = reg - acc. §13.7.4.
    sub,
    /// `[op] [r:u8]` — acc = reg * acc. §13.7.2.
    mul,
    /// `[op] [r:u8]` — acc = reg / acc. §13.7.2.
    div,
    /// `[op] [r:u8]` — acc = reg % acc. §13.7.2.
    mod,
    /// `[op] [r:u8]` — acc = reg ** acc. §13.7.1.
    pow,

    // ── Bitwise (acc = reg OP acc, ToInt32 coercion) ─────────────────────
    /// `[op] [r:u8]` — acc = reg & acc. §13.12.
    bit_and,
    /// `[op] [r:u8]` — acc = reg | acc. §13.12.
    bit_or,
    /// `[op] [r:u8]` — acc = reg ^ acc. §13.12.
    bit_xor,
    /// `[op] [r:u8]` — acc = reg << acc.
    shl,
    /// `[op] [r:u8]` — acc = reg >> acc (sign-propagating).
    shr,
    /// `[op] [r:u8]` — acc = reg >>> acc (zero-fill).
    shr_u,

    // ── Unary (operate on acc) ───────────────────────────────────────────
    /// acc = -acc. §13.5.5.
    negate,
    /// acc = ~acc (ToInt32 then bit-NOT). §13.5.6.
    bit_not,
    /// acc = !acc (ToBoolean then negate). §13.5.7.
    logical_not,
    /// acc = +acc (ToNumber). §13.5.4.
    to_number,
    /// acc = typeof acc → JSString. §13.5.3.
    typeof_,

    // ── Comparison (acc = reg CMP acc → Bool) ────────────────────────────
    /// `[op] [r:u8]` — acc = reg == acc. §7.2.14 IsLooselyEqual.
    eq,
    /// `[op] [r:u8]` — acc = reg === acc. §7.2.15 IsStrictlyEqual.
    strict_eq,
    /// `[op] [r:u8]` — acc = reg != acc.
    neq,
    /// `[op] [r:u8]` — acc = reg !== acc.
    strict_neq,
    /// `[op] [r:u8]` — acc = reg < acc. §7.2.13 IsLessThan.
    lt,
    /// `[op] [r:u8]` — acc = reg > acc.
    gt,
    /// `[op] [r:u8]` — acc = reg <= acc.
    le,
    /// `[op] [r:u8]` — acc = reg >= acc.
    ge,

    // ── Control flow ─────────────────────────────────────────────────────
    /// `[op] [o:i16]` — unconditional jump.
    jmp,
    /// `[op] [o:i16]` — jump if `!ToBoolean(acc)`.
    jmp_if_false,
    /// `[op] [o:i16]` — jump if `ToBoolean(acc)`.
    jmp_if_true,
    /// `[op] [o:i16]` — jump if acc is `null` or `undefined`.
    /// §13.5.5 OptionalChain short-circuit: when `?.` LHS evaluates
    /// to nullish, the entire chain returns undefined.
    jmp_if_nullish,

    // ── Functions / calls ─────────────────────────────────────────
    /// `[op] [k:u16]` — instantiate a `JSFunction` from
    /// `Chunk.function_templates[k]`, capturing the current
    /// frame's environment chain. The instance lands in the
    /// accumulator.
    make_function,
    /// `[op] [r_callee:u8] [argc:u8]` — invoke the function in
    /// register `r_callee` with `argc` arguments drawn from the
    /// consecutive registers `r_callee+1.. r_callee+argc`. The
    /// return value lands in the caller's accumulator after the
    /// callee's `Return`.
    call,
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8]` — method call.
    /// Identical to `Call` except `this` is bound to the value in
    /// `r_recv` (§13.3.6 — `obj.method()` produces a Reference
    /// whose base is `obj`, so the call sees `this = obj`).
    /// Args are read from `r_callee + 1.. r_callee + argc`,
    /// matching `Call` so the compiler can share its argument-
    /// emission helper.
    call_method,
    /// `[op] [r_callee:u8] [argc:u8]` — `new f(args)` (§13.3.5).
    /// Allocates a fresh ordinary object whose `[[Prototype]]` is
    /// `f.prototype`, calls `f` with `this` bound to the new
    /// object, and yields either the constructor's return value
    /// (if it's an object) or the new object (otherwise).
    new_call,
    /// Load `this` from the current call frame into acc. Top-level
    /// `this` is `undefined` in strict mode (§10.2.1.2). Arrow
    /// functions inherit `this` from their captured frame; the
    /// compiler arranges for that by emitting `LdaThis` against
    /// the lexically enclosing frame's binding.
    lda_this,
    /// `[op] [r:u8]` — acc = (reg instanceof acc).
    /// §13.10.2 InstanceofOperator. The right-hand side must be a
    /// callable; if it isn't, throws TypeError. Walks the LHS's
    /// prototype chain looking for `rhs.prototype`.
    instanceof_,
    /// `[op] [r:u8]` — acc = (ToPropertyKey(reg) in acc).
    /// §13.10.1 RelationalExpression `in`. Right-hand side must be
    /// an object; if not, throws TypeError. Walks the prototype
    /// chain. On a proxy receiver, dispatches the `has` trap.
    in_op,
    /// `[op] [r:u8]` — §7.4.6 IteratorClose for the iterator in
    /// register `r`. Looks up `iter.return`; if callable, invokes
    /// it with no args. Errors thrown by the trap are silently
    /// swallowed (the spec re-throws when the abrupt completion is
    /// a return — Cynic's strict-only profile treats both as
    /// silent). The accumulator is preserved.
    iter_close,
    /// `[op] [r_src:u8] [start:u8]` — destructuring rest helper.
    /// Reads `src.length`, allocates a fresh Array, and copies
    /// `src[start..length]` into it (preserving holes). Used to
    /// implement `const [a, b,...rest] = src` and equivalents.
    /// The new array lands in `acc`.
    array_rest_from,
    /// `[op] [r_src:u8] [r_excl_arr:u8]` — copy every own
    /// enumerable property of `src` whose key is not among the
    /// strings in the array at `r_excl_arr` into a fresh object,
    /// leaving the result in `acc`. Used for `const {x, y,...rest} = src`.
    object_rest_from,
    /// `[op] [k:u16]` — instantiate a class from
    /// `Chunk.class_templates[k]`. The heritage value (for
    /// `class … extends X`) is read from the accumulator on entry
    /// (the compiler emits the heritage expression immediately
    /// before this op); when the template's `has_heritage` is
    /// false, the accumulator is ignored. The resulting class
    /// constructor lands in `acc`. §15.7.14
    /// OrdinaryClassDefinition mirrors in `runtime/class.zig`.
    make_class,
    /// `[op] [k:u16]` — `acc = home.[[Prototype]][key_k]`, where
    /// `home` is the home object of the executing function (its
    /// `.home_object` slot) and `key_k` is the JSString constant
    /// at index `k`. §13.3.7. Throws if the function has no
    /// home object (e.g. ordinary function) or the lookup walks
    /// off the chain.
    super_get,
    /// `[op]` — `acc = home.[[Prototype]][ToPropertyKey(acc)]`.
    /// §13.3.2 EvaluatePropertyAccessWithExpressionKey for
    /// `super[expr]`. Same semantics as `super_get` but the key
    /// is computed at runtime and arrives in the accumulator.
    super_get_computed,
    /// `[op] [r_args:u8] [argc:u8]` — invoke the parent
    /// constructor (`home.[[Prototype]].constructor` of the
    /// executing function) with `this` from the current frame
    /// and `argc` arguments at registers `r_args.. r_args+argc`.
    /// The return value lands in `acc`. §13.3.7 super-call.
    super_call,
    /// Forward the *caller's* arguments to the parent
    /// constructor unchanged. Emitted by the compiler-synthesised
    /// default constructor for derived classes (§15.7.14
    /// step 14.f) — `class B extends A {}` is equivalent to
    /// `class B extends A { constructor(...args) { super(...args); } }`,
    /// but without rest-params support we read the frame's
    /// recorded `argc` directly. No operands.
    super_call_forward,
    /// Run the class instance-field initializers on the current
    /// frame's `this`. Reads the executing function's
    /// `home_object` (which is the class prototype), iterates
    /// `home_object.instance_field_inits`, and for each entry
    /// invokes `init_fn` with `this` bound to the instance and
    /// assigns the result to `this.name`. Also installs
    /// private-method bindings on the instance's
    /// `private_properties` from
    /// `home_object.private_method_inits`. No operands.
    /// §15.7.10 InitializeInstanceElements.
    init_instance_fields,
    /// `[op] [k:u16]` — private-property read. The constant pool
    /// entry at `k` is the class-prefixed key (`"P<uid>#name"`);
    /// `acc` holds the receiver. Throws TypeError on brand-check
    /// miss (no such private slot on the receiver). §7.3.27
    /// PrivateElementFind.
    lda_private,
    /// `[op] [k:u16] [r_obj:u8]` — private-property write.
    /// `acc` holds the value, `r_obj` the receiver. Throws
    /// TypeError on brand-check miss.
    sta_private,
    /// `[op] [k:u16] [r_obj:u8] [is_setter:u8]` — install the
    /// function in `acc` as a getter (`is_setter == 0`) or
    /// setter (`is_setter != 0`) on `r_obj.accessors[key_k]`.
    /// §13.2.5 PropertyDefinitionEvaluation for accessors.
    def_accessor,
    /// `[op] [r_obj:u8] [r_key:u8] [is_setter:u8]` — like
    /// `def_accessor` but the key is the string in `r_key`
    /// (after `computedKeyToString` coercion) rather than a
    /// constant index. Drives `{ get [expr](){} }` and the
    /// matching setter form.
    def_computed_accessor,
    /// `[op] [r_obj:u8]` — §B.3.1 `__proto__` literal — when an
    /// object literal contains `{ __proto__: v }` (and the key
    /// is *not* computed), the value is special: if `v` is an
    /// Object set `r_obj.[[Prototype]] = v`; if `v` is `null`
    /// set it to `null`; otherwise it's a no-op (the `__proto__`
    /// property is *not* created). The computed form
    /// `{ ["__proto__"]: v }` falls through to ordinary
    /// `sta_property` and so isn't routed here. The acc holds
    /// `v`; this op preserves acc.
    set_proto_literal,
    /// `[op] [r_obj:u8]` — §10.2.5 set [[HomeObject]]. If `acc` is
    /// a function, set its `home_object` slot to the object in
    /// `r_obj`. No-op for non-function `acc`. Emitted between
    /// `make_function` and `sta_property` / `def_accessor` for
    /// object-literal methods so `super.x` / `super[x]` /
    /// `super.x(...)` from inside the method walks
    /// `r_obj.[[Prototype]]` to find the parent property —
    /// matching the class-method machinery.
    set_home,

    /// `[op] [r_key:u8] [prefix:u8]` — §13.2.5.5 / §15.5.6.4
    /// SetFunctionName fix-up for computed property keys. If
    /// `acc` is an anonymous function-like (`.name === ""`), set
    /// its `.name` to the property-key derived from `r_key`:
    ///   - String / numeric / boolean / null / undefined → ToString
    ///   - Symbol with description `d`         → `"[" + d + "]"`
    ///   - Symbol with no description          → `""`
    ///   - Already-named function              → no-op
    /// `prefix` selects an accessor-style prefix:
    ///   - `0` → no prefix (plain method or value form)
    ///   - `1` → `"get "` (getter)
    ///   - `2` → `"set "` (setter)
    /// Drives the `name` inference for `{ [k]: function(){} }`,
    /// `{ [k]: () => x }`, `{ [k]: class{} }`, and the
    /// `{ get [k](){} }` / `{ set [k](){} }` accessor forms.
    /// The acc (the function/class) is preserved.
    set_fn_name_from,
    /// Build the implicit `arguments` array-like for the current
    /// non-arrow function frame. Reads registers[0..argc] and
    /// returns a JSObject with numeric-index properties + a
    /// `length` slot, in `acc`. §10.4.4. Emitted by the function
    /// prologue when the body references `arguments`.
    lda_arguments,
    /// `[op] [start:u8]` — §15.2.4 IteratorBindingInitialization
    /// for a rest parameter `function f(a, b,...rest) {}`. Build a
    /// fresh Array from the current frame's argument registers
    /// `start..argc`, with `length = argc - start`, leaving it in
    /// `acc`. When the caller passed fewer than `start` args, the
    /// resulting array is empty.
    rest_args_from,
    /// Suspend the current generator frame and surface `acc` as
    /// the yielded value. The runtime saves `ip`, `acc`, env,
    /// `this`, `home_object`, and the register file into the
    /// frame's owning `JSGenerator`, then unwinds the dispatch
    /// loop with `RunResult.yielded`. On resume (next call to
    /// `gen.next(arg)`), `acc` is overwritten with `arg` so the
    /// expression `let x = yield e` reads the sent value.
    /// §27.5.3.7 GeneratorYield.
    gen_yield,
    /// Wait on the value in `acc` to settle, then resume with
    /// the resolved value (or throw the rejection). later
    /// implements this by tail-chaining `Promise.resolve(value)
    ///.then(resumeFn, rejectFn)` — the resumeFn captures the
    /// async function's saved frame state. §27.5.3.8 Await.
    await_,
    /// `[op]` — §7.4.1 GetIterator. Reads the iterable from acc;
    /// looks up its `@@iterator` method, calls it with the
    /// iterable as `this`, and writes the result into acc. If
    /// `@@iterator` is missing, synthesises an array-like
    /// iterator object that walks `length` + numeric-index
    /// access — matches the later for-of fallback so existing
    /// arrays / strings still iterate. Throws `TypeError` if
    /// `@@iterator` exists but isn't callable, or if its return
    /// value isn't an object. Used by for-of, array spread, and
    /// iterable destructuring.
    iter_open,
    /// `[op]` — §27.1.4.3 GetIterator(acc, async). Prefers
    /// `@@asyncIterator`; on absence falls back to the sync
    /// `@@iterator` (the surrounding for-await-of step `await`s
    /// each `next()` result, so a sync iter still composes).
    /// Result lands in `acc`.
    async_iter_open,
    /// `[op] [r_iter:u8] [r_done:u8]` — §7.4.4 IteratorStep on an
    /// iterator opened by `iter_open` (or any spec-shaped iterator
    /// in `r_iter`). If the iter is already marked done (via the
    /// internal `__cynic_iter_done__` slot), or `.next()` returns
    /// `{done: true}`, `acc` ends as `undefined` and the boolean
    /// in `r_done` is set to `true`. Otherwise `acc` holds the
    /// stepped `.value` and `r_done` is `false`. Reading `.done`
    /// and `.value` goes through accessor-aware property reads
    /// (§7.4.7 IteratorComplete / IteratorValue). Used by
    /// `[a, b, ...rest] = src` destructuring.
    iter_step,
    /// `[op]` — §14.7.5.6 EnumerateObjectProperties. Reads the
    /// object from acc, walks its own + inherited string-keyed
    /// properties (deduplicated), and produces an iterator that
    /// yields each name. `null` / `undefined` produce an empty
    /// iterator (per §14.7.5.6 ForIn/OfHeadEvaluation step 7).
    /// Symbol-keyed properties are excluded (§14.7.5.6 step 4).
    /// Used by `for-in`.
    for_in_open,
    /// `[op]` — discard the current frame's innermost
    /// environment, restoring its parent. Used by closure-per-
    /// iteration `for (let x of …)` (§14.7.5.6
    /// CreatePerIterationEnvironment): the loop body opens a
    /// fresh `make_environment 1` at each iteration's start
    /// and pops it at the end so the next iteration parents to
    /// the same outer env. Closures captured inside the body
    /// keep their reference to the popped env — the GC walks
    /// them through `JSFunction.captured_env`.
    pop_env,
    /// `[op] [k:u16]` — §16.2.1.5 module load. The constant at
    /// `k` holds the import specifier string. The runtime asks
    /// `realm.module_loader` to resolve the specifier against
    /// the executing chunk's `base_url`, parses + compiles +
    /// runs the loaded module if not cached, and writes the
    /// module's exports namespace object into acc. Subsequent
    /// `lda_property` ops read individual named imports off
    /// that namespace. Throws `TypeError` when the loader is
    /// unset or `error.ModuleNotFound` / similar from the
    /// loader itself.
    module_load,
    /// `[op] [k:u16]` — publish acc as an export named `k` on
    /// the executing module's namespace
    /// (`realm.current_module.exports`). No-op outside module
    /// context. The compiler emits this for every `export`
    /// declaration so the import side picks up the value once
    /// the body finishes evaluating.
    module_export,

    // ── Globals ─────────────────────────────────────────────────
    /// `[op] [k:u16]` — load a global by name. The name is the
    /// `JSString` at `Chunk.constants[k]`; the value comes from
    /// `Realm.globals` (host-installed bindings like `print`,
    /// `console`, `globalThis`, plus user-declared top-level
    /// bindings as of later). Throws `ReferenceError` on miss.
    /// `let` / `const` reads emit a follow-up `throw_if_hole`
    /// for §13.3.1 TDZ; that's how the global-env declarative
    /// vs property semantics is approximated.
    lda_global,
    /// `[op] [k:u16]` — like `lda_global`, but produce
    /// `undefined` instead of raising `ReferenceError` when the
    /// global isn't present. Used to compile `typeof Identifier`
    /// where `Identifier` isn't a known binding (§13.5.3 step 3:
    /// an unresolvable Reference yields the string "undefined"
    /// rather than throwing).
    lda_global_or_undef,
    /// `[op] [k:u16]` — store acc into the realm's globals map
    /// under the name held in `Chunk.constants[k]` (a `JSString`).
    /// Creates the binding if it doesn't exist. Used by
    /// top-level `var x = e`, `let x = e`, and function-decl
    /// hoist. Inner-scope assignments still go through
    /// `sta_env`.
    sta_global,

    // ── Objects / properties ────────────────────────────────────
    /// Allocate a fresh empty `JSObject` whose `[[Prototype]]` is
    /// `%Object.prototype%` (or `null` if the realm hasn't
    /// installed builtins). Result lands in acc. Object-literal
    /// compilation emits this followed by a series of
    /// `sta_property` ops to populate the bag.
    make_object,
    /// Allocate a fresh empty `JSObject` whose `[[Prototype]]` is
    /// `%Array.prototype%`. Cynic doesn't have a true `JSArray`
    /// kind yet — array literals desugar to a plain object with
    /// stringified-index keys and a `.length` slot, but the
    /// prototype is wired correctly so `arr.push(...)` etc.
    /// dispatch through `Array.prototype`. (later: a real
    /// `JSArray` heap kind for fast indexed access.)
    make_array,
    /// `[op] [r_arr:u8]` — append every own indexed element of
    /// `acc` (the source iterable) to the array in `r_arr`,
    /// updating `r_arr.length`. §13.2.4 SpreadElement lowering.
    /// later treats any object with a numeric `.length` as
    /// spreadable; full Symbol.iterator dispatch is later.
    array_spread,
    /// `[op] [r_obj:u8]` — §13.2.5.5 / §7.3.26 CopyDataProperties.
    /// Read `acc` as the source. `null` / `undefined` are no-ops.
    /// Otherwise walk the source's own enumerable string and
    /// symbol keys (skipping the engine's `__cynic_*` slots),
    /// reading each via the regular property dispatch path
    /// (getters fire), and `[[Set]]` the result into the target
    /// in `r_obj`. Drives `{ ...src, k: v }` object-literal spread.
    object_spread,
    /// `[op] [k:u16]` — load property whose name is `JSString` at
    /// `Chunk.constants[k]` from the object currently in acc.
    /// Walks the prototype chain; missing keys yield `undefined`
    /// (§10.1.8). Throws if the receiver isn't object-typed —
    /// runtime check, like every other dynamic dispatch.
    lda_property,
    /// `[op] [k:u16] [r_obj:u8]` — store acc into property `k` of
    /// the object held in register `r_obj`. The compiler arranges
    /// for `obj.x = v` to leave `obj` in `r_obj` and `v` in acc.
    sta_property,
    /// `[op] [r_obj:u8]` — `acc = obj[acc]` (computed property
    /// read). Coerces the key to a string at runtime; non-string
    /// keys go through ToPropertyKey (§7.1.19). Walks the
    /// prototype chain like `lda_property`.
    lda_computed,
    /// `[op] [r_obj:u8] [r_key:u8]` — `obj[key] = acc` (computed
    /// property write). Stores acc; the result of the expression
    /// is the assigned value (still in acc).
    sta_computed,
    /// `[op] [k:u16] [r_obj:u8]` — `delete obj.x` (named delete).
    /// §13.5.1.2 — removes the own property whose key is the
    /// `JSString` at `Chunk.constants[k]` from the object in
    /// `r_obj`. Sets `acc` to `true` on success (or when the
    /// property didn't exist), or throws TypeError when the
    /// property is non-configurable (strict-only path; Cynic is
    /// always strict). Throws TypeError when the receiver isn't
    /// object-typed (§7.1.18 ToObject prep).
    del_named_property,
    /// `[op] [r_obj:u8] [r_key:u8]` — `delete obj[key]` (computed
    /// delete). Same semantics as `del_named_property` with the
    /// key coerced from `r_key` via §7.1.19 ToPropertyKey.
    del_computed_property,

    // ── Environments / closures ─────────────────────────────────
    /// `[op] [slot_count:u8]` — allocate a fresh `Environment`
    /// chained to the current frame's env (or null if none),
    /// with `slot_count` slots all initialised to the TDZ Hole.
    /// Sets `frame.env` to the new env. Emitted at function /
    /// script entry when the body has any named bindings.
    make_environment,
    /// `[op] [depth:u8] [slot:u8]` — load `frame.env^depth.slots[slot]`
    /// into acc. depth=0 reads the current scope's env directly.
    /// Walks the parent chain `depth` times; the compiler
    /// guarantees the chain is long enough.
    lda_env,
    /// `[op] [depth:u8] [slot:u8]` — store acc into
    /// `frame.env^depth.slots[slot]`.
    sta_env,

    // ── Exceptions ───────────────────────────────────────────────────────
    /// Raise `acc` as a thrown value. The interpreter walks the
    /// chunk's exception-handler table to find the catch site;
    /// uncaught exceptions terminate the program. §14.14.
    throw_,
    /// If `acc` is the Hole sentinel, raise a `ReferenceError` —
    /// runtime check for §13.3.1 TDZ. Otherwise no-op. Emitted
    /// after `Ldar` of any `let` / `const` slot.
    throw_if_hole,
    /// §7.1.22 RequireObjectCoercible — if `acc` is null or
    /// undefined, raise a `TypeError`. Otherwise no-op. Emitted
    /// at the head of object destructuring (`const {…} = v`,
    /// `({…} = v)`) before any property reads, so `const {} = null`
    /// throws as the spec requires.
    require_object_coercible,

    // ── Termination ──────────────────────────────────────────────────────
    /// Halt with `acc` as the program's value. Top-level only in
    /// later; later distinguishes return-from-function.
    return_,

    /// Total number of bytes the operand of `op` occupies (not
    /// counting the opcode byte itself). Drives the disassembler
    /// and the interpreter's instruction-pointer advance.
    pub fn operandSize(op: Op) u8 {
        return switch (op) {
            .lda_undefined,
            .lda_null,
            .lda_true,
            .lda_false,
            .lda_hole,
            .lda_this,
            .make_object,
            .make_array,
            .super_call_forward,
            .init_instance_fields,
            .lda_arguments,
            .gen_yield,
            .await_,
            .iter_open,
            .async_iter_open,
            .for_in_open,
            .pop_env,
            .negate,
            .bit_not,
            .logical_not,
            .to_number,
            .typeof_,
            .throw_,
            .throw_if_hole,
            .require_object_coercible,
            .return_,
            .super_get_computed,
            => 0,
            .ldar,
            .star,
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .pow,
            .bit_and,
            .bit_or,
            .bit_xor,
            .shl,
            .shr,
            .shr_u,
            .eq,
            .strict_eq,
            .neq,
            .strict_neq,
            .lt,
            .gt,
            .le,
            .ge,
            .instanceof_,
            .in_op,
            .iter_close,
            .array_spread,
            .object_spread,
            .set_proto_literal,
            .set_home,
            .rest_args_from,
            => 1, // single u8 register operand
            .set_fn_name_from => 2, // r_key:u8 + prefix:u8
            .mov,
            .array_rest_from,
            .object_rest_from,
            .iter_step,
            => 2, // src:u8, dst:u8 (or r_src, start / r_excl, or r_iter, r_done)
            .lda_constant,
            .jmp,
            .jmp_if_false,
            .jmp_if_true,
            .jmp_if_nullish,
            .make_function,
            .make_class,
            .super_get,
            .lda_property,
            .lda_private,
            .lda_global,
            .lda_global_or_undef,
            .sta_global,
            .module_load,
            .module_export,
            => 2, // u16 / i16
            .call,
            .new_call,
            .super_call,
            .lda_env,
            .sta_env,
            => 2, // u8 + u8
            .sta_property, .sta_private => 3, // k:u16 + r_obj:u8
            .def_accessor => 4, // k:u16 + r_obj:u8 + is_setter:u8
            .def_computed_accessor => 3, // r_obj:u8 + r_key:u8 + is_setter:u8
            .lda_computed => 1, // r_obj:u8 (key in acc)
            .sta_computed => 2, // r_obj:u8 + r_key:u8
            .del_named_property => 3, // k:u16 + r_obj:u8
            .del_computed_property => 2, // r_obj:u8 + r_key:u8
            .call_method => 3, // r_recv:u8 + r_callee:u8 + argc:u8
            .make_environment => 1, // slot_count:u8
            .lda_smi => 4, // i32 immediate
        };
    }

    /// Stable mnemonic for the disassembler. The exact string is
    /// part of the golden-test contract — keep stable.
    pub fn mnemonic(op: Op) []const u8 {
        return switch (op) {
            .lda_undefined => "LdaUndefined",
            .lda_null => "LdaNull",
            .lda_true => "LdaTrue",
            .lda_false => "LdaFalse",
            .lda_smi => "LdaSmi",
            .lda_constant => "LdaConstant",
            .lda_hole => "LdaHole",
            .ldar => "Ldar",
            .star => "Star",
            .mov => "Mov",
            .add => "Add",
            .sub => "Sub",
            .mul => "Mul",
            .div => "Div",
            .mod => "Mod",
            .pow => "Pow",
            .bit_and => "BitAnd",
            .bit_or => "BitOr",
            .bit_xor => "BitXor",
            .shl => "Shl",
            .shr => "Shr",
            .shr_u => "ShrU",
            .negate => "Negate",
            .bit_not => "BitNot",
            .logical_not => "LogicalNot",
            .to_number => "ToNumber",
            .typeof_ => "TypeOf",
            .eq => "Eq",
            .strict_eq => "StrictEq",
            .neq => "Neq",
            .strict_neq => "StrictNeq",
            .lt => "Lt",
            .gt => "Gt",
            .le => "Le",
            .ge => "Ge",
            .jmp => "Jmp",
            .jmp_if_false => "JmpIfFalse",
            .jmp_if_true => "JmpIfTrue",
            .jmp_if_nullish => "JmpIfNullish",
            .make_function => "MakeFunction",
            .call => "Call",
            .call_method => "CallMethod",
            .new_call => "NewCall",
            .lda_this => "LdaThis",
            .instanceof_ => "InstanceOf",
            .in_op => "In",
            .iter_close => "IterClose",
            .array_rest_from => "ArrayRestFrom",
            .object_rest_from => "ObjectRestFrom",
            .make_class => "MakeClass",
            .super_get => "SuperGet",
            .super_get_computed => "SuperGetComputed",
            .super_call => "SuperCall",
            .super_call_forward => "SuperCallForward",
            .init_instance_fields => "InitInstanceFields",
            .lda_private => "LdaPrivate",
            .sta_private => "StaPrivate",
            .def_accessor => "DefAccessor",
            .def_computed_accessor => "DefComputedAccessor",
            .set_proto_literal => "SetProtoLiteral",
            .set_home => "SetHome",
            .set_fn_name_from => "SetFnNameFrom",
            .lda_arguments => "LdaArguments",
            .rest_args_from => "RestArgsFrom",
            .gen_yield => "GenYield",
            .await_ => "Await",
            .iter_open => "IterOpen",
            .async_iter_open => "AsyncIterOpen",
            .iter_step => "IterStep",
            .for_in_open => "ForInOpen",
            .pop_env => "PopEnv",
            .module_load => "ModuleLoad",
            .module_export => "ModuleExport",
            .make_environment => "MakeEnvironment",
            .lda_env => "LdaEnv",
            .sta_env => "StaEnv",
            .make_object => "MakeObject",
            .make_array => "MakeArray",
            .array_spread => "ArraySpread",
            .object_spread => "ObjectSpread",
            .lda_property => "LdaProperty",
            .sta_property => "StaProperty",
            .lda_computed => "LdaComputed",
            .sta_computed => "StaComputed",
            .del_named_property => "DelNamedProperty",
            .del_computed_property => "DelComputedProperty",
            .lda_global => "LdaGlobal",
            .lda_global_or_undef => "LdaGlobalOrUndef",
            .sta_global => "StaGlobal",
            .throw_ => "Throw",
            .throw_if_hole => "ThrowIfHole",
            .require_object_coercible => "RequireObjectCoercible",
            .return_ => "Return",
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Op: every variant has a stable mnemonic" {
    inline for (@typeInfo(Op).@"enum".fields) |f| {
        const op: Op = @field(Op, f.name);
        const mnem = op.mnemonic();
        try testing.expect(mnem.len > 0);
    }
}

test "Op: operandSize agrees with the documented encoding" {
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.lda_undefined));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.lda_hole));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.throw_));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.throw_if_hole));
    try testing.expectEqual(@as(u8, 0), Op.operandSize(.return_));
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.ldar));
    try testing.expectEqual(@as(u8, 1), Op.operandSize(.add));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.mov));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.lda_constant));
    try testing.expectEqual(@as(u8, 2), Op.operandSize(.jmp));
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_smi));
}
