#!/bin/bash

# topa-LE Unraid Array Serial
#
# Ermittelt die echte Hardware-Identitaet eines Laufwerks.
#
# Hardware-Identitaet:
#   SMART-Modell + echte SMART-Seriennummer
#
# Sichtbare Kennung:
#   Hardware-ID
#   plus Transporthinweis bei physischem USB
#
# Beispiele:
#   WDC-WD40EFRX-68N32N0-WD-WCC7K5ZJKT08
#   WDC-WD40EFRX-68N32N0-WD-WCC7K5ZJKT08-USB3
#
# ID_SERIAL_SHORT bleibt immer die echte Hardware-Seriennummer.

set -euo pipefail

DISK="${1:-}"

if [[ ! "$DISK" =~ ^/dev/(sd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+)$ ]] ||
   [ ! -b "$DISK" ]; then
    exit 1
fi

for PROGRAMM in smartctl jq; do
    command -v "$PROGRAMM" >/dev/null 2>&1 || exit 1
done

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FORMATIERER="$VERZEICHNIS/format-disk-id.sh"
TRANSPORT_ERKENNUNG="$VERZEICHNIS/detect-transport.sh"

[ -r "$FORMATIERER" ] || exit 1
[ -r "$TRANSPORT_ERKENNUNG" ] || exit 1

TRANSPORT="$(bash "$TRANSPORT_ERKENNUNG" "$DISK")" || exit 1

JSON=""

case "$TRANSPORT" in
    USB1|USB2|USB3|USB)
        # Bei USB-SATA nur die echte Laufwerksidentitaet hinter der Bridge
        # akzeptieren. Wenn SAT keine eindeutige Identitaet liefert,
        # wird keine Adapter-/Bridge-Kennung als Ersatz erfunden.
        JSON="$(smartctl -i -d sat -j "$DISK" 2>/dev/null)" || exit 1
        ;;
    *)
        JSON="$(smartctl -i -j "$DISK" 2>/dev/null)" || exit 1
        ;;
esac

SERIENNUMMER="$(
    printf '%s\n' "$JSON" |
        jq -r '.serial_number // empty' 2>/dev/null
)" || exit 1

MODELL="$(
    printf '%s\n' "$JSON" |
        jq -r '.model_name // empty' 2>/dev/null
)" || exit 1

if [[ ! "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]] ||
   [[ "$SERIENNUMMER" =~ ^0+$ ]]; then
    exit 1
fi

[ -n "$MODELL" ] || exit 1

if [[ ! "$MODELL" =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    exit 1
fi

HARDWARE_ID="$(
    bash "$FORMATIERER" "$MODELL" "$SERIENNUMMER"
)" || exit 1

case "$TRANSPORT" in
    USB1|USB2|USB3|USB)
        KENNUNG="${HARDWARE_ID}-${TRANSPORT}"
        ;;
    *)
        KENNUNG="$HARDWARE_ID"
        ;;
esac

printf 'ID_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'ID_SERIAL=%s\n' "$KENNUNG"
