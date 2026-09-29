#!/usr/bin/env python3
"""Require identical named WPT results in the normal and GC-pressure profiles."""
import argparse
import json
import math
from pathlib import Path
import sys

from run import validate_report

BUILD_MODES = {'Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall'}


def validate_profile(report):
    validate_report(report)
    if type(report['schema_version']) is not int:
        raise ValueError('report schema_version must be an integer')
    for key in ('manifest_sha256', 'filter'):
        if not isinstance(report.get(key), str) or (key != 'filter' and not report[key]):
            raise ValueError('report needs ' + key)
    adapters = report.get('adapter_sha256')
    if (not isinstance(adapters, dict) or not adapters or
            any(not isinstance(name, str) or not name or not isinstance(digest, str) or not digest
                for name, digest in adapters.items())):
        raise ValueError('report needs adapter checksums')
    excluded = report.get('excluded')
    if not isinstance(excluded, list):
        raise ValueError('report needs excluded files')
    excluded_paths = set()
    for entry in excluded:
        if (not isinstance(entry, dict) or
                any(not isinstance(entry.get(key), str) or not entry[key]
                    for key in ('path', 'reason')) or entry['path'] in excluded_paths):
            raise ValueError('invalid or duplicate excluded file')
        excluded_paths.add(entry['path'])
    configuration = report.get('configuration')
    if not isinstance(configuration, dict):
        raise ValueError('report needs execution configuration')
    mode = configuration.get('build_mode')
    if not isinstance(mode, str) or mode not in BUILD_MODES:
        raise ValueError('invalid or missing build_mode')
    for key in ('timeout', 'long_timeout'):
        value = configuration.get(key)
        if (type(value) not in (int, float) or value <= 0 or
                (type(value) is float and not math.isfinite(value))):
            raise ValueError('invalid or missing configuration.' + key)
    for key in ('fuel', 'memory_limit'):
        value = configuration.get(key)
        if type(value) is not int or value <= 0:
            raise ValueError('invalid or missing configuration.' + key)
    threshold = configuration.get('gc_threshold')
    if ('gc_threshold' not in configuration or
            (threshold is not None and (type(threshold) is not int or threshold <= 0))):
        raise ValueError('invalid or missing configuration.gc_threshold')
    provenance = report.get('provenance', {})
    if not isinstance(provenance, dict):
        raise ValueError('invalid provenance')
    head = provenance.get('engine_git_head')
    if head is not None and (not isinstance(head, str) or not head):
        raise ValueError('invalid engine_git_head')
    for result in report['results']:
        if not result['id']:
            raise ValueError('fixture id must not be empty')
        if ('returncode' not in result or
                (result['returncode'] is not None and type(result['returncode']) is not int)):
            raise ValueError('invalid or missing fixture returncode')
        if 'harness' not in result:
            raise ValueError('missing fixture harness status')
        harness = result['harness']
        if harness is not None:
            if (not isinstance(harness, dict) or type(harness.get('status')) is not int or
                    harness['status'] not in range(4)):
                raise ValueError('invalid harness status')
            if harness.get('message') is not None and not isinstance(harness['message'], str):
                raise ValueError('invalid harness message')
        if result['status'] in ('pass', 'fail'):
            if result['returncode'] != 0 or harness is None or harness['status'] != 0:
                raise ValueError('completed fixture requires a successful process and harness')
            if not result['subtests']:
                raise ValueError('completed fixture requires nonempty subtests')
            all_passed = all(test['status'] == 0 for test in result['subtests'])
            if (result['status'] == 'pass') != all_passed:
                raise ValueError('fixture classification disagrees with its subtests')


def compare_profiles(normal, gc_stress):
    """Return differences without changing either report; malformed input raises."""
    validate_profile(normal)
    validate_profile(gc_stress)
    differences = []
    for label, report, mode, threshold in (
        ('normal', normal, 'ReleaseFast', None),
        ('GC stress', gc_stress, 'ReleaseSafe', 1),
    ):
        if report['filter']:
            differences.append(label + ': requires the full unfiltered corpus')
        configuration = report['configuration']
        if configuration['build_mode'] != mode or configuration['gc_threshold'] != threshold:
            differences.append(f'{label}: requires {mode} with gc_threshold={threshold}')
    for key in ('corpus_revision', 'manifest_sha256', 'adapter_sha256', 'excluded'):
        if normal[key] != gc_stress[key]:
            differences.append(key + ' differs between profiles')
    normal_configuration = {key: value for key, value in normal['configuration'].items()
                            if key not in ('build_mode', 'gc_threshold')}
    stress_configuration = {key: value for key, value in gc_stress['configuration'].items()
                            if key not in ('build_mode', 'gc_threshold')}
    if normal_configuration != stress_configuration:
        differences.append('execution configuration differs beyond build mode and GC threshold')
    if normal.get('provenance', {}).get('engine_git_head') != gc_stress.get('provenance', {}).get('engine_git_head'):
        differences.append('engine_git_head differs between profiles')
    normal_results = {result['id']: result for result in normal['results']}
    stress_results = {result['id']: result for result in gc_stress['results']}
    for name in sorted(normal_results.keys() - stress_results.keys()):
        differences.append('GC stress missing fixture: ' + name)
    for name in sorted(stress_results.keys() - normal_results.keys()):
        differences.append('GC stress added fixture: ' + name)
    for name in sorted(normal_results.keys() & stress_results.keys()):
        normal_result, stress_result = normal_results[name], stress_results[name]
        for field in ('status', 'returncode'):
            if normal_result[field] != stress_result[field]:
                differences.append(name + ': ' + field + ' differs')
        normal_harness = (normal_result['harness'] or {}).get('status')
        stress_harness = (stress_result['harness'] or {}).get('status')
        if normal_harness != stress_harness:
            differences.append(name + ': harness status differs')
        normal_tests = {test['name']: test['status'] for test in normal_result['subtests']}
        stress_tests = {test['name']: test['status'] for test in stress_result['subtests']}
        for test in sorted(normal_tests.keys() - stress_tests.keys()):
            differences.append(name + ': GC stress missing subtest: ' + test)
        for test in sorted(stress_tests.keys() - normal_tests.keys()):
            differences.append(name + ': GC stress added subtest: ' + test)
        for test in sorted(normal_tests.keys() & stress_tests.keys()):
            if normal_tests[test] != stress_tests[test]:
                differences.append(name + ': subtest status differs: ' + test +
                                   f' ({normal_tests[test]} -> {stress_tests[test]})')
    return differences


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--normal', required=True, type=Path, help='full ReleaseFast result report')
    parser.add_argument('--gc-stress', required=True, type=Path, help='full ReleaseSafe/GC-threshold-1 report')
    args = parser.parse_args(argv)
    try:
        normal = json.loads(args.normal.read_text(encoding='utf-8'))
        stress = json.loads(args.gc_stress.read_text(encoding='utf-8'))
        differences = compare_profiles(normal, stress)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('WPT profile comparison error: ' + str(error), file=sys.stderr)
        return 2
    for difference in differences:
        print('PROFILE MISMATCH: ' + difference)
    if differences:
        return 1
    count = sum(len(result['subtests']) for result in normal['results'])
    print(f'WPT profiles match: {len(normal["results"])} fixtures, {count} named subtests')
    return 0


if __name__ == '__main__':
    sys.exit(main())
