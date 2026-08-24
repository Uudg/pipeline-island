#!/bin/bash
# Create a stable self-signed code-signing identity for local development.
#
# WHY THIS EXISTS
#
# The macOS keychain ties an item's ACL to the calling binary's *designated
# requirement*. For an ad-hoc signed app that requirement is:
#
#     designated => cdhash H"aee7ba65..."
#
# — the hash of the binary itself. Every rebuild produces a different hash, so
# every rebuild is a brand-new identity as far as the keychain is concerned, and
# macOS re-prompts for the login password. Clicking "Always Allow" authorises
# only the exact build you clicked it for. During active development that means
# a password prompt every few minutes.
#
# Signing with a certificate instead gives:
#
#     designated => identifier "com.pipelineisland.app" and certificate leaf H"..."
#
# which is stable across rebuilds. Approve once, never again.
#
# This creates a *local, self-signed* certificate. It is not an Apple Developer
# ID: it does not enable notarization or distribution, it only makes the local
# identity stable. Nothing leaves the machine.
#
# Usage:  make signing-identity     (or run this script directly)

set -euo pipefail

CERT_NAME="Pipeline Island Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "signing identity '$CERT_NAME' already exists"
    security find-identity -v -p codesigning | grep "$CERT_NAME" || true
    exit 0
fi

echo "Creating a self-signed code-signing certificate: $CERT_NAME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Minimal OpenSSL config with the codeSigning extended key usage. Without
# extendedKeyUsage=codeSigning, `codesign` refuses the certificate.
cat > "$TMP/cert.conf" <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Pipeline Island Dev

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" 2>/dev/null

# Bundle key + cert into a PKCS#12 for import.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass: -name "$CERT_NAME" 2>/dev/null

# Import into the login keychain. -T codesign pre-authorises codesign to use the
# private key so signing itself does not prompt.
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" -P "" -A -T /usr/bin/codesign >/dev/null

# Trust the certificate for code signing. This is the one step that asks for the
# login password — once, ever.
echo
echo "macOS will now ask for your login password to trust the certificate."
echo "This happens ONCE. After this, rebuilds no longer prompt."
echo
sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign \
    -k /Library/Keychains/System.keychain "$TMP/cert.pem"

echo
echo "done. Verifying:"
security find-identity -v -p codesigning | grep "$CERT_NAME" || {
    echo "WARNING: identity not listed as valid for code signing." >&2
    exit 1
}

echo
echo "Now run:  make app"
echo "The first launch will ask for keychain access one final time — click"
echo "'Always Allow'. Subsequent rebuilds will not ask again."
