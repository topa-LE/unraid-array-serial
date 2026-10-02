#!/bin/bash
set -euo pipefail

DISK="${1:-}"

if [[ ! "$DISK" =~ ^/dev/(sd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$ ]] ||
   [ ! -b "$DISK" ]; then
    exit 1
fi

NAME="${DISK##*/}"
SYSDEV="/sys/class/block/$NAME"
PFAD=""
USB_SPEED=""
UDEV_BUS=""

[ -e "$SYSDEV" ] || exit 1

PFAD="$(readlink -f "$SYSDEV/device" 2>/dev/null || true)"

# Vom Blockgeraet nach oben laufen.
# Der erste USB-Geraeteknoten mit idVendor/idProduct ist der
# geraetenaechste USB-Knoten. Nur dessen ausgehandelte Geschwindigkeit
# wird fuer den sichtbaren Transporthinweis verwendet.
while [ -n "$PFAD" ] && [ "$PFAD" != "/" ]; do
    if [ -r "$PFAD/idVendor" ] && [ -r "$PFAD/idProduct" ]; then
        USB_SPEED="$(cat "$PFAD/speed" 2>/dev/null || true)"

        case "$USB_SPEED" in
            5000|10000|20000|40000|80000)
                printf '%s\n' "USB3"
                ;;
            480)
                printf '%s\n' "USB2"
                ;;
            1.5|12)
                printf '%s\n' "USB1"
                ;;
            *)
                if [[ "$USB_SPEED" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
                   awk -v s="$USB_SPEED" 'BEGIN { exit !(s >= 5000) }'
                then
                    printf '%s\n' "USB3"
                else
                    printf '%s\n' "USB"
                fi
                ;;
        esac

        exit 0
    fi

    PFAD="${PFAD%/*}"
    [ -n "$PFAD" ] || PFAD="/"
done

if [[ "$NAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
    printf '%s\n' "NVME"
    exit 0
fi

UDEV_BUS="$(
    udevadm info --query=property --name="$DISK" 2>/dev/null |
        sed -n 's/^ID_BUS=//p' |
        head -n 1
)"

case "$UDEV_BUS" in
    ata)
        printf '%s\n' "SATA"
        ;;
    nvme)
        printf '%s\n' "NVME"
        ;;
    *)
        printf '%s\n' "UNBEKANNT"
        ;;
esac
