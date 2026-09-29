#!/usr/bin/env python3
"""Integration contracts for the isolated Cynic WPT executor.

Run explicitly with --binary=PATH, or set WPT_CASE_BINARY. This file does
not run the integration suite during unittest discovery.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BINARY = None
HARNESS = None
PREFIX = "@@WPT@@"


class CaseFixture:
    def execute(self, *sources, options=(), harness=False):
        with tempfile.TemporaryDirectory(prefix="cynic-wpt-case-") as temp:
            directory = Path(temp)
            scripts = []
            if harness:
                from run import patch_harness

                harness_script = directory / "testharness.js"
                harness_script.write_text(patch_harness(HARNESS.read_text(encoding="utf-8")),
                                          encoding="utf-8")
                scripts.extend([ROOT / "tools/wpt/bootstrap.js", harness_script,
                                ROOT / "tools/wpt/reporter.js"])
            for index, source in enumerate(sources):
                script = directory / (str(index) + ".js")
                script.write_text(source, encoding="utf-8")
                scripts.append(script)
            if harness:
                scripts.append(ROOT / "tools/wpt/finish.js")
            return subprocess.run([str(BINARY), *options, *map(str, scripts)],
                                  capture_output=True, text=True, timeout=20)

    def records(self, result):
        return [json.loads(line[len(PREFIX):])
                for line in result.stdout.split("\n") if line.startswith(PREFIX)]


class ExecutorContract(CaseFixture, unittest.TestCase):
    def test_print_and_shared_global_scripts(self):
        result = self.execute("var answer = 40; print('first');",
                              "print(answer + 2);")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["first", "42"])

    def test_microtasks_drain_after_all_scripts(self):
        result = self.execute("Promise.resolve().then(() => print('job')); print('one');",
                              "print('two');")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["one", "two", "job"])

    def test_uncaught_exception_stops_execution(self):
        result = self.execute("throw new Error('fixture-exception');", "print('not reached');")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("not reached", result.stdout)
        self.assertIn("fixture-exception", result.stderr)

    def test_parse_failure_is_nonzero(self):
        result = self.execute("let = ;")
        self.assertNotEqual(result.returncode, 0)

    def test_fuel_termination_is_uncatchable(self):
        result = self.execute("print('entered'); try { while (true) {} } catch (_) { print('caught'); }",
                              options=("--fuel=10000",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("entered", result.stdout)
        self.assertNotIn("caught", result.stdout)

    def test_mutable_intrinsics_eval_and_wasm_compilation(self):
        result = self.execute("""
            Array.prototype.wptProbe = 7;
            if ([].wptProbe !== 7) throw new Error('frozen intrinsics');
            if (eval('6 * 7') !== 42) throw new Error('eval disabled');
            const bytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
            const module = new WebAssembly.Module(bytes);
            if (!(module instanceof WebAssembly.Module)) throw new Error('wasm disabled');
            print('enabled');
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "enabled")

    def assert_compile_capability_survives_collection(self, byte_source, expected_type):
        # Independent callbacks do not retain the capability's returned object.
        # Allocation-pressure safe points expose the missing native handle;
        # explicit GC's conservative native-stack scan can mask it.
        result = self.execute("""
            let settled;
            function settle(value) {
                for (let i = 0; i < 1000; i++) { const temporary = {i}; }
                settled = value;
            }
            globalThis.Promise = function (executor) {
                executor(settle, settle);
                return {marker: 42};
            };
            const result = WebAssembly.compile(new Uint8Array(BYTES));
            if (result.marker !== 42) throw new Error('collected capability result');
            if (!(settled instanceof EXPECTED)) throw new Error('wrong settlement');
            print('retained');
        """.replace("BYTES", byte_source).replace("EXPECTED", expected_type),
            options=("--gc-threshold=1",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "retained")

    def test_compile_capability_survives_collecting_resolve(self):
        self.assert_compile_capability_survives_collection(
            "[0,97,115,109,1,0,0,0]", "WebAssembly.Module")

    def test_compile_capability_survives_collecting_reject(self):
        self.assert_compile_capability_survives_collection(
            "[0]", "WebAssembly.CompileError")


class HarnessContract(CaseFixture, unittest.TestCase):
    def completed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records(result)
        completions = [record for record in records if record["type"] == "complete"]
        self.assertEqual(len(completions), 1, result.stdout)
        self.assertEqual(completions[0]["status"], 0, result.stdout)
        return [record for record in records if record["type"] == "result"]

    def test_sync_pass_and_shell_surface(self):
        result = self.execute("""
            test(() => {
                assert_equals(self, globalThis);
                assert_false('document' in self);
                assert_false('addEventListener' in self);
                assert_false('setTimeout' in self);
                assert_equals(typeof console.debug, 'function');
            }, 'shell surface');
            test(() => assert_equals(6 * 7, 42), 'sync pass');
        """, harness=True)
        records = self.completed(result)
        self.assertEqual([(r["name"], r["status"]) for r in records],
                         [("shell surface", 0), ("sync pass", 0)])

    def test_sync_assertion_failure_is_a_failed_subtest(self):
        result = self.execute("test(() => assert_equals(1, 2), 'sync fail');", harness=True)
        records = self.completed(result)
        self.assertEqual([(r["name"], r["status"]) for r in records], [("sync fail", 1)])
        self.assertIn("assert_equals", records[0]["message"])

    def test_unicode_line_separators_preserve_report_framing(self):
        result = self.execute(r"test(() => assert_true(true), 'name\u0085\u2028\u2029');",
                              harness=True)
        records = self.completed(result)
        self.assertEqual([(r["name"], r["status"]) for r in records],
                         [("name\u0085\u2028\u2029", 0)])

    def test_promise_and_async_test_completion(self):
        result = self.execute("""
            promise_test(() => Promise.resolve().then(() => assert_true(true)), 'promise pass');
            async_test(t => {
                Promise.resolve().then(t.step_func_done(() => assert_true(true)));
            }, 'async pass');
        """, harness=True)
        records = self.completed(result)
        self.assertEqual(sorted((r["name"], r["status"]) for r in records),
                         [("async pass", 0), ("promise pass", 0)])

    def test_rejected_promise_is_a_failed_subtest(self):
        result = self.execute("""
            promise_test(() => Promise.reject(new Error('promise-rejection')), 'promise fail');
        """, harness=True)
        records = self.completed(result)
        self.assertEqual([(r["name"], r["status"]) for r in records], [("promise fail", 1)])
        self.assertIn("promise-rejection", records[0]["message"])

    def test_pending_promise_does_not_emit_completion(self):
        result = self.execute("promise_test(() => new Promise(() => {}), 'pending');", harness=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(r["type"] == "complete" for r in self.records(result)), result.stdout)

    def test_throw_before_completion_is_nonzero(self):
        result = self.execute("throw new Error('before-complete');", harness=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("before-complete", result.stderr)
        self.assertFalse(any(r["type"] == "complete" for r in self.records(result)), result.stdout)

    def test_throw_after_completion_is_nonzero(self):
        # A no-tests done() emits the harness error synchronously. A subsequent
        # script exception must still control the executor's exit status.
        result = self.execute("done(); throw new Error('after-complete');", harness=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("after-complete", result.stderr)
        self.assertTrue(any(r["type"] == "complete" for r in self.records(result)), result.stdout)


class ModuleBuilderContract(CaseFixture, unittest.TestCase):
    def builder_source(self):
        from run import patch_support

        path = "wasm/jsapi/wasm-module-builder.js"
        source = (ROOT / "vendor/wpt" / path).read_text(encoding="utf-8")
        return patch_support(path, source)

    def test_utf8_byte_strings_without_annex_b_global(self):
        cases = {
            "ASCII": "ASCII !~*'()-_",
            "BMP": "\u00e9\u4e2d",
            "supplementary": "\U0001f600",
            "percent": "100% %41 %u0041",
            "NUL": "a\x00b",
            "empty": "",
        }
        builder = self.builder_source()
        for label, source in cases.items():
            with self.subTest(label=label):
                result = self.execute(builder, """
                    if ('unescape' in globalThis) throw new Error('unexpected Annex B global');
                    const binary = new Binary();
                    binary.emit_string(INPUT);
                    print(JSON.stringify(Array.from(binary.trunc_buffer())));
                    if ('unescape' in globalThis) throw new Error('leaked Annex B global');
                """.replace("INPUT", json.dumps(source)))
                self.assertEqual(result.returncode, 0, result.stderr)
                encoded = list(source.encode("utf-8"))
                self.assertEqual(json.loads(result.stdout), [len(encoded), *encoded])

    def test_lone_surrogates_retain_uri_error(self):
        result = self.execute(self.builder_source(), r"""
            if ('unescape' in globalThis) throw new Error('unexpected Annex B global');
            for (const source of ['\ud800', '\udc00']) {
                const binary = new Binary();
                let rejected = false;
                try {
                    binary.emit_string(source);
                } catch (error) {
                    if (!(error instanceof URIError)) throw error;
                    rejected = true;
                }
                if (!rejected) throw new Error('lone surrogate accepted');
                if (binary.length !== 0) throw new Error('bytes emitted before URIError');
            }
            if ('unescape' in globalThis) throw new Error('leaked Annex B global');
            print('rejected');
        """)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "rejected")


def load_tests(_loader, tests, _pattern):
    # Generic Python discovery exercises only the build-independent suites.
    # These real-engine tests require the explicit entry point below.
    return tests if BINARY is not None else unittest.TestSuite()


def main():
    global BINARY, HARNESS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=os.environ.get("WPT_CASE_BINARY"))
    parser.add_argument("--harness", type=Path,
                        default=ROOT / "vendor/wpt/resources/testharness.js")
    options, unittest_args = parser.parse_known_args()
    if not options.binary:
        parser.error("--binary or WPT_CASE_BINARY is required")
    BINARY = Path(options.binary).resolve()
    HARNESS = options.harness.resolve()
    unittest.main(argv=[__file__, *unittest_args])


if __name__ == "__main__":
    main()
