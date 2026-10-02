#!/usr/bin/env python3
"""Retention for result bundles created by the managed native test entrypoint."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid

NAME = re.compile(r'run-\d+-[0-9a-f]{32}\.xcresult\Z')
MAX_BYTES = 512 * 1024 ** 2


def option(arguments, name):
    if name not in arguments:
        return ''
    values = arguments[arguments.index(name) + 1:]
    return values[0] if values else ''


def selections(arguments):
    values = []
    for index, argument in enumerate(arguments):
        if argument == '--only-testing':
            if index + 1 == len(arguments) or arguments[index + 1].startswith('--'):
                raise ValueError('--only-testing requires a test selection')
            values.extend(value.strip() for value in arguments[index + 1].split(',') if value.strip())
    return list(dict.fromkeys(values))


def normalize_selections(arguments):
    selected = selections(arguments)
    forwarded = []
    skip = False
    for argument in arguments:
        if skip:
            skip = False
        elif argument == '--only-testing':
            skip = True
        else:
            forwarded.append(argument)
    if selected:
        forwarded += ['--only-testing', ','.join(selected)]
    return forwarded


def prepare(root, arguments):
    # Explicit destinations belong to the caller, including custom build dirs.
    if (option(arguments, '--action') != 'test' or
            option(arguments, '--result-bundle')):
        return list(arguments), None
    if custom := option(arguments, '--build-dir'):
        bundle = Path(custom).expanduser().resolve() / f'TestResults-{uuid.uuid4().hex}.xcresult'
        forwarded = list(arguments)
        if '--result-bundle' in forwarded:
            forwarded[forwarded.index('--result-bundle') + 1] = str(bundle)
        else:
            forwarded += ['--result-bundle', str(bundle)]
        return forwarded, None
    checkout = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    build_dir = Path(os.environ.get('TMPDIR', tempfile.gettempdir())) / f'cghostty-tests-{checkout}'
    directory = build_dir / 'ManagedTestResults'
    if build_dir.is_symlink() or directory.is_symlink():
        raise ValueError('Refusing a symlink managed test result directory')
    directory.mkdir(parents=True, exist_ok=True)
    maintain(directory)
    bundle = directory / f'run-{time.time_ns()}-{uuid.uuid4().hex}.xcresult'
    forwarded = list(arguments)
    if '--result-bundle' in forwarded:
        forwarded[forwarded.index('--result-bundle') + 1] = str(bundle)
    else:
        forwarded += ['--result-bundle', str(bundle)]
    return forwarded, directory


def summary(bundle):
    path = bundle.with_suffix('.json')
    if path.is_symlink():
        raise ValueError(f'Refusing symlink summary: {path}')
    if path.exists():
        return json.loads(path.read_text())
    try:
        data = json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
             '--path', str(bundle), '--format', 'json'], text=True, stderr=subprocess.PIPE))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        data = {'result': 'Incomplete', 'summaryError': str(error)}
    # Small, durable diagnostic information survives removal of large attachments.
    data = {key: data[key] for key in (
        'result', 'totalTestCount', 'passedTests', 'failedTests', 'skippedTests',
        'testFailures', 'startTime', 'finishTime', 'summaryError') if key in data}
    if isinstance(data.get('testFailures'), list):
        # Failure messages may themselves contain entire terminal transcripts.
        failures = data['testFailures']
        data['testFailures'] = [json.dumps(item, ensure_ascii=False)[:2048] for item in failures[:20]]
        if len(failures) > 20:
            data['omittedFailureDetails'] = len(failures) - 20
    if 'summaryError' in data:
        data['summaryError'] = data['summaryError'][:2048]
    path.write_text(json.dumps(data, indent=2) + '\n')
    return data


def executed_tests(nodes, target=''):
    for node in nodes:
        if 'test bundle' in node.get('nodeType', '').lower():
            target = node['name']
        if node.get('nodeType') == 'Test Case':
            if node.get('result') in ('Passed', 'Failed'):
                yield target + '/' + node['nodeIdentifier']
        else:
            yield from executed_tests(node.get('children', []), target)


def verify(bundle, selected=()):
    """Xcode can exit successfully when a filter matches zero tests."""
    data = summary(bundle)
    def reject(message):
        data['validationError'] = message
        bundle.with_suffix('.json').write_text(json.dumps(data, indent=2) + '\n')
        raise ValueError(message)

    passed, failed, skipped = (data.get(key, 0) for key in ('passedTests', 'failedTests', 'skippedTests'))
    print(f'Native tests: {passed} passed, {failed} failed, {skipped} skipped.', flush=True)
    if data.get('result') != 'Passed' or failed or passed == 0:
        reject('Native test run did not execute and pass any tests; inspect the selection and result bundle')
    if selected:
        tree = json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
             '--path', str(bundle), '--format', 'json'], text=True, stderr=subprocess.PIPE))
        executed = list(executed_tests(tree.get('testNodes', [])))
        for selection in selected:
            count = sum(test == selection or test.startswith(selection + '/') for test in executed)
            print(f'  {selection}: {count} executed', flush=True)
            if count == 0:
                reject(f'No tests executed for requested selection: {selection}')


def allocated_bytes(directory):
    total = 0
    for parent, _, files in os.walk(directory, followlinks=False):
        for name in files:
            total += (Path(parent) / name).lstat().st_blocks * 512
    return total


def maintain(directory, max_bytes=MAX_BYTES):
    """Caller holds the checkout build lock; no active managed test can be here."""
    if directory.is_symlink():
        raise ValueError('Refusing a symlink managed test result directory')
    bundles = sorted((p for p in directory.iterdir() if NAME.fullmatch(p.name)
                      and p.is_dir() and not p.is_symlink()), key=lambda p: p.name, reverse=True)
    counts = {'Passed': 0, 'Failed': 0}
    retained = 0
    for bundle in bundles:
        data = summary(bundle)
        category = 'Passed' if (data.get('result') == 'Passed' and data.get('passedTests', 0) > 0
                                and not data.get('validationError')) else 'Failed'
        size = allocated_bytes(bundle)
        limit = 1 if category == 'Passed' else 2
        if counts[category] < limit and retained + size <= max_bytes:
            counts[category] += 1
            retained += size
        else:
            shutil.rmtree(bundle)
    summaries = sorted((p for p in directory.glob('run-*.json')
                        if NAME.fullmatch(p.with_suffix('.xcresult').name)
                        and p.is_file() and not p.is_symlink()), key=lambda p: p.name, reverse=True)
    for path in summaries[20:]:
        path.unlink()
