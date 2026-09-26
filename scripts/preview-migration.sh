#!/bin/bash

# topa-LE Unraid Array Serial
#
# Sichere Vorschau einer Kennungsmigration.
#
# Verknuepft:
#   Unraid-Slot
#   -> aktuelle Unraid-ID
#   -> aktuelles Blockgeraet
#   -> echte SMART-Modellbezeichnung
#   -> echte SMART-Seriennummer
#   -> physische Transportart
#   -> gewuenschte neue Anzeige-ID
#
# WICHTIG:
#
# Die echte Hardware-Identitaet wird aus Modell und Seriennummer gebildet.
# Die Transportinformation ist nur ein zusaetzlicher sichtbarer Hinweis.
#
# Beispiele:
#
#   WDC-WD40EFRX-68N32N0-WD-WCC7K5ZJKT08
#   WDC-WD40EFRX-68N32N0-WD-WCC7K5ZJKT08-USB3
#
# Ein USB-Suffix entscheidet NICHT darueber, ob es dieselbe Platte ist.
# Dafuer ist die echte Hardware-Seriennummer massgeblich.
#
# Dieses Skript veraendert NICHTS.

set -euo pipefail

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FORMATIERER="$VERZEICHNIS/format-disk-id.sh"
TRANSPORT_ERKENNUNG="$VERZEICHNIS/detect-transport.sh"
DISKS_INI="/var/local/emhttp/disks.ini"

[ -x "$FORMATIERER" ] || {
    echo "STOP: format-disk-id.sh fehlt oder ist nicht ausfuehrbar."
    exit 1
}

[ -x "$TRANSPORT_ERKENNUNG" ] || {
    echo "STOP: detect-transport.sh fehlt oder ist nicht ausfuehrbar."
    exit 1
}

[ -r "$DISKS_INI" ] || {
    echo "STOP: $DISKS_INI ist nicht lesbar."
    exit 1
}

for PROGRAMM in smartctl jq udevadm findmnt awk; do
    command -v "$PROGRAMM" >/dev/null 2>&1 || {
        echo "STOP: $PROGRAMM fehlt."
        exit 1
    }
done

ermittle_transport() {
    local NAME="$1"

    bash "$VERZEICHNIS/detect-transport.sh" "/dev/$NAME"
}

BOOT_QUELLE="$(findmnt -n -o SOURCE --target /boot 2>/dev/null || true)"
BOOT_DISK=""

if [[ "$BOOT_QUELLE" =~ ^/dev/(sd[a-z]+)[0-9]+$ ]]; then
    BOOT_DISK="${BASH_REMATCH[1]}"
fi

echo "===== UNRAID ARRAY SERIAL – SICHERE MIGRATIONSVORSCHAU ====="
echo
echo "Boot-Quelle: ${BOOT_QUELLE:-nicht ermittelt}"
echo

FEHLER=0
GEPRUEFT=0
AENDERUNGEN=0

declare -A SERIENNUMMERN=()
declare -A HARDWARE_IDS=()
declare -A ANZEIGE_IDS=()

