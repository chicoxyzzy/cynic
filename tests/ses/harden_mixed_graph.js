// harden() walks a mixed object graph (plain objects, functions,
// class instances) and freezes every reachable node. The visited
// set keeps the cost linear in the graph size regardless of fan-in
// or fan-out.

class C {
  constructor(v) { this.v = v; }
  method() { return this.v; }
}

function fn() { return "fn"; }
fn.attached = { kind: "fn-attached" };

const root = {
  instance: new C(42),
  fn: fn,
  nested: { deep: { x: 1 } },
  arr: [new C(1), new C(2)],
};

harden(root);

if (Object.isExtensible(root)) throw new Error("root not frozen");
if (Object.isExtensible(root.instance)) throw new Error("class instance not frozen");
if (Object.isExtensible(root.fn)) throw new Error("function value not frozen");
if (Object.isExtensible(root.fn.attached)) throw new Error("function-attached object not frozen");
if (Object.isExtensible(root.nested)) throw new Error("nested object not frozen");
if (Object.isExtensible(root.nested.deep)) throw new Error("deep nested object not frozen");
if (Object.isExtensible(root.arr)) throw new Error("array not frozen");
if (Object.isExtensible(root.arr[0])) throw new Error("array element not frozen");
