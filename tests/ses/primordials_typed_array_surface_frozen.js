// The typed-array intrinsic surface is frozen at realm init: the
// abstract %TypedArray% constructor and its %TypedArray%.prototype,
// every concrete TypedArray prototype, and the ArrayBuffer /
// SharedArrayBuffer / DataView prototypes. None is reached by
// primordials_prototypes_frozen.js, yet each carries methods a SES
// guest must not be able to redefine (e.g. %TypedArray%.prototype.set,
// DataView.prototype.getFloat64).

const TA = Object.getPrototypeOf(Int8Array); // %TypedArray%

const surfaces = [
  TA, TA.prototype,
  Int8Array.prototype, Uint8Array.prototype, Uint8ClampedArray.prototype,
  Int16Array.prototype, Uint16Array.prototype,
  Int32Array.prototype, Uint32Array.prototype,
  Float32Array.prototype, Float64Array.prototype,
  BigInt64Array.prototype, BigUint64Array.prototype,
  ArrayBuffer.prototype, SharedArrayBuffer.prototype, DataView.prototype,
];

for (const surface of surfaces) {
  if (Object.isExtensible(surface)) {
    throw new Error(
      "typed-array intrinsic unexpectedly extensible: " +
        Object.prototype.toString.call(surface)
    );
  }
}
