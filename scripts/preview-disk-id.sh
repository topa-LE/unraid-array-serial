#!/bin/bash

# Unraid Array Serial – umkehrbare Vorschau einer Laufwerkskennung.
# Verarbeitet ausschliesslich uebergebene Textwerte.
# Keine Laufwerksabfragen, keine udev-Aenderungen, keine Array-Aktionen.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Verwendung: $0 HERSTELLER MODELL SERIENNUMMER" >&2
    exit 1
fi

HERSTELLER="$1"
MODELL="$2"
SERIE="$3"

if [ -z "$HERSTELLER" ] || [ -z "$MODELL" ] || [ -z "$SERIE" ]; then
    echo "FEHLER: Hersteller, Modell und Seriennummer duerfen nicht leer sein." >&2
    exit 1
fi

# LC_ALL=C sorgt fuer eine byteweise, reproduzierbare Kodierung.
# Die Originalwerte werden nicht gekuerzt oder normalisiert.
export LC_ALL=C

hex_kodieren() {
    printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

HERSTELLER_HEX="$(hex_kodieren "$HERSTELLER")"
MODELL_HEX="$(hex_kodieren "$MODELL")"
SERIE_HEX="$(hex_kodieren "$SERIE")"

KENNUNG="H${HERSTELLER_HEX}-M${MODELL_HEX}-S${SERIE_HEX}"

echo "=== LAUFWERKSKENNUNG – VORSCHAU ==="
echo "Hersteller: $HERSTELLER"
echo "Modell: $MODELL"
echo "Hardware-Seriennummer: $SERIE"
echo
echo "Vorgeschlagene Kennung: $KENNUNG"
echo
echo "HINWEIS: Dies ist nur ein vorlaeufiges Vorschauformat."
echo "HINWEIS: Keine Laufwerkskennung wurde geaendert."
