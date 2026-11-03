#!/usr/bin/env python3
"""Create/reuse the app's Sparkle key, publish its public key, and configure CI."""
import argparse
import base64
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "com.hermes.mac.updates"


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        # Never echo tool output here: signing tools handle private key material.
        raise SystemExit(f"{Path(command[0]).name} failed (exit {result.returncode}).")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sparkle-bin", type=Path, required=True)
    parser.add_argument("--repo", default="y-not-u/hermes-client-for-mac")
    args = parser.parse_args()
    generator = str(args.sparkle_bin.resolve() / "generate_keys")
    run(["gh", "repo", "view", args.repo, "--json", "nameWithOwner"])
    plist_path = ROOT / "HermesMac/Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    expected_public_key = info.get("SUPublicEDKey")
    if not expected_public_key:
        print("Creating the Hermes Sparkle key in your Keychain…", flush=True)
        run([generator, "--account", ACCOUNT])
    else:
        print("Checking the existing Hermes Sparkle key (restore it first on a new Mac)…", flush=True)
    public_key = run([generator, "--account", ACCOUNT, "-p"]).decode().strip()
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise SystemExit("Sparkle returned an invalid public key.")
    if expected_public_key and public_key != expected_public_key:
        raise SystemExit("Keychain key does not match the published public key. Restore the original key; CI was not changed.")
    with tempfile.TemporaryDirectory(prefix="hermes-update-key-") as directory:
        # TemporaryDirectory is owner-only; the private key never enters the repo.
        private_key = Path(directory) / "private-key"
        run([generator, "--account", ACCOUNT, "-x", str(private_key)])
        private_key.chmod(0o600)
        run(["gh", "secret", "set", "SPARKLE_PRIVATE_KEY", "--repo", args.repo],
            input=private_key.read_bytes())
    info["SUPublicEDKey"] = public_key
    plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print("SPARKLE_PRIVATE_KEY configured; public key saved to HermesMac/Info.plist.")
    print("Original key retained in Keychain; temporary export removed.")


if __name__ == "__main__":
    main()
