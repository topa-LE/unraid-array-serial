#!/bin/bash
#
# topa-LE Unraid Array Serial
# Zentraler Installations-Orchestrator.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
BASELINE="$BASE/identity-baseline.tsv"
GO="/boot/config/go"

MODUS="INSTALL"

case "${1:-}" in
    "")
        ;;
    --migrate-array)
        MODUS="MIGRATE_ARRAY"
        ;;
    *)
        echo "Verwendung: $0 [--migrate-array]"
        exit 1
        ;;
esac

echo "===== ARRAY-SERIAL – INSTALLATION / UPDATE ====="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

echo "===== 1. PROJEKTDATEIEN PRUEFEN ====="

for DATEI in \
    activation-preflight.sh \
    identity-baseline.sh \
    identity-tuple.sh \
    serial-id.sh \
    enable-boot.sh \
    install-boot.sh \
    install-flash-id.sh \
    boot-log.sh \
    boot-capture.sh \
    flash-id.sh \
    udev-authorized-id.sh \
    udev-authorized-partition-id.sh \
    migrate-array-ids.sh \
    md-migration-transaction.sh \
    md-migration-boot-resume.sh \
    59-array-serial.rules \
    61-array-serial-nvme.rules \
    62-array-serial-partitions.rules \
    63-array-serial-nvme-links.rules \
    64-array-serial-flash.rules
do
    if [ ! -f "$BASE/$DATEI" ]; then
        echo "STOP: Projektdatei fehlt: $DATEI"
        exit 1
    fi
done

echo "OK: Erforderliche Projektdateien vorhanden."

echo
echo "===== 2. SHELL-SYNTAX PRUEFEN ====="

for DATEI in \
    activation-preflight.sh \
    identity-baseline.sh \
    identity-tuple.sh \
    serial-id.sh \
    enable-boot.sh \
    install-boot.sh \
    install-flash-id.sh \
    boot-log.sh \
    boot-capture.sh \
    flash-id.sh \
    udev-authorized-id.sh \
    udev-authorized-partition-id.sh \
    migrate-array-ids.sh \
    md-migration-transaction.sh \
    md-migration-boot-resume.sh
do
    /bin/bash -n "$BASE/$DATEI" || {
        echo "STOP: Syntaxfehler: $DATEI"
        exit 1
    }
done

echo "OK: Shell-Skripte syntaktisch sauber."

if [ "$MODUS" = "MIGRATE_ARRAY" ]; then
    echo
    echo "===== ARRAY-MIGRATION – PREFLIGHT UND PLAN ====="

    if [ -e "$BASE/md-migration-resume.state" ]; then
        echo "STOP: Es existiert bereits ein MD-Migrations-Resume-State."
        echo "$BASE/md-migration-resume.state"
        exit 1
    fi

    /bin/bash "$BASE/migrate-array-ids.sh" || {
        echo "STOP: Array-Migrations-Preflight fehlgeschlagen."
        exit 1
    }

    MIGRATIONSPLAN="$BASE/migration-plan.tsv"

    if [ ! -s "$MIGRATIONSPLAN" ]; then
        echo "STOP: Migrationsplan fehlt oder ist leer:"
        echo "$MIGRATIONSPLAN"
        exit 1
    fi

    echo
    echo "===== ARRAY-MIGRATION – BOOT-RESUME EINRICHTEN ====="

    /bin/bash "$BASE/enable-boot.sh" || {
        echo "STOP: Boot-Resume konnte nicht eingerichtet werden."
        exit 1
    }

    RESUME_HOOK_ANZAHL="$(
        grep -Fc "$BASE/md-migration-boot-resume.sh" "$GO" || true
    )"

    if [ "$RESUME_HOOK_ANZAHL" -ne 1 ]; then
        echo "STOP: MD-Migrations-Resume-Hook ist nicht eindeutig."
        exit 1
    fi

    echo "OK: MD-Migrations-Resume-Hook genau einmal vorhanden."

    echo
    echo "===== ARRAY-MIGRATION – PHASE A ====="

    /bin/bash "$BASE/md-migration-transaction.sh" \
        --prepare-reboot "$MIGRATIONSPLAN" || {
            echo "STOP: MD-Migrations-Phase A fehlgeschlagen."
            exit 1
        }

    if [ ! -r "$BASE/md-migration-resume.state" ]; then
        echo "STOP: Phase A hat keinen lesbaren Resume-State erzeugt."
        exit 1
    fi

    if [ -e "/boot/config/super.dat" ]; then
        echo "STOP: Phase A meldete Erfolg, aber super.dat ist noch aktiv."
        exit 1
    fi

    echo
    echo "===== ARRAY-MIGRATION – PHASE A ERFOLGREICH ====="
    echo "Resume-State: $BASE/md-migration-resume.state"
    echo "Boot-Resume:  OK"
    echo "super.dat:    fuer Phase B geparkt"
    echo
    echo "BEREIT_FUER_MIGRATIONS_REBOOT"
    exit 0
