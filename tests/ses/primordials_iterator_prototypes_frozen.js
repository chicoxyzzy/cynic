// The %ArrayIteratorPrototype%, %MapIteratorPrototype%,
// %SetIteratorPrototype%, %StringIteratorPrototype% — and the
// %IteratorPrototype% they all share via [[Prototype]] — are
// primordials too. SES freezes the whole intrinsic graph; missing
// the iterator prototypes would leave a supply-chain hole
// (`Array.prototype.values()[Symbol.iterator].constructor =
// attacker` style).

const arr_iter = [][Symbol.iterator]();
const map_iter = new Map()[Symbol.iterator]();
const set_iter = new Set()[Symbol.iterator]();
const str_iter = ""[Symbol.iterator]();

// Each iterator instance is fresh and extensible (it's a user-
// reachable object). The PROTOTYPES are the primordials.
const protos = [
  Object.getPrototypeOf(arr_iter),
  Object.getPrototypeOf(map_iter),
  Object.getPrototypeOf(set_iter),
  Object.getPrototypeOf(str_iter),
];

for (const p of protos) {
  if (Object.isExtensible(p)) {
    throw new Error("iterator prototype is extensible: " + Object.prototype.toString.call(p));
  }
}

// The common %IteratorPrototype% (parent of each iterator's
// prototype) is also frozen.
const iter_root = Object.getPrototypeOf(protos[0]);
if (iter_root === null) {
  throw new Error("array iterator proto has no parent — missing %IteratorPrototype%");
}
if (Object.isExtensible(iter_root)) {
  throw new Error("%IteratorPrototype% is extensible");
}
