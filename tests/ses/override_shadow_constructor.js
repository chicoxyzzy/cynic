// Override-mistake fix — `constructor` gets the same synthetic-
// accessor demotion as every other frozen prototype data slot.
//
// The override mistake classically bites on `constructor`:
// `this.constructor = …` in legacy hierarchies and
// `Sub.prototype.constructor = Sub` over an `Object.create`'d
// prototype both write through an inherited frozen slot. SES
// lockdown's default enablements cover `constructor` on every
// primordial prototype for exactly this reason.

// Plain object — inherited from Object.prototype.
const o = {};
o.constructor = 1;
if (o.constructor !== 1) throw new Error("o.constructor shadow failed");
if (Object.prototype.constructor !== Object) {
  throw new Error("shadow leaked onto Object.prototype");
}
if ({}.constructor !== Object) {
  throw new Error("fresh object constructor read broken");
}

// Array instance — inherited from Array.prototype.
const a = [];
a.constructor = { mark: true };
if (!a.constructor.mark) throw new Error("a.constructor shadow failed");
if ([].constructor !== Array) {
  throw new Error("fresh array constructor read broken");
}

// §10.1.9.2 OrdinarySetWithOwnDescriptor step 3.d.iv — the shadow
// lands as an ordinary own data property on the receiver.
const d = Object.getOwnPropertyDescriptor(o, "constructor");
if (!d || d.value !== 1 || !d.writable || !d.enumerable || !d.configurable) {
  throw new Error("shadow descriptor is not a default data property");
}

// The classic prototype-pattern back-edge repair.
function Base() {}
function Sub() {}
Sub.prototype = Object.create(Array.prototype);
Sub.prototype.constructor = Sub; // writes through frozen Array.prototype slot
if (Sub.prototype.constructor !== Sub) {
  throw new Error("prototype-pattern constructor repair failed");
}

// Reads through the chain still resolve for primitives.
if ("x".constructor !== String) {
  throw new Error("primitive wrapper constructor read broken");
}
