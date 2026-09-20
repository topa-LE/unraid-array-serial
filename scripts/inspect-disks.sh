#!/bin/bash

# Unraid Array Serial – Laufwerksdiagnose
# Nur lesende Abfragen. Keine udev-Aenderungen und keine Array-Aktionen.

set -uo pipefail

echo "=== UNRAID ARRAY SERIAL – LAUFWERKSDIAGNOSE ==="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "FEHLER: Bitte als root ausfuehren."
    exit 1
fi

if ! command -v smartctl >/dev/null 2>&1; then
    echo "FEHLER: smartctl fehlt."
    exit 1
fi

if ! command -v udevadm >/dev/null 2>&1; then
    echo "FEHLER: udevadm fehlt."
    exit 1
fi

echo "Hostname: $(hostname)"
echo "Datum: $(date '+%Y-%m-%d %H:%M:%S')"
echo

ANZAHL=0

for SYSDEV in /sys/class/block/*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"

    # Nur ganze sd-, hd-, nvme- und vd-Laufwerke.
    if [[ ! "$NAME" =~ ^(sd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$ ]]; then
        continue
    fi

    DISK="/dev/$NAME"
    [ -b "$DISK" ] || continue

    ANZAHL=$((ANZAHL + 1))

    echo "============================================================"
    echo "LAUFWERK: $DISK"
    echo "============================================================"

    echo
    echo "--- UDEV-IDENTIFIKATION ---"

    udevadm info --query=property --name="$DISK" 2>/dev/null |
        grep -E '^(ID_BUS|ID_VENDOR|ID_MODEL|ID_SERIAL|ID_SERIAL_SHORT|ID_WWN|ID_PATH)=' || true

    echo
    echo "--- SERIENNUMMERNVERGLEICH ---"

    UDEV_SERIAL="$(
        udevadm info --query=property --name="$DISK" 2>/dev/null |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    # SMART-Ausgaben je Laufwerk einmal lesen und wiederverwenden.
    SMART_STANDARD_INFO="$(smartctl -i "$DISK" 2>/dev/null || true)"
    SMART_SAT_INFO=""

    if [[ "$NAME" =~ ^(sd[a-z]+|hd[a-z]+)$ ]]; then
        SMART_SAT_INFO="$(smartctl -i -d sat "$DISK" 2>/dev/null || true)"
    fi

    SMART_SERIAL="$(
        printf '%s\n' "$SMART_STANDARD_INFO" |
            sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' |
            head -n 1
    )"

    SAT_SERIAL="$(
        printf '%s\n' "$SMART_SAT_INFO" |
            sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' |
            head -n 1
    )"

    echo "Udev-Seriennummer: ${UDEV_SERIAL:-nicht verfuegbar}"
    echo "SMART-Seriennummer: ${SMART_SERIAL:-nicht verfuegbar}"
    echo "SAT-Seriennummer: ${SAT_SERIAL:-nicht verfuegbar}"

    if [ -n "$SAT_SERIAL" ] &&
       [ -n "$UDEV_SERIAL" ] &&
       [ "$SAT_SERIAL" != "$UDEV_SERIAL" ]; then
        echo "HINWEIS: SAT- und Udev-Seriennummer unterscheiden sich."
        echo "HINWEIS: Keine automatische Aenderung der Laufwerkskennung."
    fi

    echo
    echo "--- LAUFWERKSBEZEICHNUNG: VORSCHAU ---"

    # Modell, Seriennummer und gegebenenfalls Hersteller werden
    # ausschliesslich aus derselben SMART-Abfrage entnommen.
    SMART_INFO="$SMART_STANDARD_INFO"
    QUELLE="SMART-Standard"

    if [ -n "$SAT_SERIAL" ]; then
        SMART_INFO="$SMART_SAT_INFO"
        QUELLE="SMART-SAT"
    fi

    HERSTELLER="$(
        printf '%s\n' "$SMART_INFO" |
            sed -n -E 's/^[[:space:]]*Vendor:[[:space:]]*//p' |
            head -n 1
    )"

    MODELL="$(
        printf '%s\n' "$SMART_INFO" |
            sed -n -E 's/^[[:space:]]*(Device Model|Model Number):[[:space:]]*//p' |
            head -n 1
    )"

    SERIE="$(
        printf '%s\n' "$SMART_INFO" |
            sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' |
            head -n 1
    )"

    echo "Datenquelle: $QUELLE"
    echo "Hersteller: ${HERSTELLER:-unbekannt}"
    echo "Modell: ${MODELL:-nicht verfuegbar}"
    echo "Hardware-Seriennummer: ${SERIE:-nicht verfuegbar}"

    if [ -n "$HERSTELLER" ] &&
       [ -n "$MODELL" ] &&
       [ -n "$SERIE" ]; then
        echo "Status: Alle drei Angaben sind vorhanden."
        echo "HINWEIS: Eine vollstaendige Kennung koennte als Vorschau erzeugt werden."
    else
        echo "Status: Keine vollstaendige Kennung erzeugen."
        echo "HINWEIS: Fehlende Angaben werden nicht aus USB-Adapterdaten ergaenzt."
    fi

    echo "HINWEIS: Keine Aenderung an Unraid oder udev."

    echo
    echo "--- GERAETEPFAD UND USB-ADAPTER ---"

    PFAD="$(readlink -f "$SYSDEV/device" 2>/dev/null)" || PFAD=""

    if [ -n "$PFAD" ]; then
        echo "Geraetepfad: $PFAD"

        SUCHPFAD="$PFAD"

        while [ "$SUCHPFAD" != "/" ]; do
            if [ -r "$SUCHPFAD/idVendor" ] &&
               [ -r "$SUCHPFAD/idProduct" ]; then

                echo "USB-Vendor-ID: $(cat "$SUCHPFAD/idVendor")"
                echo "USB-Product-ID: $(cat "$SUCHPFAD/idProduct")"
                break
            fi

            SUCHPFAD="${SUCHPFAD%/*}"
            [ -n "$SUCHPFAD" ] || SUCHPFAD="/"
        done
    fi

    echo
    echo "--- SMART-STANDARDABFRAGE ---"

    printf '%s\n' "$SMART_STANDARD_INFO" |
        grep -Ei '^(Device Model|Model Number|Model Family|Product|Vendor|Serial Number|LU WWN Device Id|Transport protocol):' || true

    echo
    echo "--- SMART-SAT-ABFRAGE ---"

    if [ -n "$SMART_SAT_INFO" ]; then
        printf '%s\n' "$SMART_SAT_INFO" |
            grep -Ei '^(Device Model|Model Number|Model Family|Product|Vendor|Serial Number|LU WWN Device Id|Transport protocol):' || true
    else
        echo "Keine SAT-Ausgabe verfuegbar."
    fi

    echo
done

echo "============================================================"
echo "Erfasste Laufwerke: $ANZAHL"
echo "============================================================"

echo
echo "HINWEIS: Nur lesende Diagnose."
echo "HINWEIS: Keine Laufwerkskennungen oder Array-Zuordnungen geaendert."
