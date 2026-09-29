#!/usr/bin/env python3
"""Run the pinned WPT WebAssembly JS API shell slice in isolated Cynic realms.

The runner never treats lack of work as success. WPT completion, a nonempty
subtest list, successful subtests, and a successful process exit are all required.
Only an explicit reviewed baseline permits existing failures in a regression gate.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import platform
import posixpath
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = '@@WPT@@'
SCHEMA_VERSION = 1
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
BUILD_MODES = ('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')
SUBTEST_STATUS = {0: 'PASS', 1: 'FAIL', 2: 'TIMEOUT', 3: 'NOTRUN', 4: 'PRECONDITION_FAILED'}
FILE_STATUSES = {'pass', 'fail', 'timeout', 'crash', 'execution_error', 'output_limit',
                 'protocol_error', 'incomplete', 'no_tests', 'harness_error'}
SUPPORT_PATCHES = {
    'wasm/jsapi/wasm-module-builder.js': (
        'let string_utf8 = unescape(encodeURIComponent(string));',
        'let string_utf8 = encodeURIComponent(string).replace(/%([0-9A-F]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));',
    ),
}


def parse_metadata(source):
    metadata = {'globals': ['window', 'dedicatedworker'], 'scripts': [], 'variants': [], 'timeout': 'normal'}
    singular = set()
    for line in source.splitlines():
        match = re.match(r'^\s*//\s*META:\s*([\w-]+)=(.*)$', line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if key in ('global', 'timeout'):
            if key in singular:
                raise ValueError('duplicate META: ' + key)
            singular.add(key)
        if key == 'global':
            metadata['globals'] = [item.strip() for item in value.split(',')]
        elif key == 'script':
            metadata['scripts'].append(value)
        elif key == 'variant':
            if value and not value.startswith(('?', '#')):
                raise ValueError('META variant must be empty or start with ? or #')
            if value in metadata['variants']:
                raise ValueError('duplicate META variant: ' + value)
            metadata['variants'].append(value)
        elif key == 'timeout':
            if value not in ('normal', 'long'):
                raise ValueError('unsupported META timeout: ' + value)
            metadata['timeout'] = value
    if not metadata['variants']:
        metadata['variants'] = ['']
    return metadata


def resolve_script(test_path, script):
    if not script or script.startswith('//') or any(char in script for char in ('?', '#', '\\', ':', '\x00', '%')):
        raise ValueError('unsupported META script: ' + repr(script))
    candidate = script[1:] if script.startswith('/') else posixpath.join(posixpath.dirname(test_path), script)
    resolved = posixpath.normpath(candidate)
    if resolved == '..' or resolved.startswith('../') or resolved.startswith('/'):
        raise ValueError('META script escapes corpus: ' + script)
    return resolved


def patch_harness(source):
    # WPT's get_test_name uses Annex B bare braces as regex literals. Escaping
    # those two braces is semantics-preserving under Cynic's strict grammar.
    original = r'(?:{(.*)}\s*|(.*))'
    replacement = r'(?:\{(.*)\}\s*|(.*))'
    if source.count(original) != 1:
        raise ValueError('pinned testharness.js regex compatibility patch no longer matches exactly once')
    return source.replace(original, replacement)


def patch_support(path, source):
    # encodeURIComponent emits UTF-8 percent bytes (never %u escapes). Decode
    # those bytes locally, preserving coercion and lone-surrogate URIError,
    # without installing the intentionally absent Annex B unescape global.
    if path not in SUPPORT_PATCHES:
        return source
    original, replacement = SUPPORT_PATCHES[path]
    if source.count(original) != 1:
        raise ValueError('pinned support compatibility patch no longer matches exactly once: ' + path)
    return source.replace(original, replacement)


def parse_output(stdout, returncode):
    subtests, completion, protocol_error = [], None, None
    names = set()
    # Native print() delimits records with LF. JSON.stringify can leave Unicode
    # line separators inside valid strings, so Python's splitlines is too broad.
    for line in stdout.split('\n'):
        if not line.startswith(PROTOCOL):
            continue
        try:
            event = json.loads(line[len(PROTOCOL):])
            if not isinstance(event, dict):
                raise ValueError('event is not an object')
            kind = event.get('type')
            status = event.get('status')
            if type(status) is not int:
                raise ValueError('status must be an integer')
            if event.get('message') is not None and not isinstance(event['message'], str):
                raise ValueError('message must be null or a string')
            if completion is not None:
                raise ValueError('event after completion')
            if kind == 'result':
                name = event.get('name')
                if not isinstance(name, str) or status not in SUBTEST_STATUS:
                    raise ValueError('invalid subtest name or status')
                if name in names:
                    raise ValueError('duplicate subtest name: ' + name)
                names.add(name)
                subtests.append({'name': name, 'status': status, 'message': event.get('message')})
            elif kind == 'complete':
                if status not in range(4):
                    raise ValueError('invalid harness status')
                completion = {'status': status, 'message': event.get('message')}
            else:
                raise ValueError('unknown protocol event type')
        except (ValueError, TypeError) as error:
            protocol_error = str(error)
            break
    message = None
    if returncode:
        status = 'crash' if returncode < 0 else 'execution_error'
        message = 'process exited with ' + str(returncode)
    elif protocol_error:
        status, message = 'protocol_error', protocol_error
    elif completion is None:
        status, message = 'incomplete', 'WPT completion callback was not observed'
    elif completion['status'] != 0:
        status, message = 'harness_error', completion['message'] or 'WPT harness status ' + str(completion['status'])
    elif not subtests:
        status, message = 'no_tests', 'WPT completed without any subtests'
    else:
        status = 'fail' if any(test['status'] != 0 for test in subtests) else 'pass'
    return {'status': status, 'subtests': subtests, 'harness': completion,
            'returncode': returncode, 'message': message}


def execute_command(command, timeout, max_output_bytes=MAX_OUTPUT_BYTES):
    start = time.monotonic()
    # Disk-backed output bounds runner memory even if a fixture floods print().
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        error_status, error_message, returncode = None, None, None
        try:
            process = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=stdout,
                                     stderr=stderr, timeout=timeout, check=False)
            returncode = process.returncode
        except subprocess.TimeoutExpired:
            error_status, error_message = 'timeout', 'process exceeded ' + str(timeout) + ' seconds'
        except OSError as error:
            error_status, error_message = 'execution_error', str(error)
        stdout.seek(0)
        stderr.seek(0)
        out_bytes = stdout.read(max_output_bytes + 1)
        err_bytes = stderr.read(max_output_bytes + 1)
    out, err = out_bytes[:max_output_bytes].decode('utf-8', 'replace'), err_bytes[:max_output_bytes].decode('utf-8', 'replace')
    report = parse_output(out, returncode)
    if error_status:
        report.update(status=error_status, message=error_message)
    elif len(out_bytes) > max_output_bytes or len(err_bytes) > max_output_bytes:
        report.update(status='output_limit', message='process output exceeded capture limit')
    report.update(duration_seconds=round(time.monotonic() - start, 3), stdout=out, stderr=err)
    return report


def probe_build_info(binary, timeout=5.0):
    """Verify the executable's own build mode before accepting fixture results."""
    # Reuse the timeout and bounded diagnostic capture from fixture execution.
    # A metadata response has no WPT records, hence the expected incomplete
    # status here; only the standalone JSON document below establishes success.
    outcome = execute_command([str(binary), '--build-info'], timeout, max_output_bytes=4096)
    if outcome['returncode'] != 0 or outcome['status'] != 'incomplete':
        raise ValueError('build-info probe failed (' + outcome['status'] + '): ' +
                         (outcome['message'] or 'unexpected process response'))

    def unique_fields(pairs):
        fields = {}
        for name, value in pairs:
            if name in fields:
                raise ValueError('duplicate field: ' + name)
            fields[name] = value
        return fields

    try:
        metadata = json.loads(outcome['stdout'], object_pairs_hook=unique_fields)
    except ValueError as error:
        raise ValueError('build-info response must be standalone JSON: ' + str(error)) from error
    if (not isinstance(metadata, dict) or set(metadata) != {'schema_version', 'build_mode'} or
            type(metadata['schema_version']) is not int or metadata['schema_version'] != 1 or
            metadata['build_mode'] not in BUILD_MODES):
        raise ValueError('build-info response has an unsupported schema or build mode')
    return metadata['build_mode']


