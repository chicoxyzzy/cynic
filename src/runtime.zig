//! Runtime barrel module — re-exports the public runtime surface.
//!
//! The runtime layer hosts everything that comes alive at *evaluate*
//! time: NaN-boxed values, the heap, JS objects, the interpreter,
//! and built-ins. Compile-time machinery (lexer, parser, AST) lives
//! one layer below.

pub const value = @import("runtime/value.zig");
pub const Value = value.Value;

pub const string = @import("runtime/string.zig");
pub const JSString = string.JSString;

pub const utf16 = @import("runtime/utf16.zig");

pub const function = @import("runtime/function.zig");
pub const JSFunction = function.JSFunction;

pub const environment = @import("runtime/environment.zig");
pub const Environment = environment.Environment;

pub const object = @import("runtime/object.zig");
pub const JSObject = object.JSObject;

pub const heap = @import("runtime/heap.zig");
pub const Heap = heap.Heap;
pub const HandleScope = heap.HandleScope;

pub const realm = @import("runtime/realm.zig");
pub const Realm = realm.Realm;

pub const features = @import("runtime/features.zig");
pub const FeatureFlag = features.FeatureFlag;
pub const FeatureSet = features.FeatureSet;

pub const intrinsics = @import("runtime/intrinsics.zig");

pub const generator = @import("runtime/generator.zig");
pub const JSGenerator = generator.JSGenerator;

pub const symbol = @import("runtime/symbol.zig");
pub const JSSymbol = symbol.JSSymbol;

pub const bigint = @import("runtime/bigint.zig");
pub const JSBigInt = bigint.JSBigInt;

pub const module = @import("runtime/module.zig");
pub const ModuleRecord = module.ModuleRecord;

pub const lantern = @import("runtime/lantern/lantern.zig");
pub const run = lantern.run;
pub const evaluateScript = lantern.evaluateScript;