fi

echo
echo "===== 3. SERVER-IDENTITAET / BASELINE ====="

if [ -f "$BASELINE" ]; then
    echo "Vorhandene Identity-Baseline gefunden."
    echo "Die vorhandene Baseline wird NICHT ersetzt."

    /bin/bash "$BASE/identity-baseline.sh" \
        --validate "$BASELINE" || {
            echo "STOP: Vorhandene Identity-Baseline ist ungueltig."
            exit 1
        }

    echo "OK: Vorhandene Identity-Baseline gueltig."
else
    echo "Keine Identity-Baseline vorhanden."
    echo "Activation-Preflight erzeugt die servereigene Baseline."

    /bin/bash "$BASE/activation-preflight.sh" \
        --write-baseline "$BASELINE" || {
            echo "STOP: Activation-Preflight hat keine sichere Baseline erzeugt."
            exit 1
        }

    /bin/bash "$BASE/identity-baseline.sh" \
        --validate "$BASELINE" || {
            echo "STOP: Neu erzeugte Identity-Baseline ist ungueltig."
            exit 1
        }

    echo "OK: Servereigene Identity-Baseline erzeugt und validiert."
fi

echo
echo "===== 4. PERSISTENTEN KERN-BOOT-ABLAUF PRUEFEN ====="

if [ ! -f "$GO" ]; then
    echo "STOP: $GO fehlt."
    exit 1
fi

BOOT_LOG_ANZAHL="$(grep -Fc "$BASE/boot-log.sh" "$GO" || true)"
BOOT_CAPTURE_ANZAHL="$(grep -Fc "$BASE/boot-capture.sh" "$GO" || true)"
INSTALL_BOOT_ANZAHL="$(grep -Fc "$BASE/install-boot.sh" "$GO" || true)"
RESUME_BOOT_ANZAHL="$(grep -Fc "$BASE/md-migration-boot-resume.sh" "$GO" || true)"

echo "boot-log.sh                 = $BOOT_LOG_ANZAHL"
echo "boot-capture.sh             = $BOOT_CAPTURE_ANZAHL"
echo "install-boot.sh             = $INSTALL_BOOT_ANZAHL"
echo "md-migration-boot-resume.sh = $RESUME_BOOT_ANZAHL"

if [ "$BOOT_LOG_ANZAHL" -gt 1 ] ||
   [ "$BOOT_CAPTURE_ANZAHL" -gt 1 ] ||
   [ "$INSTALL_BOOT_ANZAHL" -gt 1 ] ||
   [ "$RESUME_BOOT_ANZAHL" -gt 1 ]; then
    echo "STOP: Kern-Boot-Hooks sind mehrfach vorhanden."
    exit 1
fi

if [ "$BOOT_LOG_ANZAHL" -eq 1 ] &&
   [ "$BOOT_CAPTURE_ANZAHL" -eq 1 ] &&
   [ "$INSTALL_BOOT_ANZAHL" -eq 1 ] &&
   [ "$RESUME_BOOT_ANZAHL" -eq 1 ]; then

    echo "OK: Kern-Boot-Hooks bereits vollstaendig vorhanden."
    echo "enable-boot.sh wird NICHT erneut ausgefuehrt."
else
    echo "Kern-Boot-Hooks noch nicht vollstaendig."
    echo "Einmalige Einrichtung mit enable-boot.sh."

    /bin/bash "$BASE/enable-boot.sh" || {
        echo "STOP: enable-boot.sh fehlgeschlagen."
        exit 1
    }

    BOOT_LOG_ANZAHL="$(grep -Fc "$BASE/boot-log.sh" "$GO" || true)"
    BOOT_CAPTURE_ANZAHL="$(grep -Fc "$BASE/boot-capture.sh" "$GO" || true)"
    INSTALL_BOOT_ANZAHL="$(grep -Fc "$BASE/install-boot.sh" "$GO" || true)"
    RESUME_BOOT_ANZAHL="$(grep -Fc "$BASE/md-migration-boot-resume.sh" "$GO" || true)"

    if [ "$BOOT_LOG_ANZAHL" -ne 1 ] ||
       [ "$BOOT_CAPTURE_ANZAHL" -ne 1 ] ||
       [ "$INSTALL_BOOT_ANZAHL" -ne 1 ] ||
       [ "$RESUME_BOOT_ANZAHL" -ne 1 ]; then
        echo "STOP: Kern-Boot-Hooks nach enable-boot.sh nicht eindeutig."
        exit 1
    fi

    echo "OK: Kern-Boot-Hooks eingerichtet."
fi

echo
echo "===== 5. FLASH-BOOT-PERSISTENZ ====="

FLASH_PFAD="$BASE/install-flash-id.sh"
FLASH_ZEILE="/bin/bash $FLASH_PFAD"

