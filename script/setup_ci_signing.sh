#!/usr/bin/env bash
set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; then
  echo "CI signing requires a disposable GitHub-hosted runner." >&2
  exit 1
fi
signing_step() {
  local label="$1"
  shift
  echo "[signing] Starting: $label"
  "$@"
  echo "[signing] Completed: $label"
}

# Use an isolated, disposable keychain so codesign can run without UI prompts.
signing_keychain="${RUNNER_TEMP:?RUNNER_TEMP must be set}/hermes-signing.keychain-db"
echo "[signing] Starting: generate keychain password"
signing_password="$(/usr/bin/openssl rand -hex 32)"
echo "[signing] Completed: generate keychain password"
signing_step "check non-interactive sudo access" sudo -n true
signing_step "create signing keychain" security create-keychain -p "$signing_password" "$signing_keychain"
signing_step "configure signing keychain" security set-keychain-settings -lut 1200 "$signing_keychain"
signing_step "unlock signing keychain" security unlock-keychain -p "$signing_password" "$signing_keychain"

# Preserve the runner's existing search list and make our identity discoverable
# by both Xcode and the credential helper's codesign invocation.
signing_search_list=()
echo "[signing] Starting: read keychain search list"
# Capture first so a security failure is not hidden by process substitution.
signing_existing_keychains="$(security list-keychains -d user)"
while IFS= read -r keychain; do
  signing_search_list+=("$(printf '%s' "$keychain" | sed 's/^[[:space:]]*"//; s/"$//')")
done <<< "$signing_existing_keychains"
echo "[signing] Completed: read keychain search list"
signing_step "update keychain search list" security list-keychains -d user -s "$signing_keychain" "${signing_search_list[@]}"

# Even root can be asked for GUI authorization when changing trust settings.
# Temporarily allow only the admin trust right on this disposable runner, and
# restore its original definition on success or failure. Do not disable SIP.
signing_authorization_file="$(mktemp "$RUNNER_TEMP/hermes-trust-authorization.XXXXXX")"
signing_authorization_saved=false
restore_signing_authorization() {
  if [ "$signing_authorization_saved" = true ]; then
    echo "[signing] Starting: restore admin trust authorization"
    sudo -n security authorizationdb write com.apple.trust-settings.admin < "$signing_authorization_file"
    echo "[signing] Completed: restore admin trust authorization"
    signing_authorization_saved=false
  fi
  rm -f "$signing_authorization_file"
}
trap restore_signing_authorization EXIT
echo "[signing] Starting: save admin trust authorization"
sudo -n security authorizationdb read com.apple.trust-settings.admin > "$signing_authorization_file"
signing_authorization_saved=true
echo "[signing] Completed: save admin trust authorization"
signing_step "allow non-interactive admin trust authorization" \
  sudo -n security authorizationdb write com.apple.trust-settings.admin allow

HERMES_SIGNING_KEYCHAIN="$signing_keychain" HERMES_SIGNING_TRUST_DOMAIN=admin \
  "$(dirname "${BASH_SOURCE[0]}")/setup_local_signing.sh"
restore_signing_authorization
echo "[signing] Starting: allow non-interactive private-key access"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$signing_password" "$signing_keychain" >/dev/null
echo "[signing] Completed: allow non-interactive private-key access"
