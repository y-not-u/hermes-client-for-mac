#!/usr/bin/env bash
set -euo pipefail

if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; then
  echo "CI signing requires a disposable GitHub-hosted runner." >&2
  exit 1
fi

# Only pull-request validation may use a disposable identity. Published builds
# must fail rather than silently changing the app's signing identity.
signing_temporary=false
if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
  signing_temporary=true
elif [ -z "${HERMES_SIGNING_P12_BASE64:-}" ] || [ -z "${HERMES_SIGNING_P12_PASSWORD:-}" ]; then
  echo "Release signing requires HERMES_SIGNING_P12_BASE64 and HERMES_SIGNING_P12_PASSWORD repository secrets. See docs/SETUP.md." >&2
  exit 1
fi
umask 077
signing_temp="$(mktemp -d "${RUNNER_TEMP:?RUNNER_TEMP must be set}/hermes-signing.XXXXXX")"
trap 'rm -rf "$signing_temp"' EXIT

if [ "$signing_temporary" = false ]; then
  printf '%s' "$HERMES_SIGNING_P12_BASE64" | /usr/bin/base64 --decode > "$signing_temp/identity.p12"
  /usr/bin/openssl pkcs12 -in "$signing_temp/identity.p12" -clcerts -nokeys \
    -passin env:HERMES_SIGNING_P12_PASSWORD -out "$signing_temp/certificate.pem"
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

if [ "$signing_temporary" = true ]; then
  echo "[signing] Pull-request validation uses a temporary identity; this build is not a release."
  HERMES_SIGNING_KEYCHAIN="$signing_keychain" HERMES_SIGNING_TRUST_DOMAIN=admin \
    "$(dirname "${BASH_SOURCE[0]}")/setup_local_signing.sh"
  security find-certificate -c "HermesMac Local Development" -p "$signing_keychain" > "$signing_temp/certificate.pem"
else
  signing_step "import persistent signing identity" security import "$signing_temp/identity.p12" \
    -k "$signing_keychain" -P "$HERMES_SIGNING_P12_PASSWORD" -T /usr/bin/codesign
  # Self-signed identities require code-signing trust on the disposable runner.
  # Do not rewrite authorizationdb: macOS hosted runners reject those writes.
  signing_step "configure admin code-signing trust" sudo -n security add-trusted-cert \
    -d -r trustRoot -p codeSign -k "$signing_keychain" "$signing_temp/certificate.pem"
fi
echo "[signing] Starting: allow non-interactive private-key access"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$signing_password" "$signing_keychain" >/dev/null
echo "[signing] Completed: allow non-interactive private-key access"

# Select the exact certificate, even if another keychain has the same name.
signing_fingerprint="$(/usr/bin/openssl x509 -in "$signing_temp/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
signing_identities="$(security find-identity -v -p codesigning "$signing_keychain")"
if ! printf '%s\n' "$signing_identities" | grep -F "$signing_fingerprint" | grep -Fq '"HermesMac Local Development"'; then
  echo "Expected a valid HermesMac Local Development signing identity with its private key." >&2
  exit 1
fi
printf 'HERMES_SIGNING_IDENTITY=%s\n' "$signing_fingerprint" >> "${GITHUB_ENV:?GITHUB_ENV must be set}"
echo "[signing] Signing certificate SHA-1: $signing_fingerprint"
