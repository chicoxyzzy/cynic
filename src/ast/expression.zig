//! AST nodes for ECMA-262 §13 Expressions.
//!
//! All payloads carry a `Span`. Subexpressions are arena-allocated `*Expression`
//! pointers so the union itself stays a single tag + one inline payload.
//! Numeric/string/template literals store raw byte spans only — cooked-string
//! and StringNumericValue computation are deferred to runtime, matching V8 / JSC.

const std = @import("std");
const Span = @import("../source.zig").Span;
const TokenKind = @import("../lexer/token.zig").TokenKind;

pub const Expression = union(enum) {
    null_literal: SpanOnly,
    boolean_literal: BoolLit,
    numeric_literal: SpanOnly,
    bigint_literal: SpanOnly,
    string_literal: SpanOnly,
    template_literal: TemplateLit,
    identifier_reference: IdentRef,
    parenthesized: ParenExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    logical: LogicalExpr,
    conditional: CondExpr,
    assignment: AssignExpr,
    sequence: SequenceExpr,
    /// `obj.prop` / `obj[expr]` / `obj.#priv` / `obj?.prop` / etc. (§13.3).
    member: MemberExpr,
    /// `f(args)` / `obj.method(...)` / `f?.()` (§13.3).
    call: CallExpr,
    /// `new C(args)` / `new C` (no args) (§13.3).
    new_expr: NewExpr,
    /// Wraps the root of an optional chain so the runtime knows the
    /// short-circuit boundary (§13.3.10). Always wraps a single expression
    /// that contains at least one `.optional == true` member or call.
    chain: ChainExpr,
    /// `` tag`...` `` — tagged template (§13.3.11). The template stores
    /// quasi spans; cooking them is deferred to runtime.
    tagged_template: TaggedTemplateExpr,
    /// `...expr` — spread element. Only legal inside argument lists in this
    /// slice; array/object spread come with destructuring.
    spread: SpreadExpr,
    /// `++x` / `--x` (prefix) and `x++` / `x--` (postfix). §13.4.
    update: UpdateExpr,
    /// `function name?(params) { body }` — anonymous or named function
    /// expression. Distinct from `FunctionDecl` so the AST cleanly
    /// reflects the source's statement vs expression position.
    function_expr: FunctionExpr,
    /// `[a, b,...rest,, c]` — §13.2.4. Holes (elision) become `null`
    /// entries; spread elements stay as `Expression.spread`.
    array_literal: ArrayLit,
    /// `{ a: 1, b, [c]: 2,...rest }` — §13.2.5.
    object_literal: ObjectLit,
    /// `params => body` — §15.3 ArrowFunction. `body` is either an
    /// expression (concise body) or a block statement.
    arrow_function: ArrowFunction,
    /// `class Name? (extends Heritage)? { … }` — §15.7 ClassExpression.
    class_expr: ClassExpr,
    /// `this` (§13.2.1).
    this_expr: SpanOnly,
    /// `super` keyword (§13.3.7). Only meaningful as the prefix of a
    /// SuperProperty (`super.x`, `super[x]`) or SuperCall (`super(...)`)
    /// — the surrounding member/call extension is handled by the LHS
    /// loop. Context validity (must be inside a class method /
    /// constructor) is enforced at runtime, not the parser.
    super_: SpanOnly,
    /// `yield`, `yield expr`, `yield* expr` — §15.5.4. Only valid inside
    /// a generator function body. Always at AssignmentExpression level.
    yield: YieldExpr,
    /// `await expr` — §15.8.2. Only valid inside an async function body.
    /// At UnaryExpression level (binds tighter than yield).
    await_: AwaitExpr,
    /// `/regex/flags` (§12.9.5). Span covers the entire literal including
    /// flags. Parsing the body / validating flag set is deferred to the
    /// runtime's regex engine.
    regex_literal: SpanOnly,
    /// `import(specifier)` — dynamic import (§13.3.10). The argument is
    /// an AssignmentExpression, typically a string. Returns a Promise
    /// for the imported namespace at runtime. (Import attributes
    /// `import(s, { with:... })` are deferred.)
    import_call: ImportCallExpr,
    /// `import.meta` — MetaProperty (§13.3.12.1). Only valid inside a
    /// module; references the module's metadata object at runtime.
    import_meta: SpanOnly,
    /// `new.target` — MetaProperty (§13.3.1). Only valid inside a
    /// function/method body (not arrow); references the constructor
    /// invoked via `new` when the enclosing function is being
    /// constructed, or `undefined` otherwise.
    new_target: SpanOnly,

    pub fn span(self: Expression) Span {
        return switch (self) {
            inline else => |payload| payload.span,
        };
    }
};

