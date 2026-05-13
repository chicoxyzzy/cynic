//! AST nodes for ECMA-262 §14 Statements.

const Span = @import("../source.zig").Span;
const expr = @import("expression.zig");

pub const Statement = union(enum) {
    expression: ExprStmt,
    block: BlockStmt,
    empty: SpanOnly,
    lexical: LexicalDecl,
    if_: IfStmt,
    while_: WhileStmt,
    do_while: DoWhileStmt,
    return_: ReturnStmt,
    throw_: ThrowStmt,
    break_: BreakStmt,
    continue_: ContinueStmt,
    for_: ForStmt,
    for_in_of: ForInOfStmt,
    try_: TryStmt,
    switch_: SwitchStmt,
    debugger_: SpanOnly,
    labeled: LabeledStmt,
    function_decl: FunctionDecl,
    class_decl: ClassDecl,
    /// `import …` declaration (§16.2.2). Only valid in modules.
    import_decl: ImportDecl,
    /// `export …` declaration (§16.2.3). Only valid in modules.
    export_decl: ExportDecl,

    pub fn span(self: Statement) Span {
        return switch (self) {
            inline else => |payload| payload.span,
        };
    }
};

pub const SpanOnly = struct { span: Span };

pub const ExprStmt = struct {
    span: Span,
    expression: expr.Expression,
    /// When this ExpressionStatement is part of a §11.10 / §16.1.1
    /// Directive Prologue and consists solely of a StringLiteral, this
    /// is the span over the literal's *content* (between quotes). `null`
    /// otherwise. The only standard directive is `"use strict"`; Cynic
    /// is strict-only so directives are accepted as no-ops.
    directive: ?Span = null,
};

pub const BlockStmt = struct {
    span: Span,
    body: []Statement,
};

/// §14.3 LexicalDeclaration (`let` / `const`) and §14.3.2
/// VariableStatement (`var`). Identical AST shape; `kind` distinguishes
/// them. `var` follows the same parser-time validation as `let` for
/// pattern initializers (required); runtime hoisting/redeclaration
/// semantics differ but those are not the parser's concern.
pub const LexicalDecl = struct {
    span: Span,
    kind: Kind,
    declarators: []VariableDeclarator,

    pub const Kind = enum { let_, const_, var_ };
};

pub const VariableDeclarator = struct {
    span: Span,
    name: BindingTarget,
    init: ?expr.Expression,
};

pub const BindingIdentifier = struct {
    span: Span,
};

/// §14.3.3 BindingPattern (or §13.15.5 AssignmentPattern reinterpreted).
/// The target of a binding — either a single name or a destructuring
/// pattern. `default` (for an inner element) attaches separately via
/// `BindingElement`.
pub const BindingTarget = union(enum) {
    identifier: BindingIdentifier,
    object: ObjectPattern,
    array: ArrayPattern,

    pub fn span(self: BindingTarget) Span {
        return switch (self) {
            inline else => |payload| payload.span,
        };
    }
};

/// A pattern element with an optional default — used as object property
/// values, array elements, and binding-name positions in lexical
/// declarators.
pub const BindingElement = struct {
    span: Span,
    target: BindingTarget,
    default: ?expr.Expression,
};

pub const ObjectPattern = struct {
    span: Span,
    properties: []ObjectPatternProperty,
    /// `{...,...rest }` — rest is restricted to a BindingIdentifier in
    /// object patterns (§14.3.3).
    rest: ?BindingIdentifier,
};

pub const ObjectPatternProperty = struct {
    span: Span,
    key: expr.PropertyKey,
    value: BindingElement,
    /// `{ a }` is shorthand for `{ a: a }`. `{ a = 1 }` is shorthand
    /// with a default. Implies `key` is `.ident` matching `value.target`.
    shorthand: bool,
};

