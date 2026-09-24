#!/bin/bash
set -euo pipefail

MODELL="${1:-}"
SERIENNUMMER="${2:-}"

# Nur klar begrenzte ASCII-Zeichen zulassen.
[[ "$MODELL" =~ ^[A-Za-z0-9._\ -]+$ ]] || exit 1
[[ "$SERIENNUMMER" =~ ^[A-Za-z0-9-]+$ ]] || exit 1
[[ ! "$SERIENNUMMER" =~ ^0+$ ]] || exit 1

# Unraids bisheriges WDC-Praefix vereinheitlichen.
if [[ "$MODELL" == "WDC WD"* ]]; then
    MODELL="${MODELL#WDC }"
fi

# Leerzeichen und Unterstriche durch Bindestriche ersetzen.
# Vorhandene Bindestriche und die echte Seriennummer bleiben erhalten.
MODELL="${MODELL// /-}"
MODELL="${MODELL//_/-}"

# Die beiden Bestandteile durch genau einen zusaetzlichen Bindestrich trennen.
printf '%s-%s\n' "$MODELL" "$SERIENNUMMER"
