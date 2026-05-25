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
    /// acc = +acc (ToNumber). §13.5.4. Rejects BigInt with
    /// TypeError (§7.1.4 ToNumber). Distinct from `to_numeric`,
    /// which accepts BigInt and is used by the `++` / `--` bump
    /// lowerings.
    to_number,
    /// acc = ToNumeric(acc). §7.1.4.1 — emitted by `++` / `--`
    /// to coerce the operand to a Number-or-BigInt primitive
    /// before the `inc` / `dec` bump runs. Unlike `to_number`,
    /// a BigInt operand passes through (so `0n++` doesn't
    /// TypeError on the coerce step).
    to_numeric,
    /// acc = ToString(acc). §7.1.17 — for an Object, runs
    /// §7.1.1 ToPrimitive with hint "string" which consults
    /// `Symbol.toPrimitive` / `toString` / `valueOf` in spec
    /// order. Symbol primitives throw TypeError. Used by the
    /// template-literal lowering so each substitution is
    /// coerced via the "string" hint per §13.2.8.6 step 7,
    /// not via the `+` operator's "default" hint (which
    /// would call `valueOf` first and surface a wrapped
    /// Symbol primitive that then crashes ToString).
    to_string,
    /// acc = acc + Type(acc)::unit (§13.4 PostfixExpression /
    /// PrefixUpdateExpression). The accumulator is assumed to
    /// already be ToNumeric-coerced; the bump dispatches on
    /// Number vs BigInt so the unit matches the operand's type.
    inc,
    /// acc = acc − Type(acc)::unit. Mirror of `inc`.
    dec,
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
    /// `[op] [r_counter:u8] [r_bound:u8] [o:i16]` — fused
    /// counter-loop bottom: `r_counter += 1`, then branch back to
    /// the body when `r_counter < r_bound`. Fuses the seven-opcode
    /// canonical-for-loop tail (`lda_smi 1; add r_c; star r_c; ldar
    /// r_c; lt r_b; jmp_if_true`) into one dispatch. Emitted by the
    /// compiler for `for (let i = INT; i < BOUND; i++) BODY` when
    /// the body doesn't reassign or close over `i`. Hermes calls
    /// this `JLessNLong`; V8 Ignition has a `Jump…IncIfTrue` family.
    ///
    /// Fast path: both operands int32, no overflow → int32 inc +
    /// int32 compare. Slow path: routes through `arith.incOrDec`
    /// (ToNumeric → bump, BigInt-tolerant) and `relational(.lt,
    /// …)` so the spec-observable behaviour is identical to the
    /// unfused sequence the compiler would have emitted. Acc is
    /// preserved across the opcode — the body's last expression
    /// value still surfaces to the for-statement's caller in
    /// REPL contexts.
    loop_inc_lt,

    // ── Functions / calls ─────────────────────────────────────────
    /// `[op] [k:u16]` — instantiate a `JSFunction` from
    /// `Chunk.function_templates[k]`, capturing the current
    /// frame's environment chain. The instance lands in the
    /// accumulator.
    make_function,
    /// `[op] [k:u16]` — §15.6.5 InstantiateOrdinaryFunctionExpression
    /// for a NAMED function expression. Allocates a single-slot
    /// declarative env wrapping the current frame's env, instantiates
    /// the function with that env as its `[[Environment]]`, then
    /// stores the function into the env's slot 0 (the self-name
    /// binding). The binding is immutable: writes from inside the
    /// body compile to `throw_assign_const` so user-visible writes
    /// throw a TypeError per §8.1.1.1.4 SetMutableBinding step 9.b.
    make_named_function_expr,
    /// `[op] [r_callee:u8] [argc:u8]` — invoke the function in
    /// register `r_callee` with `argc` arguments drawn from the
    /// consecutive registers `r_callee+1.. r_callee+argc`. The
    /// return value lands in the caller's accumulator after the
    /// callee's `Return`.
    call,
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8] [ic:u16]` — method
    /// call. Identical to `Call` except `this` is bound to the value
    /// in `r_recv` (§13.3.6 — `obj.method()` produces a Reference
    /// whose base is `obj`, so the call sees `this = obj`).
    /// Args are read from `r_callee + 1.. r_callee + argc`,
    /// matching `Call` so the compiler can share its argument-
    /// emission helper. The `ic` operand indexes
    /// `Chunk.inline_call_caches` — a hit on the cached callee
    /// pointer skips the proxy / revocable / bound / `valueAsFunction`
    /// dispatch chain and calls the function directly.
    call_method,
    /// `[op] [r_callee:u8] [argc:u8]` — `new f(args)` (§13.3.5).
    /// Allocates a fresh ordinary object whose `[[Prototype]]` is
    /// `f.prototype`, calls `f` with `this` bound to the new
    /// object, and yields either the constructor's return value
    /// (if it's an object) or the new object (otherwise).
    new_call,
    /// `[op] [r_callee:u8] [argc:u8]` — §15.10 PTC. Tail-call the
    /// function in register `r_callee` with `argc` arguments at
    /// `r_callee+1.. r_callee+argc`. Spec §14.6 PrepareForTailCall:
    /// the caller's frame is REUSED for the callee — no new
    /// dispatch frame is pushed, the caller's `Return` is skipped,
    /// and `function f(n) { return f(n - 1) }` recurses without
    /// stack growth. Falls back to ordinary `call` semantics
    /// (push + return) for proxies, bound functions, generators,
    /// async functions, and native callbacks — those cases either
    /// can't be flattened (the callee has its own frame allocation)
    /// or would require deeper reentrancy. Emitted by the compiler
    /// whenever (1) the call appears at a statically-detectable
    /// tail position per §15.10.1 IsInTailPosition (return
    /// expression, arrow concise body, conditional / logical /
    /// comma rhs in tail position), (2) the enclosing function is
    /// not a generator / async function, and (3) the call is not
    /// inside a try block whose catch or finally is in the same
    /// chunk.
    tail_call,
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8]` — §15.10 PTC,
    /// method-call variant. Identical to `tail_call` except
    /// `this` is bound to the value in `r_recv` (§13.3.6).
    /// No inline-cache slot — the saved tail-call frame would
    /// invalidate the cache layout that `call_method` relies on,
    /// and tail-recursive method calls are rare enough that the
    /// extra IC isn't load-bearing. Falls back to ordinary
    /// `call_method` for exotic callees, same as `tail_call`.
    tail_call_method,
    /// Load `this` from the current call frame into acc. Top-level
    /// `this` is `undefined` in strict mode (§10.2.1.2). Arrow
    /// functions inherit `this` from their captured frame; the
    /// compiler arranges for that by emitting `LdaThis` against
    /// the lexically enclosing frame's binding.
    lda_this,
    /// `[op]` — acc = new.target of the current frame.
    /// §13.3.12 NewTarget. Reads `f.new_target`, which is set
    /// to the constructing function when the frame was entered
    /// via `new f(args)` and stays `undefined` for plain calls.
    lda_new_target,
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
    /// `[op] [k:u16] [r_keys_base:u8] [inner_class_slot:u8]` —
    /// instantiate a class from `Chunk.class_templates[k]`. The
    /// heritage value (for `class … extends X`) is read from the
    /// accumulator on entry (the compiler emits the heritage
    /// expression immediately before this op); when the template's
    /// `has_heritage` is false, the accumulator is ignored.
    /// `r_keys_base` is the first register of a contiguous block
    /// holding the `to_property_key`-coerced computed-key values,
    /// one per member with `computed_key_index >= 0`, in source
    /// order; `make_class` reads them out of the enclosing frame's
    /// register file. Templates without computed keys leave
    /// `r_keys_base` as a don't-care (typically `0`).
    /// `inner_class_slot` (§15.7.14 step 27.b) is the
    /// classScopeEnvRec slot index where the runtime publishes the
    /// freshly constructed constructor BEFORE static fields /
    /// static blocks run, so a static initializer referencing the
    /// class name sees the binding live instead of in TDZ.
    /// Sentinel `0xFF` for anonymous classes (no inner env). The
    /// resulting class constructor lands in `acc`. §15.7.14
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
    /// `[op] [k:u16] [r_value:u8]` — `super.<key> = registers[r_value]`.
    /// Walks `home.[[Prototype]]` to find a setter (or data
    /// property to override); calls the setter with `this` from
    /// the current frame. The new value lands in `acc` (so the
    /// surrounding assignment expression evaluates to it).
    /// §13.3.7.
    super_set,
    /// `[op] [r_key:u8] [r_value:u8]` — `super[r_key] = r_value`.
    /// Same shape as `super_set` but the key is computed at
    /// runtime.
    super_set_computed,
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
    /// `[op] [r_args_array:u8]` — `super(...spread)` form. The
    /// args list comes from a runtime-built Array at
    /// `registers[r_args_array]`; the parent constructor runs
    /// with `this` from the current frame and one positional
    /// arg per `arr[i]` for `i` in `[0, arr.length)`. The
    /// returned `this` lands in `acc`.
    super_call_spread,
    /// `[op]` — precondition guard for `super[expr]` / `super[expr] =
    /// v` / `super[expr]++` / `super[expr] op= v` in derived
    /// constructors. §13.3.7.1 SuperProperty evaluation step 2
    /// (`actualThis = ? env.GetThisBinding()`) runs *before*
    /// Expression evaluation; in a derived ctor before `super(...)`
    /// `this` is uninitialized and §9.1.1.3.4 throws ReferenceError.
    /// The compiler emits this op before evaluating the bracket
    /// expression so the throw is observed in the spec'd order
    /// (the inner expression doesn't run). A no-op outside derived
    /// ctor frames and after super has been called.
    super_check_this,
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
    /// `[op] [k:u16]` — `acc = (#name in acc)` for the private
    /// name at constant index `k`. §13.10.2 `PrivateIdentifier in
    /// ShiftExpression`: if Type(rval) is not Object, throw a
    /// TypeError; otherwise return Boolean indicating whether the
    /// private slot is present (field, method, or accessor).
    /// Unlike `lda_private`, a brand-check miss is **not** an
    /// error — it returns `false`. The class-fields-private-in
    /// proposal (stage 4) defines this; Cynic's `#x in y`
    /// fixtures rely on it.
    private_in,
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
    /// Like `gen_yield`, but the value in `acc` is already a
    /// spec-shaped IteratorResult object and must be returned
    /// from the outer `.next()` / `.return()` / `.throw()`
    /// unchanged — no fresh `CreateIterResultObject` wrap.
    /// Emitted by sync `yield*` per §15.5.5 step 7.a.iv — the
    /// inner iterator's result is yielded through verbatim so
    /// observers see `done` exactly as the inner produced it
    /// (e.g. `done: undefined` propagates instead of being
    /// coerced to `false`), and `value` is not eagerly read.
    gen_yield_iter_result,
    /// Initial suspension marker emitted between the param
    /// prologue and the body of every `function*` / `async function*`.
    /// `wrapGenerator` / `wrapAsyncGenerator` drive the chunk
    /// synchronously from PC=0 — so the param destructuring,
    /// defaults, and RequireObjectCoercible run at call time per
    /// §10.2.1.4 FunctionDeclarationInstantiation — until they hit
    /// this opcode, which saves frame state into the generator and
    /// unwinds via `RunResult.yielded`. The wrapper is returned to
    /// the caller; the first `.next(arg)` resumes from after this
    /// op, with `acc` overwritten by `arg`.
    gen_initial_suspend,
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
    /// typed `iter_record` slot), or `.next()` returns
    /// `{done: true}`, `acc` ends as `undefined` and the boolean
    /// in `r_done` is set to `true`. Otherwise `acc` holds the
    /// stepped `.value` and `r_done` is `false`. Reading `.done`
    /// and `.value` goes through accessor-aware property reads
    /// (§7.4.7 IteratorComplete / IteratorValue). Used by
    /// `[a, b, ...rest] = src` destructuring.
    iter_step,
    /// `[op] [r_iter:u8] [r_next:u8] [r_done:u8]` — one plain
    /// `for-of` step. Calls the iterator's `[[NextMethod]]`
    /// (cached in `r_next` at loop entry, §7.4.5 GetIteratorDirect)
    /// on the iterator in `r_iter`, then folds §7.4.2 IteratorNext
    /// step 4 (result-not-object → TypeError) and §7.4.8
    /// IteratorStepValue's `.done` / `.value` reads into the same
    /// op: the stepped value lands in `acc`, the boolean `done` in
    /// `r_done`. When `r_iter` is the unmodified built-in Array
    /// iterator (chains to `%ArrayIteratorPrototype%`, `r_next`
    /// still the original `next` native) a fast path steps the
    /// backing storage directly and skips the per-step
    /// CreateIterResultObject allocation. Emitted only for plain
    /// sync `for-of`; `for-await-of` and `for-in` keep the
    /// open-coded `call_method` + `lda_property` sequence.
    for_of_next,
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
    /// `[op]` — §13.3.10 dynamic `import(specifier)`. Reads the
    /// specifier from `acc` (ToString'd at the call site), calls
    /// the module loader synchronously, and writes the resulting
    /// Promise into `acc`. The Promise is settled before the
    /// opcode returns (loader is synchronous), but observation
    /// still goes through the microtask queue — `.then(...)` /
    /// `await` reactions are queued like any other Promise
    /// reaction. TypeError on missing loader / failed load
    /// becomes a rejected Promise; the call itself never throws.
    dynamic_import,
    /// `[op]` — §16.2.1.7 ImportMeta runtime semantics. Lazy-
    /// initialise `realm.current_module.import_meta` (an
    /// ordinary object with `[[Prototype]] = %Object.prototype%`)
    /// on first read, then return the cached object in `acc`.
    /// Every subsequent evaluation in the same module returns
    /// the same object (test262
    /// `language/expressions/import.meta/same-object-returned.js`,
    /// `distinct-for-each-module.js`). The parser guarantees this
    /// opcode is only emitted inside a Module goal, so
    /// `realm.current_module` is always set when it runs;
    /// defensive check throws a SyntaxError-class TypeError if
    /// it isn't (should be unreachable in practice).
    import_meta,
    /// `[op] [k:u16]` — publish acc as an export named `k` on
    /// the executing module's namespace
    /// (`realm.current_module.exports`). No-op outside module
    /// context. The compiler emits this for every `export`
    /// declaration so the import side picks up the value once
    /// the body finishes evaluating.
    module_export,
    /// `[op]` — §16.2.1.5 InnerModuleEvaluation link-complete
    /// marker. Emitted by the compiler after the hoisted import
    /// block in `compileModuleAsChunk` (only when the module
    /// declared at least one import). Drains the microtask queue
    /// so any async dependency whose body suspended at a top-level
    /// `await` during its `module_load` gets a chance to settle
    /// before the importer's body proper begins. After draining,
    /// iterates the importer's `pending_async_deps` list and, if
    /// any dep's evaluation Promise rejected, unwinds with the
    /// rejection value (matching §16.2.1.9
    /// AsyncModuleExecutionRejected's parent-propagation). This
    /// is Cynic's lightweight stand-in for the full
    /// [[PendingAsyncDependencies]] + GatherAvailableAncestors
    /// dance: sibling sync deps still run during the import
    /// hoist (so a sync module that destructures `globalThis`
    /// captures values from before any async sibling resumes),
    /// and the importer's body runs only after every async dep
    /// settles. No-op outside module context.
    module_link_complete,
    /// `[op]` — §16.2.3.7 ExportDeclaration : `export * from
    /// "src"` (no namespace binding). Reads the source-module
    /// namespace from `acc` (left there by the immediately-preceding
    /// `module_load`) and merges every own string-keyed export
    /// EXCEPT `"default"` (§16.2.3.7 step 8 of GetExportedNames
    /// skips the default export when traversing star-export
    /// entries) onto the executing module's
    /// `realm.current_module.exports` namespace. Keys already
    /// present on the importer's namespace win (matches the
    /// ResolveExport precedence between local / indirect entries
    /// and star entries — a star entry never overwrites a binding
    /// the module already exports under the same name). The
    /// `@@toStringTag` slot installed by §28.3.5 is also skipped,
    /// since it's a Module Namespace brand property rather than
    /// an export.
    ///
    /// This is a value-copy at re-export-evaluation time. A
    /// fully-spec ResolveExport chain (§15.2.1.16.3 step 10)
    /// would resolve lazily through the source's bindings on
    /// every read; copying at body time is observably equivalent
    /// for the non-mutation case the corpus exercises (the
    /// fixtures only check `name in ns`, presence semantics).
    /// Hole sentinels (TDZ) are forwarded verbatim so the
    /// importer's `lda_property + throw_if_hole` sequence still
    /// raises the spec ReferenceError when the source binding
    /// hasn't initialised yet.
    module_reexport_star,
    /// `[op] [local_k:u16] [exported_k:u16]` — §16.2.3.7
    /// ExportDeclaration : `export { local as exported } from
    /// "src"`. Reads the source-module namespace from `acc`
    /// (left there by the immediately-preceding `module_load`),
    /// fetches the raw value under `constants[local_k]`
    /// **WITHOUT** the §9.4.6.7 GetBindingValue Hole-throw
    /// dispatch — Hole sentinels are forwarded verbatim into
    /// the importer's namespace under `constants[exported_k]`.
    /// That preserves spec semantics: an importer reading
    /// `exported` before the source-module body has run its
    /// declaration site gets the ReferenceError on the
    /// downstream `lda_property + throw_if_hole` sequence,
    /// not at re-export-evaluation time (which would throw
    /// the moment the FROM-side body ran, even if the importer
    /// never observes the binding).
    ///
    /// Distinct from a generic `lda_property` + `module_export`
    /// pair specifically because `lda_property` on a module
    /// namespace promotes Hole into a runtime ReferenceError
    /// per §9.4.6.7 — the wrong policy at re-export time.
    /// No-op outside module context.
    module_reexport_named,

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
    /// `[op] [k:u16] [r:u8]` — snapshot whether the binding
    /// named `Chunk.constants[k]` is currently present on the
    /// realm globals. Writes `true` into register `r` when the
    /// binding is *unresolved* (a later strict-mode PutValue
    /// would throw), `false` otherwise. Cynic is strict-only,
    /// so §13.15.2 step 1.a "Evaluation of the LHS produces a
    /// Reference Record { [[Base]]: unresolvable, … }" is
    /// captured *before* the RHS runs and consumed by
    /// `sta_global_strict` afterwards. Recording the snapshot
    /// in a register (rather than throwing eagerly) preserves
    /// the spec ordering — a side-effecting RHS that itself
    /// throws (e.g. `s = (new Number("a")).toFixed(Infinity)`
    /// raising RangeError) wins over the ReferenceError that
    /// PutValue would otherwise raise later.
    capture_unresolved_global,
    /// `[op] [k:u16] [r:u8]` — strict-mode store companion to
    /// `capture_unresolved_global`. If register `r` is truthy
    /// (the snapshot saw an unresolvable Reference) raise a
    /// ReferenceError on `Chunk.constants[k]` (§6.2.5.5 step
    /// 6); otherwise write `acc` into `realm.globals[name]`.
    /// Emitted in place of `sta_global` whenever the LHS of an
    /// assignment failed to resolve at compile time.
    sta_global_strict,
    /// `[op] [k:u16]` — initializer-only store for a top-level
    /// `let` / `const` / `class` binding. Writes `acc` into the
    /// realm's declarative env-record (§9.1.1.4 DeclarativeRecord)
    /// for the name held in `Chunk.constants[k]`. Bypasses the
    /// const-immutability check that `sta_global` applies — this
    /// IS the InitializeBinding step (§9.1.1.4 InitializeBinding /
    /// §13.3.1) that seeds the slot in the first place. Subsequent
    /// `sta_global` writes for the same name (re-assignment) still
    /// take the const-check path and throw TypeError when the
    /// binding is `const`.
    sta_global_init,
    /// `[op] [k:u16]` — store-and-stamp variant for top-level
    /// `function` declarations. §9.1.1.4.19
    /// CreateGlobalFunctionBinding: overwrites both the data
    /// slot AND the property flags on the global object with
    /// `{[[Writable]]:true, [[Enumerable]]:true,
    /// [[Configurable]]:false}`. Distinct from `sta_global`
    /// (which preserves existing flags) so a script like
    /// `Object.defineProperty(this, "x", {configurable:true,
    /// value:0}); function x(){}` ends with `x`'s descriptor
    /// matching the function-decl shape rather than the prior
    /// `defineProperty` shape.
    sta_global_fn_decl,
    /// `[op] [slot:u32]` — slot-indexed load of a top-level
    /// `let` / `const` / `class` binding. The runtime index is
    /// `chunk.global_lexical_base + slot`; the value is read by
    /// a bounds-checked array index into the declarative env-
    /// record's `decl_env.values()` — no name hash, no map
    /// lookup. The compiler emits this in place of `lda_global`
    /// only when the resolved binding is provably a global
    /// lexical with an assigned slot.
    ///
    /// Soundness: Cynic ships no `eval` / `Function(string)`, so
    /// the full set of global-lexical bindings is statically
    /// known at compile time — no runtime guard / ResolveType is
    /// needed before the index. This is the perf dividend of the
    /// SES no-dynamic-code stance.
    ///
    /// TDZ (§13.3.1): the slot holds the Hole until init; this
    /// op loads whatever is there and the compiler emits a
    /// following `throw_if_hole`, exactly as `lda_global` does.
    lda_global_slot,
    /// `[op] [slot:u32]` — slot-indexed non-init store to a
    /// top-level `let` / `const` binding. Runtime index is
    /// `chunk.global_lexical_base + slot`. If the slot holds the
    /// Hole → §13.3.1 ReferenceError; else if the binding is
    /// `const` (checked via `decl_consts.values()[idx]`) →
    /// §13.15.2 TypeError; else write `acc` into the slot.
    sta_global_slot,
    /// `[op] [slot:u32]` — slot-indexed initializer store for a
    /// top-level `let` / `const` / `class` binding. Runtime
    /// index is `chunk.global_lexical_base + slot`. Writes `acc`
    /// into the slot unconditionally (fills the TDZ Hole); no
    /// const check — this IS §9.1.1.4 InitializeBinding.
    sta_global_slot_init,

    // ── Objects / properties ────────────────────────────────────
    /// Allocate a fresh empty `JSObject` whose `[[Prototype]]` is
    /// `%Object.prototype%` (or `null` if the realm hasn't
    /// installed builtins). Result lands in acc. Object-literal
    /// compilation emits this followed by a series of
    /// `sta_property` ops to populate the bag.
    make_object,
    /// `[op] [k:u16]` — allocate a fresh `JSObject` with
    /// `[[Prototype]] = %Object.prototype%` AND stamp the literal
    /// shape from `Chunk.literal_shape_templates[k]` onto the
    /// receiver, pre-sizing `slots`. Used by object literals whose
    /// keys are all static identifiers (no computed keys, no
    /// methods, no spread, no `__proto__`, no shorthand
    /// getter/setter). The downstream `def_property` opcodes then
    /// take `shadowSet`'s same-attrs-update fast path on every
    /// iteration of a literal-allocating hot loop instead of
    /// re-walking the shape transition tree per key.
    make_object_shape,
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
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]` — store acc into property
    /// `k` of the object held in register `r_obj`. The compiler
    /// arranges for `obj.x = v` to leave `obj` in `r_obj` and `v`
    /// in acc. `ic` indexes the chunk's `inline_caches` table; the
    /// interpreter's hit path is a shape pointer compare + a direct
    /// `slots[cell.slot] = v` (paired with a `properties` bag
    /// update). Misses fall through to `strictSetProperty`, which
    /// re-probes the shape and refills the cell on existing own-data
    /// writable keys.
    sta_property,
    /// `[op] [k:u16] [r_obj:u8]` — §7.3.7 CreateDataPropertyOrThrow.
    /// Define an own data property on `r_obj` with the key `JSString`
    /// at `Chunk.constants[k]` and the value in `acc`, all attributes
    /// `{writable, enumerable, configurable} = true`. Does NOT walk
    /// the prototype chain (so inherited accessors don't fire) and
    /// does NOT respect `writable: false` on an existing slot. Throws
    /// TypeError if the receiver is non-extensible and the key isn't
    /// already own, or if an existing own slot is non-configurable.
    /// Drives ArrayLiteral element init (§13.2.4) and ObjectLiteral
    /// PropertyDefinitionEvaluation (§13.2.5).
    def_property,
    /// `[op] [r_obj:u8]` — `acc = obj[acc]` (computed property
    /// read). Coerces the key to a string at runtime; non-string
    /// keys go through ToPropertyKey (§7.1.19). Walks the
    /// prototype chain like `lda_property`.
    lda_computed,
    /// `[op] [r_obj:u8] [r_key:u8]` — `obj[key] = acc` (computed
    /// property write). Stores acc; the result of the expression
    /// is the assigned value (still in acc).
    sta_computed,
    /// `[op] [r_obj:u8] [r_key:u8]` — §7.3.7 CreateDataPropertyOrThrow
    /// with a computed key. The key is in `r_key` (already
    /// ToPropertyKey'd by the emitting compiler), the value in `acc`.
    /// Same semantics as `def_property` (own-data-prop, no proto
    /// walk). Drives ObjectLiteral `[expr]: value` definitions.
    def_computed,
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
    /// Unconditional `TypeError` — emitted at runtime assignment
    /// targets that are statically known to be immutable. The
    /// motivating case is `<imported> = ...` where the LHS resolves
    /// to an import binding: §8.1.1.5.5 CreateImportBinding records
    /// the binding as immutable, and §8.1.1.1.4 SetMutableBinding
    /// throws TypeError on an immutable target. `const x = 1; x =
    /// 2;` in strict mode is the same shape, but we report that as
    /// a compile-time `assignment_to_const` diagnostic so the
    /// opcode only fires for import-store paths the parser can't
    /// reject statically (e.g. via destructuring).
    throw_assign_const,
    /// If `acc` is not an Object (per §7.2.5 IsObject — Object or
    /// callable Function), raise a `TypeError`. Otherwise no-op.
    /// Emitted after each `await_` inside async `yield*` to enforce
    /// §27.6.3.7 step 7.b.iv ("If Type(innerResult) is not Object,
    /// throw a TypeError exception") — a manually implemented async
    /// iterator can return a primitive (e.g. `42`) from `.next()` /
    /// `.return()` / `.throw()`; the await fulfils with that
    /// primitive, and we then reject the outer step.
    throw_if_not_object,
    /// §7.1.19 ToPropertyKey applied to `acc`. Runs
    /// ToPrimitive(hint "string") and, for non-Symbol results,
    /// ToString. Emitted right after the key expression of a
    /// computed PropertyName so a user-defined `toString` /
    /// `[@@toPrimitive]` fires BEFORE the property value is
    /// evaluated (matching §13.2.5.5 step 4.a sequencing —
    /// PropertyKey resolution happens before the
    /// AssignmentExpression on the right-hand side).
    to_property_key,

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
            .lda_new_target,
            .make_object,
            .make_array,
            .super_call_forward,
            .init_instance_fields,
            .lda_arguments,
            .gen_yield,
            .gen_yield_iter_result,
            .gen_initial_suspend,
            .await_,
            .iter_open,
            .async_iter_open,
            .for_in_open,
            .pop_env,
            .negate,
            .bit_not,
            .logical_not,
            .to_number,
            .to_numeric,
            .to_string,
            .inc,
            .dec,
            .typeof_,
            .throw_,
            .throw_if_hole,
            .require_object_coercible,
            .throw_assign_const,
            .throw_if_not_object,
            .to_property_key,
            .return_,
            .super_get_computed,
            .super_check_this,
            .dynamic_import,
            .import_meta,
            .module_link_complete,
            .module_reexport_star,
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
            .super_call_spread,
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
            .iter_close,
            => 2, // src:u8, dst:u8 (or r_src, start / r_excl, or r_iter, r_done)
            // iter_close: r_iter:u8 + mode:u8 (0 = normal completion;
            //                                  1 = throw completion — swallow inner)
            .lda_constant,
            .jmp,
            .jmp_if_false,
            .jmp_if_true,
            .jmp_if_nullish,
            .make_function,
            .make_named_function_expr,
            .make_object_shape,
            .super_get,
            .lda_private,
            .private_in,
            .lda_global,
            .lda_global_or_undef,
            .sta_global,
            .sta_global_init,
            .sta_global_fn_decl,
            .module_load,
            .module_export,
            => 2, // u16 / i16
            .module_reexport_named => 4, // local_k:u16 + exported_k:u16
            .capture_unresolved_global,
            .sta_global_strict,
            => 3, // k:u16 + r:u8
            .make_class => 4, // k:u16 + r_keys_base:u8 + inner_class_slot:u8
            .call,
            .new_call,
            .super_call,
            .tail_call,
            .lda_env,
            .sta_env,
            => 2, // u8 + u8
            .tail_call_method => 3, // r_recv:u8 + r_callee:u8 + argc:u8
            .sta_private, .super_set, .def_property => 3, // k:u16 + r_obj:u8
            .sta_property => 5, // k:u16 + r_obj:u8 + ic:u16 (inline-cache slot)
            .def_accessor => 4, // k:u16 + r_obj:u8 + is_setter:u8
            .def_computed_accessor => 3, // r_obj:u8 + r_key:u8 + is_setter:u8
            .lda_computed => 1, // r_obj:u8 (key in acc)
            .sta_computed, .super_set_computed, .def_computed => 2, // r_obj:u8 + r_key:u8
            .del_named_property => 3, // k:u16 + r_obj:u8
            .del_computed_property => 2, // r_obj:u8 + r_key:u8
            .call_method => 5, // r_recv:u8 + r_callee:u8 + argc:u8 + ic:u16
            .for_of_next => 3, // r_iter:u8 + r_next:u8 + r_done:u8
            .loop_inc_lt => 4, // r_counter:u8 + r_bound:u8 + offset:i16
            .make_environment => 1, // slot_count:u8
            .lda_smi => 4, // i32 immediate
            .lda_property => 4, // k:u16 + ic:u16 (inline-cache slot)
            .lda_global_slot,
            .sta_global_slot,
            .sta_global_slot_init,
            => 4, // slot:u32
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
            .to_numeric => "ToNumeric",
            .to_string => "ToString",
            .inc => "Inc",
            .dec => "Dec",
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
            .loop_inc_lt => "LoopIncLt",
            .make_function => "MakeFunction",
            .make_named_function_expr => "MakeNamedFunctionExpr",
            .call => "Call",
            .call_method => "CallMethod",
            .new_call => "NewCall",
            .tail_call => "TailCall",
            .tail_call_method => "TailCallMethod",
            .lda_this => "LdaThis",
            .lda_new_target => "LdaNewTarget",
            .instanceof_ => "InstanceOf",
            .in_op => "In",
            .iter_close => "IterClose",
            .array_rest_from => "ArrayRestFrom",
            .object_rest_from => "ObjectRestFrom",
            .make_class => "MakeClass",
            .super_get => "SuperGet",
            .super_get_computed => "SuperGetComputed",
            .super_call => "SuperCall",
            .super_call_spread => "SuperCallSpread",
            .super_set => "SuperSet",
            .super_set_computed => "SuperSetComputed",
            .super_call_forward => "SuperCallForward",
            .super_check_this => "SuperCheckThis",
            .init_instance_fields => "InitInstanceFields",
            .lda_private => "LdaPrivate",
            .sta_private => "StaPrivate",
            .private_in => "PrivateIn",
            .def_accessor => "DefAccessor",
            .def_computed_accessor => "DefComputedAccessor",
            .set_proto_literal => "SetProtoLiteral",
            .set_home => "SetHome",
            .set_fn_name_from => "SetFnNameFrom",
            .lda_arguments => "LdaArguments",
            .rest_args_from => "RestArgsFrom",
            .gen_yield => "GenYield",
            .gen_yield_iter_result => "GenYieldIterResult",
            .gen_initial_suspend => "GenInitialSuspend",
            .await_ => "Await",
            .iter_open => "IterOpen",
            .async_iter_open => "AsyncIterOpen",
            .iter_step => "IterStep",
            .for_of_next => "ForOfNext",
            .for_in_open => "ForInOpen",
            .pop_env => "PopEnv",
            .module_load => "ModuleLoad",
            .dynamic_import => "DynamicImport",
            .import_meta => "ImportMeta",
            .module_export => "ModuleExport",
            .module_link_complete => "ModuleLinkComplete",
            .module_reexport_star => "ModuleReexportStar",
            .module_reexport_named => "ModuleReexportNamed",
            .make_environment => "MakeEnvironment",
            .lda_env => "LdaEnv",
            .sta_env => "StaEnv",
            .make_object => "MakeObject",
            .make_object_shape => "MakeObjectShape",
            .make_array => "MakeArray",
            .array_spread => "ArraySpread",
            .object_spread => "ObjectSpread",
            .lda_property => "LdaProperty",
            .sta_property => "StaProperty",
            .def_property => "DefProperty",
            .lda_computed => "LdaComputed",
            .sta_computed => "StaComputed",
            .def_computed => "DefComputed",
            .del_named_property => "DelNamedProperty",
            .del_computed_property => "DelComputedProperty",
            .lda_global => "LdaGlobal",
            .lda_global_or_undef => "LdaGlobalOrUndef",
            .sta_global => "StaGlobal",
            .sta_global_init => "StaGlobalInit",
            .sta_global_fn_decl => "StaGlobalFnDecl",
            .lda_global_slot => "LdaGlobalSlot",
            .sta_global_slot => "StaGlobalSlot",
            .sta_global_slot_init => "StaGlobalSlotInit",
            .capture_unresolved_global => "CaptureUnresolvedGlobal",
            .sta_global_strict => "StaGlobalStrict",
            .throw_ => "Throw",
            .throw_if_hole => "ThrowIfHole",
            .require_object_coercible => "RequireObjectCoercible",
            .throw_assign_const => "ThrowAssignConst",
            .throw_if_not_object => "ThrowIfNotObject",
            .to_property_key => "ToPropertyKey",
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
    // `lda_property` is `[op] [k:u16] [ic:u16]` — 4 bytes of operand.
    // The IC operand was added with the monomorphic property cache;
    // a stale `operandSize` here would silently misalign the
    // disassembler's PC walk (the interpreter advances explicitly,
    // so unit-test failures stay hidden — playground/source-map
    // hover would be the user-visible signal).
    try testing.expectEqual(@as(u8, 4), Op.operandSize(.lda_property));
    // `sta_property` is `[op] [k:u16] [r_obj:u8] [ic:u16]` — 5 bytes
    // of operand. Same disassembler-PC-walk hazard as `lda_property`
    // if this gets out of sync with the encoding.
    try testing.expectEqual(@as(u8, 5), Op.operandSize(.sta_property));
}
