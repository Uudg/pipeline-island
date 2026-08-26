#!/bin/bash
# Create a stable local signing identity for development.
#
# WHY
#
# The macOS keychain ties an item's ACL to the calling binary's designated
# requirement. For an ad-hoc signed app that requirement is the binary's own
# hash:
#
#     designated => cdhash H"aee7ba65..."
#
# which changes on every rebuild. So macOS treats each build as a brand-new
# app and asks for your login password again — "Always Allow" only ever
# authorises the exact build you clicked it on.
#
# Signing with a certificate gives a requirement that keys off the certificate
# instead, which survives rebuilds. Approve once, done.
#
# This is a local development certificate. Not an Apple Developer ID: no
# notarization, no distribution, nothing leaves the machine.
#
# Usage:  make signing-identity          <- NOT with sudo
#
# Do not run this with sudo. Under sudo the certificate lands in root's
# keychain, where your apps cannot see it, and the import silently succeeds
# while nothing works afterwards.

set -euo pipefail

CERT_NAME="Pipeline Island Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "$(id -u)" -eq 0 ]; then
    cat >&2 <<'EOF'
Do not run this with sudo.

Under sudo the certificate is imported into root's keychain, not yours, so the
app still cannot use it. Run it as yourself:

    make signing-identity

You may be prompted to allow keychain access once, which is expected.
EOF
    exit 1
fi

# Note: `find-identity -v` lists only TRUSTED identities, and this certificate
# is deliberately untrusted. Check the certificate itself instead.
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "signing identity '$CERT_NAME' already exists"
    exit 0
fi

echo "Creating a local code-signing certificate: $CERT_NAME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# macOS Security.framework only understands the legacy PKCS#12 algorithms:
# a SHA-1 MAC and 3DES encryption. LibreSSL defaults to a SHA-256 MAC with
# AES-256-CBC, which produces:
#
#     SecKeychainItemImport: MAC verification failed during PKCS12 import
#
# The message blames the password, which is misleading — the password is fine,
# the MAC algorithm is unreadable. `-macalg sha1` plus the two `PBE-SHA1-3DES`
# flags are what actually matter here.
#
# The password itself is also required: `security import` rejects an
# empty-password p12 with the same error. It is throwaway, protecting the file
# for the moment it exists in a temp dir that is deleted on exit.
P12_PASS="pipeline-island-local"

openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$P12_PASS" \
    -name "$CERT_NAME" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

# -T /usr/bin/codesign pre-authorises codesign to use the private key, so
# signing itself never prompts.
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign >/dev/null

echo "  imported into your login keychain"

# Mark the certificate as trusted for code signing.
#
# This is the only step that needs elevation, and it is genuinely optional:
# codesign will happily use an untrusted self-signed certificate, and the
# keychain ACL keys off the certificate either way. Skipping it leaves the app
# working; it only means `codesign --verify` reports the chain as untrusted.
if security add-trusted-cert -d -r trustRoot -p codeSign \
        -k /Library/Keychains/System.keychain "$TMP/cert.pem" 2>/dev/null; then
    echo "  trusted for code signing"
else
    echo "  (not marked trusted — needs admin rights, and is not required)"
    echo "  to do it later:"
    echo "    sudo security add-trusted-cert -d -r trustRoot -p codeSign \\"
    echo "      -k /Library/Keychains/System.keychain <cert>"
fi

# Verify by actually signing something, which is the only test that matters.
# `find-identity -v` reports 0 valid identities for an untrusted certificate
# even though codesign uses it without complaint.
PROBE=$(mktemp -d)
mkdir -p "$PROBE/Probe.app/Contents/MacOS"
printf 'int main(){return 0;}' > "$PROBE/t.c"
cc -o "$PROBE/Probe.app/Contents/MacOS/Probe" "$PROBE/t.c" 2>/dev/null
cat > "$PROBE/Probe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pipelineisland.signprobe</string>
<key>CFBundleExecutable</key><string>Probe</string>
</dict></plist>
PLIST

if codesign --force --sign "$CERT_NAME" "$PROBE/Probe.app" >/dev/null 2>&1; then
    REQUIREMENT=$(codesign -d -r- "$PROBE/Probe.app" 2>&1 | tail -1)
    rm -rf "$PROBE"
    echo
    echo "done. Signing now produces:"
    echo "  $REQUIREMENT"
    echo
    echo "That keys off the certificate rather than the binary hash, so it"
    echo "survives rebuilds."
    echo
    echo "Now run:  make app"
    echo "The first launch asks for keychain access once more — click"
    echo "'Always Allow'. Rebuilds after that will not ask again."
else
    rm -rf "$PROBE"
    echo
    echo "The certificate imported but codesign cannot use it." >&2
    echo "Signing falls back to ad-hoc, which still works — you will just" >&2
    echo "keep seeing keychain prompts on rebuild." >&2
    exit 1
fi
