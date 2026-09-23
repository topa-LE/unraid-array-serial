#!/bin/bash

# Unraid Array Serial – Hardware-Identifikation
# Entwicklungsfassung: keine Aenderung an udev oder Array-Zuordnungen.
# Ausgabe fuer udev nur bei erfolgreich ermittelter Hardware-Seriennummer.

set -euo pipefail

DISK="${1:-}"

if [[ ! "$DISK" =~ ^/dev/(sd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$ ]] ||
   [ ! -b "$DISK" ]; then
    exit 1
fi

command -v smartctl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

NAME="${DISK##*/}"

# Bei USB-SATA-Geraeten SAT bevorzugen: Die normale USB-Identifikation
# kann die Seriennummer des Adapters statt der Festplatte liefern.
USB=0
PFAD="$(readlink -f "/sys/class/block/$NAME/device" 2>/dev/null)" || exit 1

while [ "$PFAD" != "/" ]; do
    if [ -r "$PFAD/idVendor" ] && [ -r "$PFAD/idProduct" ]; then
        USB=1
        break
    fi
    PFAD="${PFAD%/*}"
    [ -n "$PFAD" ] || PFAD="/"
done

# USB-Fallback nur fuer Geraete ohne auslesbare SMART-Identitaet.
# Die Kennung stammt dann vom USB-Geraet, nicht zwingend vom Datentraeger.
usb_fallback() {
    [ "$USB" -eq 1 ] || return 1

    local EIGENSCHAFTEN MODELL_USB SERIE_USB
    EIGENSCHAFTEN="$(udevadm info --query=property --name="$DISK" 2>/dev/null)" ||
        return 1

    MODELL_USB="$(printf '%s\n' "$EIGENSCHAFTEN" |
        sed -n 's/^ID_MODEL=//p' | head -n 1)"
    SERIE_USB="$(printf '%s\n' "$EIGENSCHAFTEN" |
        sed -n 's/^ID_SERIAL_SHORT=//p' | head -n 1)"

    [ -n "$MODELL_USB" ] && [ -n "$SERIE_USB" ] || return 1
    [[ "$MODELL_USB" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$SERIE_USB" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ ! "$SERIE_USB" =~ ^0+$ ]] || return 1

    printf 'ID_SERIAL_SHORT=%s\n' "$SERIE_USB"
    printf 'ID_SERIAL=USB-%s-%s\n' "$MODELL_USB" "$SERIE_USB"
}

JSON=""

if [ "$USB" -eq 1 ]; then
    JSON="$(smartctl -i -d sat -j "$DISK" 2>/dev/null)" || {
        usb_fallback
        exit $?
    }
else
    JSON="$(smartctl -i -j "$DISK" 2>/dev/null)" || exit 1
fi

SERIENNUMMER="$(
    printf '%s\n' "$JSON" |
        jq -r '.serial_number // empty' 2>/dev/null
)" || exit 1

# Keine leeren Werte, Platzhalter oder fuer udev ungeeigneten Zeichen.
if [[ ! "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]] ||
   [[ "$SERIENNUMMER" =~ ^0+$ ]]; then
    exit 1
fi

# Modell und echte Hardware-Seriennummer aus derselben SMART-Abfrage.
MODELL="$(
    printf '%s\n' "$JSON" |
        jq -r '.model_name // empty' 2>/dev/null
)" || exit 1

# Keine Adapterbezeichnung oder erfundene Modellnummer einsetzen.
# Leerzeichen werden nur fuer den technischen Namen durch _ ersetzt.
if [ -z "$MODELL" ]; then
    exit 1
fi

MODELL="${MODELL// /_}"

if [[ ! "$MODELL" =~ ^[A-Za-z0-9._-]+$ ]]; then
    exit 1
fi

# SMART liefert bei WD-Modellen haeufig "WDC WD...".
# Nur das Herstellerpraefix entfernen; Modellcode vollstaendig behalten.
if [[ "$MODELL" == WDC_WD* ]]; then
    MODELL="${MODELL#WDC_}"
fi

KENNUNG="${MODELL}-${SERIENNUMMER}"

printf 'ID_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'ID_SERIAL=%s\n' "$KENNUNG"
