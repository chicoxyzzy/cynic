// Select testharness.js's existing JavaScript-shell environment. In particular,
// do not advertise DOM, worker, event-loop, or timer APIs the shell cannot run.
globalThis.self = globalThis;

// Cynic already supplies console.log. The harness uses console.debug when its
// debug setting is enabled; keep diagnostic output on the same host channel.
console.debug = console.log;
console.info = console.log;
console.warn = console.log;
console.error = console.log;
