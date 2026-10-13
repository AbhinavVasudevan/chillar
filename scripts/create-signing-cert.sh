#!/bin/sh
# Creates a local, self-signed code-signing identity ("Chillar Local Signing") in your login keychain.
#
# Why: macOS ties Keychain access to an app's code signature. Ad-hoc signatures change on every
# build, so the Keychain would forget Chillar each time. A stable local identity keeps the
# signature constant, so the access token can live in the Keychain without repeated prompts.
#
# Security: anything that can sign as this identity can read the app's Keychain items. So the key is
# imported WITHOUT pre-authorising codesign: every build shows a "codesign wants to use key" prompt.
# Click "Allow" (not "Always Allow"); an unexpected prompt means something else is trying to sign.
#
# The private key never leaves your Mac and can only sign code. Remove it any time with:
#   security delete-identity -c "Chillar Local Signing"
set -eu
umask 077
NAME="Chillar Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Identity \"$NAME\" already exists."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
chmod 600 "$TMP/key.pem"
# Throwaway transport password, passed via the environment so it never appears in `ps`.
P12PASS=$(openssl rand -hex 16); export P12PASS
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout env:P12PASS -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
       -out "$TMP/id.p12" -passout env:P12PASS
# `security import -P` only takes the password as an argument; it lives for a split second,
# protects a file in a 0700 temp dir that is deleted on exit, and is useless afterwards.
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12PASS" -x
unset P12PASS
echo "Created \"$NAME\"."