pub const SpanOnly = struct { span: Span };

pub const BoolLit = struct { span: Span, value: bool };

/// A template literal — `` `head${ e1 }middle${ e2 }tail` ``.
/// `quasis.len == expressions.len + 1`. Each quasi is a span over the raw
/// template text between (or around) substitutions; the parser does not
/// cook them yet.
pub const TemplateLit = struct {
    span: Span,
    quasis: []TemplateQuasi,
    expressions: []Expression,
};

pub const TemplateQuasi = struct {
    /// Span over the *contents* of the quasi, excluding the surrounding
    /// `` ` ``, `${`, or `}`. Empty quasi has start == end.
    span: Span,
};

pub const IdentRef = struct { span: Span };

pub const ParenExpr = struct {
    span: Span,
    expression: *Expression,
};

pub const UnaryExpr = struct {
    span: Span,
    op: UnaryOp,
    operand: *Expression,
};

pub const BinaryExpr = struct {
    span: Span,
    op: BinaryOp,
    lhs: *Expression,
    rhs: *Expression,
};

pub const LogicalExpr = struct {
    span: Span,
    op: LogicalOp,
    lhs: *Expression,
    rhs: *Expression,
};

pub const CondExpr = struct {
    span: Span,
    test_: *Expression,
    consequent: *Expression,
    alternate: *Expression,
};

pub const AssignExpr = struct {
    span: Span,
    op: AssignmentOp,
    target: *Expression,
    value: *Expression,
};

pub const SequenceExpr = struct {
    span: Span,
    expressions: []Expression,
};

pub const MemberExpr = struct {
    span: Span,
    object: *Expression,
    property: Property,
    /// `?.` / `?.[` / `?.(` form. Always false on `MemberExpression`s
    /// produced from `.ident` / `[expr]` / `()` directly; set true only
    /// when the spec's `OptionalChain` non-terminal applies.
    optional: bool,

    pub const Property = union(enum) {
        /// `.IdentName` or `.#PrivateIdent`. Span covers the identifier
        /// (without the leading `.`); the `#` is included for private.
        ident: Span,
        /// `[ Expression ]`.
        computed: *Expression,
    };
};

pub const CallExpr = struct {
    span: Span,
    callee: *Expression,
    arguments: []Expression,
    optional: bool,
};

pub const NewExpr = struct {
    span: Span,
    callee: *Expression,
    arguments: []Expression,
};

pub const ChainExpr = struct {
    span: Span,
    expression: *Expression,
};

pub const TaggedTemplateExpr = struct {
    span: Span,
    tag: *Expression,
    quasi: *Expression, // always a TemplateLit
};

pub const SpreadExpr = struct {
    span: Span,
    argument: *Expression,
};

pub const ArrayLit = struct {
    span: Span,
    /// `null` entries are elisions (`[1,, 3]` has 3 elements, the middle
    /// is `null`). Trailing commas do NOT add a trailing elision.
    elements: []?Expression,
};

pub const ObjectLit = struct {
    span: Span,
    properties: []ObjectMember,
};

pub const ObjectMember = union(enum) {
    property: ObjectProperty,
    /// `...expr` — object spread.
    spread: SpreadExpr,
    /// `method() { … }`, `get x() { … }`, `set x(v) { … }` — method
    /// definition shorthand inside an object literal (§13.2.5).
    method: ObjectMethod,
};

pub const ObjectMethod = struct {
    span: Span,
    kind: @import("statement.zig").MethodKind,
    key: PropertyKey,
    params: []@import("statement.zig").FunctionParam,
    body: @import("statement.zig").BlockStmt,
    is_generator: bool = false,
    is_async: bool = false,
};

