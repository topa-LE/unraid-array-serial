#!/bin/bash
# topa-LE Unraid Array Serial
# Installiert die Kennungsregel und erkennt vorhandene Laufwerke neu.
# Aendert keine Array-Zuordnungen.
set -euo pipefail

QUELLE="/boot/config/custom/array-serial"
REGEL_QUELLE="$QUELLE/59-topa-array-serial.rules"
REGEL_ZIEL="/etc/udev/rules.d/59-topa-array-serial.rules"

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

for DATEI in \
    "$QUELLE/serial-id.sh" \
    "$QUELLE/format-disk-id.sh" \
    "$REGEL_QUELLE"
do
    if [ ! -f "$DATEI" ]; then
        echo "STOP: Datei fehlt: $DATEI"
        exit 1
    fi
done

bash -n "$QUELLE/serial-id.sh"
bash -n "$QUELLE/format-disk-id.sh"

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
echo "Array-Zuordnungen nicht geaendert."

# Nach dem Laden der Regel die vorhandenen ganzen SATA-/USB-SCSI-
# Laufwerke erneut erkennen. Partitionen bleiben ausgeschlossen.
for SYSDEV in /sys/class/block/sd*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"
    [[ "$NAME" =~ ^sd[a-z]+$ ]] || continue

    if ! udevadm trigger --action=add \
        --sysname-match="$NAME" \
        --subsystem-match=block; then
        echo "STOP: Neuerkennung fuer /dev/$NAME fehlgeschlagen."
        exit 1
    fi
done

udevadm settle
echo "Geraetekennungen neu eingelesen."
