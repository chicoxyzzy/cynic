// Adding a new method to a frozen primordial prototype throws
// TypeError. This is the engine surface that closes the
// supply-chain-attack vector that motivates SES.

let threw = false;
try {
  Array.prototype.cynicShim = function () { return 42; };
} catch (e) {
  threw = e instanceof TypeError;
}
if (!threw) {
  throw new Error("Array.prototype.cynicShim assignment did not throw TypeError");
}

// Same shape via defineProperty.
threw = false;
try {
  Object.defineProperty(Array.prototype, "cynicShim2", {
    value: function () { return 1; },
    writable: true,
    enumerable: true,
    configurable: true,
  });
} catch (e) {
  threw = e instanceof TypeError;
}
if (!threw) {
  throw new Error("defineProperty on Array.prototype did not throw TypeError");
}
