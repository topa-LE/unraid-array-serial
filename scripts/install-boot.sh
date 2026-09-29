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
REGEL_59_QUELLE="$QUELLE/59-array-serial.rules"
REGEL_59_ZIEL="/etc/udev/rules.d/59-array-serial.rules"
REGEL_61_QUELLE="$QUELLE/61-array-serial-nvme.rules"
REGEL_61_ZIEL="/etc/udev/rules.d/61-array-serial-nvme.rules"
REGEL_62_QUELLE="$QUELLE/62-array-serial-partitions.rules"
REGEL_62_ZIEL="/etc/udev/rules.d/62-array-serial-partitions.rules"
GENERATOR="$QUELLE/serial-id.sh"
PARTITION_GENERATOR="$QUELLE/partition-id.sh"
TIMEOUT=20

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

for DATEI in \
    "$GENERATOR" \
    "$PARTITION_GENERATOR" \
    "$QUELLE/resolve-cached-id.sh" \
    "$QUELLE/format-disk-id.sh" \
    "$QUELLE/detect-transport.sh" \
    "$REGEL_59_QUELLE" \
    "$REGEL_61_QUELLE" \
    "$REGEL_62_QUELLE"
do
    if [ ! -f "$DATEI" ]; then
        echo "STOP: Datei fehlt: $DATEI"
        exit 1
    fi
done

bash -n "$GENERATOR"
bash -n "$PARTITION_GENERATOR"
bash -n "$QUELLE/resolve-cached-id.sh"
bash -n "$QUELLE/format-disk-id.sh"
bash -n "$QUELLE/detect-transport.sh"

if ! command -v udevadm >/dev/null 2>&1; then
    echo "STOP: udevadm fehlt."
    exit 1
fi

# Neuere udev-Versionen koennen Regeldateien mit "udevadm verify"
# vorab pruefen. Unraid-Versionen ohne dieses Unterkommando duerfen
# deshalb nicht scheitern; die Regel wurde bereits im Repository
# statisch validiert.
if udevadm help 2>&1 | grep -qE '(^|[[:space:]])verify([[:space:]]|$)'; then
    for REGEL in "$REGEL_59_QUELLE" "$REGEL_61_QUELLE" "$REGEL_62_QUELLE"; do
        if ! udevadm verify "$REGEL" >/dev/null 2>&1; then
            echo "STOP: Udev-Regelpruefung fehlgeschlagen: $REGEL"
            exit 1
        fi
    done
    echo "Udev-Regelpruefung: OK."
else
    echo "Udev-Regelpruefung: verify nicht verfuegbar – wird uebersprungen."
fi

for PAAR in \
    "$REGEL_59_QUELLE|$REGEL_59_ZIEL" \
    "$REGEL_61_QUELLE|$REGEL_61_ZIEL" \
    "$REGEL_62_QUELLE|$REGEL_62_ZIEL"
do
    QUELLDATEI="${PAAR%%|*}"
    ZIELDATEI="${PAAR#*|}"

    if [ -e "$ZIELDATEI" ] && cmp -s "$QUELLDATEI" "$ZIELDATEI"; then
        echo "Kennungsregel bereits aktuell: $ZIELDATEI"
    else
        install -m 0644 "$QUELLDATEI" "$ZIELDATEI"
        echo "Kennungsregel installiert/aktualisiert: $ZIELDATEI"
    fi
done

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

    ID_SERIAL_SHORT_ERWARTET="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    IDENTITY_SOURCE="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
    )"

    [ -n "$ID_SERIAL_SHORT_ERWARTET" ] || {
        echo "AUSGELASSEN: /dev/$NAME liefert keine Hardware-Seriennummer."
        continue
    }

    case "$IDENTITY_SOURCE" in
        ATA|NVME|USB_SAT|CACHE)
            ;;
        *)
            echo "AUSGELASSEN: /dev/$NAME liefert keine gueltige Identitaetsquelle."
            continue
            ;;
    esac

    echo "GEEIGNET: /dev/$NAME -> $ID_SERIAL"
    echo "ID-Quelle: $IDENTITY_SOURCE"
    echo "INITIALISIERE: /dev/$NAME"

    if timeout "$TIMEOUT" \
        udevadm trigger \
            --action=add \
            --sysname-match="$NAME" \
            --subsystem-match=block
    then
        :
    else
        echo "STOP: Udev-Trigger fuer /dev/$NAME fehlgeschlagen."
        exit 1
    fi

    UDEV_ID=""
    UDEV_SHORT=""

    for VERSUCH in 1 2 3 4 5; do
        UDEV_AUSGABE="$(
            udevadm info --query=property --name="/dev/$NAME" 2>/dev/null || true
        )"

        UDEV_ID="$(
            printf '%s\n' "$UDEV_AUSGABE" |
                sed -n 's/^ID_SERIAL=//p' |
                head -n 1
        )"

        UDEV_SHORT="$(
            printf '%s\n' "$UDEV_AUSGABE" |
                sed -n 's/^ID_SERIAL_SHORT=//p' |
                head -n 1
        )"

        if [ "$UDEV_ID" = "$ID_SERIAL" ] &&
           [ "$UDEV_SHORT" = "$ID_SERIAL_SHORT_ERWARTET" ]; then
            break
        fi

        sleep 1
    done

    if [ "$UDEV_ID" != "$ID_SERIAL" ] ||
       [ "$UDEV_SHORT" != "$ID_SERIAL_SHORT_ERWARTET" ]; then
        echo "STOP: Udev-Neuerkennung fuer /dev/$NAME wurde nicht sauber uebernommen."
        echo "Erwartete ID:        $ID_SERIAL"
        echo "Aktuelle ID:         ${UDEV_ID:-<leer>}"
        echo "Erwartete HW-Serial: $ID_SERIAL_SHORT_ERWARTET"
        echo "Aktuelle HW-Serial:  ${UDEV_SHORT:-<leer>}"
        exit 1
    fi

    GETRIGGERT=$((GETRIGGERT + 1))
    echo "OK: /dev/$NAME wurde gezielt neu erkannt."
done

echo
echo "Gefundene geeignete Blockgeraete: $ANZAHL"
echo "Mit sicherer eigener Kennung:       $GEEIGNET"
echo "Neu initialisiert:                  $GETRIGGERT"
echo "Gezielte Neuerkennung abgeschlossen."
