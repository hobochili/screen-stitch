#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain. build.sh signs with it when it exists, so
# rebuilt copies keep the same identity and macOS keeps their Screen Recording and microphone permissions.
# Run once per Mac.
set -euo pipefail

name="Screen Stitch Local Signing"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "\"$name\" is already in your keychain."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The system LibreSSL writes the older PKCS#12 format that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -out "$work/identity.p12" -passout pass:screen-stitch
security import "$work/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P screen-stitch -T /usr/bin/codesign >/dev/null

echo "Added \"$name\" to your login keychain."