pub const ObjectProperty = struct {
    span: Span,
    key: PropertyKey,
    value: Expression,
    /// `{ a }` is shorthand for `{ a: a }`. The key is `.ident` and value
    /// is an `identifier_reference` covering the same span.
    shorthand: bool,
};

pub const PropertyKey = union(enum) {
    /// `.ident: …` — IdentifierName key. Covers both `a:` and reserved
    /// words `if:`, `class:`, etc. (§12.7 IdentifierName position).
    ident: Span,
    /// `"x":` / `'x':`.
    string: Span,
    /// `0:` / `0.5:` — NumericLiteral key.
    numeric: Span,
    /// `[expr]:` — ComputedPropertyName.
    computed: *Expression,
    /// `#name` — PrivateIdentifier. Valid only in class member position.
    private: Span,
};

pub const ClassExpr = struct {
    span: Span,
    name: ?@import("statement.zig").BindingIdentifier,
    superclass: ?*Expression,
    body: []@import("statement.zig").ClassMember,
};

pub const YieldExpr = struct {
    span: Span,
    /// `yield` alone has no operand. `yield expr` and `yield* expr` do.
    argument: ?*Expression,
    /// `yield*` delegates to an inner iterable (§15.5.5).
    delegate: bool,
};

pub const AwaitExpr = struct {
    span: Span,
    argument: *Expression,
};

pub const ImportCallExpr = struct {
    span: Span,
    source: *Expression,
};

pub const ArrowFunction = struct {
    span: Span,
    params: []@import("statement.zig").FunctionParam,
    body: ArrowBody,
    is_async: bool = false,
};

pub const ArrowBody = union(enum) {
    /// `{... }` — function body block.
    block: @import("statement.zig").BlockStmt,
    /// Concise body — single AssignmentExpression. Pointer so the union
    /// stays cycle-safe.
    expression: *Expression,
};

pub const FunctionExpr = struct {
    span: Span,
    /// `function name() {}` — `name` is the optional binding for the
    /// expression's own scope (§15.2.4). `null` for anonymous expressions.
    name: ?@import("statement.zig").BindingIdentifier,
    params: []@import("statement.zig").FunctionParam,
    body: @import("statement.zig").BlockStmt,
    /// `function* name() {}` — generator function (§15.5).
    is_generator: bool = false,
    /// `async function name() {}` — async function (§15.8).
    is_async: bool = false,
};

pub const UpdateExpr = struct {
    span: Span,
    op: UpdateOp,
    operand: *Expression,
    prefix: bool,
};

pub const UpdateOp = enum {
    increment,
    decrement,

    pub fn fromToken(kind: TokenKind) ?UpdateOp {
        return switch (kind) {
            .plus_plus => .increment,
            .minus_minus => .decrement,
            else => null,
        };
    }

    pub fn lexeme(self: UpdateOp) []const u8 {
        return switch (self) {
            .increment => "++",
            .decrement => "--",
        };
    }
};

pub const UnaryOp = enum {
    bang,
    minus,
    plus,
    tilde,
    typeof_,
    void_,
    /// `delete` is parsed only to allow the strict-mode diagnostic
    /// `delete_of_unqualified_identifier`. The resulting node is dropped
    /// from accepted programs in this slice (it always errors), but the
    /// variant exists so recovery can produce a syntactically meaningful
    /// AST.
    delete_,

    pub fn fromToken(kind: TokenKind) ?UnaryOp {
        return switch (kind) {
            .bang => .bang,
            .minus => .minus,
            .plus => .plus,
            .tilde => .tilde,
            .kw_typeof => .typeof_,
            .kw_void => .void_,
            .kw_delete => .delete_,
            else => null,
        };
    }

    pub fn lexeme(self: UnaryOp) []const u8 {
        return switch (self) {
            .bang => "!",
            .minus => "-",
            .plus => "+",
            .tilde => "~",
            .typeof_ => "typeof",
            .void_ => "void",
            .delete_ => "delete",
        };
    }
};

