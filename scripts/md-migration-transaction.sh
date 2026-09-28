#!/bin/bash
set -euo pipefail

MODUS="${1:-}"
PLAN="${2:-}"

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_ID="$VERZEICHNIS/serial-id.sh"

usage() {
    echo "Verwendung:"
    echo "  /bin/bash $0 --prepare PLAN"
    echo "  /bin/bash $0 --apply   PLAN"
}

fehler() {
    echo
    echo "STOP: $*"
    exit 1
}

plan_laden() {
    [ -r "$PLAN" ] ||
        fehler "Migrationsplan fehlt oder ist nicht lesbar: $PLAN"

    declare -gA IDX=()
    declare -gA ALT=()
    declare -gA NEU=()
    declare -gA SERIAL=()
    declare -gA QUELLE=()
    declare -gA GESEHENE_IDX=()
    declare -ga SLOTS=()

    while IFS=$'\t' read -r SLOT SLOT_IDX ALTE_ID HW_SERIAL NEUE_ID SOURCE REST; do

        [ -n "$SLOT" ] || continue

        case "$SLOT" in
            \#*) continue ;;
        esac

        case "$SLOT_IDX" in
            ''|*[!0-9]*)
                fehler "Ungueltiger Slot-Index fuer $SLOT: $SLOT_IDX"
                ;;
        esac

        case "$SLOT" in
            parity)
                [ "$SLOT_IDX" -eq 0 ] ||
                    fehler "parity muss Slot-Index 0 verwenden."
                ;;
            parity2)
                [ "$SLOT_IDX" -eq 29 ] ||
                    fehler "parity2 muss Slot-Index 29 verwenden."
                ;;
            disk[0-9]*)
                ;;
            *)
                fehler "Nicht unterstuetzter Array-Slot: $SLOT"
                ;;
        esac

        [ -z "${GESEHENE_IDX[$SLOT_IDX]+x}" ] ||
            fehler "Slot-Index $SLOT_IDX ist mehrfach vorhanden."

        [ -n "$ALTE_ID" ] ||
            fehler "Alte ID fuer $SLOT fehlt."

        [ -n "$HW_SERIAL" ] ||
            fehler "Hardware-Seriennummer fuer $SLOT fehlt."

        [ -n "$NEUE_ID" ] ||
            fehler "Neue ID fuer $SLOT fehlt."

        case "$SOURCE" in
            ATA|USB_SAT|NVME|CACHE)
                ;;
            *)
                fehler "Ungueltige Identitaetsquelle fuer $SLOT: $SOURCE"
                ;;
        esac

        GESEHENE_IDX["$SLOT_IDX"]="$SLOT"
        IDX["$SLOT"]="$SLOT_IDX"
        ALT["$SLOT"]="$ALTE_ID"
        NEU["$SLOT"]="$NEUE_ID"
        SERIAL["$SLOT"]="$HW_SERIAL"
        QUELLE["$SLOT"]="$SOURCE"

        SLOTS+=("$SLOT")

    done < "$PLAN"

    [ "${#SLOTS[@]}" -gt 0 ] ||
        fehler "Migrationsplan enthaelt keine Array-Slots."
}

geraet_ermitteln() {
    local ERWARTETE_SERIAL="$1"
    local ERWARTETE_ID="$2"
    local ERWARTETE_QUELLE="$3"

    local DEV
    local AUSGABE
    local IST_SERIAL
    local IST_ID
    local IST_QUELLE
    local BOOT_DEV=""
    local -a TREFFER=()

    if [ -r /proc/mounts ]; then
        BOOT_DEV="$(
            awk '$2 == "/boot" { print $1; exit }' /proc/mounts 2>/dev/null |
            sed -E 's#^/dev/##; s#[0-9]+$##'
        )"
    fi

    for SYSDEV in /sys/class/block/sd* /sys/class/block/nvme*n*; do
        [ -e "$SYSDEV" ] || continue

        DEV="$(basename "$SYSDEV")"

        case "$DEV" in
            sd[a-z]|nvme[0-9]*n[0-9]*)
                ;;
            *)
                continue
                ;;
        esac

        [ "$DEV" = "$BOOT_DEV" ] && continue

        AUSGABE="$(
            timeout 20 /bin/bash "$SERIAL_ID" "/dev/$DEV" 2>/dev/null
        )" || continue

        IST_QUELLE="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
        )"

        IST_SERIAL="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
        )"

        IST_ID="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
        )"

        [ "$IST_SERIAL" = "$ERWARTETE_SERIAL" ] || continue
        [ "$IST_ID" = "$ERWARTETE_ID" ] || continue
        [ "$IST_QUELLE" = "$ERWARTETE_QUELLE" ] || continue

        TREFFER+=("$DEV")
    done

    [ "${#TREFFER[@]}" -eq 1 ] ||
        fehler "Hardware nicht eindeutig aufloesbar: Serial=$ERWARTETE_SERIAL Treffer=${#TREFFER[@]}"

    printf '%s\n' "${TREFFER[0]}"
}

plan_anzeigen() {
    echo "===== VERIFIZIERTER MD-TRANSAKTIONSPLAN ====="
    echo

    local SLOT

    for SLOT in "${SLOTS[@]}"; do
        printf '%-10s idx=%-2s  Quelle=%-7s  %s -> %s\n' \
            "$SLOT" \
            "${IDX[$SLOT]}" \
            "${QUELLE[$SLOT]}" \
            "${ALT[$SLOT]}" \
            "${NEU[$SLOT]}"
    done
}

