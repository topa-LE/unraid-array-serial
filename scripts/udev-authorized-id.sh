#!/bin/bash
#
# Udev-sicherer Identity-Wrapper.
#
# serial-id.sh bleibt der ungefilterte Resolver fuer Preflight/Migration.
# Dieser Wrapper gibt dessen Eigenschaften nur dann an Udev weiter,
# wenn die konkrete Hardware-Tuple in der persistenten Baseline steht.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
SERIAL_ID="$BASE/serial-id.sh"
BASELINE="$BASE/identity-baseline.tsv"
TIMEOUT=20

GERAET="${1:-}"

[ -n "$GERAET" ] || exit 1
[ -b "$GERAET" ] || exit 1
[ -f "$SERIAL_ID" ] || exit 1
[ -f "$BASELINE" ] || exit 1

AUSGABE="$(
    timeout "$TIMEOUT" \
        /bin/bash "$SERIAL_ID" "$GERAET" \
        2>/dev/null
)" || exit 1

HW_SERIAL="$(
    printf '%s\n' "$AUSGABE" |
        sed -n 's/^ID_SERIAL_SHORT=//p' |
        head -n 1
)"

SOURCE="$(
    printf '%s\n' "$AUSGABE" |
        sed -n 's/^IDENTITY_SOURCE=//p' |
        head -n 1
)"

APPROVED_ID="$(
    printf '%s\n' "$AUSGABE" |
        sed -n 's/^ID_SERIAL=//p' |
        head -n 1
)"

[ -n "$HW_SERIAL" ] || exit 1
[ -n "$SOURCE" ] || exit 1
[ -n "$APPROVED_ID" ] || exit 1

# Persistente Baseline akzeptiert bewusst kein CACHE.
case "$SOURCE" in
    ATA|NVME|USB_SAT)
        ;;
    *)
        exit 1
        ;;
esac

# Exakt drei Felder; keine Teilstring-/Regex-Autorisierung.
if ! awk -F '\t' \
    -v hw="$HW_SERIAL" \
    -v src="$SOURCE" \
    -v id="$APPROVED_ID" '
        NF == 3 &&
        $1 == hw &&
        $2 == src &&
        $3 == id {
            found++
        }
        END {
            exit(found == 1 ? 0 : 1)
        }
    ' "$BASELINE"
then
    exit 1
fi

printf '%s\n' "$AUSGABE"
