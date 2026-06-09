#!/bin/sh
# Convert a directory of WebAssembly `.wast` spec tests into the JSON
# manifest + `.wasm` binaries the Sarcasm conformance harness consumes,
# using wabt's `wast2json`.
#
#   wasm-testsuite-gen.sh <corpus-dir> <out-dir>
#
# The harness (tools/wasm_testsuite.zig) only reads binary `.wasm`, so
# this preprocessing step turns the text `.wast` corpus into something
# it can run. Missing wabt is non-fatal: the harness simply finds an
# empty out-dir and reports zero tests.

corpus="$1"
out="$2"

if [ -z "$corpus" ] || [ -z "$out" ]; then
    echo "usage: wasm-testsuite-gen.sh <corpus-dir> <out-dir>" >&2
    exit 2
fi

mkdir -p "$out"

if ! command -v wast2json >/dev/null 2>&1; then
    echo "wasm-testsuite: wast2json not found on PATH; install wabt to run the suite" >&2
    exit 0
fi

# Clear stale artifacts so a removed/renamed .wast doesn't linger.
rm -f "$out"/*.json "$out"/*.wasm 2>/dev/null

n=0
for f in "$corpus"/*.wast; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .wast)
    # Enable the proposals Sarcasm implements so wast2json lowers their
    # `.wast` files and the harness scores them. We deliberately do NOT
    # `--enable-all`: that also lowers `gc` / `function-references` tests,
    # which use features the engine doesn't implement and don't all reduce
    # to a clean decode-time skip. (Exception-handling can't be lowered by
    # this wabt regardless — its `(ref exn)` text syntax is unsupported.)
    if wast2json --enable-tail-call --enable-relaxed-simd \
        --enable-memory64 --enable-extended-const \
        "$f" -o "$out/$base.json" >/dev/null 2>&1; then
        n=$((n + 1))
    else
        echo "wasm-testsuite: wast2json could not convert $base.wast (skipped)" >&2
        rm -f "$out/$base.json" 2>/dev/null
    fi
done

echo "wasm-testsuite: converted $n .wast file(s) into $out" >&2