md_geraeteparameter() {
    local DEV="$1"
    local SLOT_IDX="$2"
    local PART=""
    local START=""
    local SIZE=""

    [ -b "/dev/$DEV" ] ||
        fehler "Blockgeraet existiert nicht: /dev/$DEV"

    case "$SLOT_IDX" in
        ''|*[!0-9]*)
            fehler "Ungueltiger Slot-Index fuer MD-Groesse: $SLOT_IDX"
            ;;
    esac

    case "$DEV" in
        sd[a-z])
            PART="${DEV}1"
            ;;
        nvme[0-9]*n[0-9]*)
            PART="${DEV}p1"
            ;;
        *)
            fehler "Nicht unterstuetztes Blockgeraet: /dev/$DEV"
            ;;
    esac

    [ -r "/sys/class/block/$PART/start" ] ||
        fehler "Partitionsstart fehlt fuer /dev/$DEV ($PART)."

    START="$(cat "/sys/class/block/$PART/start")"

    SIZE="$(
        sed -n \
            "s/^diskSize\\.${SLOT_IDX}=//p" \
            /proc/mdstat |
        head -n 1
    )"

    case "$START" in
        ''|*[!0-9]*)
            fehler "Ungueltiger Partitionsstart fuer /dev/$DEV: $START"
            ;;
    esac

    case "$SIZE" in
        ''|*[!0-9]*)
            fehler "Keine gueltige bestehende MD-Groesse fuer Slot $SLOT_IDX."
            ;;
    esac

    [ "$START" -gt 0 ] ||
        fehler "Partitionsstart fuer /dev/$DEV ist 0."

    [ "$SIZE" -gt 0 ] ||
        fehler "Bestehende MD-Groesse fuer Slot $SLOT_IDX ist 0."

    printf '%s\t%s\n' "$START" "$SIZE"
}


md_import_zeile() {
    local SLOT_IDX="$1"
    local DEV="$2"
    local START="$3"
    local SIZE="$4"
    local ID="$5"

    case "$SLOT_IDX" in
        ''|*[!0-9]*)
            fehler "Ungueltiger md-Slot-Index: $SLOT_IDX"
            ;;
    esac

    case "$DEV" in
        sd[a-z]|nvme[0-9]*n[0-9]*)
            ;;
        *)
            fehler "Ungueltiges md-Blockgeraet: $DEV"
            ;;
    esac

    case "$START" in
        ''|*[!0-9]*)
            fehler "Ungueltiger md-Startsektor: $START"
            ;;
    esac

    case "$SIZE" in
        ''|*[!0-9]*)
            fehler "Ungueltige md-Groesse: $SIZE"
            ;;
    esac

    [ -n "$ID" ] ||
        fehler "Leere md-Geraete-ID."

    printf 'import %s %s %s %s 0 %s\n' \
        "$SLOT_IDX" "$DEV" "$START" "$SIZE" "$ID"
}

prepare() {
    echo "===== MD-MIGRATION – PREPARE ====="
    echo

    plan_laden
    plan_anzeigen

    echo
    echo "===== GERAETEAUFLOESUNG ====="

    [ -r "$SERIAL_ID" ] ||
        fehler "serial-id.sh fehlt oder ist nicht lesbar: $SERIAL_ID"

    local SLOT
    local DEV
    local PARAMETER
    local START
    local SIZE

    for SLOT in "${SLOTS[@]}"; do
        DEV="$(
            geraet_ermitteln \
                "${SERIAL[$SLOT]}" \
                "${NEU[$SLOT]}" \
                "${QUELLE[$SLOT]}"
        )"

        PARAMETER="$(
            md_geraeteparameter                 "$DEV"                 "${IDX[$SLOT]}"
        )"
        START="${PARAMETER%%$'\t'*}"
        SIZE="${PARAMETER#*$'\t'}"

        printf '%-10s -> /dev/%-10s start=%-8s size=%s\n' \
            "$SLOT" "$DEV" "$START" "$SIZE"

        printf '           MD: '
        md_import_zeile \
            "${IDX[$SLOT]}" \
            "$DEV" \
            "$START" \
            "$SIZE" \
            "${NEU[$SLOT]}"
    done

    echo
    echo "===== STATUS ====="
    echo "Plan und aktuelle physische Hardware eindeutig verifiziert."
    echo "Blockgeraete sowie START/SIZE wurden frisch ermittelt."
    echo
    echo "MD-Importdaten wurden vollstaendig vorbereitet, aber NICHT ausgefuehrt."
    echo "Noch KEIN /proc/mdcmd beschrieben."
    echo "Noch KEINE super.dat veraendert."
    echo
    echo "ERGEBNIS: PREPARE_OK"
}

apply() {
    echo "===== MD-MIGRATION – APPLY ====="
    echo

    plan_laden
    plan_anzeigen

    echo
    echo "===== SICHERHEITSSPERRE ====="
    echo
    echo "STOP: MD-Persistenztransaktion ist noch nicht freigegeben."
    echo "Es wurde nichts veraendert."
    echo
    echo "ERGEBNIS: APPLY_GESPERRT"
    exit 1
}

case "$MODUS" in
    --prepare)
        [ -n "$PLAN" ] || {
            usage
            exit 1
        }
        prepare
        ;;
    --apply)
        [ -n "$PLAN" ] || {
            usage
            exit 1
        }
        apply
        ;;
    *)
        usage
        exit 1
        ;;
esac
