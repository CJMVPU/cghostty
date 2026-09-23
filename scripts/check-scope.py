#!/usr/bin/env python3
"""Check source boundaries and reject unsupported build targets; optionally inspect an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path)
args = parser.parse_args()

def check(condition, message):
    if not condition:
        raise SystemExit(message)

subprocess.run([sys.executable, str(ROOT / 'scripts/check-bridge.py')], check=True)

for name in ('src/apprt/gtk', 'src/apprt/gtk.zig', 'src/main_wasm.zig',
             'src/lib_vt.zig', 'src/terminal/c', 'include/ghostty',
             'src/renderer/Dmabuf.zig', 'src/renderer/shaders/glsl',
             'test/wasm-alloc.mjs', 'pkg/glslang', 'pkg/spirv-cross',
             'src/renderer/shadertoy.zig',
             'src/build/GhosttyLibVt.zig', 'src/build/webgen', 'example',
             'src/inspector', 'src/renderer/Overlay.zig',
             'pkg/dcimgui', 'pkg/freetype', 'pkg/libpng', 'pkg/zlib',
             'macos/Sources/Ghostty/Ghostty.Inspector.swift',
             'macos/Sources/Ghostty/Surface View/InspectorView.swift',
             'src/build/GhosttyI18n.zig', 'src/os/i18n.zig', 'pkg/libintl', 'po',
             'pkg/harfbuzz', 'src/font/backend.zig', 'src/font/face/freetype.zig',
             'src/font/shaper/harfbuzz.zig', 'src/font/shaper/noop.zig', 'src/stb',
             'src/terminal/apc/glyph', 'src/terminal/apc/glyph.zig',
             'src/font/opentype/glyf.zig', 'src/font/glyf_rasterize.zig',
             'src/config/ErrorList.zig', 'src/input/KeymapNoop.zig', 'src/lib/c_abi.zig',
             'src/build/GitVersion.zig', 'src/build/xcframework.zig',
             'src/build/CombineArchivesStep.zig',
             'src/renderer/backend.zig', 'src/apprt/runtime.zig', 'src/cli/tui.zig',
             'images/cghostty-icon-v2', 'images/cghostty-icon-v3',
             'images/cghostty.icon/Assets/Prompt.svg',
             'macos/Assets.xcassets/AppIconImage.imageset/cghostty.svg',
             'flatpak', 'snap', 'nix', 'dist', 'test/windows', 'test/fuzz-libghostty',
             'macos/Sources/Helpers/Backport.swift',
             'macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift',
             'macos/Sources/Features/Terminal/Window Styles/TerminalTabsTitlebarVentura.xib'):
    check(not (ROOT / name).exists(), f'Out-of-scope source returned: {name}')

project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-',
    str(ROOT / 'macos/Ghostty.xcodeproj/project.pbxproj')]))
objects = project['objects']
project_configs = objects[objects[project['rootObject']]['buildConfigurationList']]['buildConfigurations']
for ref in project_configs:
    settings = objects[ref]['buildSettings']
    check(settings['ARCHS'] == 'arm64', 'Xcode project enables another architecture')
for obj in objects.values():
    target = obj.get('buildSettings', {}).get('MACOSX_DEPLOYMENT_TARGET')
    if target is not None:
        check(target == '27.0', 'All Xcode targets, including tests and plugins, must require macOS 27')
app_configs = [obj for obj in objects.values() if obj.get('buildSettings', {}).get('PRODUCT_NAME') == 'cghostty']
check(len(app_configs) == 3, 'Expected Debug, ReleaseLocal, and Release app configurations')
for obj in app_configs:
    settings = obj['buildSettings']
    check(settings['MACOSX_DEPLOYMENT_TARGET'] == '27.0', 'App deployment target must be macOS 27')
    expected = 'com.cjmvpu.cghostty' + ('.debug' if obj['name'] == 'Debug' else '')
    check(settings['PRODUCT_BUNDLE_IDENTIFIER'] == expected, 'App bundle identity mismatch')
    check(settings['EXECUTABLE_NAME'] == 'cghostty', 'App executable identity mismatch')

zig = shutil.which('zig')
check(zig, 'The pinned Zig toolchain must be on PATH; see scripts/zig-toolchain.json')
subprocess.run([zig, 'build', 'check-config-bridge'], cwd=ROOT, check=True)
# Exercise the actual entry point: accepting an unsupported target is a failure.
for target, diagnostic in (('x86_64-macos', 'Apple Silicon'), ('aarch64-linux', 'on and for macOS'),
                           ('aarch64-windows', 'on and for macOS'), ('aarch64-ios', 'on and for macOS'),
                           ('wasm32-freestanding', 'on and for macOS')):
    result = subprocess.run([zig, 'build', '--help', f'-Dtarget={target}'], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    check(result.returncode != 0 and diagnostic in result.stdout,
          f'Expected explicit rejection for {target}:\n{result.stdout}')

for flag in ('emit-lib-vt', 'emit-webdata', 'emit-lib', 'xcframework-target', 'font-backend', 'i18n'):
    value = 'universal' if flag == 'xcframework-target' else 'true'
    result = subprocess.run([zig, 'build', '--help', f'-D{flag}={value}'], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    check(result.returncode != 0 and 'invalid option' in result.stdout.lower(),
          f'Removed build option {flag} was not rejected:\n{result.stdout}')

if args.app:
    app = args.app.resolve()
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    check(info['CFBundleIdentifier'] == 'com.cjmvpu.cghostty', 'Release app bundle ID mismatch')
    check(info['CFBundleExecutable'] == 'cghostty', 'Executable name mismatch')
    check(info['LSMinimumSystemVersion'] == '27.0', 'App must require macOS 27')
    check('SUFeedURL' not in info and 'SUPublicEDKey' not in info, 'Upstream updater metadata remains')
    executables = [app / 'Contents/MacOS/cghostty']
    for binary in executables:
        arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
        check(arch == 'arm64', f'{binary} has unexpected architecture: {arch}')
    check(not (app / 'Contents/Frameworks/Sparkle.framework').exists(), 'Upstream updater is bundled')
    check((app / 'Contents/Resources/cghostty/shell-integration').is_dir(), 'Shell integration missing')
    check((app / 'Contents/Resources/cghostty/licenses/LXGW-WenKai-OFL.txt').is_file(),
          'Bundled LXGW WenKai font license missing')
    font = app / 'Contents/Resources/cghostty/fonts/LXGWWenKaiMono-Medium.ttf'
    check(font.is_file(), 'Bundled default font resource missing')
    check(hashlib.sha256(font.read_bytes()).hexdigest() ==
          '7a674f448b15a1b3df781c3498973d77f71d270788f7f921080c1344e9d739e1',
          'Bundled default font differs from the pinned Medium face')
    check(not (app / 'Contents/Resources/locale').exists(), 'Legacy gettext catalogs remain')
    localized = {path.parent.name for path in (app / 'Contents/Resources').glob('*.lproj/CommandPalette.strings')}
    check(localized == {'en.lproj', 'zh-Hans.lproj', 'zh-Hant.lproj', 'ja.lproj'},
          f'Unexpected command palette localizations: {localized}')
    check((app / 'Contents/Resources/terminfo/78/xterm-ghostty').exists() or
          (app / 'Contents/Resources/terminfo/x/xterm-ghostty').exists(), 'Terminal description missing')
    version = subprocess.check_output([str(executables[0]), '+version'], text=True)
    check(version.startswith('cghostty '), 'CLI identifies as another application')
    defaults = subprocess.check_output([str(executables[0]), '+show-config', '--default'], text=True)
    keys = {line.split('=', 1)[0].strip() for line in defaults.splitlines() if '=' in line}
    check(not any(key.startswith(('gtk-', 'linux-cgroup', 'auto-update')) for key in keys),
          'Removed platform/updater configuration is still exposed')
    check('cursor-effect' in keys, 'Native cursor effect is missing')
    check(not {'custom-shader', 'custom-shader-animation'} & keys, 'GLSL configuration remains')
    check(not {'class', 'language', 'x11-instance-name'} & keys, 'GTK-only configuration remains')
    help_text = subprocess.check_output([str(executables[0]), '+help'], text=True)
    check('+new-window' not in help_text and '+new-tab' not in help_text and '+toggle-quick-terminal' not in help_text,
          'GTK-only IPC action remains in the CLI')
    actions = subprocess.check_output([str(executables[0]), '+list-actions'], text=True)
    bindings = subprocess.check_output([str(executables[0]), '+list-keybinds', '--default'], text=True)
    check('inspector' not in actions.lower() and 'inspector' not in bindings.lower(),
          'Removed Inspector action or default binding is still exposed')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

print('PASS: macOS arm64 scope, independent identity, unsupported targets and removed build options' +
      (', release app architecture/resources/signature' if args.app else ''))
