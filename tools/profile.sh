#!/usr/bin/env bash
#
# tools/profile.sh — Run a test262 sweep under `samply` and emit a
# top-N hot-function list. Used by the `/profile` slash command.
#
# Usage:
#   tools/profile.sh [filter] [top_n]
#
# Args:
#   filter  — test262 path substring (default: "built-ins/Array")
#   top_n   — how many hot functions to print (default: 20)
#
# Output:
#   - profile.json — full samply profile (open with `samply load`)
#   - prints the top-N hot functions to stdout
#
# Prereq: `samply` on PATH. Install on macOS with `brew install samply`
# or `cargo install samply`. Linux: same `cargo install` works; or
# build from https://github.com/mstange/samply.

set -eu

FILTER="${1:-built-ins/Array}"
TOP_N="${2:-20}"

cd "$(dirname "$0")/.."

if ! command -v samply >/dev/null 2>&1; then
    cat >&2 <<EOF
profile.sh: \`samply\` not found on PATH.

Install with one of:
    brew install samply           # macOS / Linuxbrew
    cargo install samply          # any platform with Rust toolchain

Then re-run.
EOF
    exit 1
fi

# Use the ReleaseFast harness — Debug interpretation is 5-10×
# slower and would over-weight cold paths in the profile.
echo "==> Building test262 harness (ReleaseFast)..." >&2
zig build test262 -- --quiet --filter=__nonexistent_filter__ >/dev/null

HARNESS_BIN="$(find .zig-cache -name 'test262' -type f -perm -u+x | head -1)"
if [[ -z "${HARNESS_BIN:-}" ]]; then
    echo "profile.sh: couldn't locate the test262 harness binary in .zig-cache" >&2
    exit 1
fi

echo "==> Profiling '${FILTER}' under samply..." >&2
echo "    harness: ${HARNESS_BIN}" >&2

# `samply record --save-only` writes a profile without launching the
# GUI viewer. `--unstable-presymbolicate` emits a `profile.syms.json`
# sidecar so the inline top-N below can resolve symbols without
# re-walking the debug info ourselves.
samply record \
    --save-only \
    --unstable-presymbolicate \
    --output profile.json \
    -- \
    "${HARNESS_BIN}" \
    --quiet \
    --mode=runtime \
    "--filter=${FILTER}" \
    >/dev/null

echo "==> Wrote profile.json (+ profile.syms.json sidecar)." >&2
echo "    Load in the UI with: samply load profile.json" >&2
echo "" >&2
echo "==> Top ${TOP_N} hot functions (self time, sample count):" >&2

# Walk the Firefox-Profiler JSON: for every sample across every
# thread, take the leaf frame, resolve its function name through
# `frameTable.func[]` → `funcTable.name[]` → `stringArray[]`. Most
# names come out as `0x<addr>`; we cross-reference the sidecar
# `profile.syms.json` (per-library symbol table) to resolve them
# to source-level function names where possible.
python3 - "${TOP_N}" <<'PY'
import json, sys, collections, pathlib, bisect

top_n = int(sys.argv[1])
profile = json.loads(pathlib.Path("profile.json").read_text())

# Build a per-lib RVA→symbol map from the sidecar. The sidecar
# layout: { "data": [{ "debug_name", "symbol_table": [{rva, size, symbol}], ... }, ...],
# "string_table": ["..."] }. Library order in `data` mirrors
# the `.libs` order in profile.json, but we cross-reference by
# debugName to be safe.
syms_path = pathlib.Path("profile.syms.json")
lib_rva_tables = {}   # debugName -> (sorted_rvas, names, sizes)
if syms_path.exists():
    side = json.loads(syms_path.read_text())
    str_tab = side.get("string_table", [])
    for entry in side.get("data", []):
        debug = entry.get("debug_name") or ""
        rvas, names, sizes = [], [], []
        for s in entry.get("symbol_table", []):
            rvas.append(s["rva"])
            names.append(str_tab[s["symbol"]] if isinstance(s["symbol"], int) else s["symbol"])
            sizes.append(s.get("size", 0))
        # Sort by rva for bisect.
        order = sorted(range(len(rvas)), key=lambda i: rvas[i])
        rvas = [rvas[i] for i in order]
        names = [names[i] for i in order]
        sizes = [sizes[i] for i in order]
        lib_rva_tables[debug] = (rvas, names, sizes)

libs = profile.get("libs", [])

def resolve(lib_index, addr):
    if lib_index is None or lib_index < 0 or lib_index >= len(libs):
        return f"<no-lib>+0x{addr:x}"
    lib = libs[lib_index]
    debug = lib.get("debugName") or lib.get("name") or ""
    tbl = lib_rva_tables.get(debug)
    if not tbl:
        return f"{debug}+0x{addr:x}"
    rvas, names, sizes = tbl
    i = bisect.bisect_right(rvas, addr) - 1
    if i < 0:
        return f"{debug}+0x{addr:x}"
    base = rvas[i]
    if sizes[i] and addr >= base + sizes[i]:
        return f"{debug}+0x{addr:x}"
    return names[i]

counts = collections.Counter()
for thread in profile.get("threads", []):
    stacks = thread.get("samples", {}).get("stack", []) or []
    stack_tbl = thread.get("stackTable", {})
    frame_tbl = thread.get("frameTable", {})
    func_tbl = thread.get("funcTable", {})
    resource_tbl = thread.get("resourceTable", {})

    stack_frame = stack_tbl.get("frame", [])
    frame_addr = frame_tbl.get("address", [])
    frame_func = frame_tbl.get("func", [])
    func_res = func_tbl.get("resource", [])
    res_lib = resource_tbl.get("lib", [])

    for s in stacks:
        if s is None:
            continue
        f = stack_frame[s]
        addr = frame_addr[f] if f < len(frame_addr) else None
        if addr is None or addr < 0:
            continue
        fn = frame_func[f] if f < len(frame_func) else None
        res = func_res[fn] if fn is not None and fn < len(func_res) else -1
        lib_idx = res_lib[res] if 0 <= res < len(res_lib) else None
        counts[resolve(lib_idx, addr)] += 1

total = sum(counts.values())
print(f"   (total samples: {total})", file=sys.stderr)
for name, c in counts.most_common(top_n):
    pct = 100.0 * c / total if total else 0.0
    print(f"  {c:>5}  {pct:5.1f}%  {name}", file=sys.stderr)
PY
