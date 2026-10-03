#!/bin/bash
#
# topa-LE Unraid Array Serial
# Richtet den persistenten Boot-Start des Projekts ein.
#
# Ein einziger Aufruf sorgt dafuer, dass bei jedem Unraid-Boot:
# - install-boot.sh die aktuellen Udev-Regeln installiert,
# - vorhandene Laufwerke initialisiert werden,
# - Boot-/Kernel-Logging persistent gestartet wird,
# - eine vorbereitete MD-Migration nach dem Reboot fortgesetzt wird.
#
# Alte Projekt-Hooks und deren Kommentarzeilen werden entfernt.
# Mehrfacher Aufruf ist idempotent.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
GO="/boot/config/go"

INSTALL_AUFRUF="/bin/bash $BASE/install-boot.sh"
BOOT_LOG_AUFRUF="/bin/bash $BASE/boot-log.sh &"
BOOT_CAPTURE_AUFRUF="/bin/bash $BASE/boot-capture.sh &"
RESUME_AUFRUF="/bin/bash $BASE/md-migration-boot-resume.sh &"

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
    "$BASE/boot-capture.sh" \
    "$BASE/md-migration-boot-resume.sh"
do
    if [ ! -r "$DATEI" ]; then
        echo "STOP: Erforderliche Datei fehlt: $DATEI"
        exit 1
    fi

    /bin/bash -n "$DATEI" || {
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

while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do

    case "$ZEILE" in
        "# topa-LE Array Serial - START")
            IN_LEGACY_BLOCK=1
            continue
            ;;
    esac

    if [ "${IN_LEGACY_BLOCK:-0}" -eq 1 ]; then
        if [ "$ZEILE" = "# topa-LE Array Serial - END" ]; then
            IN_LEGACY_BLOCK=0
        fi
        continue
    fi

    if [ "${IN_INSTALL_BLOCK:-0}" -eq 1 ]; then
        if [ "$ZEILE" = "}" ]; then
            IN_INSTALL_BLOCK=0
        fi
        continue
    fi

    case "$ZEILE" in
        *"/boot/config/custom/array-serial/install-udev-rule.sh"*)
            case "$ZEILE" in
                *"{") IN_INSTALL_BLOCK=1 ;;
            esac
            continue
            ;;

        *"/boot/config/custom/array-serial/install-boot.sh"*)
            case "$ZEILE" in
                *"{") IN_INSTALL_BLOCK=1 ;;
            esac
            continue
            ;;

        *"/boot/config/custom/array-serial/md-migration-boot-resume.sh"*)
            continue
            ;;

        *"/boot/config/custom/array-serial/boot-log.sh"*)
            continue
            ;;

        *"/boot/config/custom/array-serial/boot-capture.sh"*)
            continue
            ;;

        '    echo "array-serial: install-boot.sh fehlgeschlagen." >&2')
            IN_INSTALL_BLOCK=1
            continue
            ;;

        "# array-serial: persistentes Boot-/Kernel-Logging")
            continue
            ;;

        "# array-serial: persistenter Projektstart")
            continue
            ;;

        "# array-serial: Boot-Diagnose so frueh wie moeglich starten")
            continue
            ;;

        "# array-serial: persistente Udev-Regeln vor Unraid/emhttp installieren")
            continue
            ;;

        "# array-serial: vorbereitete MD-Migration nach Reboot fortsetzen")
            continue
            ;;
    esac

    printf '%s\n' "$ZEILE"

done < "$GO" > "$TMP" || {
    rm -f "$TMP"
    echo "STOP: Bereinigung von $GO fehlgeschlagen."
    exit 1
}

REST="${TMP}.rest"

{
    echo '#!/bin/bash'
    echo
    echo '# array-serial: Boot-Diagnose so frueh wie moeglich starten'
    echo "$BOOT_LOG_AUFRUF"
    echo "$BOOT_CAPTURE_AUFRUF"
    echo
    echo '# array-serial: persistente Udev-Regeln vor Unraid/emhttp installieren'
    echo "$INSTALL_AUFRUF || {"
    echo '    echo "array-serial: install-boot.sh fehlgeschlagen." >&2'
    echo '}'
    echo
    echo '# array-serial: vorbereitete MD-Migration nach Reboot fortsetzen'
    echo "$RESUME_AUFRUF"
    echo
} > "$REST"

ERSTE_ZEILE=1

while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do

    if [ "$ERSTE_ZEILE" -eq 1 ]; then
        ERSTE_ZEILE=0

        if [ "$ZEILE" = "#!/bin/bash" ]; then
            continue
        fi
    fi

    printf '%s\n' "$ZEILE"

done < "$TMP" >> "$REST"

mv -f "$REST" "$TMP"

if ! /bin/bash -n "$TMP"; then
    rm -f "$TMP"
    echo "STOP: Neue $GO-Version hat einen Syntaxfehler. Original bleibt unveraendert."
    exit 1
fi

mv -f "$TMP" "$GO"
sync

echo "===== PERSISTENTER BOOT-HOOK ====="

grep -nE \
    'array-serial|install-udev-rule|install-boot|boot-log|boot-capture|md-migration-boot-resume' \
    "$GO" || true

echo
echo "===== VALIDIERUNG ====="

INSTALL_COUNT="$(grep -Fc "$INSTALL_AUFRUF" "$GO" || true)"
LOGGER_COUNT="$(grep -Fc "$BOOT_LOG_AUFRUF" "$GO" || true)"
CAPTURE_COUNT="$(grep -Fc "$BOOT_CAPTURE_AUFRUF" "$GO" || true)"
RESUME_COUNT="$(grep -Fc "$RESUME_AUFRUF" "$GO" || true)"
LEGACY_COUNT="$(grep -Fc "$BASE/install-udev-rule.sh" "$GO" || true)"

KOMMENTAR_LOG_COUNT="$(
    grep -Fc '# array-serial: Boot-Diagnose so frueh wie moeglich starten' "$GO" || true
)"

KOMMENTAR_UDEV_COUNT="$(
    grep -Fc '# array-serial: persistente Udev-Regeln vor Unraid/emhttp installieren' "$GO" || true
)"

KOMMENTAR_RESUME_COUNT="$(
    grep -Fc '# array-serial: vorbereitete MD-Migration nach Reboot fortsetzen' "$GO" || true
)"

if [ "$INSTALL_COUNT" -ne 1 ] ||
   [ "$LOGGER_COUNT" -ne 1 ] ||
   [ "$CAPTURE_COUNT" -ne 1 ] ||
   [ "$RESUME_COUNT" -ne 1 ] ||
   [ "$LEGACY_COUNT" -ne 0 ] ||
   [ "$KOMMENTAR_LOG_COUNT" -ne 1 ] ||
   [ "$KOMMENTAR_UDEV_COUNT" -ne 1 ] ||
   [ "$KOMMENTAR_RESUME_COUNT" -ne 1 ]; then

    echo "STOP: Boot-Hook ist nicht eindeutig."
    cp -p "$BACKUP" "$GO"
    sync
    exit 1
fi

echo "OK: install-boot.sh genau einmal."
echo "OK: boot-log.sh genau einmal."
echo "OK: boot-capture.sh genau einmal."
echo "OK: md-migration-boot-resume.sh genau einmal."
echo "OK: Boot-Diagnose-Kommentar genau einmal."
echo "OK: Udev-Kommentar genau einmal."
echo "OK: Resume-Kommentar genau einmal."
echo "OK: Legacy install-udev-rule.sh entfernt."
echo "Backup: $BACKUP"
echo "ERGEBNIS: ARRAY_SERIAL_BOOT_ENABLE_OK"
