#!/usr/bin/env python3
"""Build configurable macOS Dock launchers for Chrome profiles."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent


def validate(profiles):
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("Config must be a nonempty list.")
    labels, names = set(), set()
    for p in profiles:
        if not isinstance(p, dict):
            raise ValueError("Each profile must be an object.")
        label, name = p.get("label", ""), p.get("chrome_name", "")
        if not isinstance(label, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9 _-]{0,29}", label
        ):
            raise ValueError(
                "Labels must be 1–30 letters, numbers, spaces, underscores or hyphens."
            )
        if not isinstance(name, str) or not name.strip() or any(c in name for c in "\r\n\0"):
            raise ValueError("chrome_name must be a nonempty single line.")
        if label.casefold() in labels or name in names:
            raise ValueError("Labels and Chrome names must be unique.")
        labels.add(label.casefold())
        names.add(name)
        ImageColor.getrgb(p.get("color", "#163B70"))
        initial = p.get("initial", label[0])
        if not isinstance(initial, str) or not 1 <= len(initial) <= 2:
            raise ValueError("initial must be one or two characters.")
    return profiles


def icon(profile, target):
    image = Image.new("RGBA", (1024, 1024))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((12, 12, 1012, 1012), radius=210, fill=profile.get("color", "#163B70"))
    fontpath = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    for text, size, y in [
        (profile.get("initial", profile["label"][0]), 470, 340),
        (profile["label"].upper(), 125, 830),
    ]:
        font = ImageFont.truetype(fontpath, size)
        while draw.textbbox((0, 0), text, font=font)[2] > 900:
            size -= 2
            font = ImageFont.truetype(fontpath, size)
        draw.text((512, y), text, font=font, fill="white", anchor="mm")
    image.save(target, format="ICNS")


def compile_app(source, app):
    subprocess.run(["/usr/bin/osacompile", "-o", str(app), str(source)], check=True)
    plistpath = app / "Contents/Info.plist"
    with plistpath.open("rb") as f:
        plist = plistlib.load(f)
    plist["LSUIElement"] = True
    with plistpath.open("wb") as f:
        plistlib.dump(plist, f)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "profiles.local.json")
    parser.add_argument("--output", type=Path, default=ROOT / "build/ProfileDock")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Building apps requires macOS.")
    profiles = validate(json.loads(args.config.read_text()))
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error(
            "Output already exists. Choose a new output folder; existing apps are never overwritten."
        )
    output.mkdir(parents=True)
    helper = output / "ProfileDock Helper.app"
    compile_app(ROOT / "switcher.applescript", helper)
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", str(ROOT / "WindowMenu.swift"),
        "-o", str(helper / "Contents/Resources/ProfileDockMenu"),
    ], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(helper)], check=True)
    for profile in profiles:
        app = output / f"Chrome {profile['label']}.app"
        compile_app(ROOT / "launcher.applescript", app)
        resources = app / "Contents/Resources"
        (resources / "profile.txt").write_text(profile["chrome_name"], encoding="utf-8")
        icon(profile, resources / "applet.icns")
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
    print(f"Created {len(profiles)} launchers in {output}")
    print("Keep all apps together. Drag individual Chrome launchers into the Dock.")


if __name__ == "__main__":
    main()
