// Cynic-shipped stub of harness/resizableArrayBufferUtils.js.
//
// The upstream helper manufactures TypedArray subclass constructors via
// `new Function('return class My' + type + ' extends ' + type + ' {}')()`.
// Cynic permanently bans `new Function(string)` (AGENTS.md: "eval and
// runtime code construction — out permanently"), so the upstream
// `try/catch` leaves the subclass slots `undefined`, which propagates
// into the `ctors` array and breaks every fixture that iterates `ctors`.
//
// This stub aliases the `My*` slots to the real built-in constructors.
// We lose the user-subclass semantics signal but recover ~166 fixtures
// of genuine engine-behavior signal on resizable ArrayBuffer + TypedArray
// interactions (length tracking, OOB detection, growth/shrink mid-op).
//
// Same identifier surface as upstream: `MyUint8Array`, `MyFloat32Array`,
// `MyBigInt64Array`, `builtinCtors`, `floatCtors`, `ctors`,
// `CreateResizableArrayBuffer`, `Convert`, `ToNumbers`, `MayNeedBigInt`,
// `CreateRabForTest`, `CollectValuesAndResize`, `TestIterationAndResize`.

var MyUint8Array = Uint8Array;
var MyFloat32Array = Float32Array;
var MyBigInt64Array = (typeof BigInt64Array !== "undefined") ? BigInt64Array : undefined;

var builtinCtors = [
  Uint8Array,
  Int8Array,
  Uint16Array,
  Int16Array,
  Uint32Array,
  Int32Array,
  Float32Array,
  Float64Array,
  Uint8ClampedArray,
];

if (typeof Float16Array !== "undefined") {
  builtinCtors.push(Float16Array);
}

if (typeof BigUint64Array !== "undefined") {
  builtinCtors.push(BigUint64Array);
}

if (typeof BigInt64Array !== "undefined") {
  builtinCtors.push(BigInt64Array);
}

var floatCtors = [
  Float32Array,
  Float64Array,
  MyFloat32Array,
];

if (typeof Float16Array !== "undefined") {
  floatCtors.push(Float16Array);
}

var ctors = builtinCtors.concat(MyUint8Array, MyFloat32Array);

if (typeof MyBigInt64Array !== "undefined") {
  ctors.push(MyBigInt64Array);
}

function CreateResizableArrayBuffer(byteLength, maxByteLength) {
  return new ArrayBuffer(byteLength, { maxByteLength: maxByteLength });
}

function Convert(item) {
  if (typeof item == "bigint") {
    return Number(item);
  }
  return item;
}

function ToNumbers(array) {
  var result = [];
  for (var i = 0; i < array.length; i++) {
    var item = array[i];
    result.push(Convert(item));
  }
  return result;
}

function MayNeedBigInt(ta, n) {
  assert.sameValue(typeof n, "number");
  if ((typeof BigInt64Array !== "undefined" && ta instanceof BigInt64Array)
      || (typeof BigUint64Array !== "undefined" && ta instanceof BigUint64Array)) {
    return BigInt(n);
  }
  return n;
}

function CreateRabForTest(ctor) {
  var rab = CreateResizableArrayBuffer(4 * ctor.BYTES_PER_ELEMENT, 8 * ctor.BYTES_PER_ELEMENT);
  // Write some data into the array.
  var taWrite = new ctor(rab);
  for (var i = 0; i < 4; ++i) {
    taWrite[i] = MayNeedBigInt(taWrite, 2 * i);
  }
  return rab;
}

function CollectValuesAndResize(n, values, rab, resizeAfter, resizeTo) {
  if (typeof n == "bigint") {
    values.push(Number(n));
  } else {
    values.push(n);
  }
  if (values.length == resizeAfter) {
    rab.resize(resizeTo);
  }
  return true;
}

function TestIterationAndResize(iterable, expected, rab, resizeAfter, newByteLength) {
  var values = [];
  var resized = false;
  var arrayValues = false;

  for (var value of iterable) {
    if (Array.isArray(value)) {
      arrayValues = true;
      values.push([
        value[0],
        Number(value[1]),
      ]);
    } else {
      values.push(Number(value));
    }
    if (!resized && values.length == resizeAfter) {
      rab.resize(newByteLength);
      resized = true;
    }
  }
  if (!arrayValues) {
    assert.compareArray([].concat(values), expected, "TestIterationAndResize: list of iterated values");
  } else {
    for (var i = 0; i < expected.length; i++) {
      assert.compareArray(values[i], expected[i], "TestIterationAndResize: list of iterated lists of values");
    }
  }
  assert(resized, "TestIterationAndResize: resize condition should have been hit");
}
