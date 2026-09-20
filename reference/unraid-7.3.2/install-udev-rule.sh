#!/bin/bash

# topa-LE: Stabile ATA-Seriennummern fuer USB-SATA-Laufwerke.
# Keine Array-Zuordnung, kein Array-Start, keine Paritaetssynchronisierung.

set -euo pipefail

VERZEICHNIS="/boot/config/custom/array-serial"
QUELLE="$VERZEICHNIS/60-persistent-storage.rules"
ORIGINAL="$VERZEICHNIS/60-persistent-storage.original.rules"
HELFER="$VERZEICHNIS/serial-id.sh"

SYSTEMREGEL="/lib/udev/rules.d/60-persistent-storage.rules"
ZIEL="/etc/udev/rules.d/60-persistent-storage.rules"

echo "=== ARRAY-SERIAL: BOOT-REGEL INSTALLIEREN ==="

if [ ! -f "$QUELLE" ] || [ ! -f "$ORIGINAL" ] ||
   [ ! -f "$HELFER" ]; then
    echo "FEHLER: Eine benoetigte Datei fehlt."
    exit 1
fi

if ! cmp -s "$ORIGINAL" "$SYSTEMREGEL"; then
    echo "FEHLER: Systemregel weicht vom gesicherten Original ab."
    exit 1
fi

if ! bash -n "$HELFER"; then
    echo "FEHLER: Seriennummern-Helfer hat einen Syntaxfehler."
    exit 1
fi

if [ -e "$ZIEL" ]; then
    if ! cmp -s "$QUELLE" "$ZIEL"; then
        echo "FEHLER: Am Ziel existiert eine andere Regel."
        exit 1
    fi

    echo "OK: Unsere Regel ist bereits installiert."
else
    if ! cp "$QUELLE" "$ZIEL"; then
        echo "FEHLER: Regel konnte nicht installiert werden."
        exit 1
    fi

    if ! cmp -s "$QUELLE" "$ZIEL"; then
        echo "FEHLER: Installierte Regel stimmt nicht mit der Quelle ueberein."
        rm -f "$ZIEL"
        exit 1
    fi

    echo "OK: Seriennummernregel installiert."
fi

echo "=== ARRAY-SERIAL: UDEV-REGELN NEU LADEN ==="
udevadm control --reload

echo "=== ARRAY-SERIAL: VIA-LABS-LAUFWERKE NEU ERKENNEN ==="

ANZAHL=0

for SYSDEV in /sys/class/block/sd*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"
    [[ "$NAME" =~ ^sd[a-z]+$ ]] || continue

    USBPFAD="$(readlink -f "$SYSDEV/device")" || continue
    PFAD="$USBPFAD"
    GEFUNDEN=0

    while [ "$PFAD" != "/" ]; do
        if [ -r "$PFAD/idVendor" ] && [ -r "$PFAD/idProduct" ]; then
            VENDOR="$(cat "$PFAD/idVendor")"
            PRODUKT="$(cat "$PFAD/idProduct")"

            if [ "$VENDOR" = "2109" ] && [ "$PRODUKT" = "0715" ]; then
                GEFUNDEN=1
                break
            fi
        fi

        PFAD="${PFAD%/*}"
        [ -n "$PFAD" ] || PFAD="/"
    done

    if [ "$GEFUNDEN" -eq 1 ]; then
        echo "Neuerkennung: /dev/$NAME"

        udevadm trigger --action=add \
            --sysname-match="$NAME" \
            --subsystem-match=block

        ANZAHL=$((ANZAHL + 1))
    fi
done

udevadm settle

echo "Erfasste VIA-Labs-Laufwerke: $ANZAHL"
echo "OK: Udev-Neuerkennung abgeschlossen."
