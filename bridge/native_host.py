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
MAX_MESSAGE = 4 * 1024 * 1024
MAX_ICON = 64 * 1024
WINDOW_STATES = {"normal", "minimized", "maximized", "fullscreen"}
COMMANDS = {"focus", "close"}
ICON = re.compile(r"data:image/(png|x-icon|vnd\.microsoft\.icon|jpeg|gif|webp|svg\+xml);base64,[A-Za-z0-9+/=]+")
# How long to wait before asking an out-of-date extension to reload again.
RELOAD_COOLDOWN = 600


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
        clean = {"id": w["id"], "title": str(w.get("title", "Chrome window"))[:1000],
                 "tabCount": max(0, int(w.get("tabCount", 0))),
                 "focused": focused, "lastFocused": times[w["id"]]}
        # Optional extras for the Dock list: a host name (never a URL) and
        # the active tab's favicon.
        if w.get("state") in WINDOW_STATES:
            clean["state"] = w["state"]
        host = w.get("host")
        if isinstance(host, str) and re.fullmatch(r"[A-Za-z0-9.-]{1,253}", host):
            clean["host"] = host
        icon = w.get("icon")
        if isinstance(icon, str) and len(icon) <= MAX_ICON and ICON.fullmatch(icon):
            clean["icon"] = icon
        result.append(clean)
    was_focused.clear()
    was_focused.update(focused_now)
    return result


def installed_extension_version(key):
    try:
        return json.loads((ROOT / "extensions" / key / "manifest.json").read_text()).get("version")
    except (OSError, ValueError):
        return None


def should_reload(key, running_version):
    """True when the extension files on disk are newer than the code Chrome is
    running, so `setup.py` updates reach Chrome without a manual reload. A
    marker keeps a mismatch that a reload can't fix (the extension loaded
    from some other folder) from turning into a reload loop."""
    installed = installed_extension_version(key)
    if not installed or installed == running_version:
        return False
    marker = ROOT / "reloads" / (key + ".json")
    try:
        if time.time() - json.loads(marker.read_text()).get("at", 0) < RELOAD_COOLDOWN:
            return False
    except (OSError, ValueError, AttributeError):
        pass
    atomic(marker, {"at": time.time(), "from": running_version, "to": installed})
    return True


def main():
    config = json.loads((ROOT / "profiles.json").read_text())
    profile = None
    windows = []
    features = []
    version = None
    last_focused = {}
    last_write = 0
    last_launch = 0
    buffer = b""
    state_path = None
    commands = None
    active_path = None
    try:
        while True:
            ready, _, _ = select.select([sys.stdin.fileno()], [], [], 0.1)
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
                        offered = message.get("features")
                        features = [f for f in offered if f in ("close", "favicon", "reload")] if isinstance(offered, list) else []
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
                        offered_version = message.get("version")
                        version = offered_version if isinstance(offered_version, str) and len(offered_version) < 40 else None
                        if "reload" in features and version and should_reload(key, version):
                            send({"type": "reload"})
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
                    atomic(state_path, {"session": SESSION, "connected": True, "updated": now,
                                        "version": version, "features": features, "windows": windows})
                    last_write = now
                heartbeat = ROOT / "launchers" / (profile + ".json")
                running = False
                try:
                    live = json.loads(heartbeat.read_text())
                    os.kill(int(live["pid"]), 0)
                    # The pid check already proves the launcher is alive. A
                    # stale heartbeat on top of that only means its timer was
                    # delayed (App Nap); "relaunching" a live app delivers a
                    # Reopen event instead, which would steal focus.
                    running = True
                except (OSError, ValueError, KeyError):
                    pass
                # 8s, not 1.5s: an ad-hoc-signed local build can take several
                # seconds to cold-launch before its first heartbeat lands, and
                # a second `open` on a still-launching app arrives as Reopen.
                if windows and not running and now - last_launch > 8:
                    subprocess.run(["/usr/bin/open", "-g", "-j", "-a", config[profile]["app"], "--args", "--indicator-only"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    last_launch = now
                for file in commands.glob("*.json"):
                    try:
                        command = json.loads(file.read_text())
                        if (command.get("session") == SESSION and command.get("type") in COMMANDS
                                and any(w["id"] == command.get("windowId") for w in windows)):
                            send({"type": command["type"], "windowId": command["windowId"], "requestId": file.stem})
                        elif re.fullmatch(r"[A-Za-z0-9_-]{1,64}", file.stem):
                            # Meant for an older connection, or the window is
                            # gone: answer now so the sender falls back at once
                            # instead of waiting out its timeout.
                            atomic(ROOT / "results" / (file.stem + ".json"), {"ok": False})
                    except (OSError, ValueError):
                        pass
                    finally:
                        file.unlink(missing_ok=True)
    finally:
        if state_path:
            try:
                current = json.loads(state_path.read_text())
                if current.get("session") == SESSION:
                    atomic(state_path, {"session": SESSION, "connected": False, "updated": time.time(),
                                        "version": version, "windows": []})
            except (OSError, ValueError):
                pass


def run():
    try:
        main()
    except BrokenPipeError:
        # Chrome closed the connection mid-message (its window or extension
        # went away): a normal end, not a crash. Point stdout at /dev/null so
        # Python's exit-time flush doesn't hit the closed pipe again.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    except Exception:
        import traceback
        log = ROOT / "host.log"
        log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Chrome retries a failing host every few seconds; keep the log small.
        if log.exists() and log.stat().st_size > 256 * 1024:
            log.write_text(log.read_text()[-64 * 1024:])
        with log.open("a") as f:
            f.write(f"--- {time.ctime()} (pid {os.getpid()}) ---\n")
            traceback.print_exc(file=f)
        raise


if __name__ == "__main__":
    run()