FLASH_ANZAHL="$(grep -Fc "$FLASH_PFAD" "$GO" || true)"
EMHTTP_ANZAHL="$(grep -Fc '/usr/local/sbin/emhttp' "$GO" || true)"

echo "install-flash-id.sh = $FLASH_ANZAHL"
echo "emhttp               = $EMHTTP_ANZAHL"

if [ "$FLASH_ANZAHL" -gt 1 ]; then
    echo "STOP: Flash-Boot-Hook ist mehrfach vorhanden."
    exit 1
fi

if [ "$EMHTTP_ANZAHL" -ne 1 ]; then
    echo "STOP: emhttp ist nicht eindeutig in $GO vorhanden."
    exit 1
fi

if [ "$FLASH_ANZAHL" -eq 0 ]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    BACKUP_GO="${GO}.array-serial-flash-${STAMP}.bak"
    TMP_GO="${GO}.array-serial-flash.$$"

    cp -p "$GO" "$BACKUP_GO" || {
        echo "STOP: Backup von $GO fehlgeschlagen."
        exit 1
    }

    while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do
        if printf '%s\n' "$ZEILE" | grep -Fq '/usr/local/sbin/emhttp'; then
            echo "# array-serial: Flash-ID bei jedem Boot installieren"
            echo "$FLASH_ZEILE"
        fi

        printf '%s\n' "$ZEILE"
    done < "$GO" > "$TMP_GO" || {
        rm -f "$TMP_GO"
        echo "STOP: Neuer $GO-Inhalt konnte nicht erzeugt werden."
        exit 1
    }

    /bin/bash -n "$TMP_GO" || {
        rm -f "$TMP_GO"
        echo "STOP: Neuer $GO-Inhalt hat Syntaxfehler."
        exit 1
    }

    mv "$TMP_GO" "$GO" || {
        rm -f "$TMP_GO"
        echo "STOP: $GO konnte nicht aktualisiert werden."
        exit 1
    }

    echo "OK: Flash-Boot-Hook eingerichtet."
    echo "Backup: $BACKUP_GO"
else
    echo "OK: Flash-Boot-Hook bereits vorhanden."
fi

FLASH_ANZAHL="$(grep -Fc "$FLASH_PFAD" "$GO" || true)"

if [ "$FLASH_ANZAHL" -ne 1 ]; then
    echo "STOP: Flash-Boot-Hook ist nicht eindeutig."
    exit 1
fi

echo
echo "===== 6. ARRAY-/POOL-UDEV AKTIVIEREN ====="

/bin/bash "$BASE/install-boot.sh" || {
    echo "STOP: install-boot.sh fehlgeschlagen."
    exit 1
}

echo
echo "===== 7. FLASH-ID AKTIVIEREN ====="

/bin/bash "$BASE/install-flash-id.sh" || {
    echo "STOP: install-flash-id.sh fehlgeschlagen."
    exit 1
}

echo
echo "===== 8. ABSCHLUSSKONTROLLE ====="

/bin/bash "$BASE/identity-baseline.sh" \
    --validate "$BASELINE" || {
        echo "STOP: Identity-Baseline nach Installation ungueltig."
        exit 1
    }

for REGEL in \
    59-array-serial.rules \
    61-array-serial-nvme.rules \
    62-array-serial-partitions.rules \
    63-array-serial-nvme-links.rules \
    64-array-serial-flash.rules
do
    if [ ! -f "/etc/udev/rules.d/$REGEL" ]; then
        echo "STOP: Runtime-Udev-Regel fehlt: $REGEL"
        exit 1
    fi

    if ! cmp -s "$BASE/$REGEL" "/etc/udev/rules.d/$REGEL"; then
        echo "STOP: Runtime-Udev-Regel ist nicht aktuell: $REGEL"
        exit 1
    fi

    echo "UDEV OK: $REGEL"
done

for AUFRUF in \
    "$BASE/boot-log.sh" \
    "$BASE/boot-capture.sh" \
    "$BASE/install-boot.sh" \
    "$BASE/md-migration-boot-resume.sh" \
    "$BASE/install-flash-id.sh"
do
    ANZAHL="$(grep -Fc "$AUFRUF" "$GO" || true)"

    if [ "$ANZAHL" -ne 1 ]; then
        echo "STOP: Persistenter Boot-Hook nicht eindeutig: $AUFRUF"
        exit 1
    fi

    echo "BOOT-HOOK OK: $AUFRUF"
done

echo
echo "===== INSTALLATION ERFOLGREICH ====="
echo "Identity-Baseline: $BASELINE"
echo "Runtime-Udev: OK"
echo "Persistenter Boot-Ablauf: OK"
echo "Flash-ID Runtime: OK"
echo "Flash-ID Boot-Persistenz: OK"
echo
echo "BEREIT_FUER_REBOOT"
