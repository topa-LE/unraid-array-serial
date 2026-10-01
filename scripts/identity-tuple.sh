#!/bin/bash
#
# topa-LE Unraid Array Serial
#
# Gemeinsamer Identitaetsvertrag fuer Aktivierung und Early-Boot.
#
# Kanonisches Tupel:
#
#   HW_SERIAL<TAB>SOURCE<TAB>APPROVED_ID
#
# Dieses Skript veraendert weder Udev noch Unraid-Konfigurationen.
# Es ruft ausschliesslich serial-id.sh fuer ein konkretes Blockgeraet auf
# und prueft dessen berechnete Identitaet gegen ein erwartetes Tupel.
#

set -euo pipefail

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_ID="$VERZEICHNIS/serial-id.sh"
TIMEOUT=20

usage() {
    echo "Verwendung:" >&2
    echo "  $0 --read /dev/Geraet" >&2
    echo "  $0 --match /dev/Geraet HW_SERIAL SOURCE APPROVED_ID" >&2
}

identitaet_lesen() {
    local DEV="$1"
    local OUT=""
    local HW_SERIAL=""
    local SOURCE=""
    local ID=""

    [ -b "$DEV" ] || {
        echo "STOP: Kein Blockgeraet: $DEV" >&2
        return 1
    }

    [ -f "$SERIAL_ID" ] || {
        echo "STOP: serial-id.sh fehlt: $SERIAL_ID" >&2
        return 1
    }

    OUT="$(
        timeout "$TIMEOUT" \
            /bin/bash "$SERIAL_ID" "$DEV" \
            2>/dev/null
    )" || {
        echo "STOP: Identitaet konnte nicht sicher ermittelt werden: $DEV" >&2
        return 1
    }

    HW_SERIAL="$(
        printf '%s\n' "$OUT" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    SOURCE="$(
        printf '%s\n' "$OUT" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
    )"

    ID="$(
        printf '%s\n' "$OUT" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    [ -n "$HW_SERIAL" ] || {
        echo "STOP: Hardware-Seriennummer fehlt: $DEV" >&2
        return 1
    }

    [ -n "$ID" ] || {
        echo "STOP: Projekt-ID fehlt: $DEV" >&2
        return 1
    }

    case "$SOURCE" in
        ATA|NVME|USB_SAT|CACHE)
            ;;
        *)
            echo "STOP: Unbekannte Identitaetsquelle '$SOURCE': $DEV" >&2
            return 1
            ;;
    esac

    case "$HW_SERIAL" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            echo "STOP: Ungueltige Hardware-Seriennummer: $DEV" >&2
            return 1
            ;;
    esac

    case "$ID" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            echo "STOP: Ungueltige Projekt-ID: $DEV" >&2
            return 1
            ;;
    esac

    printf '%s\t%s\t%s\n' \
        "$HW_SERIAL" \
        "$SOURCE" \
        "$ID"
}

case "${1:-}" in
    --read)
        [ "$#" -eq 2 ] || {
            usage
            exit 2
        }

        identitaet_lesen "$2"
        ;;

    --match)
        [ "$#" -eq 5 ] || {
            usage
            exit 2
        }

        DEV="$2"
        ERWARTETE_SERIAL="$3"
        ERWARTETE_SOURCE="$4"
        ERWARTETE_ID="$5"

        IST_TUPEL="$(identitaet_lesen "$DEV")" || exit 1

        IFS=$'\t' read -r \
            IST_SERIAL \
            IST_SOURCE \
            IST_ID \
            <<< "$IST_TUPEL"

        if [ "$IST_SERIAL" != "$ERWARTETE_SERIAL" ] ||
           [ "$IST_SOURCE" != "$ERWARTETE_SOURCE" ] ||
           [ "$IST_ID" != "$ERWARTETE_ID" ]; then

            echo "STOP: Identitaets-Tupel stimmt nicht ueberein." >&2
            echo "Geraet:          $DEV" >&2
            echo "Erwartete Serial: $ERWARTETE_SERIAL" >&2
            echo "Aktuelle Serial:  $IST_SERIAL" >&2
            echo "Erwartete Quelle: $ERWARTETE_SOURCE" >&2
            echo "Aktuelle Quelle:  $IST_SOURCE" >&2
            echo "Erwartete ID:     $ERWARTETE_ID" >&2
            echo "Aktuelle ID:      $IST_ID" >&2

            exit 1
        fi

        printf '%s\n' "$IST_TUPEL"
        ;;

    *)
        usage
        exit 2
        ;;
esac
