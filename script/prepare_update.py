#!/usr/bin/env python3
"""Prepare version metadata and a signed Sparkle feed for a stable GitHub release."""
import argparse
import html
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPOSITORY = "https://github.com/y-not-u/hermes-client-for-mac"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def release_version(tag):
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
        raise ValueError("Stable release tags must use vMAJOR.MINOR.PATCH (for example v0.1.0).")
    return tag[1:]


def check_appcast(path, tag, archive):
    root = ET.parse(path).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected one release in the generated appcast.")
    item = items[0]
    enclosure = item.find("enclosure")
    expected = f"{REPOSITORY}/releases/download/{tag}/{archive.name}"
    if enclosure is None or enclosure.get("url") != expected:
        raise ValueError("Appcast does not reference the immutable release archive URL.")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("Appcast archive size does not match.")
    if not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        raise ValueError("Appcast archive is unsigned.")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") != release_version(tag):
        raise ValueError("App bundle version does not match the release tag.")
    build = item.findtext(f"{{{SPARKLE}}}version", "")
    if not build.isdecimal() or int(build) < 1:
        raise ValueError("Appcast is missing a positive build number.")
    return enclosure.get(f"{{{SPARKLE}}}edSignature")


def run(command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        # Signing tools use a private-key file; do not forward captured output.
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}).")


def generate_appcast(archive, output_dir, tools, tag, private_key):
    release_version(tag)
    if not private_key.strip():
        raise ValueError("SPARKLE_PRIVATE_KEY is required for publishing updates.")
    output_dir.mkdir(parents=True, exist_ok=False)
    staged = output_dir / archive.name
    shutil.copy2(archive, staged)
    release_url = f"{REPOSITORY}/releases/tag/{tag}"
    staged.with_suffix(".html").write_text(
        f'<p>Hermes {html.escape(release_version(tag))}</p>'
        f'<p><a href="{html.escape(release_url, quote=True)}">查看完整更新记录</a></p>')
    feed = output_dir / "appcast.xml"
    with tempfile.TemporaryDirectory(prefix="hermes-appcast-key-") as directory:
        key_file = Path(directory) / "key"
        key_file.write_text(private_key.strip())
        key_file.chmod(0o600)
        run([str(tools / "generate_appcast"), "--ed-key-file", str(key_file),
             "--maximum-deltas", "0", "--embed-release-notes", "--link", release_url,
             "--download-url-prefix", f"{REPOSITORY}/releases/download/{tag}/",
             str(output_dir)])
        signature = check_appcast(feed, tag, staged)
        run([str(tools / "sign_update"), "--verify", "--ed-key-file", str(key_file),
             str(staged), signature])
        # SURequireSignedFeed also authenticates the version metadata and notes.
        run([str(tools / "sign_update"), "--verify", "--ed-key-file", str(key_file), str(feed)])
    return feed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata = commands.add_parser("metadata")
    metadata.add_argument("--tag")
    metadata.add_argument("--build", type=int, required=True)
    metadata.add_argument("--github-env", type=Path, required=True)
    appcast = commands.add_parser("appcast")
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--archive", type=Path, required=True)
    appcast.add_argument("--output-dir", type=Path, required=True)
    appcast.add_argument("--sparkle-bin", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "metadata":
            version = release_version(args.tag) if args.tag else "0.1.0"
            if args.build < 1:
                raise ValueError("Build number must be positive.")
            with args.github_env.open("a") as output:
                output.write(f"HERMES_MARKETING_VERSION={version}\nHERMES_BUILD_NUMBER={args.build}\n")
        else:
            feed = generate_appcast(args.archive.resolve(), args.output_dir.resolve(),
                                    args.sparkle_bin.resolve(), args.tag,
                                    os.environ.get("SPARKLE_PRIVATE_KEY", ""))
            print(f"Signed and verified update feed: {feed}")
    except (ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
