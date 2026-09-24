#!/usr/bin/env python3
"""Render xcresult failures, skips and GPU capability in the CI job summary."""
import argparse
import json
from pathlib import Path


def test_cases(nodes):
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            yield node
        else:
            yield from test_cases(node.get('children', []))


def skip_messages(node):
    for child in node.get('children', []):
        if child.get('nodeType') == 'Skip Message':
            yield child.get('name', 'No reason provided')
        yield from skip_messages(child)


def quoted(value):
    return '\n'.join('    ' + line for line in str(value).splitlines())


def render(summary, tree, gpu):
    lines = ['## Native test results', '',
             f"Result: {summary.get('result', 'Unknown')}; "
             f"passed: {summary.get('passedTests', '?')}; "
             f"failed: {summary.get('failedTests', '?')}; "
             f"skipped: {summary.get('skippedTests', '?')}.", '']
    if gpu is not None:
        lines += ['### Runtime Metal capability', '', quoted(json.dumps(gpu, ensure_ascii=False, indent=2)), '']
    for failure in summary.get('testFailures', []):
        lines += ['### Failure', '', quoted(failure.get('testIdentifierString', failure.get('testName', 'Unknown test'))),
                  '', quoted(failure.get('failureText', 'No failure text')), '']
    skipped = [node for node in test_cases(tree.get('testNodes', [])) if node.get('result') == 'Skipped']
    if skipped:
        lines += ['### Skipped tests', '',
                  'Skipped GPU tests are not GPU rendering validation. Run them on a Metal 4 capable Mac.', '']
        for node in skipped:
            lines += [quoted(node.get('nodeIdentifier', node.get('name', 'Unknown test'))),
                      quoted('\n'.join(skip_messages(node)) or 'See xcresult for the skip reason'), '']
    lines += ['Full logs and xcresult: the `cghostty-ci-diagnostics` artifact.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=Path)
    parser.add_argument('tests', type=Path)
    parser.add_argument('--gpu', type=Path)
    args = parser.parse_args()
    gpu = json.loads(args.gpu.read_text()) if args.gpu and args.gpu.exists() else None
    print(render(json.loads(args.summary.read_text()), json.loads(args.tests.read_text()), gpu))


if __name__ == '__main__':
    main()
