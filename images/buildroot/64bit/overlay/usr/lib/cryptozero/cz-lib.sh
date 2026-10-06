#!/bin/sh
# Shared helpers for cz-unlock / cz-enroll.  POSIX sh (busybox ash).
# All secrets are handled as lowercase hex strings; nothing touches disk
# except the CIK partition itself and TPM objects.

. /etc/cryptozero.conf

# CIK partition layout: 8-byte magic "CZCIK001" followed by a 32-byte key.
CZ_MAGIC_HEX=435a43494b303031

cz_find_cik_dev() {
    t=0
    while [ "$t" -le "$CZ_CIK_WAIT" ]; do
        for u in /sys/class/block/*/uevent; do
            if grep -qx "PARTNAME=$CZ_CIK_PARTNAME" "$u" 2>/dev/null; then
                echo "/dev/$(basename "$(dirname "$u")")"
                return 0
            fi
        done
        t=$((t + 1)); sleep 1
    done
    return 1
}

# cz_read_cik DEV -> prints 64 hex chars
cz_read_cik() {
    raw=$(dd if="$1" bs=40 count=1 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
    [ "${#raw}" -eq 80 ] || return 1
    [ "$(echo "$raw" | cut -c1-16)" = "$CZ_MAGIC_HEX" ] || return 1
    echo "$raw" | cut -c17-80
}

# cz_hex2bin HEX -> raw bytes on stdout (busybox printf has no \x, use octal)
cz_hex2bin() {
    h=$1
    while [ -n "$h" ]; do
        b=$(echo "$h" | cut -c1-2); h=$(echo "$h" | cut -c3-)
        printf "\\$(printf '%03o' "0x$b")"
    done
}

# cz_write_cik DEV KEYHEX   (refuses unless DEV is the partition named CIK)
cz_write_cik() {
    base=$(basename "$1")
    grep -qx "PARTNAME=$CZ_CIK_PARTNAME" "/sys/class/block/$base/uevent" 2>/dev/null || {
        echo "refusing: $1 is not a GPT partition named $CZ_CIK_PARTNAME" >&2; return 1; }
    hex="$CZ_MAGIC_HEX$2"
    [ "${#hex}" -eq 80 ] || return 1
    cz_hex2bin "$hex" | dd of="$1" bs=40 count=1 conv=fsync 2>/dev/null
}

# cz_unseal [PIN] -> prints 64 hex chars of the TPM secret
cz_unseal() {
    S=/tmp/.cz-session.$$
    tpm2_startauthsession --policy-session -S "$S" >/dev/null 2>&1 || return 1
    tpm2_policypcr -S "$S" -l "$CZ_PCRS" >/dev/null 2>&1 || { tpm2_flushcontext "$S" >/dev/null 2>&1; rm -f "$S"; return 1; }
    auth="session:$S"
    if [ "$CZ_USE_PIN" = 1 ]; then
        tpm2_policyauthvalue -S "$S" >/dev/null 2>&1 || { tpm2_flushcontext "$S" >/dev/null 2>&1; rm -f "$S"; return 1; }
        auth="session:$S+str:$1"
    fi
    out=$(tpm2_unseal -c "$CZ_TPM_HANDLE" -p "$auth" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
    tpm2_flushcontext "$S" >/dev/null 2>&1; rm -f "$S"
    [ "${#out}" -eq 64 ] || return 1
    echo "$out"
}

# Extend the last policy PCR so nothing else in this boot (fallback prompt,
# the "debug" root login) can satisfy the policy and unseal the secret.
cz_lock_tpm() {
    tpm2_pcrextend "${CZ_PCRS##*[:,]}:${CZ_PCRS%%:*}=$(printf cryptozero-locked | sha256sum | cut -d' ' -f1)" >/dev/null 2>&1
}

# True only if the TPM answers and positively has no object at CZ_TPM_HANDLE.
cz_tpm_unenrolled() {
    caps=$(tpm2_getcap handles-persistent 2>/dev/null) || return 1
    ! echo "$caps" | grep -qi "$CZ_TPM_HANDLE"
}

# cz_derive TPMHEX CIKHEX -> 64 hex chars used as the Opal password
cz_derive() {
    printf 'cryptozero-v1:%s:%s' "$1" "$2" | sha256sum | cut -d' ' -f1
}
