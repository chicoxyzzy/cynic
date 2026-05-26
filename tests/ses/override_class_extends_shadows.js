// Override-mistake fix — subclass methods shadow a frozen base
// prototype's method via the same accessor-pair demotion that
// works for plain object assignment.
//
// Without the fix, `class Sub extends Base {}` followed by a
// method on Sub.prototype that collides with Base.prototype
// would fail when the engine tried to install Sub.prototype's
// method through OrdinarySet on the frozen Base.prototype slot.
// (Class bodies use defineProperty, not assignment, so this is
// also a check that Sub.prototype is a non-frozen own object —
// the freeze stops at the spec-mandated primordials.)

class Base {
  greet() { return "base"; }
}
class Sub extends Base {
  greet() { return "sub"; }
}

const s = new Sub();
if (s.greet() !== "sub") {
  throw new Error("subclass method did not shadow base method");
}

const b = new Base();
if (b.greet() !== "base") {
  throw new Error("base method was clobbered by subclass install");
}
