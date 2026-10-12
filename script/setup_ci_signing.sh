#!/usr/bin/env bash
set -euo pipefail

# Use an isolated, disposable keychain so codesign can run without UI prompts.
signing_keychain="${RUNNER_TEMP:?RUNNER_TEMP must be set}/hermes-signing.keychain-db"
signing_password="$(/usr/bin/openssl rand -hex 32)"
security create-keychain -p "$signing_password" "$signing_keychain"
security set-keychain-settings -lut 21600 "$signing_keychain"
security unlock-keychain -p "$signing_password" "$signing_keychain"

# Preserve the runner's existing search list and make our identity discoverable
# by both Xcode and the credential helper's codesign invocation.
signing_search_list=()
while IFS= read -r keychain; do
  signing_search_list+=("$(printf '%s' "$keychain" | sed 's/^[[:space:]]*"//; s/"$//')")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$signing_keychain" "${signing_search_list[@]}"

HERMES_SIGNING_KEYCHAIN="$signing_keychain" \
  "$(dirname "${BASH_SOURCE[0]}")/setup_local_signing.sh"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$signing_password" "$signing_keychain" >/dev/null
