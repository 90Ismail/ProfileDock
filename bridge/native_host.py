#!/usr/bin/env python3
"""Chrome native messaging host. All state and requests remain on this Mac."""
import json
import os
import re
import select
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path.home() / "Library/Application Support/ProfileDock/bridge"
SESSION = uuid.uuid4().hex
MAX_MESSAGE = 1024 * 1024


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + "." + SESSION + ".tmp")
    temp.write_text(json.dumps(value))
    temp.chmod(0o600)
    temp.replace(path)


def send(message):
    raw = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(raw)) + raw)
    sys.stdout.buffer.flush()


def open_profile(label):
    """Click Chrome's own Profiles menu item matching this profile's label.

    Command-line invocation (`open -a`, `-na`, or the raw binary) cannot
    reliably make an already-running Chrome open a specific *other* profile,
    and Chrome's actual menu text often isn't an exact match for our Dock
    label (e.g. "Ismail (STU)" for label "STU"), so this matches by
    substring rather than requiring equality.
    """
    escaped = label.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
    tell application "Google Chrome" to activate
    tell application "System Events" to tell process "Google Chrome"
        repeat 50 times
            if exists menu bar item "Profiles" of menu bar 1 then exit repeat
            delay 0.1
        end repeat
        set profileMenu to menu 1 of menu bar item "Profiles" of menu bar 1
        set menuNames to name of every menu item of profileMenu
        set targetIndex to 0
        repeat with i from 1 to count menuNames
            if (item i of menuNames) contains "{escaped}" then
                set targetIndex to i
                exit repeat
            end if
        end repeat
        if targetIndex > 0 then click menu item targetIndex of profileMenu
    end tell
    '''
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True)


def clean_windows(windows, memory):
    """Validate a snapshot. `memory` persists between snapshots and records,
    per window, the last moment it was seen focused — including the moment
    it *lost* focus. A Dock click always blurs Chrome before the launcher
    reads state, so "lost focus a second ago" is how the launcher can still
    tell this profile was the one in front."""
    if not isinstance(windows, list) or len(windows) > 1000:
        raise ValueError("Invalid window list")
    times = memory.setdefault("times", {})
    was_focused = memory.setdefault("focused", set())
    result = []
    now = time.time()
    focused_now = set()
    for w in windows:
        if not isinstance(w, dict) or type(w.get("id")) is not int:
            raise ValueError("Invalid window ID")
        focused = bool(w.get("focused", False))
        if focused:
            focused_now.add(w["id"])
        if focused or w["id"] in was_focused:
            times[w["id"]] = now
        times.setdefault(w["id"], 0)
        result.append({"id": w["id"], "title": str(w.get("title", "Chrome window"))[:1000],
                       "tabCount": max(0, int(w.get("tabCount", 0))),
                       "focused": focused, "lastFocused": times[w["id"]]})
    was_focused.clear()
    was_focused.update(focused_now)
    return result


def main():
    config = json.loads((ROOT / "profiles.json").read_text())
    profile = None
    windows = []
    last_focused = {}
    last_write = 0
    last_launch = 0
    buffer = b""
    state_path = None
    commands = None
    active_path = None
    # A profile with no window open (and that Chrome wasn't launched
    # targeting) typically has no active background context at all, so no
    # native_host.py instance ever receives "hello" for it — nobody would be
    # listening on that profile's own commands/<key>/ folder. Every running
    # instance instead polls this one shared folder for "please open this
    # profile" requests, whichever of them happens to still be alive.
    global_requests = ROOT / "open-requests"
    global_requests.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        while True:
            for file in global_requests.glob("*.json"):
                claimed = file.with_suffix(".claimed")
                try:
                    file.rename(claimed)
                except OSError:
                    continue
                try:
                    request = json.loads(claimed.read_text())
                    if isinstance(request.get("label"), str):
                        open_profile(request["label"])
                except (OSError, ValueError):
                    pass
                finally:
                    claimed.unlink(missing_ok=True)
            ready, _, _ = select.select([sys.stdin.fileno()], [], [], 0.15)
            if ready:
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                while len(buffer) >= 4:
                    size = struct.unpack("=I", buffer[:4])[0]
                    if size > MAX_MESSAGE:
                        raise ValueError("Message too large")
                    if len(buffer) < size + 4:
                        break
                    message = json.loads(buffer[4:4 + size])
                    buffer = buffer[4 + size:]
                    if message.get("type") == "hello":
                        key = message.get("profile", "")
                        if profile or not re.fullmatch(r"[a-z0-9_-]{1,40}", key) or key not in config:
                            raise ValueError("Unknown profile")
                        profile = key
                        state_path = ROOT / "state" / (key + ".json")
                        commands = ROOT / "commands" / key
                        commands.mkdir(parents=True, exist_ok=True, mode=0o700)
                        # Chrome's MV3 service worker can restart and open a
                        # fresh native-messaging connection without reliably
                        # closing the old one's stdin, leaving it running
                        # forever. Claiming this marker lets every older
                        # instance for the same profile notice on its next
                        # tick that a newer connection has taken over, so it
                        # can exit instead of piling up and racing the new
                        # one for command files.
                        active_path = ROOT / "active" / (key + ".json")
                        atomic(active_path, {"session": SESSION, "pid": os.getpid(), "updated": time.time()})
                        send({"type": "ready"})
                    elif message.get("type") == "result" and profile and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(message.get("requestId", ""))):
                        # Lets the launcher raise Chrome only once the right
                        # window is in front, instead of guessing with a delay.
                        results = ROOT / "results"
                        atomic(results / (message["requestId"] + ".json"), {"ok": bool(message.get("ok"))})
                        for old in results.glob("*.json"):  # ones a launcher stopped waiting for
                            try:
                                if time.time() - old.stat().st_mtime > 30:
                                    old.unlink()
                            except OSError:
                                pass
                    elif message.get("type") == "snapshot" and profile and message.get("profile") == profile:
                        windows = clean_windows(message.get("windows"), last_focused)
                        last_write = 0
            if profile:
                now = time.time()
                try:
                    if json.loads(active_path.read_text()).get("session") != SESSION:
                        break  # superseded by a newer connection for this profile
                except (OSError, ValueError):
                    pass
                if now - last_write > 0.2:
                    atomic(state_path, {"session": SESSION, "connected": True, "updated": now, "windows": windows})
                    last_write = now
                heartbeat = ROOT / "launchers" / (profile + ".json")
                running = False
                try:
                    live = json.loads(heartbeat.read_text())
                    os.kill(int(live["pid"]), 0)
                    # The pid check above already proves the process is
                    # alive. A stale heartbeat on top of that just means its
                    # 1s timer got delayed (e.g. App Nap while backgrounded
                    # with no visible window) — it does NOT mean the process
                    # died. Relaunching it in that case sends a macOS Reopen
                    # event to the still-alive process, which unconditionally
                    # raises Chrome (NativeLauncher's applicationShouldHandleReopen
                    # -> choose() -> activateChrome()), stealing focus from
                    # whatever app the user is actually using. A hung-but-alive
                    # process wouldn't be fixed by a reopen event either, so
                    # there's no upside to the staleness check — only false
                    # positives.
                    running = True
                except (OSError, ValueError, KeyError):
                    pass
                # 8s, not 1.5s: an ad-hoc-signed local build can take several
                # seconds to cold-launch (Gatekeeper verification, framework
                # loading, more under system load) before its first heartbeat
                # write lands. Retrying sooner than that risks a second `open
                # -a` landing on the still-launching-but-now-alive process,
                # which macOS delivers as a Reopen event instead of a second
                # launch — see the comment above on why that steals focus.
                if windows and not running and now - last_launch > 8:
                    subprocess.run(["/usr/bin/open", "-g", "-j", "-a", config[profile]["app"], "--args", "--indicator-only"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    last_launch = now
                for file in commands.glob("*.json"):
                    try:
                        command = json.loads(file.read_text())
                        if command.get("session") == SESSION and command.get("type") == "focus" and any(w["id"] == command.get("windowId") for w in windows):
                            send({"type": "focus", "windowId": command["windowId"], "requestId": file.stem})
                    except (OSError, ValueError):
                        pass
                    finally:
                        file.unlink(missing_ok=True)
    finally:
        if state_path:
            try:
                current = json.loads(state_path.read_text())
                if current.get("session") == SESSION:
                    atomic(state_path, {"session": SESSION, "connected": False, "updated": time.time(), "windows": []})
            except (OSError, ValueError):
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        log = ROOT / "host.log"
        log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with log.open("a") as f:
            f.write(f"--- {time.ctime()} (pid {os.getpid()}) ---\n")
            traceback.print_exc(file=f)
        raise