pub const ArrayPattern = struct {
    span: Span,
    /// `null` slots are elisions: `[,, x]` has 3 elements, the first two
    /// are `null`. Trailing commas do not introduce trailing elisions.
    elements: []?BindingElement,
    /// `[...,...rest]` — rest target may itself be a pattern in array
    /// patterns (`[...[x, y]]`), unlike object patterns. Pointer so the
    /// `BindingTarget ↔ ArrayPattern` cycle resolves.
    rest: ?*BindingTarget,
};

pub const IfStmt = struct {
    span: Span,
    test_: expr.Expression,
    consequent: *Statement,
    alternate: ?*Statement,
};

pub const WhileStmt = struct {
    span: Span,
    test_: expr.Expression,
    body: *Statement,
};

pub const DoWhileStmt = struct {
    span: Span,
    body: *Statement,
    test_: expr.Expression,
};

pub const ReturnStmt = struct {
    span: Span,
    argument: ?expr.Expression,
};

pub const ThrowStmt = struct {
    span: Span,
    argument: expr.Expression,
};

/// §14.13 LabelledStatement — `IDENTIFIER : Statement`. The `label`
/// span covers the identifier (without the trailing `:`). Multiple
/// labels at one site nest as `LabeledStmt { body: LabeledStmt { … } }`.
pub const LabeledStmt = struct {
    span: Span,
    label: Span,
    body: *Statement,
};

pub const BreakStmt = struct {
    span: Span,
    /// `break LabelIdentifier;` — span over the label identifier.
    /// `null` for the unlabeled form.
    label: ?Span,
};

pub const ContinueStmt = struct {
    span: Span,
    label: ?Span,
};

/// §14.7.4 C-style ForStatement: `for (init?; test?; update?) body`.
pub const ForStmt = struct {
    span: Span,
    init: ?ForHead,
    test_: ?expr.Expression,
    update: ?expr.Expression,
    body: *Statement,
};

/// §14.7.5 ForInOfStatement: `for (left in/of right) body`. ES2018
/// `for await (left of right) body` is the same shape with `is_await =
/// true`; only `kind ==.of_` is a valid combination with `is_await`.
pub const ForInOfStmt = struct {
    span: Span,
    kind: Kind,
    is_await: bool = false,
    left: ForHead,
    right: expr.Expression,
    body: *Statement,

    pub const Kind = enum { in_, of_ };
};

/// The init / left of a for-loop is either a `let`/`const` declaration or
/// a plain expression. For for-in/of, the parser additionally enforces
/// "single binding, no initializer" — but the AST shape is shared.
pub const ForHead = union(enum) {
    lexical: LexicalDecl,
    expression: expr.Expression,
};

/// §14.15 TryStatement. Either `handler` or `finalizer` (or both) is
/// always present.
pub const TryStmt = struct {
    span: Span,
    block: BlockStmt,
    handler: ?CatchClause,
    finalizer: ?BlockStmt,
};

pub const CatchClause = struct {
    span: Span,
    /// `catch (e) {}` form. `null` for `catch {}` (catch-binding optional
    /// since ES2019). Per §14.15, the parameter is a BindingIdentifier or
    /// BindingPattern.
    param: ?BindingTarget,
    body: BlockStmt,
};

/// §14.12 SwitchStatement. `cases` is the list of `case`/`default` clauses
/// in source order; the spec restricts `default` to at most once but the
/// parser doesn't enforce this here yet.
pub const SwitchStmt = struct {
    span: Span,
    discriminant: expr.Expression,
    cases: []SwitchCase,
};

pub const SwitchCase = struct {
    span: Span,
    /// `null` for `default:` clauses, otherwise the `case Expr:` test.
    test_: ?expr.Expression,
    body: []Statement,
};

/// §15.2 FunctionDeclaration: `function name(params) { body }`. Generators
/// (`function*`) and `async` variants are deferred.
pub const FunctionDecl = struct {
    span: Span,
    name: BindingIdentifier,
    params: []FunctionParam,
    body: BlockStmt,
    /// `function* name() {}` — generator function (§15.5).
    is_generator: bool = false,
    /// `async function name() {}` — async function (§15.8).
    is_async: bool = false,
};

