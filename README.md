# ProfileDock

**A different Dock icon for every Chrome profile on macOS.**

Keep work, personal, and school browsing easy to recognize with colorful, labeled app icons. Click a launcher to select that profile through Chrome’s own **Profiles** menu. Chrome handles bringing its existing profile window forward or opening one when needed.

Built from a personal collection of AppleScript shortcuts, this public version uses configurable names and generated letter icons.

## Features

- Separate, recognizable Dock launchers with configurable labels, colors, and initials.
- Uses Chrome’s built-in profile switching. When a profile has several windows, a chooser lists their titles and tab counts.
- Matches profile names instead of fragile menu positions.
- One shared helper for macOS Accessibility permission.
- Launchers exit after handing off; they do not pretend to track whether a profile is running.
- No account sign-in, passwords, Chrome data extraction, analytics, or network calls in the tool.

## Requirements

- macOS with Google Chrome installed and its interface set to English.
- Python 3.10+ and Pillow (installed below).
- Existing Chrome profiles with **unique display names** in Chrome’s Profiles menu.

This is a macOS utility, not a Chrome extension. It does not create accounts or profiles.

## Setup

In a terminal in this repository:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp profiles.example.json profiles.local.json
```

Edit `profiles.local.json`. Set `chrome_name` to the **exact visible name in Chrome → Profiles**, not an email address or profile-directory name. Rename duplicate Chrome profiles first.

```json
[
  {"label": "Work", "chrome_name": "Work", "color": "#163B70", "initial": "W"},
  {"label": "Personal", "chrome_name": "Personal", "color": "#21865A", "initial": "P"},
  {"label": "School", "chrome_name": "School", "color": "#338CC7", "initial": "S"}
]
```

Build directly into your Applications folder:

```sh
python build.py --output "$HOME/Applications/ProfileDock"
open "$HOME/Applications/ProfileDock"
```

Drag `Chrome Work.app`, `Chrome Personal.app`, and the other launchers into the Dock. Keep **ProfileDock Helper.app** in the same folder as the launchers; it does not need to be pinned.

## First launch and permissions

Click a launcher. macOS may request permission for **ProfileDock Helper** to control Chrome or System Events. Allow these prompts to use profile switching.

If you see “not allowed assistive access,” open **System Settings → Privacy & Security → Accessibility**, add `ProfileDock Helper.app` using **+**, and enable it. You may need to authenticate. Check **Privacy & Security → Automation** for the helper’s Chrome and System Events permissions as well.

The apps are locally compiled AppleScript apps, not signed or notarized distribution binaries. Build from source on your own Mac. Do not disable Gatekeeper or System Integrity Protection.

## How it works

1. Each launcher reads its own location and passes its `profile.txt` to the neighboring helper.
2. The helper activates Chrome and waits for its Profiles menu.
3. It finds exactly one matching menu item and selects it.
4. It briefly brings each normal Chrome window forward and reads the checked profile menu item to identify membership.
5. One matching window is focused immediately; multiple matching windows appear in a chooser. Cancel leaves the initially selected profile window in front.

There is no window database, browser-history reader, or account tracker. Running indicators in the Dock are controlled by macOS; these launchers are not reliable per-profile activity indicators. Incognito windows are excluded. The scan can visibly switch windows or Spaces and briefly restore minimized windows before minimizing them again. Avoid interacting with Chrome during the scan. The chooser is a native dialog, not a Windows taskbar thumbnail preview.

## Customize or rebuild

Change the local JSON and choose a **new** output directory. The builder refuses to overwrite existing folders. After checking the new launchers, replace the old Dock shortcuts manually. Rebuilding the helper can require renewing its Accessibility permission.

`label` controls the app/icon label (letters, numbers, spaces, hyphens, underscores; up to 30 characters). `initial` takes one or two characters. `color` accepts a Pillow color such as `#163B70`.

The example icons are generic letter artwork generated locally. No personal photographs or account information are included. `profiles.local.json` and generated app bundles are ignored by Git.

## Troubleshooting

- **Profile not found:** Match spelling and capitalization in Chrome’s Profiles menu. Use distinct display names.
- **No Profiles menu:** Chrome must use English; localized menu labels are not supported yet. Chrome UI updates may require changes to the AppleScript.
- **Repeated permission error:** Remove the old helper entry in Accessibility and add the current helper from its final location.
- **Icon looks stale:** Remove and re-add that launcher in the Dock.
- **New window opens:** Chrome may have no reusable window for that profile. This tool delegates to Chrome; it cannot guarantee which window Chrome selects.

## Development

```sh
python -m unittest discover -s tests -v
python build.py --config profiles.example.json --output build/demo
```

Tests validate configuration handling. Building on macOS checks AppleScript compilation and icon generation. End-to-end window switching needs real Chrome profiles and interactive macOS permissions.

## Remove

Remove the shortcuts from the Dock and delete only the generated ProfileDock folder. This does not delete Chrome profiles or browsing data. Remove the helper’s Accessibility permission if desired.

## License

MIT. Independent project; not affiliated with Google or Apple.
