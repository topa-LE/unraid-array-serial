#!/bin/bash
# topa-LE Unraid Array Serial
# Installiert die Kennungsregel und erkennt geeignete Laufwerke gezielt neu.
# Aendert keine Array-Zuordnungen.
set -euo pipefail

QUELLE="/boot/config/custom/array-serial"
REGEL_QUELLE="$QUELLE/59-array-serial.rules"
REGEL_ZIEL="/etc/udev/rules.d/59-array-serial.rules"

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

for DATEI in \
    "$QUELLE/serial-id.sh" \
    "$QUELLE/format-disk-id.sh" \
    "$QUELLE/detect-transport.sh" \
    "$REGEL_QUELLE"
do
    if [ ! -f "$DATEI" ]; then
        echo "STOP: Datei fehlt: $DATEI"
        exit 1
    fi
done

bash -n "$QUELLE/serial-id.sh"
bash -n "$QUELLE/format-disk-id.sh"
bash -n "$QUELLE/detect-transport.sh"

if [ -e "$REGEL_ZIEL" ]; then
    if ! cmp -s "$REGEL_QUELLE" "$REGEL_ZIEL"; then
        echo "STOP: Am Installationsziel liegt eine andere Regel."
        exit 1
    fi
    echo "Kennungsregel ist bereits installiert."
else
    install -m 0644 "$REGEL_QUELLE" "$REGEL_ZIEL"
    echo "Kennungsregel installiert."
fi

udevadm control --reload

echo "Udev-Regeln neu geladen."

# Das physische Laufwerk ermitteln, auf dem /boot eingehangen ist.
# Wenn das nicht eindeutig gelingt, keine Neuerkennung ausfuehren.
BOOT_QUELLE="$(findmnt -n -o SOURCE --target /boot)" || {
    echo "STOP: Boot-Quelle nicht ermittelbar."
    exit 1
}

BOOT_GERAET="$(lsblk -r -n -s -o NAME "$BOOT_QUELLE" | tail -n 1)" || {
    echo "STOP: Boot-Laufwerk nicht ermittelbar."
    exit 1
}

if [ -z "$BOOT_GERAET" ]; then
    echo "STOP: Boot-Laufwerk ist leer."
    exit 1
fi

echo "USB-Boot-Laufwerk wird ausgenommen: /dev/$BOOT_GERAET"

# Nur Laufwerke erneut erkennen, fuer die das Kennungsskript
# erfolgreich eine neue ID_SERIAL ermittelt. Das Boot-Laufwerk
# bleibt unabhaengig von seiner SMART-Erkennung unangetastet.
for SYSDEV in /sys/class/block/sd*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"
    [[ "$NAME" =~ ^sd[a-z]+$ ]] || continue

    if [ "$NAME" = "$BOOT_GERAET" ]; then
        continue
    fi

    if ! KENNUNG="$(bash "$QUELLE/serial-id.sh" "/dev/$NAME" 2>/dev/null)"; then
        continue
    fi

    if ! grep -q "^ID_SERIAL=" <<< "$KENNUNG"; then
        continue
    fi

    echo "Kennung fuer /dev/$NAME wird eingelesen."
    udevadm trigger --action=add \
        --sysname-match="$NAME" \
        --subsystem-match=block
done

udevadm settle
echo "Gezielte Neuerkennung abgeschlossen."
