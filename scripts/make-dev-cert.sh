#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Down Local Signing" in your login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS forgets privacy grants
# (Desktop/Documents/Downloads/removable volumes) each time you rebuild. A stable
# identity keeps the app's designated requirement constant across builds.
#
# This modifies your keychain and asks for your password to trust the certificate
# for code signing. Run it yourself. `make app` / `make run` pick the identity up automatically
# unless Config/Local.xcconfig exists; in Xcode, select it there (option B in Local.xcconfig.example).
set -euo pipefail

NAME="Down Local Signing"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "'$NAME' already exists."; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
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

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PASS" -name "$NAME"

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME" && echo "Done. Rebuild with 'make app' (or, if you have Config/Local.xcconfig, enable option B there)."
