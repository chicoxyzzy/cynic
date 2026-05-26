// Static methods live on the constructor function, not on
// `Constructor.prototype`. A subclass static of the same name
// shadows the base static the same way an instance method does —
// but the install path goes through the FUNCTION's own properties,
// which are also subject to the override-mistake fix because the
// base function (and its `.name` / `.length` slots) are frozen
// under SES.

class Base {
  static greet() { return "base"; }
}
class Sub extends Base {
  static greet() { return "sub"; }
}

if (Sub.greet() !== "sub") {
  throw new Error("static shadow on subclass did not win lookup");
}
if (Base.greet() !== "base") {
  throw new Error("base static was clobbered by subclass install");
}
