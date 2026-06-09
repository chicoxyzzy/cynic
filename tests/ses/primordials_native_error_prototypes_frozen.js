// Every NativeError prototype is frozen at realm init, not just
// Error.prototype (which primordials_prototypes_frozen.js already
// checks). The six §20.5.6 NativeError subclasses plus AggregateError
// each own a distinct prototype object (TypeError.prototype is not
// Error.prototype), so each is a separate frozen surface a SES guest
// must not be able to monkeypatch.

const errorCtors = [
  TypeError, RangeError, ReferenceError,
  SyntaxError, EvalError, URIError, AggregateError,
];

for (const ctor of errorCtors) {
  if (Object.isExtensible(ctor.prototype)) {
    throw new Error(
      "NativeError prototype unexpectedly extensible: " + ctor.name
    );
  }
}