def corpus_file(directory, name):
    if not isinstance(name, str) or not name or '\\' in name or '\x00' in name:
        raise ValueError('invalid corpus path: ' + repr(name))
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or name != path.as_posix():
        raise ValueError('invalid corpus path: ' + repr(name))
    resolved = (directory / name).resolve()
    if not resolved.is_relative_to(directory.resolve()):
        raise ValueError('corpus path escapes vendor directory: ' + name)
    if not resolved.is_file():
        raise ValueError('missing corpus file: ' + name)
    return resolved


def load_corpus(manifest_path):
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    if not isinstance(manifest, dict) or manifest.get('schema_version') != SCHEMA_VERSION:
        raise ValueError('unsupported corpus manifest schema')
    directory = manifest_path.parent
    files = manifest['files']
    for name, info in files.items():
        actual = hashlib.sha256(corpus_file(directory, name).read_bytes()).hexdigest()
        if actual != info['sha256']:
            raise ValueError('corpus checksum mismatch: ' + name)
    records, excluded, seen = [], [], set()
    for record in manifest['tests']:
        path = record['path']
        if path in seen:
            raise ValueError('duplicate test manifest record: ' + path)
        seen.add(path)
        if path not in files:
            raise ValueError('test missing checksum: ' + path)
        metadata = parse_metadata(corpus_file(directory, path).read_text(encoding='utf-8'))
        scripts = [resolve_script(path, script) for script in metadata['scripts']]
        if record['scripts'] != scripts or record['variants'] != metadata['variants']:
            raise ValueError('manifest metadata differs from source: ' + path)
        if 'globals' in record and record['globals'] != metadata['globals']:
            raise ValueError('manifest globals differ from source: ' + path)
        if 'timeout' in record and record['timeout'] != metadata['timeout']:
            raise ValueError('manifest timeout differs from source: ' + path)
        reason = record.get('excluded_reason')
        if reason is not None:
            if not isinstance(reason, str) or not reason:
                raise ValueError('excluded test requires a reason: ' + path)
            excluded.append({'path': path, 'reason': reason})
            continue
        if 'jsshell' not in metadata['globals']:
            raise ValueError('included test does not explicitly declare jsshell: ' + path)
        if any(metadata['variants']):
            raise ValueError('nonempty WPT variants need host semantics before execution: ' + path)
        for script in scripts:
            if script not in files:
                raise ValueError('dependency missing checksum: ' + script)
            corpus_file(directory, script)
        for variant in metadata['variants']:
            records.append({'id': path + variant, 'path': path, 'variant': variant,
                            'scripts': scripts, 'timeout': metadata['timeout']})
    if 'resources/testharness.js' not in files:
        raise ValueError('testharness.js missing checksum')
    actual_tests = {path.relative_to(directory).as_posix() for path in (directory / 'wasm/jsapi').rglob('*.any.js')}
    if actual_tests != seen:
        raise ValueError('manifest does not enumerate every imported .any.js fixture')
    return manifest, records, excluded, hashlib.sha256(manifest_bytes).hexdigest()


