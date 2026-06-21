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

// Flag a move only when it stands clear of the noise: |ratio-1| must be
// >= MOVE_PCT (an absolute floor) AND >= spread%/SNR (the per-iteration
// ratio spread, scaled). Interleaving cancels host drift so the ratio
// MEDIAN is solid even when per-iteration spread is high — so a noisy host
// just needs a bigger move to call, and same-code A/B shows all "·" rather
// than littering every cell with a noise flag.
const MOVE_PCT = 5;
const SNR = 3;

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
    const movePct = Math.abs(r.ratio - 1) * 100;
    const confident = movePct >= MOVE_PCT && movePct >= r.spread / SNR;
    let mark = "·";
    if (confident && r.ratio < 1) {
      mark = "🟢 faster";
    } else if (confident && r.ratio > 1) {
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
      "cancels — the **ratio** (median of per-iteration ratios) is the " +
      "trustworthy signal (`< 1.0` = HEAD faster). `base ms`/`head ms` are " +
      "informational; `spread%` is the per-iteration ratio spread (host " +
      `noise). A move is flagged only when it clears BOTH ±${MOVE_PCT}% and ` +
      `spread%/${SNR}, so a noisy host just needs a bigger move to call and ` +
      "same-code runs stay clean.",
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
