#!/usr/bin/env python3
"""Regenerate macOS AppIcon sizes from the checked-in 1024px master using sips."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
catalog = root / "HermesMac/Assets.xcassets"
app_icon = catalog / "AppIcon.appiconset"
master = app_icon / "icon_512x512@2x.png"
if not master.is_file():
    raise SystemExit(f"Missing 1024px master icon: {master}")

images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        filename = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
        destination = app_icon / filename
        if destination != master:
            subprocess.run(
                ["sips", "-z", str(size * scale), str(size * scale), str(master), "--out", str(destination)],
                check=True, stdout=subprocess.DEVNULL,
            )
        images.append({"filename": filename, "idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x"})

info = {"author": "xcode", "version": 1}
(catalog / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
(app_icon / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")
