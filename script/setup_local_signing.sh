#!/usr/bin/env bash
set -euo pipefail
IDENTITY="HermesMac Local Development"
signing_trust_domain="${HERMES_SIGNING_TRUST_DOMAIN:-user}"
case "$signing_trust_domain" in
  user) ;;
  admin)
    if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ] || [ -z "${HERMES_SIGNING_KEYCHAIN:-}" ]; then
      echo "Admin trust is only supported on a disposable GitHub Actions runner with an explicit signing keychain." >&2
      exit 1
    fi
    ;;
  *) echo "Unsupported signing trust domain: $signing_trust_domain" >&2; exit 1 ;;
esac
# Print labels rather than command arguments, which can contain passwords.
signing_step() {
  local label="$1"
  shift
  echo "[signing] Starting: $label"
  "$@"
  echo "[signing] Completed: $label"
}
signing_keychain_args=()
if [ -n "${HERMES_SIGNING_KEYCHAIN:-}" ]; then
  signing_keychain_args+=("$HERMES_SIGNING_KEYCHAIN")
fi
echo "[signing] Starting: check existing signing identity"
if security find-identity -v -p codesigning "${signing_keychain_args[@]}" | grep -Fq "\"$IDENTITY\""; then
  echo "$IDENTITY is already available."
  exit 0
fi
echo "[signing] Completed: check existing signing identity"
# Never replace an existing key: its certificate defines the app's stable identity.
echo "[signing] Starting: check existing certificate"
if security find-certificate -c "$IDENTITY" "${signing_keychain_args[@]}" >/dev/null 2>&1; then
  echo "Existing certificate is not a valid signing identity. Check its private key and code-signing trust in Keychain Access; do not recreate it." >&2
  exit 1
fi
echo "[signing] Completed: check existing certificate"
umask 077
signing_temp="$(mktemp -d)"
trap 'rm -rf "$signing_temp"' EXIT
signing_keychain="${HERMES_SIGNING_KEYCHAIN:-$(security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"$//')}"
cat > "$signing_temp/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = HermesMac Local Development
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
echo "[signing] Starting: generate code-signing certificate"
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$signing_temp/certificate.cnf" -keyout "$signing_temp/key.pem" \
  -out "$signing_temp/certificate.pem" 2> "$signing_temp/openssl.log"
echo "[signing] Completed: generate code-signing certificate"
echo "[signing] Starting: generate identity password"
/usr/bin/openssl rand -hex 32 > "$signing_temp/password"
echo "[signing] Completed: generate identity password"
signing_step "export signing identity" /usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
  -inkey "$signing_temp/key.pem" -in "$signing_temp/certificate.pem" \
  -out "$signing_temp/identity.p12" -passout "file:$signing_temp/password" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
signing_step "import signing identity" security import "$signing_temp/identity.p12" -k "$signing_keychain" \
  -P "$(cat "$signing_temp/password")" -T /usr/bin/codesign
# User-domain trust can request GUI authorization even in an unlocked keychain.
# CI uses root's admin-domain operation without rewriting authorization rights.
# sudo -n fails instead of asking for a password.
# The certificate stays in the disposable signing keychain,
# and trust is restricted to code signing on the disposable hosted runner.
if [ "$signing_trust_domain" = "admin" ]; then
  signing_step "configure admin code-signing trust (non-interactive)" \
    sudo -n security add-trusted-cert -d -r trustRoot -p codeSign \
      -k "$signing_keychain" "$signing_temp/certificate.pem"
else
  signing_step "configure user code-signing trust" \
    security add-trusted-cert -r trustRoot -p codeSign \
      -k "$signing_keychain" "$signing_temp/certificate.pem"
fi
echo "[signing] Starting: verify signing identity"
security find-identity -v -p codesigning "$signing_keychain" | grep -F "\"$IDENTITY\""
echo "[signing] Completed: verify signing identity"
if [ "$signing_trust_domain" = "admin" ]; then
  echo "CI certificate signing identity ready."
else
  echo "Local signing ready. Keep this certificate and its private key in Keychain."
fi
