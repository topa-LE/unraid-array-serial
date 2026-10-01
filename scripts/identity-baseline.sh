#!/bin/bash
#
# topa-LE Unraid Array Serial
#
# Validiert eine persistente Identitaets-Baseline.
#
# Format:
#
#   HW_SERIAL<TAB>SOURCE<TAB>APPROVED_ID
#
# Die Baseline bindet eine physische Hardware-Seriennummer an genau
# eine vom Projekt berechnete ID und deren Identitaetsquelle.
#
# Dieses Skript erzeugt oder veraendert keine Baseline.
# Es veraendert weder Udev noch Unraid-Konfigurationen.
#

set -euo pipefail

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_TUPLE="$VERZEICHNIS/identity-tuple.sh"

usage() {
    echo "Verwendung:" >&2
    echo "  $0 --validate BASELINE" >&2
    echo "  $0 --authorize BASELINE /dev/Geraet" >&2
}

feld_pruefen() {
    local NAME="$1"
    local WERT="$2"

    [ -n "$WERT" ] || {
        echo "STOP: Leeres Baseline-Feld: $NAME" >&2
        return 1
    }

    case "$WERT" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            echo "STOP: Ungueltiges Baseline-Feld: $NAME" >&2
            return 1
            ;;
    esac
}

baseline_laden() {
    local DATEI="$1"
    local ZEILE=""
    local HW=""
    local SOURCE=""
    local ID=""
    local EXTRA=""
    local NR=0

    [ -f "$DATEI" ] || {
        echo "STOP: Baseline fehlt: $DATEI" >&2
        return 1
    }

    [ -r "$DATEI" ] || {
        echo "STOP: Baseline nicht lesbar: $DATEI" >&2
        return 1
    }

    BASELINE_ANZAHL=0

    unset BASELINE_HW BASELINE_SOURCE BASELINE_ID
    declare -gA BASELINE_HW=()
    declare -gA BASELINE_SOURCE=()
    declare -gA BASELINE_ID=()

    while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do
        NR=$((NR + 1))

        [ -n "$ZEILE" ] || {
            echo "STOP: Leere Zeile in Baseline: Zeile $NR" >&2
            return 1
        }

        case "$ZEILE" in
            \#*)
                echo "STOP: Kommentare sind in der Baseline nicht erlaubt: Zeile $NR" >&2
                return 1
                ;;
        esac

        HW=""
        SOURCE=""
        ID=""
        EXTRA=""

        IFS=$'\t' read -r HW SOURCE ID EXTRA <<< "$ZEILE"

        feld_pruefen "HW_SERIAL in Zeile $NR" "$HW" || return 1
        feld_pruefen "SOURCE in Zeile $NR" "$SOURCE" || return 1
        feld_pruefen "APPROVED_ID in Zeile $NR" "$ID" || return 1

        [ -z "$EXTRA" ] || {
            echo "STOP: Zu viele Felder in Baseline: Zeile $NR" >&2
            return 1
        }

        case "$SOURCE" in
            ATA|NVME|USB_SAT|CACHE)
                ;;
            *)
                echo "STOP: Ungueltige Identitaetsquelle '$SOURCE' in Zeile $NR" >&2
                return 1
                ;;
        esac

        if [ -n "${BASELINE_HW[$HW]+x}" ]; then
            echo "STOP: Hardware-Seriennummer mehrfach in Baseline: $HW" >&2
            return 1
        fi

        for VORHANDENE_HW in "${!BASELINE_ID[@]}"; do
            if [ "${BASELINE_ID[$VORHANDENE_HW]}" = "$ID" ]; then
                echo "STOP: APPROVED_ID mehrfach in Baseline: $ID" >&2
                return 1
            fi
        done

        BASELINE_HW["$HW"]="$HW"
        BASELINE_SOURCE["$HW"]="$SOURCE"
        BASELINE_ID["$HW"]="$ID"

        BASELINE_ANZAHL=$((BASELINE_ANZAHL + 1))
    done < "$DATEI"

    [ "$BASELINE_ANZAHL" -gt 0 ] || {
        echo "STOP: Baseline ist leer." >&2
        return 1
    }
}

baseline_validieren() {
    local DATEI="$1"

    baseline_laden "$DATEI"

    echo "Baseline-Eintraege: $BASELINE_ANZAHL"
    echo "BASELINE_VALID"
}

geraet_autorisieren() {
    local DATEI="$1"
    local DEV="$2"
    local TUPEL=""
    local HW=""
    local SOURCE=""
    local ID=""

    [ -f "$IDENTITY_TUPLE" ] || {
        echo "STOP: identity-tuple.sh fehlt: $IDENTITY_TUPLE" >&2
        return 1
    }

    baseline_laden "$DATEI"

    TUPEL="$(
        /bin/bash "$IDENTITY_TUPLE" --read "$DEV"
    )" || return 1

    IFS=$'\t' read -r HW SOURCE ID <<< "$TUPEL"

    [ -n "${BASELINE_HW[$HW]+x}" ] || {
        echo "STOP: Hardware ist nicht durch die Baseline autorisiert." >&2
        echo "Geraet:    $DEV" >&2
        echo "HW-Serial: $HW" >&2
        echo "Quelle:    $SOURCE" >&2
        echo "ID:        $ID" >&2
        return 1
    }

    if [ "${BASELINE_SOURCE[$HW]}" != "$SOURCE" ] ||
       [ "${BASELINE_ID[$HW]}" != "$ID" ]; then

        echo "STOP: Hardware stimmt nicht mit der Baseline ueberein." >&2
        echo "Geraet:             $DEV" >&2
        echo "HW-Serial:          $HW" >&2
        echo "Erwartete Quelle:   ${BASELINE_SOURCE[$HW]}" >&2
        echo "Aktuelle Quelle:    $SOURCE" >&2
        echo "Erwartete ID:       ${BASELINE_ID[$HW]}" >&2
        echo "Aktuelle ID:        $ID" >&2
        return 1
    fi

    printf '%s\n' "$TUPEL"
}

case "${1:-}" in
    --validate)
        [ "$#" -eq 2 ] || {
            usage
            exit 2
        }

        baseline_validieren "$2"
        ;;

    --authorize)
        [ "$#" -eq 3 ] || {
            usage
            exit 2
        }

        geraet_autorisieren "$2" "$3"
        ;;

    *)
        usage
        exit 2
        ;;
esac
