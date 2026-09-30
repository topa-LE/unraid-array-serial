#!/bin/bash
#
# topa-LE Unraid Array Serial
#
# Separater Installer fuer die Identitaet des physischen
# Unraid-Boot-Laufwerks.
#
# Dieser Installer ist bewusst vom Array-/Pool-Installer getrennt.
# Er installiert nur die Flash-Udev-Regel und triggert anschliessend
# ausschliesslich das physische /boot-Laufwerk sowie dessen Partitionen.
#
# Es werden keine Partitionstabellen, Dateisysteme, UUIDs,
# Hardware-Seriennummern oder Unraid-Lizenzdaten veraendert.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RULE_SOURCE="$SCRIPT_DIR/64-array-serial-flash.rules"
RULE_TARGET="/etc/udev/rules.d/64-array-serial-flash.rules"
FLASH_ID="$SCRIPT_DIR/flash-id.sh"
DETECT_TRANSPORT="$SCRIPT_DIR/detect-transport.sh"

echo "===== ARRAY-SERIAL – FLASH-ID INSTALLATION ====="

for DATEI in \
    "$RULE_SOURCE" \
    "$FLASH_ID" \
    "$DETECT_TRANSPORT"
do
    [ -f "$DATEI" ] || {
        echo "FEHLER: Datei fehlt: $DATEI" >&2
        exit 1
    }
done

[ -f "$FLASH_ID" ] || {
    echo "FEHLER: flash-id.sh fehlt." >&2
    exit 1
}

[ -f "$DETECT_TRANSPORT" ] || {
    echo "FEHLER: detect-transport.sh fehlt." >&2
    exit 1
}

BOOT_SOURCE="$(findmnt -n -o SOURCE --target /boot 2>/dev/null)" || {
    echo "FEHLER: /boot-Quelle konnte nicht ermittelt werden." >&2
    exit 1
}

[ -b "$BOOT_SOURCE" ] || {
    echo "FEHLER: /boot-Quelle ist kein Blockgeraet: $BOOT_SOURCE" >&2
    exit 1
}

BOOT_GERAET="$(
    lsblk -r -n -s -o NAME "$BOOT_SOURCE" 2>/dev/null |
        tail -n 1
)"

[ -n "$BOOT_GERAET" ] || {
    echo "FEHLER: Physisches /boot-Laufwerk konnte nicht ermittelt werden." >&2
    exit 1
}

BOOT_DISK="/dev/$BOOT_GERAET"

[ -b "$BOOT_DISK" ] || {
    echo "FEHLER: Physisches /boot-Laufwerk existiert nicht: $BOOT_DISK" >&2
    exit 1
}

echo "Boot-Quelle:    $BOOT_SOURCE"
echo "Boot-Laufwerk: $BOOT_DISK"

echo
echo "===== FLASH-UDEV-REGEL INSTALLIEREN ====="

install -m 0644 "$RULE_SOURCE" "$RULE_TARGET"

udevadm control --reload-rules

echo "Installiert: $RULE_TARGET"

echo
echo "===== BOOT-LAUFWERK TRIGGERN ====="

udevadm trigger \
    --action=change \
    --subsystem-match=block \
    --sysname-match="$BOOT_GERAET"

udevadm settle

FLASH_SOURCE="$(
    udevadm info --query=property --name="$BOOT_DISK" 2>/dev/null |
        sed -n 's/^IDENTITY_SOURCE=//p' |
        head -n 1
)"

FLASH_SERIAL="$(
    udevadm info --query=property --name="$BOOT_DISK" 2>/dev/null |
        sed -n 's/^ID_SERIAL=//p' |
        head -n 1
)"

FLASH_SHORT="$(
    udevadm info --query=property --name="$BOOT_DISK" 2>/dev/null |
        sed -n 's/^ID_SERIAL_SHORT=//p' |
        head -n 1
)"

[ "$FLASH_SOURCE" = "FLASH" ] || {
    echo "FEHLER: Boot-Laufwerk wurde nicht als FLASH erkannt." >&2
    exit 1
}

[ -n "$FLASH_SERIAL" ] || {
    echo "FEHLER: Keine Flash-ID erzeugt." >&2
    exit 1
}

[ -n "$FLASH_SHORT" ] || {
    echo "FEHLER: Keine Hardware-Seriennummer vorhanden." >&2
    exit 1
}

echo "Flash-ID:       $FLASH_SERIAL"
echo "Hardware-ID:    $FLASH_SHORT"

echo
echo "===== BOOT-PARTITIONEN TRIGGERN ====="

PARTITIONEN=0

while IFS= read -r PARTITION; do
    [ -n "$PARTITION" ] || continue

    PARTITIONSNAME="${PARTITION#/dev/}"

    echo "Trigger: $PARTITION"

    udevadm trigger \
        --action=change \
        --subsystem-match=block \
        --sysname-match="$PARTITIONSNAME"

    PARTITIONEN=$((PARTITIONEN + 1))
done < <(
    lsblk -r -n -o NAME,TYPE "$BOOT_DISK" |
        awk '$2 == "part" { print "/dev/" $1 }'
)

udevadm settle

[ "$PARTITIONEN" -ge 1 ] || {
    echo "FEHLER: Keine Partition auf dem Boot-Laufwerk gefunden." >&2
    exit 1
}

echo "Getriggerte Partitionen: $PARTITIONEN"

echo
echo "===== ABSCHLUSSKONTROLLE ====="

udevadm info --query=property --name="$BOOT_DISK" |
    grep -E '^(IDENTITY_SOURCE|ID_BUS|ID_MODEL|ID_SERIAL|ID_SERIAL_SHORT|DEVLINKS)=' |
    sort

echo
echo "Flash-by-id-Links:"

find /dev/disk/by-id \
    -maxdepth 1 \
    -type l \
    \( -lname "../../$BOOT_GERAET" -o -lname "../../${BOOT_SOURCE#/dev/}" \) \
    -printf '%f -> %l\n' |
    sort || true

echo
echo "FLASH_ID_INSTALLATION_OK"
