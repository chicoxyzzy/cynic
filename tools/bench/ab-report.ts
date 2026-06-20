// ab-report.ts — diff two bench.zig output dirs into a markdown report.
//
// Same-runner A/B: the bench runner produces a baseline dir and a HEAD dir
// (both timed in one job on the same CPU). This emits, per config, the
// per-fixture base/head p50 and the HEAD/baseline ratio. < 1.0 = HEAD
// faster; > 1.0 = slower. Absolute ms on shared hardware are noisy; the
// ratio is the trustworthy signal because both halves ran on one machine.
//
// Runs on Node ≥ 23 directly (`node ab-report.ts <base-dir> <head-dir>`)
// via type-stripping — no build step. Type-checked with tsgo (see
// package.json `typecheck`).

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { argv, exit } from "node:process";

// Movement threshold: |ratio - 1| past this is flagged. Calibrated on a
// shared-vCPU remote with a same-code A/B: the noise floor is ~7% (up to
// ~18% on promise_chain) and does NOT shrink with more runs — it's neighbour
// jitter between the two A/B halves, not sample noise — so only 10 %+
// moves are worth flagging. Re-run a flag to confirm: real regressions
// reproduce, jitter doesn't.
const THRESH = 0.1;

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

// bench.zig table -> Map<fixture, p50_ms>. First token is the fixture name,
// second is p50, regardless of the optional p95/p99 columns that follow at
// high run counts.
function parse(path: string): Map<string, number> {
  const res = new Map<string, number>();
  if (!existsSync(path)) return res;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const tok = line.trim().split(/\s+/);
    if (tok.length < 4 || tok[0] === "bench" || tok[0] === "-----") continue;
    const p50 = Number(tok[1]);
    if (Number.isFinite(p50)) res.set(tok[0], p50);
  }
  return res;
}

interface Block {
  readonly text: string;
  readonly worst: number;
}

function block(basePath: string, headPath: string, title: string): Block | null {
  const base = parse(basePath);
  const head = parse(headPath);
  const common = [...head.keys()].filter((n) => base.has(n)).sort();
  if (common.length === 0) return null;
  const rows = [
    `#### ${title}`,
    "",
    "| fixture | base ms | head ms | ratio | |",
    "|---|--:|--:|--:|:--|",
  ];
  let worst = 1.0;
  for (const n of common) {
    const b = base.get(n) ?? 0;
    const h = head.get(n) ?? 0;
    const r = b ? h / b : NaN;
    let mark: string;
    if (r <= 1 - THRESH) {
      mark = "🟢 faster";
    } else if (r >= 1 + THRESH) {
      mark = "🔴 slower";
      worst = Math.max(worst, r);
    } else {
      mark = "·";
    }
    rows.push(`| ${n} | ${b.toFixed(2)} | ${h.toFixed(2)} | ${r.toFixed(3)}× | ${mark} |`);
  }
  return { text: rows.join("\n") + "\n", worst };
}

function main(): void {
  const baseDir = argv[2];
  const headDir = argv[3];
  if (!baseDir || !headDir) {
    console.error("usage: ab-report.ts <base-dir> <head-dir>");
    exit(2);
  }
  const out: string[] = [
    "## Same-runner A/B bench",
    "",
    "Ratio = HEAD p50 / baseline p50, both measured in this job on the same " +
      "CPU. **< 1.0 = HEAD faster, > 1.0 = slower.** Absolute ms are " +
      "informational (shared-runner CPU varies); the ratio is the signal. " +
      `Movers past ±${Math.round(THRESH * 100)}% are flagged — but on the ` +
      "shared box that's a coarse gate: re-run a flagged fixture to confirm " +
      "(real regressions reproduce, jitter doesn't).",
    "",
  ];
  let anyBlock = false;
  let regression = false;
  for (const { key, title } of CONFIGS) {
    const res = block(join(baseDir, `${key}.txt`), join(headDir, `${key}.txt`), title);
    if (!res) continue;
    anyBlock = true;
    out.push(res.text);
    if (res.worst >= 1 + THRESH) regression = true;
  }
  if (!anyBlock) out.push("_No comparable fixtures between the two refs._");
  out.push("");
  out.push(
    regression
      ? "🔴 = a fixture regressed past the threshold; review before merge."
      : "_No regressions past the threshold._",
  );
  console.log(out.join("\n"));
}

main();