while IFS='|' read -r SLOT DEVICE SLOT_ID SLOT_ID_SB STATUS; do
    [ -n "$SLOT" ] || continue
    [ -n "$DEVICE" ] || continue

    case "$SLOT" in
        parity|parity2|parity3|flash)
            continue
            ;;
    esac

    if [[ ! "$DEVICE" =~ ^sd[a-z]+$ ]]; then
        continue
    fi

    if [ -n "$BOOT_DISK" ] && [ "$DEVICE" = "$BOOT_DISK" ]; then
        continue
    fi

    DEV="/dev/$DEVICE"

    echo "============================================================"
    echo "SLOT:          $SLOT"
    echo "GERAET:        $DEV"
    echo "UNRAID-ID:     ${SLOT_ID:-<leer>}"
    echo "SUPER-ID:      ${SLOT_ID_SB:-<leer>}"
    echo "UNRAID-STATUS: ${STATUS:-<leer>}"

    if [ ! -b "$DEV" ]; then
        echo "ERGEBNIS:      STOP – Blockgeraet fehlt."
        echo
        FEHLER=1
        continue
    fi

    UDEV_ID="$(
        udevadm info --query=property --name="$DEV" 2>/dev/null |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    echo "UDEV-ID:       ${UDEV_ID:-<leer>}"

    if [ -z "$SLOT_ID" ] ||
       [ -z "$SLOT_ID_SB" ] ||
       [ -z "$UDEV_ID" ]; then
        echo "ERGEBNIS:      STOP – eine bestehende Kennung fehlt."
        echo
        FEHLER=1
        continue
    fi

    if [ "$SLOT_ID" != "$SLOT_ID_SB" ]; then
        echo "ERGEBNIS:      STOP – aktuelle Slot-ID und gespeicherte Super-ID unterscheiden sich."
        echo
        FEHLER=1
        continue
    fi

    if [ "$SLOT_ID" != "$UDEV_ID" ]; then
        echo "ERGEBNIS:      STOP – Unraid-Slot und aktuelles Udev-Geraet stimmen nicht ueberein."
        echo
        FEHLER=1
        continue
    fi

    JSON="$(smartctl -i -d sat -j "$DEV" 2>/dev/null || true)"

    MODELL="$(
        printf '%s\n' "$JSON" |
            jq -r '.model_name // empty' 2>/dev/null
    )"

    SERIENNUMMER="$(
        printf '%s\n' "$JSON" |
            jq -r '.serial_number // empty' 2>/dev/null
    )"

    echo "SMART-MODELL:  ${MODELL:-<leer>}"
    echo "SMART-SERIAL:  ${SERIENNUMMER:-<leer>}"

    if [ -z "$MODELL" ] || [ -z "$SERIENNUMMER" ]; then
        echo "ERGEBNIS:      STOP – keine eindeutige SMART-Identitaet."
        echo
        FEHLER=1
        continue
    fi

    if [[ ! "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]] ||
       [[ "$SERIENNUMMER" =~ ^0+$ ]]; then
        echo "ERGEBNIS:      STOP – ungueltige Hardware-Seriennummer."
        echo
        FEHLER=1
        continue
    fi

    if [ -n "${SERIENNUMMERN[$SERIENNUMMER]+x}" ]; then
        echo "ERGEBNIS:      STOP – Hardware-Seriennummer ist nicht eindeutig."
        echo "                Bereits erkannt bei ${SERIENNUMMERN[$SERIENNUMMER]}"
        echo
        FEHLER=1
        continue
    fi

    SERIENNUMMERN["$SERIENNUMMER"]="$SLOT"

    if ! HARDWARE_ID="$(bash "$FORMATIERER" "$MODELL" "$SERIENNUMMER")"; then
        echo "ERGEBNIS:      STOP – Hardware-ID kann nicht sicher erzeugt werden."
        echo
        FEHLER=1
        continue
    fi

    if [ -n "${HARDWARE_IDS[$HARDWARE_ID]+x}" ]; then
        echo "ERGEBNIS:      STOP – Hardware-ID ist nicht eindeutig."
        echo "                Bereits erkannt bei ${HARDWARE_IDS[$HARDWARE_ID]}"
        echo
        FEHLER=1
        continue
    fi

    HARDWARE_IDS["$HARDWARE_ID"]="$SLOT"

    TRANSPORT="$(ermittle_transport "$DEVICE")"

    case "$TRANSPORT" in
        USB1|USB2|USB3|USB)
            ANZEIGE_ID="${HARDWARE_ID}-${TRANSPORT}"
            ;;
        *)
            ANZEIGE_ID="$HARDWARE_ID"
            ;;
    esac

    echo "HARDWARE-ID:   $HARDWARE_ID"
    echo "TRANSPORT:     $TRANSPORT"
    echo "NEUE-ID:       $ANZEIGE_ID"

    if [ -n "${ANZEIGE_IDS[$ANZEIGE_ID]+x}" ]; then
        echo "ERGEBNIS:      STOP – neue Anzeige-ID ist nicht eindeutig."
        echo "                Bereits erkannt bei ${ANZEIGE_IDS[$ANZEIGE_ID]}"
        echo
        FEHLER=1
        continue
    fi

    ANZEIGE_IDS["$ANZEIGE_ID"]="$SLOT"

    if [ "$SLOT_ID" = "$ANZEIGE_ID" ]; then
        echo "ERGEBNIS:      OK – Kennung bereits korrekt."
    else
        echo "ERGEBNIS:      OK – bestehender Slot eindeutig derselben Hardware zugeordnet."
        echo "                Nur die sichtbare Kennung wuerde sich aendern."
        AENDERUNGEN=$((AENDERUNGEN + 1))
    fi

    GEPRUEFT=$((GEPRUEFT + 1))
    echo

done < <(
    awk '
        /^\["[^"]+"\]$/ {
            if (slot != "") {
                print slot "|" device "|" id "|" idSb "|" status
            }

            slot=$0
            gsub(/^\["|"\]$/, "", slot)

            device=""
            id=""
            idSb=""
            status=""
            next
        }

        /^device="/ {
            device=$0
            sub(/^device="/, "", device)
            sub(/"$/, "", device)
            next
        }

        /^id="/ {
            id=$0
            sub(/^id="/, "", id)
            sub(/"$/, "", id)
            next
        }

        /^idSb="/ {
            idSb=$0
            sub(/^idSb="/, "", idSb)
            sub(/"$/, "", idSb)
            next
        }

        /^status="/ {
            status=$0
            sub(/^status="/, "", status)
            sub(/"$/, "", status)
            next
        }

        END {
            if (slot != "") {
                print slot "|" device "|" id "|" idSb "|" status
            }
        }
    ' "$DISKS_INI"
)

echo "============================================================"
echo "===== ZUSAMMENFASSUNG ====="
echo "Sicher gepruefte Array-Laufwerke: $GEPRUEFT"
echo "Davon mit geplanter Namensaenderung: $AENDERUNGEN"

if [ "$FEHLER" -ne 0 ]; then
    echo "ERGEBNIS: STOP"
    echo "Mindestens eine Zuordnung konnte nicht zweifelsfrei bestaetigt werden."
    exit 1
fi

echo "ERGEBNIS: OK"
echo "Alle geprueften bestehenden Slots stimmen mit ihren aktuellen"
echo "Udev-Geraeten ueberein und besitzen eine eindeutige Hardware-Identitaet."
echo
echo "Die Transportinformation ist nur Bestandteil der sichtbaren Kennung."
echo "Die echte Seriennummer bleibt Grundlage der Hardware-Zuordnung."
echo
echo "HINWEIS: Es wurde nichts veraendert."
