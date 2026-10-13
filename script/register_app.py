#!/usr/bin/env python3
"""Remove competing project builds before registering the app being launched."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
with (app / "Contents/Info.plist").open("rb") as source:
    bundle_id = plistlib.load(source)["CFBundleIdentifier"]

lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
registry = subprocess.run([lsregister, "-dump"], check=True, capture_output=True, text=True).stdout
for entry in re.split(r"^-+$", registry, flags=re.MULTILINE):
    identifier = re.search(r"^identifier:\s+(.+)$", entry, re.MULTILINE)
    path = re.search(r"^path:\s+(.+) \(0x[0-9a-fA-F]+\)$", entry, re.MULTILINE)
    if not identifier or identifier[1] != bundle_id or not path:
        continue
    registered = Path(path[1]).resolve()
    # Only change this checkout's registrations; leave installed apps alone.
    if registered != app and registered.is_relative_to(root):
        subprocess.run([lsregister, "-u", str(registered)], check=True)
        print(f"Unregistered old build: {registered}")

# The directory timestamp may otherwise stay unchanged across incremental builds.
app.touch()
subprocess.run([lsregister, "-f", str(app)], check=True)
