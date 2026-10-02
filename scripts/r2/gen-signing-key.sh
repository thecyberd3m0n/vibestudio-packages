#!/bin/bash
# Generate a new GPG signing key for the apt repo Release files.
#
# Produces:
#   - the public key, exported into scripts/r2/keys/ (armored + binary), which
#     must be shipped to clients so `apt` trusts the repo.
#   - the private key, exported to $HOME (chmod 600) for you to store as the
#     GPG_SIGNING_KEY GitHub secret. It is NOT written into the repo.
#
# Usage: scripts/r2/gen-signing-key.sh ["Real Name"] [email]

set -euo pipefail

NAME="${1:-VibeStudio Packages}"
EMAIL="${2:-packages@vibestudio.app}"

command -v gpg >/dev/null 2>&1 || { echo "ERROR: gpg not found" >&2; exit 1; }

R2_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$R2_DIR/keys"
mkdir -p "$KEYS_DIR"

echo "Generating RSA-4096 signing key for '$NAME <$EMAIL>'..."
# No passphrase: the private key is protected by being a GitHub secret, and a
# passphraseless key keeps CI signing simple. Sign-only, no expiry.
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
%commit
EOF

KEY_ID="$(gpg --list-secret-keys --with-colons "$EMAIL" | awk -F: '/^fpr:/ {print $10; exit}')"
[[ -n "$KEY_ID" ]] || { echo "ERROR: could not determine key id" >&2; exit 1; }

PUB_ASC="$KEYS_DIR/vibestudio-packages.asc"
PUB_GPG="$KEYS_DIR/vibestudio-packages.gpg"
SECRET_OUT="$HOME/vibestudio-packages-secret.asc"

gpg --armor --export "$KEY_ID" > "$PUB_ASC"
gpg --export "$KEY_ID" > "$PUB_GPG"
( umask 077; gpg --armor --export-secret-keys "$KEY_ID" > "$SECRET_OUT" )

cat <<EOF

Done.

  Key ID (fingerprint): $KEY_ID
  Public key (armored): $PUB_ASC
  Public key (binary):  $PUB_GPG
  Private key:          $SECRET_OUT   (chmod 600 — keep safe, do NOT commit)

Next steps:
  1. Add to your R2 env / GitHub secrets:
       GPG_KEY_ID=$KEY_ID
       GPG_SIGNING_KEY = contents of $SECRET_OUT
     (leave GPG_PASSPHRASE empty — this key has none)
  2. Ship the public key ($PUB_GPG) to clients so apt trusts the repo
     (e.g. add it to the fork's termux-keyring package).
  3. Once stored securely, delete the local private export:
       shred -u "$SECRET_OUT"   # or rm
EOF
