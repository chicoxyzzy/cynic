// harden() returns its argument so it can be chained at the
// definition site: `const x = harden({...});`. Matches
// `@endo/ses` `harden`.

const o = { x: 1 };
const r = harden(o);
if (r !== o) {
  throw new Error("harden did not return its argument");
}