def validate_report(report):
    if not isinstance(report, dict) or report.get('schema_version') != SCHEMA_VERSION:
        raise ValueError('unsupported baseline schema')
    if not isinstance(report.get('corpus_revision'), str) or not report['corpus_revision']:
        raise ValueError('baseline needs corpus revision')
    results = report.get('results')
    if not isinstance(results, list) or not results:
        raise ValueError('baseline needs nonempty results')
    ids = set()
    for result in results:
        if not isinstance(result, dict) or not isinstance(result.get('subtests'), list):
            raise ValueError('baseline result needs an object with subtests')
        name = result.get('id')
        if not isinstance(name, str) or name in ids:
            raise ValueError('invalid or duplicate baseline file id')
        ids.add(name)
        if not isinstance(result.get('status'), str) or result['status'] not in FILE_STATUSES:
            raise ValueError('unknown baseline file status')
        names = set()
        for subtest in result['subtests']:
            if not isinstance(subtest, dict) or not isinstance(subtest.get('name'), str) or subtest['name'] in names:
                raise ValueError('invalid or duplicate baseline subtest')
            names.add(subtest['name'])
            if type(subtest.get('status')) is not int or subtest['status'] not in SUBTEST_STATUS:
                raise ValueError('invalid baseline subtest status')
        if result['status'] == 'pass' and (not names or any(t['status'] != 0 for t in result['subtests'])):
            raise ValueError('baseline claims pass without passing subtests')


