#!/usr/bin/env bash
# One-time: create a self-signed code-signing certificate ("LG Smart Touch Enabler Dev") in your login keychain.
# Signing every build with the same certificate keeps its macOS privacy grants (Accessibility, Input Monitoring)
# across rebuilds. Ad-hoc signing changes the signature each build, which resets them.
set -euo pipefail
NAME="LG Smart Touch Enabler Dev"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "Signing identity '$NAME' already exists."; exit 0
fi

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
cat > "$D/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$D/openssl.cnf" -keyout "$D/key.pem" -out "$D/cert.pem" 2>/dev/null
PW="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout "pass:$PW" 2>/dev/null
security import "$D/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
# Trust it for code signing (macOS asks for your login password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$D/cert.pem" || echo "note: could not set trust (not required; signing still works)"
echo "Created signing identity '$NAME'."
security find-identity -p codesigning "$KC" | grep "$NAME" || true
