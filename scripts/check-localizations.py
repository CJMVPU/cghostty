#!/usr/bin/env python3
"""Check that native command translations cover the built-in source strings."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'src/input/command.zig').read_text()
keys = {json.loads(value) for value in re.findall(r'\.(?:title|description)\s*=\s*("(?:[^"\\]|\\.)*")', source)}
keys.discard('')
catalog = json.loads((ROOT / 'macos/Sources/Ghostty/CommandPalette.xcstrings').read_text())
entries = catalog['strings']
if keys != entries.keys():
    raise SystemExit(f'Command catalog drift: missing={sorted(keys - entries.keys())}, obsolete={sorted(entries.keys() - keys)}')
languages = set()
count = 0
for key, entry in entries.items():
    if set(entry.get('localizations', {})) != {'zh-Hans', 'zh-Hant', 'ja'}:
        raise SystemExit(f'Missing or unexpected language: {key}')
    for language, value in entry.get('localizations', {}).items():
        unit = value['stringUnit']
        if unit['state'] != 'translated' or not unit['value']:
            raise SystemExit(f'Incomplete catalog unit: {language}: {key}')
        languages.add(language)
        count += 1
if catalog['sourceLanguage'] != 'en' or languages != {'zh-Hans', 'zh-Hant', 'ja'}:
    raise SystemExit('Expected English source and only Simplified Chinese, Traditional Chinese, Japanese translations')
print(f'PASS: {len(keys)} command strings, {len(languages)} languages, {count} translations')
