#!/bin/bash
# topa-LE Unraid Array Serial
# Installiert die Kennungsregel und initialisiert geeignete Laufwerke
# vor dem Start von Unraid/emhttp.
#
# Unterstuetzt dynamisch:
# - beliebig viele vollständige sdX-Laufwerke
# - beliebig viele NVMe-Namespace-Laufwerke
#
# Das physische Boot-Laufwerk wird immer ausgeschlossen.
# Array-Zuordnungen werden nicht veraendert.

set -euo pipefail

QUELLE="/boot/config/custom/array-serial"
REGEL_QUELLE="$QUELLE/59-array-serial.rules"
REGEL_ZIEL="/etc/udev/rules.d/59-array-serial.rules"
GENERATOR="$QUELLE/serial-id.sh"
TIMEOUT=20

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

for DATEI in \
    "$GENERATOR" \
    "$QUELLE/format-disk-id.sh" \
    "$QUELLE/detect-transport.sh" \
    "$REGEL_QUELLE"
do
    if [ ! -f "$DATEI" ]; then
        echo "STOP: Datei fehlt: $DATEI"
        exit 1
    fi
done

bash -n "$GENERATOR"
bash -n "$QUELLE/format-disk-id.sh"
bash -n "$QUELLE/detect-transport.sh"

if command -v udevadm >/dev/null 2>&1; then
    udevadm verify "$REGEL_QUELLE" >/dev/null
else
    echo "STOP: udevadm fehlt."
    exit 1
fi

if [ -e "$REGEL_ZIEL" ] && cmp -s "$REGEL_QUELLE" "$REGEL_ZIEL"; then
    echo "Kennungsregel ist bereits aktuell."
else
    install -m 0644 "$REGEL_QUELLE" "$REGEL_ZIEL"
    echo "Kennungsregel installiert/aktualisiert."
fi

udevadm control --reload
echo "Udev-Regeln neu geladen."

# Physisches Laufwerk bestimmen, auf dem /boot liegt.
# Bei nicht eindeutiger Erkennung wird aus Sicherheitsgruenden
# keine Laufwerks-Neuerkennung gestartet.
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

echo "Boot-Laufwerk wird ausgenommen: /dev/$BOOT_GERAET"

ANZAHL=0
GEEIGNET=0
GETRIGGERT=0

# Keine feste Geraeteliste und keine feste Laufwerksanzahl.
# Es werden alle aktuell vorhandenen Blockgeraete betrachtet.
for SYSDEV in /sys/class/block/*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"

    if [[ "$NAME" =~ ^sd[a-z]+$ ]]; then
        :
    elif [[ "$NAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        :
    else
        continue
    fi

    # Partitionen und sonstige DEVTYPEs sicher ausschliessen.
    DEVTYPE="$(udevadm info --query=property --path="$SYSDEV" 2>/dev/null |
        sed -n 's/^DEVTYPE=//p' |
        head -n 1)"

    [ "$DEVTYPE" = "disk" ] || continue

    ANZAHL=$((ANZAHL + 1))

    if [ "$NAME" = "$BOOT_GERAET" ]; then
        echo "AUSGELASSEN: /dev/$NAME ist das Boot-Laufwerk."
        continue
    fi

    echo "PRUEFE: /dev/$NAME"

    if ! KENNUNG="$(
        timeout "$TIMEOUT" \
            bash "$GENERATOR" "/dev/$NAME" \
            2>/dev/null
    )"; then
        echo "AUSGELASSEN: /dev/$NAME liefert keine sichere eigene Kennung."
        continue
    fi

    if ! grep -q '^ID_SERIAL=' <<< "$KENNUNG"; then
        echo "AUSGELASSEN: /dev/$NAME liefert keine ID_SERIAL."
        continue
    fi

    GEEIGNET=$((GEEIGNET + 1))

    ID_SERIAL="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    echo "GEEIGNET: /dev/$NAME -> $ID_SERIAL"
    echo "INITIALISIERE: /dev/$NAME"

    if timeout "$TIMEOUT" \
        udevadm trigger \
            --action=add \
            --sysname-match="$NAME" \
            --subsystem-match=block
    then
        GETRIGGERT=$((GETRIGGERT + 1))
    else
        echo "STOP: Udev-Trigger fuer /dev/$NAME fehlgeschlagen."
        exit 1
    fi
done

echo "Warte auf Abschluss der Udev-Verarbeitung."

if ! timeout "$TIMEOUT" udevadm settle; then
    echo "STOP: udevadm settle hat das Zeitlimit von ${TIMEOUT}s ueberschritten."
    exit 1
fi

echo
echo "Gefundene geeignete Blockgeraete: $ANZAHL"
echo "Mit sicherer eigener Kennung:       $GEEIGNET"
echo "Neu initialisiert:                  $GETRIGGERT"
echo "Gezielte Neuerkennung abgeschlossen."
