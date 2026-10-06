#!/bin/sh
# Run by run.sh under dash (close to the PBA's busybox ash).
# Env: CZ_LIB, CZ_CONF, PIN, TPM2TOOLS_TCTI.
# Variables below are read inside the eval'd test expressions.
# shellcheck disable=SC2034
# shellcheck source=/dev/null
. "$CZ_LIB"

# swtpm has no kernel resource manager in front of it: emulate /dev/tpmrm0 by
# flushing transient objects after every tpm2 command.
for t in createprimary create load evictcontrol startauthsession policypcr \
         policyauthvalue unseal getcap pcrextend; do
    eval "tpm2_$t() { command tpm2_$t \"\$@\"; _rc=\$?; command tpm2_flushcontext -t >/dev/null 2>&1; return \$_rc; }"
done

fail=0
t() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }
rand() { dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -v -tx1 | tr -d ' \n'; }
W=$(mktemp -d)

S1=$(rand); S2=$(rand)
t "unenrolled before sealing"            'cz_tpm_unenrolled'
t "seal"                                 'cz_seal "$S1" "$PIN" "$W"'
t "enrolled after sealing"               '! cz_tpm_unenrolled'
t "policy unseal returns the secret"     '[ "$(cz_unseal "$PIN")" = "$S1" ]'
[ "$CZ_USE_PIN" = 1 ] &&
t "wrong PIN refused"                    '[ -z "$(cz_unseal "x$PIN")" ]'
for pw in "$PIN" "str:$PIN" ""; do
    out=$(command tpm2_unseal -c "$CZ_TPM_HANDLE" -p "$pw" 2>/dev/null | od -An -tx1)
    command tpm2_flushcontext -t >/dev/null 2>&1
    t "bare password '$pw' cannot bypass the PCR policy" '[ -z "$out" ]'
done
t "re-seal replaces the old object"      'cz_seal "$S2" "$PIN" "$W" && [ "$(cz_unseal "$PIN")" = "$S2" ]'
t "lock extends the policy PCR"          'cz_lock_tpm'
t "no unseal after lock"                 '[ -z "$(cz_unseal "$PIN")" ]'

cz_hex2bin "$CZ_MAGIC_HEX$S1" > "$W/cik"
t "CIK round trip"                       '[ "$(cz_read_cik "$W/cik")" = "$S1" ]'
cz_hex2bin "00$S1" > "$W/bad"
t "CIK with bad magic rejected"          '! cz_read_cik "$W/bad" >/dev/null'
# Pinned: changing the KDF locks every enrolled user out of their drive.
t "KDF known answer" '[ "$(cz_derive aa bb)" = 1750466b8f6ff13c09d58da7fafdd701298bc483433521a0a710ee8091fda819 ]'

rm -rf "$W"
exit $fail
