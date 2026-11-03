"""Regression checks for stable release metadata and authenticated update feeds."""
from pathlib import Path
import base64
from contextlib import redirect_stdout
import io
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from prepare_update import REPOSITORY, SPARKLE, check_appcast, generate_appcast, release_version
import setup_update_signing


class PrepareUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "HermesMac.zip"
        self.archive.write_bytes(b"test archive")
        self.feed = self.root / "appcast.xml"
        self.write_feed()

    def write_feed(self, *, url=None, size=None, signature="test-signature", version="0.1.0", build="42"):
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
        ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
        ET.SubElement(item, "enclosure", {
            "url": url or f"{REPOSITORY}/releases/download/v0.1.0/HermesMac.zip",
            "length": str(size if size is not None else self.archive.stat().st_size),
            f"{{{SPARKLE}}}edSignature": signature})
        ET.ElementTree(root).write(self.feed)

    def test_stable_tags_only(self):
        self.assertEqual(release_version("v1.2.3"), "1.2.3")
        for tag in ["v1.2", "1.2.3", "v01.2.3", "v1.2.3-beta", "v1.2.3\nINJECT=value"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag)

    def test_valid_feed_references_exact_archive(self):
        self.assertEqual(check_appcast(self.feed, "v0.1.0", self.archive), "test-signature")

    def test_rejects_unsigned_wrong_version_or_mutable_download(self):
        for invalid in [dict(signature=""), dict(size=1), dict(version="0.2.0"),
                        dict(build=""), dict(build="0"), dict(build="revision-sha"),
                        dict(url=f"{REPOSITORY}/releases/latest/download/HermesMac.zip")]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.write_feed(**invalid)
                check_appcast(self.feed, "v0.1.0", self.archive)

    def test_rejects_ambiguous_feed(self):
        root = ET.parse(self.feed)
        root.getroot().find("channel").append(ET.Element("item"))
        root.write(self.feed)
        with self.assertRaises(ValueError):
            check_appcast(self.feed, "v0.1.0", self.archive)

    def test_missing_key_fails_before_staging(self):
        output = self.root / "updates"
        with self.assertRaises(ValueError):
            generate_appcast(self.archive, output, self.root, "v0.1.0", "")
        self.assertFalse(output.exists())

    def test_signing_verifies_archive_and_feed_and_removes_key(self):
        output = self.root / "updates"
        commands = []
        keys = []

        def fake_run(command):
            commands.append(command)
            key = Path(command[command.index("--ed-key-file") + 1])
            self.assertEqual(key.read_text(), "test-private-key")
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            keys.append(key)
            if Path(command[0]).name == "generate_appcast":
                (output / "appcast.xml").write_bytes(self.feed.read_bytes())

        with patch("prepare_update.run", side_effect=fake_run):
            generated = generate_appcast(self.archive, output, self.root, "v0.1.0", "test-private-key")
        self.assertTrue(generated.exists())
        self.assertEqual(len(commands), 3)
        self.assertTrue(all("--verify" in command for command in commands[1:]))
        self.assertFalse(any(key.exists() for key in keys))
        self.assertTrue((output / "HermesMac.html").exists())

    def test_failed_generation_removes_private_key(self):
        keys = []

        def fail(command):
            keys.append(Path(command[command.index("--ed-key-file") + 1]))
            raise RuntimeError("signing failed")

        with patch("prepare_update.run", side_effect=fail), self.assertRaises(RuntimeError):
            generate_appcast(self.archive, self.root / "updates", self.root, "v0.1.0", "private")
        self.assertFalse(any(key.exists() for key in keys))


class UpdateKeySetupTests(unittest.TestCase):
    def test_published_key_is_reused_and_cannot_be_silently_replaced(self):
        for state in ["matching", "missing", "different"]:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "HermesMac").mkdir()
                public = base64.b64encode(bytes([1]) * 32).decode()
                plist = root / "HermesMac/Info.plist"
                plist.write_bytes(plistlib.dumps({"SUPublicEDKey": public}))
                calls = []
                exports = []

                def fake_run(command, **kwargs):
                    calls.append(command)
                    if "-p" in command:
                        if state == "missing":
                            raise SystemExit("Restore the original key first")
                        if state == "different":
                            return base64.b64encode(bytes([2]) * 32)
                        return public.encode()
                    if "-x" in command:
                        export = Path(command[-1])
                        export.write_text("test-private-key")
                        exports.append(export)
                    if command[:3] == ["gh", "secret", "set"]:
                        self.assertEqual(kwargs["input"], b"test-private-key")
                    return b"{}"

                with patch.object(setup_update_signing, "ROOT", root), \
                     patch.object(setup_update_signing, "run", side_effect=fake_run), \
                     patch("sys.argv", ["setup_update_signing.py", "--sparkle-bin", str(root)]), \
                     redirect_stdout(io.StringIO()):
                    if state == "matching":
                        setup_update_signing.main()
                    else:
                        with self.assertRaises(SystemExit):
                            setup_update_signing.main()
                self.assertEqual(any(command[:3] == ["gh", "secret", "set"] for command in calls),
                                 state == "matching")
                self.assertFalse(any(len(command) == 3 and command[1] == "--account" for command in calls))
                self.assertFalse(any(export.exists() for export in exports))
                self.assertEqual(plistlib.loads(plist.read_bytes())["SUPublicEDKey"], public)


if __name__ == "__main__":
    unittest.main()
