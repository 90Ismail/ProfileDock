# ProfileDock

**A Dock icon for every Chrome profile on macOS, that knows each profile's windows.**

Click a profile's icon to go straight to its windows. Hover it to see them listed. Work, school, and personal browsing each get their own recognizable icon, and none of them stop at Chrome's "Who's using Chrome?" picker.

Everything stays on your Mac: no accounts, analytics, or network calls. Window titles, tab counts, and site names travel from Chrome to the Dock through local files only, never URLs.

## How it works

`setup.py` installs four pieces:

- **A launcher app per profile** (`Chrome Work.app`, …) for the Dock.
- **A small Chrome extension per profile** that reports that profile's windows.
- **A local bridge** (`native_host.py`) that Chrome starts for the extension. It passes window lists to the Dock and commands back to Chrome.
- **The ProfileDock Agent**, a background helper started at login. It draws the hover list and handles the things launchers can't (see below). It needs Accessibility permission.

## Requirements

- macOS with Google Chrome, its interface set to English.
- Python 3.10 or later. No packages are needed; Pillow is optional, for icons made from each profile's Google picture.
- Xcode command line tools (`xcode-select --install`).
- Chrome profiles with distinct names.

## Setup

In a terminal in this repository:

```sh
python3 setup.py                     # asks for a short Dock label per Chrome profile
python3 setup.py --config my.json    # or reuse a saved configuration
python3 setup.py --status            # each profile's connection, and anything to fix
```

A configuration maps a short key to a label and Chrome profile folder. It can also set a `color` as `[r, g, b]` and an `icon` path:

```json
{
  "work": {"label": "Work", "chromeDirectory": "Default"},
  "school": {"label": "School", "chromeDirectory": "Profile 1"}
}
```

Then, once for each profile:

1. Load its extension: in that profile, open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose the folder `setup.py` printed.
2. Drag its app from the printed `apps` folder into the Dock.
3. When macOS asks, give **ProfileDock Agent** Accessibility permission (System Settings → Privacy & Security → Accessibility).

Running `setup.py` again updates everything in place, and running extensions reload themselves. The exception is extensions older than 0.2.0, which can't do that: click ↻ on ProfileDock in `chrome://extensions` once per profile. Restarting Chrome is not enough, because Chrome keeps running a folder-loaded extension's old background code until it's reloaded. `--status` tells you which profiles need this.

A profile with no open windows shows as not connected. Chrome stops its extension until a window opens.

## Using it

**Clicking a profile icon** always does something visible:

- **The profile has no windows:** one opens.
- **Another app or profile is in front:** that profile's most recently used window comes forward.
- **That profile is already in front:** its next window comes forward, so repeated clicks visit them all.

Minimized windows stay put while a visible window can be shown, as with any Dock icon. A double-click counts as one click.

**Hovering an icon** lists the profile's windows with each one's favicon, site, and tab count, in the order clicks walk through them:
- **Current** marks the window in front, and **Last used** marks the one a click would bring back.
- Click a row to switch to that window. Close a window with **×** or a middle-click, or open another with **New Window**.
- The list updates while it's open and closes with Esc.

**Right-clicking an icon** shows the same windows as a Dock menu.

**Chrome's own Dock icon** never stops at the "Who's using Chrome?" picker. Clicked while Chrome has no windows open, it opens the profile you used last, as Chrome does with its picker turned off.

The Agent also:
- adds an **Option+Tab** window switcher for all apps (hold Option and press Tab, or point and click; Esc cancels);
- makes the **green button** fill the screen (Option-click it for full screen);
- minimizes profile windows **into their own Dock icon** (yellow button or Cmd+M);
- resumes a launcher if macOS ever leaves one frozen at launch, so clicks are never lost.

## Troubleshooting

- **A profile isn't connected:** run `python3 setup.py --status`. It says whether the extension is missing, out of date, or just has no windows open.
- **Clicks open the profile through Chrome's Profiles menu:** that's the fallback when the bridge isn't connected yet. It still lands on the right profile.
- **Opening Chrome from Spotlight or Launchpad shows the picker:** untick **Show on startup** at the bottom of the picker.
- **Icon looks stale:** remove that launcher from the Dock and drag it in again.
- **Logs:** `~/Library/Application Support/ProfileDock/agent.log` (Agent) and `bridge/host.log` (bridge errors).

## Simple version without the extension (build.py)

`build.py` builds an older, simpler variant. It's made of AppleScript launchers that pick the profile in Chrome's Profiles menu, plus a helper that learns windows as you use them. It needs Pillow (`pip install -r requirements.txt`) and its own configuration (`profiles.example.json`):

```sh
python build.py --config profiles.local.json --output "$HOME/Applications/ProfileDock"
```

It can't see a profile's windows until you've visited them, and it has no hover list. Use `setup.py` unless you can't install the extension.

## Development

```sh
python3 -m unittest discover -s tests -v
```

The tests cover:
- the bridge;
- which window a Dock click picks (`bridge/WindowChoice.swift`, built with the Xcode tools);
- the Chrome extension, run against a fake Chrome API (needs Node.js);
- the `--status` messages and `build.py`'s configuration checks.

Tests skip what the machine can't run. Window switching itself needs real Chrome profiles and macOS permissions, so test it by hand.

## Remove

1. Remove the icons from the Dock.
2. Unload the Agent and delete its files:

   ```sh
   launchctl bootout gui/$(id -u)/local.profiledock.agent
   rm ~/Library/LaunchAgents/local.profiledock.agent.plist
   rm -r ~/Library/Application\ Support/ProfileDock
   ```
3. Remove the extension from each profile, and ProfileDock Agent from Accessibility.

This doesn't touch Chrome profiles or browsing data.

## License

MIT. Independent project; not affiliated with Google or Apple.
