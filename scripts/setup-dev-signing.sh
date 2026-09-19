#!/usr/bin/env bash
# ============================================================================
# One-time dev setup: create a STABLE self-signed code-signing identity
# ("MLM Dev") and use it to sign the mlm-auth helper.
#
# WHY: macOS keychain records "Always Allow" access consent against the
# signing identity of the binary that requests an item. Ad-hoc signatures
# get a fresh identity on every rebuild, so consent is lost on every build
# and the user is re-prompted for the keychain password. A stable
# self-signed cert keeps the consent alive across rebuilds — one
# "Always Allow" click for the helper then lasts indefinitely.
#
# What this script does:
#   1. If "MLM Dev" is NOT already a valid codesigning identity:
#        - generate an UNENCRYPTED RSA key (genpkey — never prompts),
#        - self-sign a 10-year code-signing cert (CN="MLM Dev",
#          extendedKeyUsage=codeSigning),
#        - export PKCS12 with a RANDOM non-empty password (an EMPTY
#          p12 password fails `security import` with "MAC verification
#          failed" on macOS; the password is generated at runtime and
#          only ever lives in memory),
#        - import it into the login keychain with /usr/bin/codesign
#          allowed to use the key (-T /usr/bin/codesign),
#        - mark the cert trusted (trustRoot) so it counts as a valid
#          codesigning identity. THIS STEP SHOWS ONE GUI DIALOG asking
#          for the login password — type it once.
#   2. Verify the identity is usable: `security find-identity -v -p codesigning`.
#   3. Sign the built mlm-auth helper with "MLM Dev".
#
# IDEMPOTENT: re-running when "MLM Dev" already exists skips everything
# keychain-related and just re-signs the helper (no dialogs).
#
# Usage:
#   ./scripts/setup-dev-signing.sh
# ============================================================================

set -euo pipefail

CERT_NAME="MLM Dev"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mlm-dev-signing.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# True when the identity is already present and valid for codesigning.
identity_exists() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${CERT_NAME}\""
}

if identity_exists; then
  echo "› '${CERT_NAME}' identity already present — skipping keychain setup (no dialogs)"
else
  echo "› generating unencrypted RSA-2048 key (no prompts)"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${WORK_DIR}/mlm-dev.key" 2>/dev/null
  chmod 600 "${WORK_DIR}/mlm-dev.key"

  echo "› self-signing 10-year code-signing cert '${CERT_NAME}'"
  # Extension config as a file (portable across OpenSSL / LibreSSL —
  # `req -addext` is not available in older LibreSSL).
  cat > "${WORK_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = codesign_ext

[dn]
CN = ${CERT_NAME}

[codesign_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -new -x509 \
    -key "${WORK_DIR}/mlm-dev.key" \
    -sha256 -days 3650 \
    -config "${WORK_DIR}/openssl.cnf" \
    -out "${WORK_DIR}/mlm-dev.crt" 2>/dev/null

  # OPENSSL 3.x exports modern AES/PBES2 PKCS12 by default, which macOS's
  # keychain importer rejects ("MAC verification failed"). -legacy forces
  # the classic 3DES/SHA-1 layout macOS expects. LibreSSL has no -legacy
  # flag but already emits the classic layout, so only pass it on OpenSSL 3.
  LEGACY_FLAG=""
  if openssl version 2>/dev/null | grep -q "OpenSSL 3"; then
    LEGACY_FLAG="-legacy"
  fi

  # RANDOM non-empty p12 password — see header: empty passwords break
  # `security import`. Never written to disk; both export and import
  # happen here, so nothing is ever prompted for.
  P12_PW="$(openssl rand -hex 16)"
  echo "› exporting PKCS12"
  # shellcheck disable=SC2086
  openssl pkcs12 -export ${LEGACY_FLAG} \
    -out "${WORK_DIR}/mlm-dev.p12" \
    -inkey "${WORK_DIR}/mlm-dev.key" \
    -in "${WORK_DIR}/mlm-dev.crt" \
    -name "${CERT_NAME}" \
    -password pass:"${P12_PW}"

  echo "› importing into the login keychain (prompts only if the keychain is locked)"
  security import "${WORK_DIR}/mlm-dev.p12" \
    -k "${LOGIN_KEYCHAIN}" \
    -P "${P12_PW}" \
    -T /usr/bin/codesign

  echo "› marking cert trusted — ONE GUI dialog will ask for the login password"
  if ! security add-trusted-cert -r trustRoot \
      -k "${LOGIN_KEYCHAIN}" \
      "${WORK_DIR}/mlm-dev.crt"; then
    echo "✗ trust step failed (dialog cancelled?). Re-run this script." >&2
    exit 1
  fi
  # Drop the p12 + password from memory-ish scope; temp files die with the trap.
  unset P12_PW
fi

# Verify the identity is usable before relying on it.
if ! identity_exists; then
  echo "✗ '${CERT_NAME}' not found in the codesigning identity list after import" >&2
  echo "  (a dialog may have been cancelled — re-run this script)" >&2
  exit 1
fi
echo "› identity verified:"
security find-identity -v -p codesigning | grep "\"${CERT_NAME}\"" || true

# Sign the built helper. Build it first if it is not there yet.
BIN_DIR="$(cd "${REPO_ROOT}" && swift build --show-bin-path)"
HELPER="${BIN_DIR}/mlm-auth"
if [[ ! -f "${HELPER}" ]]; then
  echo "› mlm-auth not built yet — running swift build"
  (cd "${REPO_ROOT}" && swift build)
fi

echo "› signing ${HELPER} with '${CERT_NAME}'"
codesign --force --sign "${CERT_NAME}" "${HELPER}"

echo "› done. The helper is signed with a stable identity:"
codesign -dv "${HELPER}" 2>&1 | grep -E 'Identifier|Authority|Signature' || true
echo ""
echo "Next time the app needs a token, the helper may prompt ONCE for keychain"
echo "access — click 'Always Allow'. App rebuilds will no longer re-prompt."
