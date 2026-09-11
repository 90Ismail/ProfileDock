#!/usr/bin/env python3
"""Install ProfileDock locally; no Python packages required."""
import argparse
import base64
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
ROOT = Path.home() / 'Library/Application Support/ProfileDock/bridge'
CHROME = Path.home() / 'Library/Application Support/Google/Chrome'


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


DEFAULT_ICON_COLORS = [
    (10, 42, 92), (34, 139, 84), (104, 56, 160),
    (77, 166, 238), (135, 21, 48), (23, 103, 121),
]


def generate_icon(profile, index, target):
    """A large, badge-free circular photo on a colored rounded-square, with
    the profile label beneath it. Pillow is optional — callers fall back to
    a plain Chrome icon when it (or a cached Google avatar) isn't available.
    """
    try:
        from PIL import Image, ImageDraw, ImageFont, ImageOps
    except ImportError:
        return False
    photo_path = CHROME / profile['chromeDirectory'] / 'Google Profile Picture.png'
    if not photo_path.exists():
        return False
    color = tuple(profile['color']) if profile.get('color') else DEFAULT_ICON_COLORS[index % len(DEFAULT_ICON_COLORS)]
    size = 1024
    photo = Image.open(photo_path).convert('RGB')
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((12, 12, size - 12, size - 12), radius=210, fill=color)
    circle_d = 760
    photo_sq = ImageOps.fit(photo, (circle_d, circle_d), method=Image.LANCZOS)
    mask = Image.new('L', (circle_d, circle_d), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, circle_d, circle_d), fill=255)
    ring = Image.new('RGBA', (circle_d + 16, circle_d + 16), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((0, 0, circle_d + 16, circle_d + 16), fill=(255, 255, 255, 60))
    origin = ((size - circle_d - 16) // 2, 96)
    canvas.alpha_composite(ring, origin)
    canvas.paste(photo_sq, ((size - circle_d) // 2, 96 + 8), mask)
    text = profile['label'].upper()
    font_path = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'
    text_size = 150
    font = ImageFont.truetype(font_path, text_size)
    while draw.textbbox((0, 0), text, font=font)[2] > size - 140:
        text_size -= 2
        font = ImageFont.truetype(font_path, text_size)
    draw.text((size / 2, 930), text, font=font, fill='white', anchor='mm')
    canvas.save(target, format='ICNS')
    return True


def safe_python():
    """A Python interpreter Chrome can actually exec.

    macOS blocks apps like Chrome from executing anything under
    ~/Desktop, ~/Documents or ~/Downloads unless the user has granted
    that app Files & Folders access. If ProfileDock (or its venv) lives
    under one of those, sys.executable would silently fail every time
    Chrome tries to launch the native messaging host.
    """
    protected = tuple(str(Path.home() / p) for p in ('Desktop', 'Documents', 'Downloads'))
    for candidate in (sys.executable, '/opt/homebrew/bin/python3', '/usr/local/bin/python3', '/usr/bin/python3'):
        # Check the literal invoked path, not its resolved target: macOS's
        # Files & Folders protection blocks access based on the path used to
        # reach a file (even a symlink living under Desktop/Documents/
        # Downloads), regardless of where that symlink ultimately points.
        if candidate and Path(candidate).exists() and not str(Path(candidate)).startswith(protected):
            return candidate
    raise SystemExit('Could not find a Python interpreter outside Desktop/Documents/Downloads for the background helper.')


def status():
    profiles = json.loads((ROOT / 'profiles.json').read_text())
    ready = True
    for key, profile in profiles.items():
        try:
            state = json.loads((ROOT / 'state' / (key + '.json')).read_text())
            connected = state['connected'] and time.time() - state['updated'] < 5
        except (OSError, ValueError, KeyError):
            connected = False
        print(f"{profile['label']}: " + (f"Connected — {len(state['windows'])} window(s)" if connected else 'Waiting for Chrome extension'))
        ready &= connected
    return ready


def install(config):
    if sys.platform != 'darwin':
        raise SystemExit('ProfileDock requires macOS.')
    if subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode:
        raise SystemExit('Install Apple command line tools with: xcode-select --install\nThen run setup again.')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if config:
        profiles = json.loads(Path(config).read_text())
    else:
        cache = json.loads((CHROME / 'Local State').read_text())['profile']['info_cache']
        profiles = {}
        print('Give each Chrome profile a short Dock label. Press Enter to use its current name.')
        for i, (directory, info) in enumerate(cache.items()):
            label = input(f"{info.get('name', directory)} ({directory}) label: ").strip() or info.get('name', directory)
            profiles[f'profile{i+1}'] = {'label': label, 'chromeDirectory': directory}
    for key, profile in profiles.items():
        if not key or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789_-' for c in key):
            raise SystemExit('Profile keys must contain lowercase letters, digits, underscores or hyphens.')
        if not profile.get('label') or '/' in profile['label'] or ':' in profile['label']:
            raise SystemExit('Profile labels cannot be empty or contain / or :.')
    # The window picker is built directly into NativeLauncher (shown as an
    # in-process panel) rather than as a separate helper process: a second
    # process has no shared foreground state with the launcher, so handing
    # it focus was an unreliable cross-process race.
    run('xcrun', 'swiftc', '-O', SOURCE / 'bridge/NativeLauncher.swift', '-o', ROOT / 'ProfileDockLauncher')
    shutil.copy2(SOURCE / 'bridge/native_host.py', ROOT / 'native_host.py')
    # The public key gives all local profile variants a stable Chrome extension ID.
    public = ROOT / 'extension-public.der'
    if not public.exists():
        private = ROOT / 'temporary-key.pem'
        try:
            run('openssl', 'genrsa', '-out', private, '2048')
            run('openssl', 'rsa', '-in', private, '-pubout', '-outform', 'DER', '-out', public)
        finally:
            private.unlink(missing_ok=True)
    raw = public.read_bytes()
    extension_id = ''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(raw).hexdigest()[:32])
    for index, (key, profile) in enumerate(profiles.items()):
        extension = ROOT / 'extensions' / key
        shutil.copytree(SOURCE / 'extension', extension, dirs_exist_ok=True)
        manifest = json.loads((extension / 'manifest.json').read_text())
        manifest['key'] = base64.b64encode(raw).decode()
        manifest['name'] = 'ProfileDock — ' + profile['label']
        (extension / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        (extension / 'config.json').write_text(json.dumps({'profileKey': key, 'label': profile['label']}))
        app = ROOT / 'apps' / ('Chrome ' + profile['label'] + '.app')
        resources = app / 'Contents/Resources'
        executables = app / 'Contents/MacOS'
        resources.mkdir(parents=True, exist_ok=True)
        executables.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'ProfileDockLauncher', executables / 'ProfileDock')
        generated = ROOT / 'generated-icons' / (key + '.icns')
        generated.parent.mkdir(parents=True, exist_ok=True)
        if profile.get('icon'):
            icon = Path(profile['icon'])
        elif generate_icon(profile, index, generated):
            icon = generated
        else:
            icon = Path('/Applications/Google Chrome.app/Contents/Resources/app.icns')
        if icon.exists():
            shutil.copy2(icon, resources / 'app.icns')
        info = {'CFBundleIdentifier': 'local.profiledock.profile.' + key, 'CFBundleName': 'Chrome ' + profile['label'],
                'CFBundleExecutable': 'ProfileDock', 'CFBundleIconFile': 'app.icns', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'ProfileDockKey': key, 'ProfileDockLabel': profile['label'],
                'ProfileDockDirectory': profile['chromeDirectory']}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', app)
        profile['app'] = str(app)
    (ROOT / 'profiles.json').write_text(json.dumps(profiles, indent=2))
    (ROOT / 'profiles.json').chmod(0o600)
    import shlex
    wrapper = ROOT / 'native-host'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(safe_python()) + ' ' + shlex.quote(str(ROOT / 'native_host.py')) + '\n')
    wrapper.chmod(0o700)
    host = CHROME / 'NativeMessagingHosts/local.profiledock.bridge.json'
    host.parent.mkdir(parents=True, exist_ok=True)
    host.write_text(json.dumps({'name': 'local.profiledock.bridge', 'description': 'ProfileDock window connection',
                               'path': str(wrapper), 'type': 'stdio', 'allowed_origins': ['chrome-extension://' + extension_id + '/']}))
    print('\nApps built. Existing Dock shortcuts have not been replaced.\n')
    for key, p in profiles.items():
        print(f"{p['label']}: open chrome://extensions in that profile, enable Developer mode, click Load unpacked, choose:\n  {ROOT / 'extensions' / key}\n")
    print('Check connections: python3 setup.py --status\nOnce connected, open the apps folder and drag each profile app to the Dock:\n' + str(ROOT / 'apps'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Set up ProfileDock profile icons and live window indicators.')
    parser.add_argument('--config', help='Optional local JSON profile configuration')
    parser.add_argument('--status', action='store_true', help='Check which profiles are connected')
    args = parser.parse_args()
    if args.status:
        sys.exit(0 if status() else 1)
    install(args.config)
