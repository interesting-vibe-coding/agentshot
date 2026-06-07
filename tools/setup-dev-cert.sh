#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity for local dev.
#
# Why: ad-hoc signing (`codesign -s -`) gives a new CDHash every rebuild, and
# macOS TCC binds the Accessibility grant to that CDHash — so every rebuild
# silently loses the permission ("System Settings shows it ON but the app isn't
# trusted"). A stable signing identity makes TCC match on the certificate
# (designated requirement) instead, so the grant survives rebuilds.
#
# The identity lives in a DEDICATED keychain with a known password, so codesign
# never prompts and we never touch the user's login keychain password.
#
# Idempotent: safe to run repeatedly. build.sh auto-detects the identity.
set -euo pipefail

IDENTITY_CN="AgentShot Dev (local)"
KC_NAME="agentshot-codesign"
KC="$HOME/Library/Keychains/${KC_NAME}.keychain-db"
KC_PASS="agentshot-dev"   # local-only, not a secret

# Already set up? Then we're done.
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY_CN"; then
    echo "✓ dev signing identity already present in $KC"
    exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Use macOS's LibreSSL — its PKCS#12 output is accepted by `security import`.
# Homebrew's OpenSSL 3.x produces a p12 MAC that `security` rejects.
OPENSSL=/usr/bin/openssl

echo "==> generating self-signed code-signing cert"
cat > "$TMP/cfg.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = AgentShot Dev (local)
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

$OPENSSL req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cfg.cnf" -extensions v3 >/dev/null 2>&1

$OPENSSL pkcs12 -export -out "$TMP/id.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$KC_PASS" >/dev/null 2>&1

echo "==> creating dedicated keychain $KC"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock / no timeout
security unlock-keychain -p "$KC_PASS" "$KC"

echo "==> importing identity"
security import "$TMP/id.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign -A
# Let codesign use the private key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1
# Trust the self-signed cert for code signing so it counts as a valid identity
# (otherwise `codesign -s` reports "no identity found"). User domain, no sudo.
security add-trusted-cert -p codeSign -k "$KC" "$TMP/cert.pem" >/dev/null 2>&1

# Add to the user keychain search list so `codesign -s` can find it.
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
if ! security list-keychains -d user | grep -q "$KC_NAME"; then
    security list-keychains -d user -s "$KC" $EXISTING
fi

echo "==> verifying"
security find-identity -v -p codesigning "$KC"
echo "✓ done. build.sh will now sign with: $IDENTITY_CN"
