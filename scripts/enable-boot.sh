#!/bin/bash
# topa-LE Unraid Array Serial
# Richtet den persistenten Boot-Start des Projekts ein.
#
# Ein einziger Aufruf sorgt dafuer, dass bei jedem Unraid-Boot:
# - install-boot.sh die aktuellen Udev-Regeln installiert,
# - vorhandene Laufwerke initialisiert werden,
# - Boot-/Kernel-Logging persistent gestartet wird.
#
# Alte Projekt-Hooks werden entfernt.
# Mehrfacher Aufruf ist idempotent.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
GO="/boot/config/go"

INSTALL_AUFRUF="/bin/bash $BASE/install-boot.sh"
BOOT_LOG_AUFRUF="/bin/bash $BASE/boot-log.sh &"
BOOT_CAPTURE_AUFRUF="/bin/bash $BASE/boot-capture.sh &"

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

if [ ! -f "$GO" ]; then
    echo "STOP: $GO fehlt."
    exit 1
fi

for DATEI in \
    "$BASE/install-boot.sh" \
    "$BASE/boot-log.sh" \
    "$BASE/boot-capture.sh"
do
    if [ ! -r "$DATEI" ]; then
        echo "STOP: Erforderliche Datei fehlt: $DATEI"
        exit 1
    fi

    bash -n "$DATEI" || {
        echo "STOP: Syntaxfehler: $DATEI"
        exit 1
    }
done

BACKUP="${GO}.array-serial-$(date +%Y%m%d-%H%M%S).bak"
cp -p "$GO" "$BACKUP" || {
    echo "STOP: Backup von $GO fehlgeschlagen."
    exit 1
}

TMP="${GO}.array-serial.$$"

awk '
    # Alte und aktuelle Array-Serial-Bloecke vollständig entfernen.
    # Auch mehrzeilige Fehlerbloecke mit "{ ... }" werden entfernt.
    /\/boot\/config\/custom\/array-serial\/install-udev-rule\.sh/ {
        if ($0 ~ /\{[[:space:]]*$/) skip_block=1
        next
    }

    /\/boot\/config\/custom\/array-serial\/install-boot\.sh/ {
        if ($0 ~ /\{[[:space:]]*$/) skip_block=1
        next
    }

    skip_block {
        if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) skip_block=0
        next
    }

    # Reste einer früher bereits unvollständig entfernten Fehlerbehandlung.
    /^[[:space:]]*echo "array-serial: install-boot\.sh fehlgeschlagen\." >&2[[:space:]]*$/ {
        orphan_block=1
        next
    }

    orphan_block && /^[[:space:]]*\}[[:space:]]*$/ {
        orphan_block=0
        next
    }

    /\/boot\/config\/custom\/array-serial\/boot-log\.sh/       { next }
    /\/boot\/config\/custom\/array-serial\/boot-capture\.sh/   { next }

    /^# array-serial: persistentes Boot-\/Kernel-Logging$/      { next }
    /^# array-serial: persistenter Projektstart$/              { next }

    { print }
' "$GO" > "$TMP" || {
    rm -f "$TMP"
    echo "STOP: Bereinigung von $GO fehlgeschlagen."
    exit 1
}

cat >> "$TMP" <<EOF2

# array-serial: persistenter Projektstart
$INSTALL_AUFRUF || {
    echo "array-serial: install-boot.sh fehlgeschlagen." >&2
}

$BOOT_LOG_AUFRUF
$BOOT_CAPTURE_AUFRUF
EOF2

mv -f "$TMP" "$GO"
sync

echo "===== PERSISTENTER BOOT-HOOK ====="

grep -nE \
    'array-serial|install-udev-rule|install-boot|boot-log|boot-capture' \
    "$GO"

echo
echo "===== VALIDIERUNG ====="

INSTALL_COUNT="$(grep -Fc "$INSTALL_AUFRUF" "$GO" || true)"
LOGGER_COUNT="$(grep -Fc "$BOOT_LOG_AUFRUF" "$GO" || true)"
CAPTURE_COUNT="$(grep -Fc "$BOOT_CAPTURE_AUFRUF" "$GO" || true)"
LEGACY_COUNT="$(grep -Fc "$BASE/install-udev-rule.sh" "$GO" || true)"

if [ "$INSTALL_COUNT" -ne 1 ] ||
   [ "$LOGGER_COUNT" -ne 1 ] ||
   [ "$CAPTURE_COUNT" -ne 1 ] ||
   [ "$LEGACY_COUNT" -ne 0 ]; then
    echo "STOP: Boot-Hook ist nicht eindeutig."
    cp -p "$BACKUP" "$GO"
    sync
    exit 1
fi

echo "OK: install-boot.sh genau einmal."
echo "OK: boot-log.sh genau einmal."
echo "OK: boot-capture.sh genau einmal."
echo "OK: Legacy install-udev-rule.sh entfernt."
echo "Backup: $BACKUP"
echo "ERGEBNIS: ARRAY_SERIAL_BOOT_ENABLE_OK"
