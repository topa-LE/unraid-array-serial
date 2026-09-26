#!/bin/bash

# Persistenter Fallback fuer Laufwerke, deren Bridge keine
# verlaessliche Hardware-Seriennummer zur Bootzeit liefert.
#
# Der Cache enthaelt eine zuvor verifizierte echte Hardware-ID.
# sdX wird niemals als persistente Identitaet verwendet.
#
# Cache-Schluessel:
#   stabiler physischer ID_PATH der Bridge/LUN
#
# Sicherheitsmerkmale:
#   exakte Kapazitaet
#
# Bei fehlendem oder widerspruechlichem Eintrag:
#   keine Identitaet ausgeben.

set -euo pipefail

DISK="${1:-}"
CACHE="${2:-/boot/config/custom/array-serial/identity-cache.tsv}"

[[ "$DISK" =~ ^/dev/[a-zA-Z0-9]+$ ]] || exit 1
[ -b "$DISK" ] || exit 1
[ -r "$CACHE" ] || exit 1

PFAD="$(
    udevadm info --query=property --name="$DISK" 2>/dev/null |
        sed -n 's/^ID_PATH=//p' |
        head -n 1
)"

[ -n "$PFAD" ] || exit 1

GROESSE="$(blockdev --getsize64 "$DISK" 2>/dev/null)"
[[ "$GROESSE" =~ ^[0-9]+$ ]] || exit 1

TREFFER="$(
    awk -F '\t' \
        -v pfad="$PFAD" \
        -v groesse="$GROESSE" \
        '
        $1 == pfad && $2 == groesse {
            print
        }
        ' \
        "$CACHE"
)"

ANZAHL="$(
    printf '%s\n' "$TREFFER" |
        sed '/^$/d' |
        wc -l
)"

[ "$ANZAHL" -eq 1 ] || exit 1

ID_SERIAL_SHORT="$(
    printf '%s\n' "$TREFFER" |
        cut -f3
)"

ID_SERIAL="$(
    printf '%s\n' "$TREFFER" |
        cut -f4
)"

[[ "$ID_SERIAL_SHORT" =~ ^[A-Za-z0-9-]+$ ]] || exit 1
[[ "$ID_SERIAL" =~ ^[A-Za-z0-9._-]+$ ]] || exit 1

# Der Cache wird nur fuer zuvor verifizierte ATA/SATA-Laufwerke
# hinter einer Bridge verwendet. Neben der stabilen Kennung muessen
# deshalb auch die fuer die nachfolgenden Udev-Regeln notwendigen
# Basiseigenschaften konsistent gesetzt werden.
#
# Kein WWN wird erfunden.

MODELL="${ID_SERIAL%-${ID_SERIAL_SHORT}-USB*}"
MODELL="${MODELL//-/_}"

[ -n "$MODELL" ] || exit 1

printf 'ID_ATA=1\n'
printf 'ID_BUS=ata\n'
printf 'ID_TYPE=disk\n'
printf 'ID_MODEL=%s\n' "$MODELL"
printf 'ID_SERIAL_SHORT=%s\n' "$ID_SERIAL_SHORT"
printf 'ID_SERIAL=%s\n' "$ID_SERIAL"
