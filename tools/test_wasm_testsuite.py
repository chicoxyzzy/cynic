#!/usr/bin/env python3
"""Exercise the actual Wasm harness's scoring and process exit contract."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
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
COUNTER = (EMPTY + b'\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00'
           + b'\x06\x06\x01\x7f\x01\x41\x00\x0b\x07\x05\x01\x01f\x00\x00'
           + b'\x0a\x0d\x01\x0b\x00\x23\x00\x41\x01\x6a\x24\x00\x23\x00\x0b')
GENERATOR = Path(__file__).with_name('wasm-testsuite-gen.sh')
FEATURES = ('tail-call', 'relaxed-simd', 'memory64', 'extended-const',
            'multi-memory', 'function-references')
FAKE_CONVERTER = '''import json, os, pathlib, sys
args = sys.argv[1:]
features = json.loads(os.environ['WABT_FEATURES'])
if args == ['--help']:
    for feature, prefix in features.items():
        print('--' + prefix + '-' + feature + ' feature')
    sys.exit(0)
with open(os.environ['WABT_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
allowed = {'--' + prefix + '-' + feature for feature, prefix in features.items()}
for arg in args:
    if arg.startswith('--') and arg not in allowed:
        sys.exit('unknown option ' + arg)
source = pathlib.Path(args[args.index('-o') - 1])
output = pathlib.Path(args[args.index('-o') + 1])
output.write_text('{"commands": []}')
if os.environ.get('WABT_BROKEN') or source.name.startswith('bad'):
    sys.exit('converter diagnostic: rejected ' + source.name)
'''


def module_command(name='case.wasm', kind='module'):
    return {'type': kind, 'filename': name, 'module_type': 'binary'}


class WasmGeneratorContract(unittest.TestCase):
    def run_generator(self, features, sources=('good.wast',), broken=False):
        with tempfile.TemporaryDirectory(prefix='cynic-wasm-generator-') as directory:
            root = Path(directory)
            corpus, output, binary = root / 'corpus', root / 'output', root / 'bin'
            for path in (corpus, output, binary):
                path.mkdir()
            for name in sources:
                (corpus / name).write_text('(module)\n')
            (output / 'stale.json').write_text('{}')
            converter = binary / 'wast2json'
            converter.write_text('#!' + sys.executable + '\n' + FAKE_CONVERTER)
            converter.chmod(0o755)
            calls = root / 'calls.jsonl'
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                       WABT_FEATURES=json.dumps(features), WABT_CALLS=str(calls))
            if broken:
                env['WABT_BROKEN'] = '1'
            result = subprocess.run(['sh', str(GENERATOR), str(corpus), str(output)],
                                    env=env, capture_output=True, text=True, timeout=30)
            invocations = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, invocations, {path.name for path in output.iterdir()}

    def test_legacy_wabt_receives_all_required_enable_flags(self):
        result, calls, files = self.run_generator(dict.fromkeys(FEATURES, 'enable'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {'good.json'})
        self.assertIn('converted 1 .wast file(s)', result.stderr)
        for call in calls:
            self.assertEqual({arg for arg in call if arg.startswith('--')},
                             {'--enable-' + feature for feature in FEATURES})

    def test_default_on_features_do_not_receive_removed_enable_flags(self):
        features = dict.fromkeys(FEATURES, 'disable')
        features['function-references'] = 'enable'
        result, calls, files = self.run_generator(features)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(files, {'good.json'})
        for call in calls:
            self.assertEqual([arg for arg in call if arg.startswith('--')],
                             ['--enable-function-references'])

    def test_unknown_required_feature_fails_before_conversion(self):
        features = dict.fromkeys(FEATURES, 'enable')
        del features['memory64']
        result, calls, files = self.run_generator(features)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('memory64', result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(files, {'stale.json'})

    def test_broken_converter_fails_smoke_check_with_its_diagnostic(self):
        result, calls, files = self.run_generator(dict.fromkeys(FEATURES, 'enable'), broken=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('converter diagnostic:', result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(files, {'stale.json'})

    def test_unsupported_file_is_skipped_without_leaving_a_partial_manifest(self):
        result, _, files = self.run_generator(dict.fromkeys(FEATURES, 'enable'),
                                             sources=('bad.wast', 'good.wast'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('bad.wast (skipped)', result.stderr)
        self.assertEqual(files, {'good.json'})

    def test_zero_converted_files_is_a_generation_failure(self):
        for sources in ((), ('bad.wast',)):
            with self.subTest(sources=sources):
                result, _, files = self.run_generator(dict.fromkeys(FEATURES, 'enable'), sources=sources)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('converted 0 .wast file(s)', result.stderr)
                self.assertEqual(files, set())


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

    def test_module_definition_validates_without_running_start_or_changing_current(self):
        result = self.run_harness([
            module_command('constant.wasm'),
            dict(module_command(), definition='true', name='$M'),
            {'type': 'assert_return', 'action': {'type': 'invoke', 'field': 'f', 'args': []},
             'expected': [{'type': 'i32', 'value': '42'}]},
        ], {'constant.wasm': CONSTANT, 'case.wasm': TRAPPING_START}, options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_summary(result, 3, 3)

    def test_explicit_instances_have_independent_state(self):
        commands = [dict(module_command(), definition='true', name='$M'),
                    {'type': 'instance', 'definition': '$M', 'instance': '$I1'},
                    {'type': 'instance', 'definition': '$M', 'instance': '$I2'}]
        for instance, expected in (('$I1', 1), ('$I1', 2), ('$I2', 1)):
            commands.append({'type': 'assert_return',
                             'action': {'type': 'invoke', 'module': instance, 'field': 'f', 'args': []},
                             'expected': [{'type': 'i32', 'value': str(expected)}]})
        result = self.run_harness(commands, {'case.wasm': COUNTER}, options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_summary(result, 6, 6)

    def test_definition_start_traps_only_when_explicitly_instantiated(self):
        result = self.run_harness([
            dict(module_command(), definition='true', name='$M'),
            {'type': 'instance', 'definition': '$M', 'instance': '$I'},
        ], {'case.wasm': TRAPPING_START}, options=('--min-pass-pct=100',))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assert_summary(result, 1, 2)

    def test_missing_definition_is_a_manifest_error(self):
        result = self.run_harness([{'type': 'instance', 'definition': '$missing'}])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('harness error', result.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[__file__, *remaining])
