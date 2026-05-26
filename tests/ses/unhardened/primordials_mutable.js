// Under `--unhardened`, primordials are not frozen at realm init:
// `Array.prototype` is extensible and writable. This is the
// inverse of `primordials_constructors_frozen.js` and friends in
// the parent directory.
//
// The primary use case: code written before SES that monkey-
// patches primordials for polyfills / shims. `cynic --unhardened
// run polyfill.js` keeps that pattern working.

if (!Object.isExtensible(Array.prototype)) {
  throw new Error("Array.prototype unexpectedly non-extensible under --unhardened");
}
if (!Object.isExtensible(Object.prototype)) {
  throw new Error("Object.prototype unexpectedly non-extensible under --unhardened");
}
if (!Object.isExtensible(Function.prototype)) {
  throw new Error("Function.prototype unexpectedly non-extensible under --unhardened");
}

// Monkey-patch should succeed.
Array.prototype.cynicUnhardenedShim = function () { return 42; };
if ([].cynicUnhardenedShim() !== 42) {
  throw new Error("monkey-patch failed despite --unhardened");
}
