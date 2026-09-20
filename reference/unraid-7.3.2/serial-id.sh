#!/bin/bash

# Universeller Helfer fuer USB-SATA-Laufwerke.
# Liest die echte ATA-Seriennummer ueber SAT/SMART.
# Keine fest hinterlegten Laufwerke oder Seriennummern.
# Keine Veraenderung von Array-Zuordnungen.

set -euo pipefail

DISK="${1:-}"

# Nur ganze SCSI/SATA-Blockgeraete akzeptieren.
# Partitionen und andere Eingaben werden abgewiesen.
if [[ ! "$DISK" =~ ^/dev/sd[a-z]+$ ]] || [ ! -b "$DISK" ]; then
    exit 1
fi

# Echte ATA-Identifikation ueber SAT abfragen.
# Bei nicht unterstuetzten Geraeten keine Kennung ausgeben.
JSON="$(smartctl -i -d sat -j "$DISK" 2>/dev/null)" || exit 1

SERIENNUMMER="$(
    printf '%s\n' "$JSON" |
        jq -r '.serial_number // empty' 2>/dev/null
)" || exit 1

# Nur eindeutig verwendbare Seriennummern akzeptieren.
if [[ ! "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]]; then
    exit 1
fi

# Offensichtliche Platzhalter nicht als echte Seriennummer verwenden.
if [[ "$SERIENNUMMER" =~ ^0+$ ]]; then
    exit 1
fi

# udev uebernimmt diese Werte bei erfolgreichem IMPORT.
printf 'ID_SERIAL_SHORT=%s\n' "$SERIENNUMMER"
printf 'ID_SERIAL=%s\n' "$SERIENNUMMER"
