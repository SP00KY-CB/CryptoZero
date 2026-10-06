#!/bin/bash
# Exercise the PBA's TPM/CIK logic (cz-lib.sh) against a software TPM.
# Needs: swtpm, tpm2-tools >= 5, dash.     Usage: tests/tpm/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY=$HERE/../../images/buildroot/64bit/overlay
T=$(mktemp -d)
trap '[ -f "$T/pid" ] && kill "$(cat "$T/pid")" 2>/dev/null; rm -rf "$T"' EXIT
export TPM2TOOLS_TCTI="swtpm:host=127.0.0.1,port=2321"
export CZ_LIB=$OVERLAY/usr/lib/cryptozero/cz-lib.sh CZ_CONF=$T/conf

fresh_tpm() {
    [ -f "$T/pid" ] && kill "$(cat "$T/pid")" && sleep 0.5
    rm -rf "$T/state"; mkdir "$T/state"
    swtpm socket --tpm2 --tpmstate dir="$T/state" --server type=tcp,port=2321 \
        --ctrl type=tcp,port=2322 --flags not-need-init,startup-clear --daemon --pid file="$T/pid"
    sleep 0.5
}

rc=0
for mode in "1:hex:12 34" "0:"; do
    usepin=${mode%%:*}; export PIN=${mode#*:}
    sed "s/^CZ_USE_PIN=.*/CZ_USE_PIN=$usepin/" "$OVERLAY/etc/cryptozero.conf" > "$CZ_CONF"
    echo "# CZ_USE_PIN=$usepin"
    fresh_tpm
    dash "$HERE/cases.sh" || rc=1
done
exit $rc
