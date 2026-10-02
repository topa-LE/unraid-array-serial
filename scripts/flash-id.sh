#!/bin/bash

# topa-LE Unraid Array Serial
#
# Erzeugt ausschliesslich fuer das physische Unraid-Boot-Laufwerk
# eine saubere, stabile Udev-Identitaet.
#
# WICHTIG:
# - keine Schreibzugriffe auf den Datentraeger
# - keine Aenderung von FAT-Label, UUID oder PARTUUID
# - keine Aenderung der USB-Hardware-Seriennummer
# - keine Aenderung von Unraid-Lizenzdaten
#
# Die Hardware-Seriennummer stammt ausschliesslich aus den bereits
# von Udev gelieferten USB-Eigenschaften.

set -euo pipefail

DISK="${1:-}"

if [[ ! "$DISK" =~ ^/dev/sd[a-z]+$ ]] || [ ! -b "$DISK" ]; then
    exit 1
fi

BOOT_QUELLE="$(findmnt -n -o SOURCE --target /boot 2>/dev/null)" || exit 1
BOOT_GERAET="$(lsblk -r -n -s -o NAME "$BOOT_QUELLE" 2>/dev/null | tail -n 1)" || exit 1

[ -n "$BOOT_GERAET" ] || exit 1
[ "$DISK" = "/dev/$BOOT_GERAET" ] || exit 1

UDEV="$(
    udevadm info --query=property --name="$DISK" 2>/dev/null
)" || exit 1

SERIENNUMMER="$(
    printf '%s\n' "$UDEV" |
        sed -n 's/^ID_SERIAL_SHORT=//p' |
        head -n 1
)"

VENDOR_ID="$(
    printf '%s\n' "$UDEV" |
        sed -n 's/^ID_VENDOR_ID=//p' |
        head -n 1
)"

PRODUCT_ID="$(
    printf '%s\n' "$UDEV" |
        sed -n 's/^ID_MODEL_ID=//p' |
        head -n 1
)"

MODEL="$(
    printf '%s\n' "$UDEV" |
        sed -n 's/^ID_MODEL=//p' |
        head -n 1
)"

[ -n "$SERIENNUMMER" ] || exit 1
[ -n "$VENDOR_ID" ] || exit 1
[ -n "$PRODUCT_ID" ] || exit 1
[ -n "$MODEL" ] || exit 1

[[ "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]] || exit 1
[[ "$VENDOR_ID" =~ ^[A-Fa-f0-9]{4}$ ]] || exit 1
[[ "$PRODUCT_ID" =~ ^[A-Fa-f0-9]{4}$ ]] || exit 1
[[ ! "$SERIENNUMMER" =~ ^0+$ ]] || exit 1

TRANSPORT="$(
    bash "$(dirname -- "${BASH_SOURCE[0]}")/detect-transport.sh" "$DISK"
)" || exit 1

case "$TRANSPORT" in
    USB1|USB2|USB3|USB)
        ;;
    *)
        exit 1
        ;;
esac

#
# Hersteller fuer die menschenlesbare Kennung bestimmen.
#
# Viele USB-Sticks liefern keinen brauchbaren iManufacturer-String.
# lsusb kann fuer die konkrete VID:PID-Kombination dennoch eine
# menschenlesbare Geraetebezeichnung liefern.
#
#
# Fuer die kompakte Kennung verwenden wir den ersten Namensteil.
# Falls keine brauchbare Aufloesung vorhanden ist, bleibt "USB".
#

HERSTELLER="USB"

if command -v lsusb >/dev/null 2>&1; then
    LSUSB_ZEILE="$(
        lsusb -d "${VENDOR_ID}:${PRODUCT_ID}" 2>/dev/null |
            head -n 1
    )"

    if [ -n "$LSUSB_ZEILE" ]; then
        USB_BESCHREIBUNG="${LSUSB_ZEILE#* ID ${VENDOR_ID}:${PRODUCT_ID} }"

        if [ "$USB_BESCHREIBUNG" != "$LSUSB_ZEILE" ]; then
            KANDIDAT="${USB_BESCHREIBUNG%% *}"

            if [[ "$KANDIDAT" =~ ^[A-Za-z0-9.-]+$ ]] &&
               [ "$KANDIDAT" != "Linux" ]; then
                HERSTELLER="$KANDIDAT"
            fi
        fi
    fi
fi

MODELL_SAUBER="$(
    printf '%s' "$MODEL" |
        sed \
            -e 's/[^A-Za-z0-9.-]/-/g' \
            -e 's/--*/-/g' \
            -e 's/^-//' \
            -e 's/-$//'
)"

[ -n "$MODELL_SAUBER" ] || MODELL_SAUBER="Flash"

KENNUNG="${HERSTELLER}-${MODELL_SAUBER}-${SERIENNUMMER}"

printf 'IDENTITY_SOURCE=FLASH\n'
printf 'ID_BUS=usb\n'
printf 'ID_MODEL=%s\n' "$MODELL_SAUBER"
printf 'ID_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'ID_SERIAL=%s\n' "$KENNUNG"
