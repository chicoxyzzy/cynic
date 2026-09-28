#!/usr/bin/env python3
"""Contract tests for the WPT shell orchestrator (no engine build required)."""
import contextlib
import copy
from datetime import datetime
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('wpt_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


def protocol(*events):
    return '\n'.join('@@WPT@@' + json.dumps(event) for event in events)


def result(name='example', status=0):
    return dict(type='result', name=name, status=status, message=None)


def complete(status=0):
    return dict(type='complete', status=status, message=None)


class MetadataTests(unittest.TestCase):
    def test_globals_scripts_timeout_and_variants(self):
        meta = runner.parse_metadata('''// META: global=window,jsshell
// META: script=/wasm/jsapi/wasm-module-builder.js
// META: script=../helper.js
// META: timeout=long
// META: variant=?a
// META: variant=
''')
        self.assertEqual(meta['globals'], ['window', 'jsshell'])
        self.assertEqual(meta['scripts'], ['/wasm/jsapi/wasm-module-builder.js', '../helper.js'])
        self.assertEqual(meta['variants'], ['?a', ''])
        self.assertEqual(meta['timeout'], 'long')

    def test_base_variant_only_when_unspecified(self):
        self.assertEqual(runner.parse_metadata('')['variants'], [''])
        self.assertEqual(runner.parse_metadata('// META: variant=?x')['variants'], ['?x'])

    def test_default_globals_follow_wpt_and_normal_timeout_is_accepted(self):
        self.assertEqual(runner.parse_metadata('')['globals'], ['window', 'dedicatedworker'])
        self.assertEqual(runner.parse_metadata('// META: timeout=normal')['timeout'], 'normal')

    def test_duplicate_variants_rejected(self):
        with self.assertRaises(ValueError):
            runner.parse_metadata('// META: variant=?x\n// META: variant=?x')

    def test_invalid_timeout_rejected(self):
        with self.assertRaises(ValueError):
            runner.parse_metadata('// META: timeout=forever')

    def test_dependencies_resolve_inside_vendor(self):
        self.assertEqual(runner.resolve_script('wasm/jsapi/foo/a.any.js', '../helper.js'), 'wasm/jsapi/helper.js')
        self.assertEqual(runner.resolve_script('wasm/jsapi/a.any.js', '/common/utils.js'), 'common/utils.js')
        for value in ('https://example.test/a.js', '../../../secret.js', '/../../secret.js', 'a.js?x', '//host/file.js', '%2e%2e/file.js'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                runner.resolve_script('wasm/jsapi/a.any.js', value)

    def test_patch_is_exact_and_fails_on_changed_upstream(self):
        source = r'prefix (?:{(.*)}\s*|(.*)) suffix'
        self.assertEqual(runner.patch_harness(source), r'prefix (?:\{(.*)\}\s*|(.*)) suffix')
        for bad in ('unrelated source', source + source):
            with self.assertRaises(ValueError):
                runner.patch_harness(bad)

    def test_builder_patch_is_narrow_and_upstream_changes_fail_closed(self):
        original = 'let string_utf8 = unescape(encodeURIComponent(string));'
        patched = runner.patch_support('wasm/jsapi/wasm-module-builder.js', original)
        self.assertNotIn('unescape(', patched)
        self.assertIn('encodeURIComponent(string)', patched)
        self.assertEqual(runner.patch_support('wasm/jsapi/unrelated.js', original), original)
        for source in ('changed upstream', original + '\n' + original):
            with self.assertRaises(ValueError):
                runner.patch_support('wasm/jsapi/wasm-module-builder.js', source)

    @unittest.skipUnless(shutil.which('node'), 'Node is an optional reference for support-patch equivalence')
    def test_builder_utf8_patch_preserves_byte_string_and_error_semantics(self):
        original = 'let string_utf8 = unescape(encodeURIComponent(string));'
        patched = runner.patch_support('wasm/jsapi/wasm-module-builder.js', original)
        source = ('function original(string) {' + original + 'return string_utf8;}\n' +
                  'function patched(string) {' + patched + 'return string_utf8;}\n' + r'''
const samples = ['', 'ASCII !~*\'()', '%00%u1234', '\x00\x80\xff', 'é漢😀', '\ud800', '\udfff', 42, null, undefined];
function observe(fn, value) {
  try { return {bytes: Array.from(fn(value), char => char.charCodeAt(0))}; }
  catch (error) { return {error: error.name}; }
}
for (const sample of samples) {
  if (JSON.stringify(observe(original, sample)) !== JSON.stringify(observe(patched, sample))) throw new Error('different bytes or error');
}
let calls = 0;
const value = {toString() { ++calls; return 'é😀'; }};
patched(value);
if (calls !== 1) throw new Error('different coercion count');
''')
        completed = subprocess.run([shutil.which('node'), '-e', source], capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)


class ProtocolTests(unittest.TestCase):
    def test_normal_and_subtest_failure(self):
        self.assertEqual(runner.parse_output(protocol(result(), complete()), 0)['status'], 'pass')
        parsed = runner.parse_output(protocol(result(status=1), complete()), 0)
        self.assertEqual(parsed['status'], 'fail')
        self.assertEqual(parsed['subtests'][0]['status'], 1)

    def test_unfinished_empty_and_harness_errors_never_pass(self):
        for output, status in (
            ('', 'incomplete'), (protocol(result()), 'incomplete'),
            (protocol(complete()), 'no_tests'),
            (protocol(result(), complete(1)), 'harness_error'),
        ):
            with self.subTest(status=status):
                self.assertEqual(runner.parse_output(output, 0)['status'], status)

    def test_process_errors_override_complete(self):
        output = protocol(result(), complete())
        self.assertEqual(runner.parse_output(output, 1)['status'], 'execution_error')
        self.assertEqual(runner.parse_output(output, -11)['status'], 'crash')

    def test_strict_protocol(self):
        outputs = [
            '@@WPT@@broken', protocol({'type': 'result', 'status': 0}),
            protocol(result(status=True)), protocol(result(status=9)),
            protocol(result(), result(), complete()),
            protocol(complete(), complete()), protocol(complete(), result()),
            protocol({'type': 'unknown'}),
            protocol(dict(type='complete', status=0, message=[])),
        ]
        for output in outputs:
            with self.subTest(output=output):
                self.assertEqual(runner.parse_output(output, 0)['status'], 'protocol_error')

    def test_nonprotocol_output_ignored(self):
        output = 'fixture log\n' + protocol(result(), complete()) + '\nmore log'
        self.assertEqual(runner.parse_output(output, 0)['status'], 'pass')

    def test_unicode_line_separators_inside_json_are_not_record_delimiters(self):
        for separator in ('\u0085', '\u2028', '\u2029'):
            name = 'name' + separator + 'continues'
            output = '\n'.join('@@WPT@@' + json.dumps(event, ensure_ascii=False)
                               for event in (result(name), complete()))
            parsed = runner.parse_output(output, 0)
            with self.subTest(separator=repr(separator)):
                self.assertEqual(parsed['status'], 'pass')
                self.assertEqual(parsed['subtests'][0]['name'], name)


class ExecutionTests(unittest.TestCase):
    def test_real_child_success_failure_and_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            child = Path(directory) / 'child.py'
            child.write_text('import sys\nprint(' + repr(protocol(result(), complete())) + ')\nsys.exit(int(sys.argv[1]))\n')
            passed = runner.execute_command([sys.executable, str(child), '0'], timeout=2)
            self.assertEqual(passed['status'], 'pass')
            failed = runner.execute_command([sys.executable, str(child), '3'], timeout=2)
            self.assertEqual(failed['status'], 'execution_error')
            child.write_text('import time\ntime.sleep(5)\n')
            timed_out = runner.execute_command([sys.executable, str(child)], timeout=0.05)
            self.assertEqual(timed_out['status'], 'timeout')

    def test_missing_binary_is_reported(self):
        report = runner.execute_command(['/missing/wpt/binary'], timeout=1)
        self.assertEqual(report['status'], 'execution_error')

    def test_output_is_bounded(self):
        report = runner.execute_command([sys.executable, '-c', 'print("x" * 1000)'], timeout=2, max_output_bytes=100)
        self.assertEqual(report['status'], 'output_limit')


class ProvenanceTests(unittest.TestCase):
    def test_host_timestamp_revision_and_dirty_state_are_recorded(self):
        revision = 'a' * 40
        responses = [subprocess.CompletedProcess([], 0, revision + '\n', ''),
                     subprocess.CompletedProcess([], 0, ' M build.zig\n?? tools/wpt/\n', '')]
        with mock.patch.object(runner.subprocess, 'run', side_effect=responses) as run:
            provenance = runner.capture_provenance()
        timestamp = datetime.fromisoformat(provenance['generated_at_utc'].replace('Z', '+00:00'))
        self.assertIsNotNone(timestamp.tzinfo)
        self.assertTrue(provenance['platform'])
        self.assertTrue(provenance['architecture'])
        self.assertEqual(provenance['engine_git_head'], revision)
        self.assertIs(provenance['engine_git_dirty'], True)
        self.assertEqual(run.call_count, 2)
        self.assertTrue(all(call.kwargs['timeout'] <= 5 for call in run.call_args_list))

    def test_git_failure_is_best_effort(self):
        with mock.patch.object(runner.subprocess, 'run', side_effect=OSError('git unavailable')):
            provenance = runner.capture_provenance()
        self.assertIsNone(provenance['engine_git_head'])
        self.assertIsNone(provenance['engine_git_dirty'])

    def test_clean_git_tree_is_distinct_from_unavailable(self):
        responses = [subprocess.CompletedProcess([], 0, 'b' * 40 + '\n', ''),
                     subprocess.CompletedProcess([], 0, '', '')]
        with mock.patch.object(runner.subprocess, 'run', side_effect=responses):
            self.assertIs(runner.capture_provenance()['engine_git_dirty'], False)


class BaselineTests(unittest.TestCase):
    def report(self):
        return dict(schema_version=1, corpus_revision='abc', results=[
            dict(id='a.any.js', status='fail', subtests=[result('good'), result('bad', 1)]),
            dict(id='b.any.js?x', status='pass', subtests=[result('also good')]),
        ])

    def test_existing_failures_permitted_and_improvements_permitted(self):
        before = self.report()
        self.assertEqual(runner.compare_baseline(before, self.report()), [])
        after = self.report()
        after['results'][0]['subtests'][1]['status'] = 0
        after['results'][0]['status'] = 'pass'
        self.assertEqual(runner.compare_baseline(before, after), [])

    def test_regressions_and_disappearing_members_detected(self):
        before = self.report()
        changes = [
            lambda x: x['results'][0]['subtests'][0].update(status=1),
            lambda x: x['results'][0]['subtests'].pop(),
            lambda x: x['results'].pop(),
            lambda x: x['results'][1].update(status='incomplete'),
            lambda x: x.update(corpus_revision='different'),
        ]
        for change in changes:
            after = self.report()
            change(after)
            with self.subTest(after=after):
                self.assertTrue(runner.compare_baseline(before, after))

    def test_new_corpus_members_require_explicit_baseline_refresh(self):
        before = self.report()
        after = self.report()
        after['results'].append(dict(id='new.any.js', status='pass', subtests=[result()]))
        self.assertTrue(runner.compare_baseline(before, after))

    def test_malformed_baselines_are_rejected_with_clear_errors(self):
        malformed = [[], {}, dict(schema_version=1, corpus_revision='abc', results=[None]),
                     dict(schema_version=1, corpus_revision='abc', results=[{'id': 'x', 'status': 'pass', 'subtests': []}])]
        for report in malformed:
            with self.subTest(report=report), self.assertRaises(ValueError):
                runner.validate_report(report)

    def test_already_failing_subtest_cannot_degrade_to_timeout_or_notrun(self):
        for status in (2, 3, 4):
            after = self.report()
            after['results'][0]['subtests'][1]['status'] = status
            with self.subTest(status=status):
                self.assertTrue(runner.compare_baseline(self.report(), after))

    def test_existing_error_cannot_hide_changed_exit_or_harness_status(self):
        for old_fields, new_fields in (
            ({'status': 'execution_error', 'returncode': 1}, {'returncode': 2}),
            ({'status': 'harness_error', 'harness': {'status': 1}}, {'harness': {'status': 2}}),
        ):
            before = self.report()
            before['results'][0].update(old_fields)
            after = copy.deepcopy(before)
            after['results'][0].update(new_fields)
            self.assertTrue(runner.compare_baseline(before, after))

    def test_adapter_changes_require_review_but_engine_changes_do_not(self):
        before = self.report()
        before.update(adapter_sha256={'run.py': 'old'}, binary_sha256='engine-before')
        after = copy.deepcopy(before)
        after['binary_sha256'] = 'engine-after'
        before['provenance'] = {'generated_at_utc': 'before', 'platform': 'old host'}
        after['provenance'] = {'generated_at_utc': 'after', 'platform': 'different host'}
        self.assertEqual(runner.compare_baseline(before, after), [])
        after['adapter_sha256']['run.py'] = 'changed'
        self.assertTrue(runner.compare_baseline(before, after))


class CorpusAndCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        files = {
            'wasm/jsapi/test.any.js': '// META: global=jsshell\n// META: script=helper.js\n',
            'wasm/jsapi/helper.js': '// support file\n',
            'wasm/jsapi/browser.any.js': '// browser-only fixture\n',
            'resources/testharness.js': r'// (?:{(.*)}\s*|(.*))',
        }
        hashes = {}
        for name, source in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            hashes[name] = {'sha256': hashlib.sha256(source.encode()).hexdigest()}
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text(json.dumps({
            'schema_version': 1, 'upstream': {'revision': 'abc'}, 'files': hashes,
            'tests': [
                {'path': 'wasm/jsapi/test.any.js', 'scripts': ['wasm/jsapi/helper.js'],
                 'variants': [''], 'globals': ['jsshell'], 'timeout': 'normal', 'excluded_reason': None},
                {'path': 'wasm/jsapi/browser.any.js', 'scripts': [], 'variants': [''],
                 'globals': ['window', 'dedicatedworker'], 'timeout': 'normal', 'excluded_reason': 'No jsshell global'},
            ],
        }))
        self.binary = self.root / 'fake-binary'
        self.binary.touch()
        self.args = ['--binary', str(self.binary), '--manifest', str(self.manifest)]

    def main(self, extra):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return runner.main(self.args + extra)

    def test_load_includes_base_case_and_explicit_exclusions(self):
        _, cases, exclusions, fingerprint = runner.load_corpus(self.manifest)
        self.assertEqual([case['variant'] for case in cases], [''])
        self.assertEqual(len(exclusions), 1)
        self.assertEqual(len(fingerprint), 64)
        self.assertEqual(self.main(['--list']), 0)
        self.assertEqual(self.main(['--list', '--filter=absent']), 2)

    def test_nonempty_variants_fail_before_execution_until_host_semantics_exist(self):
        fixture = self.root / 'wasm/jsapi/test.any.js'
        fixture.write_text(fixture.read_text() + '// META: variant=?different-semantics\n')
        manifest = json.loads(self.manifest.read_text())
        manifest['files']['wasm/jsapi/test.any.js']['sha256'] = hashlib.sha256(fixture.read_bytes()).hexdigest()
        manifest['tests'][0]['variants'] = ['?different-semantics']
        self.manifest.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'variant.*host semantics'):
            runner.load_corpus(self.manifest)
        with mock.patch.object(runner, 'execute_command') as execute:
            self.assertEqual(self.main([]), 2)
            execute.assert_not_called()

    def test_support_patch_is_temporary_and_recorded_in_provenance(self):
        name = 'wasm/jsapi/wasm-module-builder.js'
        original = 'let string_utf8 = unescape(encodeURIComponent(string));'
        support = self.root / name
        support.write_text(original)
        fixture = self.root / 'wasm/jsapi/test.any.js'
        fixture.write_text('// META: global=jsshell\n// META: script=/wasm/jsapi/wasm-module-builder.js\n')
        manifest = json.loads(self.manifest.read_text())
        manifest['files'][name] = {'sha256': hashlib.sha256(support.read_bytes()).hexdigest()}
        manifest['files']['wasm/jsapi/test.any.js']['sha256'] = hashlib.sha256(fixture.read_bytes()).hexdigest()
        manifest['tests'][0]['scripts'] = [name]
        self.manifest.write_text(json.dumps(manifest))

        def execute(command, timeout):
            patched = next(Path(path) for path in command if path.endswith('/wasm-module-builder.js'))
            self.assertNotEqual(patched, support)
            self.assertNotIn('unescape(', patched.read_text())
            return dict(runner.parse_output(protocol(result(), complete()), 0), stdout='', stderr='', duration_seconds=0)

        output = self.root / 'report.json'
        with mock.patch.object(runner, 'execute_command', side_effect=execute):
            self.assertEqual(self.main(['--json-out', str(output)]), 0)
        self.assertEqual(support.read_text(), original)
        self.assertIn(name + ' (patched)', json.loads(output.read_text())['adapter_sha256'])

    def test_changed_source_missing_dependency_and_unlisted_fixture_rejected(self):
        fixture = self.root / 'wasm/jsapi/test.any.js'
        original = fixture.read_bytes()
        fixture.write_text('// changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            runner.load_corpus(self.manifest)
        fixture.write_bytes(original)
        (self.root / 'wasm/jsapi/new.any.js').write_text('// unlisted')
        with self.assertRaisesRegex(ValueError, 'enumerate every'):
            runner.load_corpus(self.manifest)
        (self.root / 'wasm/jsapi/new.any.js').unlink()
        (self.root / 'wasm/jsapi/helper.js').unlink()
        with self.assertRaisesRegex(ValueError, 'missing corpus file'):
            runner.load_corpus(self.manifest)

    def test_execution_order_and_json_output(self):
        invocations = []

        def execute(command, timeout):
            script_paths = [Path(path) for path in command[3:]]
            invocations.append(([path.name for path in script_paths], script_paths[0].read_text(), timeout))
            return dict(runner.parse_output(protocol(result(), complete()), 0), stdout='', stderr='', duration_seconds=0)

        output = self.root / 'results.json'
        with mock.patch.object(runner, 'execute_command', side_effect=execute):
            self.assertEqual(self.main(['--json-out', str(output)]), 0)
        self.assertEqual(len(invocations), 1)
        self.assertEqual(invocations[0][0], ['environment.js', 'bootstrap.js', 'testharness.js', 'reporter.js', 'helper.js', 'test.any.js', 'finish.js'])
        self.assertIn('globalThis.__wpt_variant = "";', invocations[0][1])
        report = json.loads(output.read_text())
        self.assertEqual(len(report['results']), 1)
        self.assertEqual(report['summary']['files'], {'pass': 1})
        self.assertEqual(set(report['adapter_sha256']), {'run.py', 'case.zig', 'bootstrap.js', 'reporter.js', 'finish.js', 'testharness.js (patched)'})
        self.assertEqual(len(report['binary_sha256']), 64)
        self.assertIn('generated_at_utc', report['provenance'])

    def test_failures_are_visible_and_baseline_is_explicit(self):
        outcome = dict(runner.parse_output(protocol(result(status=1), complete()), 0), stdout='', stderr='', duration_seconds=0)
        baseline = self.root / 'baseline.json'
        with mock.patch.object(runner, 'execute_command', side_effect=lambda *args: copy.deepcopy(outcome)):
            self.assertEqual(self.main([]), 1)
            self.assertEqual(self.main(['--write-baseline', str(baseline)]), 1)
            self.assertTrue(baseline.is_file())
            self.assertEqual(self.main(['--baseline', str(baseline)]), 0)

    def test_baseline_rejects_filtered_selection(self):
        with self.assertRaises(SystemExit) as error:
            self.main(['--filter=test', '--write-baseline', str(self.root / 'baseline.json')])
        self.assertEqual(error.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
