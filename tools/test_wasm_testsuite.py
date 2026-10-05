#!/usr/bin/env python3
"""Exercise the actual Wasm harness's scoring and process exit contract."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

BINARY = None
EMPTY = b'\x00asm\x01\x00\x00\x00'
IMPORTED_START = (EMPTY + b'\x01\x04\x01\x60\x00\x00'
                  + b'\x02\x12\x01\x08spectest\x05print\x00\x00\x08\x01\x00')
TRAPPING_START = (EMPTY + b'\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00'
                  + b'\x08\x01\x00\x0a\x05\x01\x03\x00\x00\x0b')
CONSTANT = (EMPTY + b'\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00'
            + b'\x07\x05\x01\x01f\x00\x00\x0a\x06\x01\x04\x00\x41\x2a\x0b')


def module_command(name='case.wasm', kind='module'):
    return {'type': kind, 'filename': name, 'module_type': 'binary'}


class WasmHarnessContract(unittest.TestCase):
    def run_harness(self, commands, files=None, extra_manifests=None, options=()):
        with tempfile.TemporaryDirectory(prefix='cynic-wasm-scoring-') as directory:
            root = Path(directory)
            (root / 'case.json').write_text(json.dumps({'commands': commands}), encoding='utf-8')
            for name, contents in (files or {}).items():
                (root / name).write_bytes(contents)
            for name, contents in (extra_manifests or {}).items():
                (root / name).write_text(contents, encoding='utf-8')
            return subprocess.run([str(BINARY), '--gen-dir=' + directory, '--quiet', *options],
                                  capture_output=True, text=True, timeout=30)

    def assert_summary(self, result, passed, scored, skipped=0):
        match = re.search(r'wasm spec testsuite: (\d+)/(\d+) pass .*?, (\d+) skip', result.stdout)
        self.assertIsNotNone(match, result.stdout + result.stderr)
        self.assertEqual(tuple(map(int, match.groups())), (passed, scored, skipped),
                         result.stdout + result.stderr)

    def test_standalone_modules_count_and_clear_the_full_success_gate(self):
        for binary in (EMPTY, IMPORTED_START):
            with self.subTest(binary=binary):
                result = self.run_harness([module_command()], {'case.wasm': binary},
                                          options=('--min-pass-pct=100',))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_summary(result, 1, 1)

    def test_standalone_start_trap_fails_the_gate_even_after_a_successful_module(self):
        result = self.run_harness([module_command('good.wasm'), module_command()],
                                  {'good.wasm': EMPTY, 'case.wasm': TRAPPING_START},
                                  options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assert_summary(result, 1, 2)

    def test_missing_module_cannot_pass_an_uninstantiable_assertion(self):
        result = self.run_harness([module_command(kind='assert_uninstantiable')],
                                  options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('harness error', result.stderr)
        self.assertIn('case.json', result.stderr)
        self.assertIn('FileNotFound', result.stderr)

    def test_bad_manifest_is_fatal_even_in_quiet_mode_without_a_score_floor(self):
        commands = [module_command(), {'type': 'assert_return',
                    'action': {'type': 'invoke', 'field': 'f', 'args': []},
                    'expected': [{'type': 'i32', 'value': '42'}]}]
        for source in ('{', '{"commands":"not an array"}'):
            with self.subTest(source=source):
                result = self.run_harness(commands, {'case.wasm': CONSTANT},
                                          {'broken.json': source})
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('broken.json: harness error', result.stderr)

    def test_text_forms_are_explicitly_skipped(self):
        result = self.run_harness([
            module_command(), {'type': 'module', 'filename': 'quoted.wat', 'module_type': 'text'},
            {'type': 'assert_uninstantiable', 'filename': 'quoted.wat', 'module_type': 'text'},
        ], {'case.wasm': EMPTY}, options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_summary(result, 1, 1, 2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[__file__, *remaining])
