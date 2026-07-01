#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate so the app keeps
# a STABLE code signature across rebuilds.
#
# Why: macOS Accessibility (TCC) remembers permission by the binary's "designated
# requirement". Ad-hoc signing (`codesign --sign -`) produces a fresh cdhash on
# every build, so the grant is lost each rebuild. A real signing identity makes
# the requirement key on the certificate instead — grant once, survives rebuilds.
#
# Idempotent: re-running detects an existing identity and does nothing.
set -euo pipefail

IDENTITY_NAME="ConditionManager Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "==> Signing identity '$IDENTITY_NAME' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# A non-empty password is required: Apple's Security framework rejects p12 files
# with an empty MAC password ("MAC verification failed"). LibreSSL's default
# algorithms (3DES/SHA1) are already import-compatible, so no -legacy is needed.
P12PASS="cmdev"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12PASS"

echo "==> Importing into login keychain (allowing codesign to use the key)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -A

echo
echo "==> Done. Verifying:"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || {
    echo "WARNING: identity not found after import — check Keychain Access." >&2
    exit 1
}

cat <<'EOF'

Next:
  1) Run the app once via Scripts/dev-run.sh — it now signs with this identity.
  2) The FIRST time codesign uses the key, macOS may show a keychain dialog.
     Click "Always Allow" so future builds are silent.
  3) Grant Accessibility in System Settings ONCE. It now survives rebuilds.
EOF
