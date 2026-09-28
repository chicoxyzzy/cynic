// Loading has ended. Upstream done() still waits for outstanding subtests; the
// executor drains microtasks afterwards. A pending promise cannot manufacture a
// completion record just because that queue becomes empty.
done();
