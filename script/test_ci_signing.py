"""Exercise CI signing with a throwaway certificate and mocked system keychains."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CISigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        script = Path(__file__).with_name("setup_ci_signing.sh")
        shutil.copy(script, self.root / script.name)
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin",
                        GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted",
                        GITHUB_EVENT_NAME="push", RUNNER_TEMP=str(self.root),
                        GITHUB_ENV=str(self.root / "github-env"),
                        HERMES_SIGNING_P12_PASSWORD="test-only-password",
                        TEST_ROOT=str(self.root))
        self.env.pop("HERMES_SIGNING_P12_BASE64", None)
        self.run_command(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey",
                          "rsa:2048", "-nodes", "-days", "1", "-subj",
                          "/CN=HermesMac Local Development", "-keyout",
                          str(self.root / "key.pem"), "-out", str(self.root / "cert.pem")])
        self.run_command(["/usr/bin/openssl", "pkcs12", "-export", "-inkey",
                          str(self.root / "key.pem"), "-in", str(self.root / "cert.pem"),
                          "-out", str(self.root / "identity.p12"),
                          "-passout", "env:HERMES_SIGNING_P12_PASSWORD"])
        self.env["HERMES_SIGNING_P12_BASE64"] = base64.b64encode(
            (self.root / "identity.p12").read_bytes()).decode()
        fingerprint = self.run_command(["/usr/bin/openssl", "x509", "-in",
                                       str(self.root / "cert.pem"), "-noout",
                                       "-fingerprint", "-sha1"]).stdout
        self.fingerprint = fingerprint.strip().split("=")[1].replace(":", "")
        self.env["TEST_FINGERPRINT"] = self.fingerprint
        self.write_executable("security", '''#!/bin/bash
set -eu
echo "$1" >> "$TEST_ROOT/operations"
case "$1" in
  list-keychains)
    if [ "$#" -eq 3 ]; then echo '"/tmp/existing.keychain-db"'; fi ;;
  find-identity)
    echo "1) $TEST_FINGERPRINT \\"HermesMac Local Development\\"" ;;
  find-certificate) cat "$TEST_ROOT/cert.pem" ;;
esac
''')
        self.write_executable("sudo", '''#!/bin/bash
set -eu
test "$1" = -n
shift
"$@"
''')
        # PR setup is separately covered by the existing local signing workflow.
        # This stub proves the CI wrapper chooses that branch without secrets.
        self.write_executable("setup_local_signing.sh", '''#!/bin/bash
echo temporary >> "$TEST_ROOT/operations"
''', directory=self.root)

    def write_executable(self, name, content, directory=None):
        path = (directory or self.bin) / name
        path.write_text(content)
        path.chmod(0o700)

    def run_command(self, args):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=True)

    def sign(self):
        return subprocess.run(["/bin/bash", str(self.root / "setup_ci_signing.sh")],
                              env=self.env, text=True, capture_output=True)

    def test_repeated_release_imports_same_identity_and_cleans_private_files(self):
        for _ in range(2):
            result = self.sign()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(self.env["HERMES_SIGNING_P12_PASSWORD"], result.stdout)
            self.assertFalse(list(self.root.glob("hermes-signing.*")))
        operations = (self.root / "operations").read_text()
        self.assertEqual(operations.splitlines().count("import"), 2)
        self.assertNotIn("temporary", operations)
        self.assertEqual((self.root / "github-env").read_text().splitlines(),
                         [f"HERMES_SIGNING_IDENTITY={self.fingerprint}"] * 2)

    def test_missing_secret_fails_before_keychain_changes(self):
        del self.env["HERMES_SIGNING_P12_BASE64"]
        result = self.sign()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository secrets", result.stderr)
        self.assertFalse((self.root / "operations").exists())

    def test_wrong_password_fails_before_keychain_changes(self):
        self.env["HERMES_SIGNING_P12_PASSWORD"] = "wrong-password"
        self.assertNotEqual(self.sign().returncode, 0)
        self.assertFalse((self.root / "operations").exists())
        self.assertFalse(list(self.root.glob("hermes-signing.*")))

    def test_unavailable_identity_cannot_be_selected(self):
        self.env["TEST_FINGERPRINT"] = "0" * 40
        self.assertNotEqual(self.sign().returncode, 0)
        self.assertFalse((self.root / "github-env").exists())

    def test_pull_request_uses_temporary_identity_without_release_secrets(self):
        self.env["GITHUB_EVENT_NAME"] = "pull_request"
        del self.env["HERMES_SIGNING_P12_BASE64"]
        del self.env["HERMES_SIGNING_P12_PASSWORD"]
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = (self.root / "operations").read_text().splitlines()
        self.assertIn("temporary", operations)
        self.assertNotIn("import", operations)


if __name__ == "__main__":
    unittest.main()
