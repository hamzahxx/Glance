#!/bin/bash
# Creates a local code-signing identity so Glance keeps a stable identity
# across rebuilds.
#
# macOS keys camera and Accessibility permissions to an app's code signature.
# An ad-hoc signature ("codesign -s -") changes whenever the binary changes, so
# every rebuild looks like a brand-new app and every permission has to be
# granted again. A self-signed certificate fixes the identity in place.
#
# Everything here is local and private: no Apple account, nothing published, and
# the certificate can be deleted from Keychain Access at any time.
set -euo pipefail

NAME="Glance Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✅ '$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Creating certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/gg.key" -out "$TMP/gg.crt" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# macOS cannot read the PKCS12 encoding OpenSSL 3 writes by default.
openssl pkcs12 -export -out "$TMP/gg.p12" -inkey "$TMP/gg.key" -in "$TMP/gg.crt" \
    -name "$NAME" -passout pass:glance \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "Importing into your login keychain…"
security import "$TMP/gg.p12" -k "$KEYCHAIN" -P glance -T /usr/bin/codesign -A

echo "Trusting it for code signing (macOS will ask for your login password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/gg.crt"

echo
security find-identity -v -p codesigning
echo
echo "Done. Now run ./bundle.sh — it will pick this identity up automatically."
echo "You will grant camera and Accessibility once more, and then they stick."
