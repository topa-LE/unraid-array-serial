#!/bin/bash
set -euo pipefail

GO="/boot/config/go"
AUFRUF="/bin/bash /boot/config/custom/array-serial/install-boot.sh"

[ "$(id -u)" -eq 0 ] || {
    echo "STOP: Root-Rechte erforderlich."
    exit 1
}

[ -f "$GO" ] || {
    echo "STOP: /boot/config/go fehlt."
    exit 1
}

[ -f /boot/config/custom/array-serial/install-boot.sh ] || {
    echo "STOP: Installationsskript fehlt."
    exit 1
}

if grep -Fxq "$AUFRUF" "$GO"; then
    echo "Boot-Aufruf bereits vorhanden."
    exit 0
fi

cp -p "$GO" "$GO.array-serial.bak"

DATEI="$(mktemp)"

awk -v aufruf="$AUFRUF" '
    !eingefuegt && $0 ~ /^\/usr\/local\/sbin\/emhttp([[:space:]]|$)/ {
        print aufruf
        eingefuegt=1
    }
    { print }
    END {
        if (!eingefuegt) exit 1
    }
' "$GO" > "$DATEI" || {
    rm -f "$DATEI"
    echo "STOP: emhttp-Startzeile nicht gefunden."
    exit 1
}

cat "$DATEI" > "$GO"
rm -f "$DATEI"

echo "Boot-Aufruf vor emhttp eingetragen."
echo "Original gesichert unter: $GO.array-serial.bak"
