#!/usr/bin/env python3
"""Contracts for the required normal-versus-GC WPT comparison."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest

from compare_profiles import compare_profiles, main


def report(stress=False):
    return {
        'schema_version': 1,
        'corpus_revision': 'a' * 40,
        'manifest_sha256': 'b' * 64,
        'adapter_sha256': {'case.zig': 'c' * 64, 'run.py': 'd' * 64},
        'binary_sha256': ('e' if stress else 'f') * 64,
        'provenance': {'engine_git_head': '1' * 40, 'engine_git_dirty': stress},
        'configuration': {'timeout': 10.0, 'long_timeout': 60.0,
                          'fuel': 50000000, 'memory_limit': 268435456,
                          'gc_threshold': 1 if stress else None,
                          'build_mode': 'ReleaseSafe' if stress else 'ReleaseFast'},
        'filter': '',
        'excluded': [{'path': 'wasm/jsapi/browser.any.js', 'reason': 'browser host required'}],
        'results': [
            {'id': 'wasm/jsapi/one.any.js', 'status': 'fail', 'returncode': 0,
             'harness': {'status': 0, 'message': None},
             'subtests': [{'name': 'works', 'status': 0},
                          {'name': 'known gap', 'status': 1}]},
            {'id': 'wasm/jsapi/strict.any.js', 'status': 'execution_error', 'returncode': 1,
             'harness': None, 'subtests': []},
        ],
    }


class ProfileComparisonTests(unittest.TestCase):
    def test_matching_named_results_allow_order_and_diagnostic_differences(self):
        normal, stress = report(), report(True)
        stress['results'].reverse()
        stress['results'][1]['subtests'].reverse()
        stress['results'][1].update(stdout='different diagnostic', duration_seconds=9)
        stress['results'][1]['harness']['message'] = 'different diagnostic'
        stress['provenance'].update(platform='other OS', generated_at_utc='later')
        before = copy.deepcopy((normal, stress))
        self.assertEqual(compare_profiles(normal, stress), [])
        self.assertEqual((normal, stress), before)

    def test_each_profile_is_fixed_and_cannot_be_swapped(self):
        self.assertTrue(compare_profiles(report(True), report()))
        for side, field, value in [('normal', 'build_mode', 'ReleaseSafe'),
                                   ('stress', 'build_mode', 'ReleaseFast'),
                                   ('normal', 'gc_threshold', 1),
                                   ('stress', 'gc_threshold', None),
                                   ('stress', 'gc_threshold', 32768)]:
            normal, stress = report(), report(True)
            target = normal if side == 'normal' else stress
            target['configuration'][field] = value
            with self.subTest(side=side, field=field, value=value):
                self.assertTrue(compare_profiles(normal, stress))

    def test_named_regressions_and_improvements_both_fail_parity(self):
        for index, status in [(0, 1), (1, 0)]:
            normal, stress = report(), report(True)
            stress['results'][0]['subtests'][index]['status'] = status
            if index == 1:
                stress['results'][0]['status'] = 'pass'
            with self.subTest(index=index):
                differences = compare_profiles(normal, stress)
                self.assertTrue(any(stress['results'][0]['subtests'][index]['name'] in item
                                    for item in differences))

    def test_rebalanced_totals_cannot_hide_different_names(self):
        normal, stress = report(), report(True)
        stress['results'][0]['subtests'] = [{'name': 'works', 'status': 1},
                                            {'name': 'known gap', 'status': 0}]
        self.assertTrue(compare_profiles(normal, stress))

    def test_missing_or_added_fixtures_and_subtests_fail(self):
        for change in ('missing fixture', 'added fixture', 'missing subtest', 'added subtest'):
            normal, stress = report(), report(True)
            if change == 'missing fixture':
                stress['results'].pop()
            elif change == 'added fixture':
                extra = copy.deepcopy(stress['results'][1])
                extra['id'] = 'wasm/jsapi/new.any.js'
                stress['results'].append(extra)
            elif change == 'missing subtest':
                stress['results'][0]['subtests'].pop(0)
            else:
                stress['results'][0]['subtests'].append({'name': 'new assertion', 'status': 1})
            with self.subTest(change=change):
                self.assertTrue(compare_profiles(normal, stress))

    def test_file_exit_and_harness_classifications_are_compared(self):
        for field, value in [('status', 'crash'), ('returncode', -6),
                             ('harness', {'status': 2, 'message': None})]:
            normal, stress = report(), report(True)
            stress['results'][1][field] = value
            with self.subTest(field=field):
                self.assertTrue(compare_profiles(normal, stress))

    def test_corpus_adapters_exclusions_and_execution_options_must_match(self):
        for field, value in [('corpus_revision', '2' * 40),
                             ('manifest_sha256', '2' * 64),
                             ('adapter_sha256', {'case.zig': '2' * 64}),
                             ('excluded', []),
                             ('configuration', dict(report(True)['configuration'], fuel=10)),
                             ('provenance', {'engine_git_head': '2' * 40})]:
            normal, stress = report(), report(True)
            stress[field] = value
            with self.subTest(field=field):
                self.assertTrue(compare_profiles(normal, stress))

    def test_absent_git_provenance_is_supported(self):
        normal, stress = report(), report(True)
        normal['provenance']['engine_git_head'] = None
        stress['provenance']['engine_git_head'] = None
        self.assertEqual(compare_profiles(normal, stress), [])

    def test_one_sided_git_provenance_cannot_claim_same_revision(self):
        normal, stress = report(), report(True)
        del stress['provenance']['engine_git_head']
        self.assertTrue(compare_profiles(normal, stress))

    def test_filtered_reports_are_not_complete_comparisons(self):
        normal, stress = report(), report(True)
        normal['filter'] = stress['filter'] = 'constructor'
        self.assertTrue(compare_profiles(normal, stress))

    def test_malformed_profile_metadata_is_rejected(self):
        mutations = [
            ('schema_version', True), ('configuration', None), ('configuration', {}),
            ('manifest_sha256', ''), ('adapter_sha256', []), ('excluded', None),
            ('filter', None), ('provenance', []),
        ]
        for field, value in mutations:
            normal, stress = report(), report(True)
            stress[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                compare_profiles(normal, stress)
        for field, value in [('gc_threshold', True), ('fuel', True), ('timeout', float('nan')),
                             ('build_mode', 'unknown'), ('build_mode', [])]:
            normal, stress = report(), report(True)
            stress['configuration'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                compare_profiles(normal, stress)

    def test_malformed_results_are_rejected(self):
        for field, value in [('returncode', True), ('returncode', '0'),
                             ('harness', []), ('harness', {}),
                             ('harness', {'status': True}), ('harness', {'status': 8})]:
            normal, stress = report(), report(True)
            stress['results'][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                compare_profiles(normal, stress)
        for mutate in ('duplicate fixture', 'duplicate subtest', 'unknown status'):
            normal, stress = report(), report(True)
            if mutate == 'duplicate fixture':
                stress['results'].append(copy.deepcopy(stress['results'][0]))
            elif mutate == 'duplicate subtest':
                stress['results'][0]['subtests'].append(copy.deepcopy(stress['results'][0]['subtests'][0]))
            else:
                stress['results'][0]['status'] = 'unknown'
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                compare_profiles(normal, stress)

    def test_identically_inconsistent_completed_fixtures_are_rejected(self):
        # Equality is not enough: two equally malformed reports cannot pass.
        for status in ('pass', 'fail'):
            for field, value in [('returncode', None), ('returncode', 3), ('returncode', -11),
                                 ('harness', None), ('harness', {'status': 1}),
                                 ('harness', {'status': 2}), ('subtests', [])]:
                normal, stress = report(), report(True)
                for profile in (normal, stress):
                    fixture = profile['results'][0]
                    fixture['status'] = status
                    if status == 'pass':
                        fixture['subtests'] = [{'name': 'works', 'status': 0}]
                    fixture[field] = value
                with self.subTest(status=status, field=field, value=value), self.assertRaises(ValueError):
                    compare_profiles(normal, stress)

    def test_identical_failing_classifications_need_a_nonpassing_subtest(self):
        normal, stress = report(), report(True)
        for profile in (normal, stress):
            profile['results'][0]['subtests'] = [{'name': 'works', 'status': 0}]
        with self.assertRaises(ValueError):
            compare_profiles(normal, stress)

    def test_completed_fixtures_can_report_each_nonpassing_subtest_status(self):
        for status in (1, 2, 3, 4):
            normal, stress = report(), report(True)
            for profile in (normal, stress):
                profile['results'][0]['subtests'] = [{'name': 'nonpassing assertion', 'status': status}]
            with self.subTest(status=status):
                self.assertEqual(compare_profiles(normal, stress), [])

    def test_cli_returns_distinct_success_difference_and_invalid_statuses(self):
        with tempfile.TemporaryDirectory() as temporary:
            normal_path = Path(temporary) / 'normal.json'
            stress_path = Path(temporary) / 'stress.json'
            normal_path.write_text(json.dumps(report()), encoding='utf-8')
            args = ['--normal', str(normal_path), '--gc-stress', str(stress_path)]
            stress_path.write_text(json.dumps(report(True)), encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(args), 0)
            stress = report(True)
            stress['results'][0]['subtests'][0]['status'] = 1
            stress_path.write_text(json.dumps(stress), encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(args), 1)
            stress_path.write_text('{ invalid', encoding='utf-8')
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(args), 2)


if __name__ == '__main__':
    unittest.main()
