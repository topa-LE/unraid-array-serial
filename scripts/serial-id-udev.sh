#!/bin/bash
# Zusaetzliche udev-Eigenschaften ohne Aenderung der Unraid-ID_SERIAL.
set -euo pipefail

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUSGABE="$(bash "$VERZEICHNIS/serial-id.sh" "${1:-}")" || exit 1

SERIENNUMMER=""
KENNUNG=""

while IFS='=' read -r SCHLUESSEL WERT; do
    case "$SCHLUESSEL" in
        ID_SERIAL_SHORT) SERIENNUMMER="$WERT" ;;
        ID_SERIAL) KENNUNG="$WERT" ;;
    esac
done <<< "$AUSGABE"

[ -n "$SERIENNUMMER" ] && [ -n "$KENNUNG" ] || exit 1

printf 'TOPA_ARRAY_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'TOPA_ARRAY_SERIAL=%s\n' "$KENNUNG"