pub const BinaryOp = enum {
    // §13.6 Exponentiation
    star_star,
    // §13.7 Multiplicative
    star,
    slash,
    percent,
    // §13.8 Additive
    plus,
    minus,
    // §13.9 Shift
    lt_lt,
    gt_gt,
    gt_gt_gt,
    // §13.10 Relational
    lt,
    le,
    gt,
    ge,
    instanceof_,
    in_,
    // §13.11 Equality
    eq_eq,
    bang_eq,
    eq_eq_eq,
    bang_eq_eq,
    // §13.12 Bitwise
    amp,
    caret,
    pipe,

    pub fn fromToken(kind: TokenKind) ?BinaryOp {
        return switch (kind) {
            .star_star => .star_star,
            .star => .star,
            .slash => .slash,
            .percent => .percent,
            .plus => .plus,
            .minus => .minus,
            .lt_lt => .lt_lt,
            .gt_gt => .gt_gt,
            .gt_gt_gt => .gt_gt_gt,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .kw_instanceof => .instanceof_,
            .kw_in => .in_,
            .eq_eq => .eq_eq,
            .bang_eq => .bang_eq,
            .eq_eq_eq => .eq_eq_eq,
            .bang_eq_eq => .bang_eq_eq,
            .amp => .amp,
            .caret => .caret,
            .pipe => .pipe,
            else => null,
        };
    }

    pub fn lexeme(self: BinaryOp) []const u8 {
        return switch (self) {
            .star_star => "**",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .plus => "+",
            .minus => "-",
            .lt_lt => "<<",
            .gt_gt => ">>",
            .gt_gt_gt => ">>>",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .instanceof_ => "instanceof",
            .in_ => "in",
            .eq_eq => "==",
            .bang_eq => "!=",
            .eq_eq_eq => "===",
            .bang_eq_eq => "!==",
            .amp => "&",
            .caret => "^",
            .pipe => "|",
        };
    }
};

pub const LogicalOp = enum {
    and_and, // &&
    or_or, // ||
    nullish, // ??

    pub fn fromToken(kind: TokenKind) ?LogicalOp {
        return switch (kind) {
            .amp_amp => .and_and,
            .pipe_pipe => .or_or,
            .question_question => .nullish,
            else => null,
        };
    }

    pub fn lexeme(self: LogicalOp) []const u8 {
        return switch (self) {
            .and_and => "&&",
            .or_or => "||",
            .nullish => "??",
        };
    }
};

pub const AssignmentOp = enum {
    eq, // =
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    star_star_eq, // **=
    lt_lt_eq, // <<=
    gt_gt_eq, // >>=
    gt_gt_gt_eq, // >>>=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    amp_amp_eq, // &&=
    pipe_pipe_eq, // ||=
    question_question_eq, // ??=

    pub fn fromToken(kind: TokenKind) ?AssignmentOp {
        return switch (kind) {
            .eq => .eq,
            .plus_eq => .plus_eq,
            .minus_eq => .minus_eq,
            .star_eq => .star_eq,
            .slash_eq => .slash_eq,
            .percent_eq => .percent_eq,
            .star_star_eq => .star_star_eq,
            .lt_lt_eq => .lt_lt_eq,
            .gt_gt_eq => .gt_gt_eq,
            .gt_gt_gt_eq => .gt_gt_gt_eq,
            .amp_eq => .amp_eq,
            .pipe_eq => .pipe_eq,
            .caret_eq => .caret_eq,
            .amp_amp_eq => .amp_amp_eq,
            .pipe_pipe_eq => .pipe_pipe_eq,
            .question_question_eq => .question_question_eq,
            else => null,
        };
    }

    pub fn lexeme(self: AssignmentOp) []const u8 {
        return switch (self) {
            .eq => "=",
            .plus_eq => "+=",
            .minus_eq => "-=",
            .star_eq => "*=",
            .slash_eq => "/=",
            .percent_eq => "%=",
            .star_star_eq => "**=",
            .lt_lt_eq => "<<=",
            .gt_gt_eq => ">>=",
            .gt_gt_gt_eq => ">>>=",
            .amp_eq => "&=",
            .pipe_eq => "|=",
            .caret_eq => "^=",
            .amp_amp_eq => "&&=",
            .pipe_pipe_eq => "||=",
            .question_question_eq => "??=",
        };
    }
};
