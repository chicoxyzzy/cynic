#!/bin/sh
# Convert a directory of WebAssembly `.wast` spec tests into the JSON
# manifest + `.wasm` binaries the Sarcasm conformance harness consumes,
# using wabt's `wast2json`.
#
#   wasm-testsuite-gen.sh <corpus-dir> <out-dir>
#
# The harness (tools/wasm_testsuite.zig) only reads binary `.wasm`, so
# this preprocessing step turns the text `.wast` corpus into something
# it can run. A missing/broken converter or an empty generated corpus
# is a setup failure, not a successful zero-test run.

set -eu

corpus="${1:-}"
out="${2:-}"

if [ -z "$corpus" ] || [ -z "$out" ]; then
    echo "usage: wasm-testsuite-gen.sh <corpus-dir> <out-dir>" >&2
    exit 2
fi

if ! command -v wast2json >/dev/null 2>&1; then
    echo "wasm-testsuite: wast2json not found on PATH; install wabt to run the suite" >&2
    exit 2
fi

# wabt exposes --enable-X for default-off features and --disable-X for
# default-on ones. Several enable flags disappeared in 1.0.42 when their
# features became defaults; support both that version and older packages.
if ! help=$(wast2json --help); then
    echo "wasm-testsuite: could not inspect wast2json options" >&2
    exit 2
fi
set --
for feature in tail-call relaxed-simd memory64 extended-const multi-memory function-references; do
    case "$help" in
        *"--enable-$feature "*) set -- "$@" "--enable-$feature" ;;
        *"--disable-$feature "*) ;;
        *)
            echo "wasm-testsuite: wast2json does not support required feature $feature" >&2
            exit 2
            ;;
    esac
done

# Catch global converter/option errors once, with the real diagnostic,
# before treating unsupported proposal syntax as per-file skips.
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cynic-wast2json.XXXXXX")
trap 'rm -rf "$temporary"' 0
trap 'exit 2' 1 2 15
printf '%s\n' '(module)' > "$temporary/probe.wast"
if ! wast2json "$@" "$temporary/probe.wast" -o "$temporary/probe.json" > "$temporary/converter.log" 2>&1; then
    echo "wasm-testsuite: wast2json smoke conversion failed" >&2
    cat "$temporary/converter.log" >&2
    exit 2
fi

mkdir -p "$out"

# Clear stale artifacts so a removed/renamed .wast doesn't linger.
rm -f "$out"/*.json "$out"/*.wasm

n=0
for f in "$corpus"/*.wast; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .wast)
    # Enable the proposals Sarcasm implements so wast2json lowers their
    # `.wast` files and the harness scores them. We deliberately do NOT
    # `--enable-all`: that also lowers `gc` tests (unimplemented) — and
    # it switches wabt to a non-standard compressed import-section
    # encoding that no standard decoder accepts.
    if wast2json "$@" "$f" -o "$out/$base.json" > "$temporary/converter.log" 2>&1; then
        n=$((n + 1))
    else
        echo "wasm-testsuite: wast2json could not convert $base.wast (skipped)" >&2
        sed -n '1,8p' "$temporary/converter.log" >&2
        rm -f "$out/$base.json"
    fi
done

echo "wasm-testsuite: converted $n .wast file(s) into $out" >&2
if [ "$n" -eq 0 ]; then
    exit 2
fi
