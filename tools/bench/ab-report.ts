// ab-report.ts — render an interleaved A/B run into a markdown report.
//
// bench.zig's `--ab-baseline` mode measures HEAD and baseline back-to-back
// per iteration and reports, per fixture: base_ms, head_ms, the median of
// the per-iteration ratios (head/base), and the spread of those ratios.
// Because each pair is timed at the same instant, the ratio cancels host
// drift — trustworthy even on a noisy shared box. This tool just formats
// one directory of those per-config tables into markdown.
//
// Runs on Node >= 23 directly (`node ab-report.ts <dir>`) via
// type-stripping — no build step. Type-checked with tsgo (package.json).

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

// A move past this on the (drift-cancelled) ratio is flagged. Interleaving
// removes the between-halves jitter, so a few percent is meaningful — but a
// fixture whose own per-iteration ratio spread is high is marked uncertain
// rather than trusted.
const MOVE = 0.05;
const NOISY_SPREAD = 25; // ratio-spread% above which a row is "(noisy)"

interface BenchConfig {
  readonly key: string;
  readonly title: string;
}

const CONFIGS: readonly BenchConfig[] = [
  { key: "micros-jit", title: "Micros — JIT (default tier)" },
  { key: "micros-nojit", title: "Micros — interpreter (`--no-jit`)" },
  { key: "macros-jit", title: "Macros — JIT (default tier)" },
  { key: "macros-nojit", title: "Macros — interpreter (`--no-jit`)" },
];

interface Row {
  readonly name: string;
  readonly base: number;
  readonly head: number;
  readonly ratio: number;
  readonly spread: number;
}

// Parse a bench.zig interleaved table: "name base_ms head_ms ratioX spread%".
function parse(path: string): Row[] {
  if (!existsSync(path)) return [];
  const rows: Row[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const t = line.trim().split(/\s+/);
    if (t.length < 5 || t[0] === "bench" || t[0] === "-----") continue;
    const base = Number(t[1]);
    const head = Number(t[2]);
    const ratio = Number(t[3].replace(/x$/i, ""));
    const spread = Number(t[4]);
    if (![base, head, ratio, spread].every(Number.isFinite)) continue;
    rows.push({ name: t[0], base, head, ratio, spread });
  }
  return rows;
}

interface Block {
  readonly text: string;
  readonly regressed: boolean;
}

function block(path: string, title: string): Block | null {
  const rows = parse(path);
  if (rows.length === 0) return null;
  const out = [
    `#### ${title}`,
    "",
    "| fixture | base ms | head ms | ratio | spread% | |",
    "|---|--:|--:|--:|--:|:--|",
  ];
  let regressed = false;
  for (const r of rows.sort((a, b) => a.name.localeCompare(b.name))) {
    let mark = "·";
    if (r.spread > NOISY_SPREAD) {
      mark = "≈ noisy";
    } else if (r.ratio <= 1 - MOVE) {
      mark = "🟢 faster";
    } else if (r.ratio >= 1 + MOVE) {
      mark = "🔴 slower";
      regressed = true;
    }
    out.push(`| ${r.name} | ${r.base.toFixed(2)} | ${r.head.toFixed(2)} | ${r.ratio.toFixed(3)}× | ${r.spread.toFixed(0)} | ${mark} |`);
  }
  return { text: out.join("\n") + "\n", regressed };
}

function main(): void {
  const dir = argv[2];
  if (!dir) {
    console.error("usage: ab-report.ts <dir>   (dir of bench.zig --ab-baseline tables)");
    exit(2);
  }
  const out: string[] = [
    "## Interleaved A/B bench",
    "",
    "HEAD vs baseline, measured **back-to-back per iteration** so host drift " +
      "cancels — the **ratio** is the trustworthy signal (`< 1.0` = HEAD " +
      "faster). `base ms`/`head ms` are informational. `spread%` is the " +
      `per-iteration ratio spread: a low value means the ratio is solid; ` +
      `> ${NOISY_SPREAD}% is marked ≈ noisy (re-run before trusting). Moves ` +
      `past ±${Math.round(MOVE * 100)}% are flagged.`,
    "",
  ];
  let any = false;
  let regressed = false;
  for (const { key, title } of CONFIGS) {
    const res = block(join(dir, `${key}.txt`), title);
    if (!res) continue;
    any = true;
    out.push(res.text);
    if (res.regressed) regressed = true;
  }
  if (!any) out.push("_No comparable configs in the directory._");
  out.push("");
  out.push(regressed
    ? "🔴 = a fixture regressed past the threshold (and not noisy); review before merge."
    : "_No regressions past the threshold._");
  console.log(out.join("\n"));
}

main();
