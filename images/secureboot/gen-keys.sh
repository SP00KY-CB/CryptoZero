#!/bin/bash
# Generate a private Secure Boot key hierarchy (PK, KEK, db) for signing the
# CryptoZero PBA.  Requires: openssl, efitools (cert-to-efi-sig-list,
# sign-efi-sig-list).
#
#   secureboot/gen-keys.sh [KEYDIR]      (default: $HOME/.cryptozero-secureboot)
#
# KEEP KEYDIR OUT OF THE REPO AND OFFLINE (or in an HSM).  Whoever holds
# db.key can sign code your firmware will boot.
set -euo pipefail
KEYDIR=${1:-$HOME/.cryptozero-secureboot}
DAYS=${DAYS:-3650}
[ -e "$KEYDIR/db.key" ] && { echo "$KEYDIR/db.key already exists; refusing to overwrite."; exit 1; }
mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"; cd "$KEYDIR"
umask 077
GUID=$(cat /proc/sys/kernel/random/uuid); echo "$GUID" > GUID

for k in PK KEK db; do
    openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days "$DAYS" \
        -subj "/CN=CryptoZero Secure Boot $k/" -keyout "$k.key" -out "$k.crt"
    openssl x509 -in "$k.crt" -outform DER -out "$k.cer"
    cert-to-efi-sig-list -g "$GUID" "$k.crt" "$k.esl"
done
# Authenticated variable updates: PK signs PK and KEK, KEK signs db.
sign-efi-sig-list -g "$GUID" -k PK.key  -c PK.crt  PK  PK.esl  PK.auth
sign-efi-sig-list -g "$GUID" -k PK.key  -c PK.crt  KEK KEK.esl KEK.auth
sign-efi-sig-list -g "$GUID" -k KEK.key -c KEK.crt db  db.esl  db.auth
echo
echo "Keys written to $KEYDIR"
echo "  Sign with:   SB_KEY=$KEYDIR/db.key SB_CERT=$KEYDIR/db.crt"
echo "  Enroll in firmware: db.cer (UI 'append key') or db.auth/KEK.auth/PK.auth (efi-updatevar)."
echo "  See docs/TPM_CIK.md."