pub const FunctionParam = union(enum) {
    /// `name` or `name = default` BindingIdentifier with optional initializer.
    simple: SimpleParam,
    /// `...name` rest parameter — must be the last parameter.
    rest: RestParam,
};

pub const SimpleParam = struct {
    span: Span,
    target: BindingTarget,
    default: ?expr.Expression,
};

pub const RestParam = struct {
    span: Span,
    target: BindingTarget,
};

/// §15.7 ClassDeclaration: `class Name (extends Heritage)? { … }`.
pub const ClassDecl = struct {
    span: Span,
    name: BindingIdentifier,
    superclass: ?expr.Expression,
    body: []ClassMember,
};

pub const ClassMember = union(enum) {
    method: MethodDef,
    field: FieldDef,
    /// `static { … }` — class static initialization block (§15.7.13).
    /// Runs once at class definition time with `this` bound to the class.
    static_block: StaticBlock,
};

pub const MethodDef = struct {
    span: Span,
    is_static: bool,
    kind: MethodKind,
    key: expr.PropertyKey,
    params: []FunctionParam,
    body: BlockStmt,
    is_generator: bool = false,
    is_async: bool = false,
};

pub const MethodKind = enum {
    method,
    /// `get x() { … }`
    getter,
    /// `set x(v) { … }`
    setter,
};

pub const StaticBlock = struct {
    span: Span,
    body: []Statement,
};

/// §16.2.2 ImportDeclaration. Carries any combination of:
/// • `default` — `import name from "x"`
/// • `namespace` — `import * as ns from "x"`
/// • `named` — `import { a, b as c } from "x"`
/// All three may be empty for `import "x";` (side-effect import).
pub const ImportDecl = struct {
    span: Span,
    default: ?BindingIdentifier,
    namespace: ?BindingIdentifier,
    named: []NamedSpecifier,
    /// Module specifier — span over the StringLiteral token (incl. quotes).
    source: Span,
};

pub const NamedSpecifier = struct {
    span: Span,
    /// Source-side name. Either an IdentifierName or a StringLiteral
    /// (§16.2.2 ModuleExportName allows string literals for non-ident names).
    imported_span: Span,
    /// Local binding. When `imported as local` is omitted, equals
    /// `imported_span`.
    local: BindingIdentifier,
};

/// §16.2.3 ExportDeclaration.
pub const ExportDecl = struct {
    span: Span,
    body: ExportBody,
};

pub const ExportBody = union(enum) {
    /// `export { a, b as c }` (no source) or
    /// `export { a } from "..."` (re-export).
    named: NamedExportBody,
    /// `export *` / `export * as ns` from "...".
    all: AllExportBody,
    /// `export let/const/function/class …` — the inner statement IS the
    /// declaration (LexicalDecl, FunctionDecl, ClassDecl).
    declaration: *Statement,
    /// `export default Expression;` or `export default function/class`.
    /// Anonymous defaults still use the `function_expr` / `class_expr`
    /// expression forms (with `name = null`) inside.
    default_value: expr.Expression,
};

pub const NamedExportBody = struct {
    specifiers: []ExportSpecifier,
    /// Re-export source — a StringLiteral span when present.
    source: ?Span,
};

pub const ExportSpecifier = struct {
    span: Span,
    /// Local-side name.
    local_span: Span,
    /// Exported (renamed) name. Equal to `local_span` when no `as` rename.
    exported_span: Span,
};

pub const AllExportBody = struct {
    /// `export * as ns` — span of the `ns` IdentifierName, if any.
    namespace_local: ?Span,
    source: Span,
};

pub const FieldDef = struct {
    span: Span,
    is_static: bool,
    key: expr.PropertyKey,
    init: ?expr.Expression,
};