def compare_baseline(before, after):
    validate_report(before)
    validate_report(after)
    regressions = []
    for key in ('corpus_revision', 'manifest_sha256', 'configuration', 'adapter_sha256'):
        if before.get(key) != after.get(key):
            regressions.append(key + ' changed; review and explicitly refresh the baseline')
    old = {item['id']: item for item in before['results']}
    new = {item['id']: item for item in after['results']}
    for name in sorted(old.keys() - new.keys()):
        regressions.append('fixture disappeared: ' + name)
    for name in sorted(new.keys() - old.keys()):
        regressions.append('fixture added: ' + name)
    for name in sorted(old.keys() & new.keys()):
        previous, current = old[name], new[name]
        if previous['status'] == 'pass' and current['status'] != 'pass':
            regressions.append(name + ': previously passing fixture is ' + current['status'])
        elif previous['status'] == 'fail' and current['status'] not in ('pass', 'fail'):
            regressions.append(name + ': fixture became ' + current['status'])
        elif previous['status'] not in ('pass', 'fail') and current['status'] not in ('pass', 'fail', previous['status']):
            regressions.append(name + ': fixture error changed to ' + current['status'])
        if previous['status'] not in ('pass', 'fail') and current['status'] == previous['status']:
            if previous.get('returncode') != current.get('returncode'):
                regressions.append(name + ': process exit status changed within ' + current['status'])
            old_harness = (previous.get('harness') or {}).get('status')
            new_harness = (current.get('harness') or {}).get('status')
            if old_harness != new_harness:
                regressions.append(name + ': harness status changed within ' + current['status'])
        old_tests = {test['name']: test for test in previous['subtests']}
        new_tests = {test['name']: test for test in current['subtests']}
        for test in sorted(old_tests.keys() - new_tests.keys()):
            regressions.append(name + ': subtest disappeared: ' + test)
        for test in sorted(new_tests.keys() - old_tests.keys()):
            regressions.append(name + ': subtest added: ' + test)
        for test in sorted(old_tests.keys() & new_tests.keys()):
            if old_tests[test]['status'] == 0 and new_tests[test]['status'] != 0:
                regressions.append(name + ': previously passing subtest failed: ' + test)
            elif new_tests[test]['status'] not in (0, old_tests[test]['status']):
                regressions.append(name + ': failing subtest changed status: ' + test +
                                   ' (' + SUBTEST_STATUS[old_tests[test]['status']] + ' -> ' + SUBTEST_STATUS[new_tests[test]['status']] + ')')
    return regressions


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('must be a finite positive number')
    return number


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('must be a positive integer')
    return number


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=True) + '\n', encoding='utf-8')


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def capture_provenance():
    """Identify the measured checkout and host without constraining the gate."""
    provenance = {'generated_at_utc': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
                  'platform': platform.system(), 'architecture': platform.machine(),
                  'engine_git_head': None, 'engine_git_dirty': None}
    for key, arguments in (
        ('engine_git_head', ['rev-parse', '--verify', 'HEAD']),
        ('engine_git_dirty', ['status', '--porcelain=v1', '--untracked-files=normal']),
    ):
        try:
            result = subprocess.run(['git', *arguments], cwd=ROOT, capture_output=True,
                                    text=True, timeout=2, check=False)
            if result.returncode == 0:
                provenance[key] = bool(result.stdout.strip()) if key == 'engine_git_dirty' else result.stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            # Source archives and machines without Git can still run the suite.
            pass
    return provenance


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True, help='built cynic-wpt-case executable')
    parser.add_argument('--expect-build-mode', choices=BUILD_MODES,
                        help='require this observed executor build mode before running fixtures')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'vendor/wpt/manifest.json')
    parser.add_argument('--filter', default='', help='substring of fixture path plus variant')
    parser.add_argument('--list', action='store_true', help='list selected cases without executing')
    parser.add_argument('--json-out', type=Path, help='write complete machine-readable results')
    parser.add_argument('--baseline', type=Path, help='require no regression against reviewed full results')
    parser.add_argument('--write-baseline', type=Path, help='explicitly record the full current result baseline')
    parser.add_argument('--timeout', type=positive_float, default=10.0)
    parser.add_argument('--long-timeout', type=positive_float, default=60.0)
    parser.add_argument('--fuel', type=positive_int, default=50_000_000)
    parser.add_argument('--memory-limit', type=positive_int, default=256 * 1024 * 1024)
    parser.add_argument('--gc-threshold', type=positive_int)
    parser.add_argument('--quiet', action='store_true', help='print failures and summary only')
    args = parser.parse_args(argv)
    if args.filter and (args.baseline or args.write_baseline):
        parser.error('baseline operations require the full unfiltered corpus')
    if args.baseline and args.write_baseline:
        parser.error('reading and overwriting a baseline in the same run is not allowed')
    try:
        manifest, records, excluded, fingerprint = load_corpus(args.manifest.resolve())
        selected = [record for record in records if args.filter in record['id']]
        if not selected:
            raise ValueError('no tests match the requested selection')
        if args.list:
            for record in selected:
                print(record['id'])
            print(f'{len(selected)} cases selected; {len(excluded)} files explicitly excluded')
            return 0
        before = None
        if args.baseline:
            before = json.loads(args.baseline.read_text(encoding='utf-8'))
            validate_report(before)
        binary = args.binary.resolve()
        if not binary.is_file():
            raise ValueError('runner binary does not exist: ' + str(binary))
        build_mode = probe_build_info(binary)
        if args.expect_build_mode and build_mode != args.expect_build_mode:
            raise ValueError('executor build mode is ' + build_mode + '; expected ' + args.expect_build_mode)
        directory = args.manifest.resolve().parent
        harness_source = corpus_file(directory, 'resources/testharness.js').read_text(encoding='utf-8')
        local = Path(__file__).resolve().parent
        shims = [local / name for name in ('bootstrap.js', 'reporter.js', 'finish.js')]
        for shim in shims:
            if not shim.is_file():
                raise ValueError('missing shell adapter: ' + str(shim))
        patched_harness = patch_harness(harness_source)
        patched_support = {}
        for name in sorted({name for record in selected for name in record['scripts']}):
            if name in SUPPORT_PATCHES:
                source = corpus_file(directory, name).read_text(encoding='utf-8')
                patched_support[name] = patch_support(name, source)
        adapters = {path.name: file_sha256(path) for path in [Path(__file__), local / 'case.zig', *shims]}
        adapters['testharness.js (patched)'] = hashlib.sha256(patched_harness.encode('utf-8')).hexdigest()
        for name, source in patched_support.items():
            adapters[name + ' (patched)'] = hashlib.sha256(source.encode('utf-8')).hexdigest()
        report = {'schema_version': SCHEMA_VERSION,
                  'corpus_revision': manifest['upstream']['revision'],
                  'manifest_sha256': fingerprint,
                  'adapter_sha256': adapters,
                  # Engine changes are what the gate measures; record their
                  # identity for reproduction without pinning this comparison.
                  'binary_sha256': file_sha256(binary),
                  'provenance': capture_provenance(),
                  'configuration': {'build_mode': build_mode,
                                    'timeout': args.timeout, 'long_timeout': args.long_timeout,
                                    'fuel': args.fuel, 'memory_limit': args.memory_limit,
                                    'gc_threshold': args.gc_threshold},
                  'filter': args.filter, 'excluded': excluded, 'results': []}
        with tempfile.TemporaryDirectory(prefix='cynic-wpt-') as temporary:
            temporary = Path(temporary)
            harness = temporary / 'testharness.js'
            harness.write_text(patched_harness, encoding='utf-8')
            patched_support_paths = {}
            for name, source in patched_support.items():
                destination = temporary / 'support' / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(source, encoding='utf-8')
                patched_support_paths[name] = destination
            environment = temporary / 'environment.js'
            for record in selected:
                environment.write_text('globalThis.__wpt_variant = ' + json.dumps(record['variant']) + ';\n'
                                       'globalThis.__wpt_test_path = ' + json.dumps(record['path']) + ';\n', encoding='utf-8')
                command = [str(binary), '--fuel=' + str(args.fuel), '--memory-limit=' + str(args.memory_limit)]
                if args.gc_threshold:
                    command.append('--gc-threshold=' + str(args.gc_threshold))
                scripts = [environment, shims[0], harness, shims[1]]
                scripts.extend(patched_support_paths.get(name, corpus_file(directory, name)) for name in record['scripts'])
                scripts.extend([corpus_file(directory, record['path']), shims[2]])
                command.extend(str(script) for script in scripts)
                timeout = args.long_timeout if record['timeout'] == 'long' else args.timeout
                outcome = execute_command(command, timeout)
                outcome.update(id=record['id'], path=record['path'], variant=record['variant'])
                report['results'].append(outcome)
                passed = sum(test['status'] == 0 for test in outcome['subtests'])
                if not args.quiet or outcome['status'] != 'pass':
                    print(f'[{outcome["status"].upper()}] {record["id"]} ({passed}/{len(outcome["subtests"])} subtests passed)', flush=True)
                    if outcome['message']:
                        print('  ' + outcome['message'], flush=True)
                    for test in outcome['subtests']:
                        if test['status'] != 0:
                            print('  ' + SUBTEST_STATUS[test['status']] + ': ' + test['name'] + ': ' + (test['message'] or ''), flush=True)
                    if outcome['status'] not in ('pass', 'fail') and outcome['stderr']:
                        print('  ' + outcome['stderr'][-4000:].strip(), flush=True)
        statuses = Counter(item['status'] for item in report['results'])
        substatuses = Counter(SUBTEST_STATUS[test['status']] for item in report['results'] for test in item['subtests'])
        report['summary'] = {'files': dict(sorted(statuses.items())), 'subtests': dict(sorted(substatuses.items())), 'excluded_files': len(excluded)}
        regressions = compare_baseline(before, report) if before is not None else []
        if before is not None:
            report['regressions'] = regressions
        if args.json_out:
            write_json(args.json_out, report)
        if args.write_baseline:
            # Diagnostics can be large; preserve every named status, not print logs.
            baseline = {key: value for key, value in report.items() if key != 'results'}
            baseline['results'] = [{key: value for key, value in result.items() if key not in ('stdout', 'stderr', 'duration_seconds')} for result in report['results']]
            write_json(args.write_baseline, baseline)
            print('Baseline written to ' + str(args.write_baseline))
        print('Files: ' + ', '.join(f'{count} {status}' for status, count in sorted(statuses.items())) + f'; {len(excluded)} excluded')
        print('Subtests: ' + (', '.join(f'{count} {status}' for status, count in sorted(substatuses.items())) or 'none'))
        if before is not None:
            for regression in regressions:
                print('REGRESSION: ' + regression)
            print('Baseline: ' + (str(len(regressions)) + ' regressions' if regressions else 'no regressions; existing failures remain reported'))
            return 1 if regressions else 0
        return 0 if statuses.get('pass', 0) == len(selected) else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('WPT runner error: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
