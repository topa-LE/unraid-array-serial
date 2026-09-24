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

JSON=""

if [ "$USB" -eq 1 ]; then
    # Ohne auslesbare Laufwerksidentitaet keine USB-Adapterkennung verwenden.
    JSON="$(smartctl -i -d sat -j "$DISK" 2>/dev/null)" || exit 1
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
# Modell und Seriennummer bleiben fuer die Kennungsbildung unveraendert.
if [ -z "$MODELL" ]; then
    exit 1
fi

# SMART liefert bei WD-Modellen haeufig "WDC WD...".
# Nur dieses bekannte Herstellerpraefix entfernen.
if [[ "$MODELL" == "WDC WD"* ]]; then
    MODELL="${MODELL#WDC }"
fi

# Erst nach der Praefixbehandlung pruefen.
# Die Kodierung darunter bildet Sonderzeichen eindeutig als -HH ab.
if [[ ! "$MODELL" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    exit 1
fi

# Umkehrbare Kodierung: Bindestrich=-2D, Unterstrich=-5F, Punkt=-2E.
# -00- trennt Modell und Seriennummer eindeutig voneinander.
# Die originale SMART-Seriennummer wird nicht umgeschrieben.
kodieren() {
    local WERT="$1"
    local ZEICHEN HEX AUSGABE=""
    local I

    for ((I = 0; I < ${#WERT}; I++)); do
        ZEICHEN="${WERT:I:1}"

        case "$ZEICHEN" in
            [A-Za-z0-9])
                AUSGABE+="$ZEICHEN"
                ;;
            *)
                printf -v HEX '%02X' "'$ZEICHEN"
                AUSGABE+="-$HEX"
                ;;
        esac
    done

    printf '%s' "$AUSGABE"
}

export LC_ALL=C
KENNUNG="$(kodieren "$MODELL")-00-$(kodieren "$SERIENNUMMER")"

printf 'ID_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'ID_SERIAL=%s\n' "$KENNUNG"
