#!/bin/bash
# One-time setup: a local code-signing certificate so macOS keeps Toplet's permissions across builds.
#
# Why: macOS remembers permissions (Accessibility, Bluetooth, folders, Calendar…) by the app's code
# signature. Ad-hoc builds are identified only by a hash of the exact binary, so EVERY rebuild looks
# like a new app and macOS asks again. Signed with the same certificate every time, the identity
# stays "app.toplet.Toplet signed by Toplet Local Signing" and granted permissions survive rebuilds.
#
#   local/make-signing-identity.sh          create the certificate (asks for your login password once)
#   local/make-signing-identity.sh --remove delete it again
#
# What it changes: adds one self-signed certificate + private key named "Toplet Local Signing" to
# your login keychain, trusted for code signing only, for your user only. Nothing else. It is only
# useful on this Mac; it cannot sign releases for other people (that needs an Apple Developer ID).
set -euo pipefail
NAME="Toplet Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--remove" ]; then
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null && echo "removed identity '$NAME'" || echo "no identity named '$NAME'"
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists and is trusted for code signing. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# 10-year self-signed certificate; the key never leaves this Mac.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null

# Import with access for codesign only, then trust it for code signing (macOS asks for your password).
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Trusting '$NAME' for code signing — macOS will ask for your login password…"
security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem"   # trust only; the import above added the certificate

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Done. local/build.sh now signs Toplet with '$NAME'."
  echo "Grant Toplet's permissions once more after the next install; after that they stay across rebuilds."
else
  echo "The certificate was added but is not yet a valid code-signing identity. Open Keychain Access,"
  echo "find '$NAME', and under Trust set Code Signing to 'Always Trust'."
  exit 1
fi
