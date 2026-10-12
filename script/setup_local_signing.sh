#!/usr/bin/env bash
set -euo pipefail
IDENTITY="HermesMac Local Development"
signing_keychain_args=()
if [ -n "${HERMES_SIGNING_KEYCHAIN:-}" ]; then
  signing_keychain_args+=("$HERMES_SIGNING_KEYCHAIN")
fi
if security find-identity -v -p codesigning "${signing_keychain_args[@]}" | grep -Fq "\"$IDENTITY\""; then
  echo "$IDENTITY is already available."
  exit 0
fi
# Never replace an existing key: its certificate defines the app's stable identity.
if security find-certificate -c "$IDENTITY" "${signing_keychain_args[@]}" >/dev/null 2>&1; then
  echo "Existing certificate is not a valid signing identity. Check its private key and code-signing trust in Keychain Access; do not recreate it." >&2
  exit 1
fi
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
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$signing_temp/certificate.cnf" -keyout "$signing_temp/key.pem" \
  -out "$signing_temp/certificate.pem" 2> "$signing_temp/openssl.log"
/usr/bin/openssl rand -hex 32 > "$signing_temp/password"
/usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
  -inkey "$signing_temp/key.pem" -in "$signing_temp/certificate.pem" \
  -out "$signing_temp/identity.p12" -passout "file:$signing_temp/password" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$signing_temp/identity.p12" -k "$signing_keychain" \
  -P "$(cat "$signing_temp/password")" -T /usr/bin/codesign
# Trust only for code signing, in this user's keychain (no system-wide trust).
security add-trusted-cert -r trustRoot -p codeSign -k "$signing_keychain" "$signing_temp/certificate.pem"
security find-identity -v -p codesigning "$signing_keychain" | grep -F "\"$IDENTITY\""
echo "Local signing ready. Keep this certificate and its private key in Keychain."
