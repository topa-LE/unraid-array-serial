#!/bin/bash
# topa-LE Unraid Array Serial – Boot-Installation
# Installiert nur zusaetzliche udev-Eigenschaften.
# Bestehende Unraid-ID_SERIAL und Array-Zuordnungen bleiben unangetastet.
set -euo pipefail

QUELLE="/boot/config/custom/array-serial"
REGEL_QUELLE="$QUELLE/99-topa-array-serial.rules"
REGEL_ZIEL="/etc/udev/rules.d/99-topa-array-serial.rules"

[ "$(id -u)" -eq 0 ] || {
    echo "FEHLER: Root-Rechte erforderlich."
    exit 1
}

for DATEI in \
    "$QUELLE/serial-id.sh" \
    "$QUELLE/format-disk-id.sh" \
    "$QUELLE/serial-id-udev.sh" \
    "$REGEL_QUELLE"; do
    [ -f "$DATEI" ] || {
        echo "FEHLER: Datei fehlt: $DATEI"
        exit 1
    }
done

bash -n "$QUELLE/serial-id.sh"
bash -n "$QUELLE/format-disk-id.sh"
bash -n "$QUELLE/serial-id-udev.sh"

if [ -e "$REGEL_ZIEL" ]; then
    if cmp -s "$REGEL_QUELLE" "$REGEL_ZIEL"; then
        echo "Udev-Regel ist bereits installiert."
    else
        echo "FEHLER: Am Ziel liegt eine abweichende Regel."
        echo "Keine vorhandene Regel wird ueberschrieben."
        exit 1
    fi
else
    install -m 0644 "$REGEL_QUELLE" "$REGEL_ZIEL"
    echo "Zusaetzliche udev-Regel installiert."
fi

udevadm control --reload
echo "Udev-Regeln neu geladen."
echo "Keine bestehenden Geraete erneut ausgeloest."
echo "Keine ID_SERIAL- oder Array-Zuordnungen geaendert."
