#!/usr/bin/env bash
# CI only: imports the self-signed "Snip Self-Signed" code-signing identity from the
# SIGNING_P12_BASE64 / SIGNING_P12_PASSWORD secrets and exports SIGN_IDENTITY for bundle.sh.
set -euo pipefail

if [ -z "${SIGNING_P12_BASE64:-}" ]; then
  echo "No signing certificate secret; the app will be ad-hoc signed."
  exit 0
fi

KEYCHAIN="$RUNNER_TEMP/snip-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12="$RUNNER_TEMP/snip.p12"
echo "$SIGNING_P12_BASE64" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# Trust the certificate for code signing so codesign accepts it.
openssl pkcs12 -in "$P12" -nokeys -passin "pass:$SIGNING_P12_PASSWORD" -out "$RUNNER_TEMP/snip-cert.pem" 2>/dev/null \
  || openssl pkcs12 -legacy -in "$P12" -nokeys -passin "pass:$SIGNING_P12_PASSWORD" -out "$RUNNER_TEMP/snip-cert.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUNNER_TEMP/snip-cert.pem" || true

security find-identity -p codesigning "$KEYCHAIN"
HASH="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/Snip Self-Signed/ { print $2; exit }')"
if [ -n "$HASH" ]; then
  echo "SIGN_IDENTITY=$HASH" >> "$GITHUB_ENV"
  echo "Using signing identity $HASH"
else
  echo "::warning::Signing identity not found in keychain; the app will be ad-hoc signed."
fi
