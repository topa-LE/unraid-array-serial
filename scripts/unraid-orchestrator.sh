#!/bin/bash
#
# topa-LE Unraid Array Serial
# Zentraler Installations-Orchestrator.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
BASELINE="$BASE/identity-baseline.tsv"
GO="/boot/config/go"

MODUS="INSTALL"
RECOVERY_DIR=""

case "${1:-}" in
    "")
        ;;
    --new-server)
        [ "$#" -eq 1 ] || exit 1
        MODUS="NEW_SERVER"
        ;;
    --migrate-array)
        [ "$#" -eq 1 ] || {
            echo "Verwendung: $0 [--migrate-array | --recover-migration-baseline TRANSAKTIONSVERZEICHNIS]"
            exit 1
        }
        MODUS="MIGRATE_ARRAY"
        ;;
    --recover-migration-baseline)
        [ "$#" -eq 2 ] || {
            echo "Verwendung: $0 [--migrate-array | --recover-migration-baseline TRANSAKTIONSVERZEICHNIS]"
            exit 1
        }
        MODUS="RECOVER_MIGRATION_BASELINE"
        RECOVERY_DIR="$2"
        ;;
    *)
        echo "Verwendung: $0 [--migrate-array | --recover-migration-baseline TRANSAKTIONSVERZEICHNIS]"
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
    install-new-server.sh \
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
    md-migration-array-state.sh \
    md-migration-state-bridge.sh \
    md-migration-boot-resume.sh \
    migrate-pool-ids.sh \
    pool-migration-transaction.sh \
    pool-migration-baseline.sh \
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
    install-new-server.sh \
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
    md-migration-array-state.sh \
    md-migration-state-bridge.sh \
    md-migration-boot-resume.sh \
    migrate-pool-ids.sh \
    pool-migration-transaction.sh \
    pool-migration-baseline.sh
do
    /bin/bash -n "$BASE/$DATEI" || {
        echo "STOP: Syntaxfehler: $DATEI"
        exit 1
    }
done

echo "OK: Shell-Skripte syntaktisch sauber."

migrationsbaseline_erzeugen() {
    local PLAN="$1"
    local BASELINE_TMP=""

    [ -r "$PLAN" ] || {
        echo "STOP: Migrationsplan nicht lesbar:"
        echo "$PLAN"
        return 1
    }

    if [ -e "$BASELINE" ]; then
        echo "Vorhandene Identity-Baseline gefunden."
        echo "Die vorhandene Baseline wird NICHT ersetzt."

        /bin/bash "$BASE/identity-baseline.sh" \
            --validate "$BASELINE" || {
                echo "STOP: Vorhandene Identity-Baseline ist ungueltig."
                return 1
            }

        echo "OK: Vorhandene Identity-Baseline gueltig."
        return 0
    fi

    BASELINE_TMP="${BASELINE}.migration.$$"
    : > "$BASELINE_TMP"

    while IFS=$'\t' read -r NAME SLOT ALTE_ID HW SOURCE_ID SOURCE; do
        if [ -z "$NAME" ] ||
           [ -z "$SLOT" ] ||
           [ -z "$ALTE_ID" ] ||
           [ -z "$HW" ] ||
           [ -z "$SOURCE_ID" ] ||
           [ -z "$SOURCE" ]; then

            rm -f "$BASELINE_TMP"
            echo "STOP: Migrationsplan enthaelt eine unvollstaendige Zeile."
            return 1
        fi

        case "$SOURCE" in
            ATA|NVME|USB_SAT)
                ;;
            *)
                rm -f "$BASELINE_TMP"
                echo "STOP: Migrationsplan enthaelt keine persistente Identitaetsquelle:"
                echo "$SOURCE"
                return 1
                ;;
        esac

        printf '%s\t%s\t%s\n' \
            "$HW" "$SOURCE" "$SOURCE_ID" >> "$BASELINE_TMP"
    done < "$PLAN"

    if [ ! -s "$BASELINE_TMP" ]; then
        rm -f "$BASELINE_TMP"
        echo "STOP: Aus dem Migrationsplan konnte keine Baseline erzeugt werden."
        return 1
    fi

    /bin/bash "$BASE/identity-baseline.sh" \
        --validate "$BASELINE_TMP" || {
            rm -f "$BASELINE_TMP"
            echo "STOP: Aus dem Migrationsplan erzeugte Baseline ist ungueltig."
            return 1
        }

    mv "$BASELINE_TMP" "$BASELINE"
    chmod 600 "$BASELINE"
    sync

    /bin/bash "$BASE/identity-baseline.sh" \
        --validate "$BASELINE" || {
            echo "STOP: Persistierte Migrations-Baseline ist ungueltig."
            return 1
        }

    echo "OK: Identity-Baseline sicher aus dem verifizierten Migrationsplan erzeugt."
    echo "Baseline: $BASELINE"
}

if [ "$MODUS" = "RECOVER_MIGRATION_BASELINE" ]; then
    echo
    echo "===== ARRAY-MIGRATION – BASELINE-RECOVERY ====="

    [ -d "$RECOVERY_DIR" ] || {
        echo "STOP: Transaktionsverzeichnis fehlt:"
        echo "$RECOVERY_DIR"
        exit 1
    }

    case "$RECOVERY_DIR" in
        "$BASE"/md-migration-*)
            ;;
        *)
            echo "STOP: Recovery-Verzeichnis liegt nicht im erwarteten Array-Serial-Pfad."
            exit 1
            ;;
    esac

    if [ -e "$BASE/md-migration-resume.state" ]; then
        echo "STOP: Baseline-Recovery ist bei vorhandenem MD-Migrations-Resume-State nicht erlaubt."
        echo "$BASE/md-migration-resume.state"
        exit 1
    fi

    RECOVERY_PLAN="$RECOVERY_DIR/migration-plan.tsv"
    RECOVERY_PLAN_SHA="$RECOVERY_DIR/migration-plan.tsv.sha256"
    RECOVERY_MANIFEST="$RECOVERY_DIR/md-transaction.tsv"
    RECOVERY_MANIFEST_SHA="$RECOVERY_DIR/md-transaction.tsv.sha256"
    RECOVERY_SUPER_SHA="$RECOVERY_DIR/super.dat.after-migration.sha256"

    for DATEI in \
        "$RECOVERY_PLAN" \
        "$RECOVERY_PLAN_SHA" \
        "$RECOVERY_MANIFEST" \
        "$RECOVERY_MANIFEST_SHA" \
        "$RECOVERY_SUPER_SHA"
    do
        [ -r "$DATEI" ] || {
            echo "STOP: Recovery-Datei fehlt oder ist nicht lesbar:"
            echo "$DATEI"
            exit 1
        }
    done

    [ -r /boot/config/super.dat ] || {
        echo "STOP: Aktive /boot/config/super.dat fehlt oder ist nicht lesbar."
        exit 1
    }

    echo "Pruefe gesicherten Migrationsplan ..."
    sha256sum -c "$RECOVERY_PLAN_SHA" >/dev/null || {
        echo "STOP: SHA256-Pruefung des Migrationsplans fehlgeschlagen."
        exit 1
    }
    echo "Migrationsplan-SHA256: OK"

    echo "Pruefe gesichertes Transaktionsmanifest ..."
    sha256sum -c "$RECOVERY_MANIFEST_SHA" >/dev/null || {
        echo "STOP: SHA256-Pruefung des Transaktionsmanifests fehlgeschlagen."
        exit 1
    }
    echo "Transaktionsmanifest-SHA256: OK"

    echo "Pruefe aktive super.dat gegen abgeschlossene Phase B ..."

    RECOVERY_SUPER_EXPECTED=""
    RECOVERY_SUPER_PATH=""

    read -r RECOVERY_SUPER_EXPECTED RECOVERY_SUPER_PATH < "$RECOVERY_SUPER_SHA" || {
        echo "STOP: Gespeicherter super.dat-SHA256 konnte nicht gelesen werden."
        exit 1
    }

    if [ "${#RECOVERY_SUPER_EXPECTED}" -ne 64 ]; then
        echo "STOP: Gespeicherter super.dat-SHA256 hat keine gueltige Laenge."
        exit 1
    fi

    case "$RECOVERY_SUPER_EXPECTED" in
        *[!0-9a-fA-F]*)
            echo "STOP: Gespeicherter super.dat-SHA256 ist ungueltig."
            exit 1
            ;;
    esac

    if [ "$RECOVERY_SUPER_PATH" != "/boot/config/super.dat" ]; then
        echo "STOP: Gespeicherter super.dat-SHA256 verweist auf einen unerwarteten Pfad:"
        echo "$RECOVERY_SUPER_PATH"
        exit 1
    fi

    AKTUELLER_SUPER_HASH=""
    AKTUELLER_SUPER_PFAD=""

    read -r AKTUELLER_SUPER_HASH AKTUELLER_SUPER_PFAD < <(
        sha256sum /boot/config/super.dat
    ) || {
        echo "STOP: SHA256 der aktiven super.dat konnte nicht ermittelt werden."
        exit 1
    }

    if [ "$AKTUELLER_SUPER_HASH" != "$RECOVERY_SUPER_EXPECTED" ]; then
        echo "STOP: Aktive super.dat gehoert nicht zum abgeschlossenen Migrationszustand."
        echo "Erwartet: $RECOVERY_SUPER_EXPECTED"
        echo "Aktuell:  $AKTUELLER_SUPER_HASH"
        exit 1
    fi

    echo "Aktive super.dat SHA256: OK"
    echo "MD-Migrations-Resume-State: NICHT VORHANDEN"

    echo
    echo "===== ARRAY-MIGRATION – IDENTITY-BASELINE WIEDERHERSTELLEN ====="

    migrationsbaseline_erzeugen "$RECOVERY_PLAN" || {
        echo "STOP: Migrations-Baseline konnte nicht wiederhergestellt werden."
        exit 1
    }

    echo
    echo "===== BASELINE-RECOVERY ERFOLGREICH ====="
    echo "Identity-Baseline: $BASELINE"
    echo "Transaktionsverzeichnis: $RECOVERY_DIR"
    echo
    echo "BEREIT_FUER_NORMALE_INSTALLATION"
    exit 0
fi

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
    echo "===== ARRAY-MIGRATION – IDENTITY-BASELINE ====="

    migrationsbaseline_erzeugen "$MIGRATIONSPLAN" || {
        echo "STOP: Migrations-Baseline konnte nicht erzeugt werden."
        exit 1
    }

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

    echo
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
NEW_SERVER_INSTALL=0

if [ "$MODUS" = "NEW_SERVER" ]; then
    echo "===== NEW-SERVER – ERSTINSTALLATION ====="

    if [ -f "$BASELINE" ]; then
        echo "Vorhandene Baseline wird validiert."
        /bin/bash "$BASE/identity-baseline.sh"             --validate "$BASELINE" || exit 1
        echo "OK: Vorhandene Baseline gueltig."
    else
        /bin/bash "$BASE/install-new-server.sh" --apply || exit 1
        echo "OK: New-Server-Baseline erstellt."
        NEW_SERVER_INSTALL=1
    fi

    MODUS="INSTALL"
fi

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
    echo "Erstinstallation und bestehende Serverkonfiguration werden geprueft."

    if /bin/bash "$BASE/install-new-server.sh" --preview; then
        echo "Neuer Unraid-Server erkannt."
        /bin/bash "$BASE/install-new-server.sh" --apply || exit 1
        echo "OK: Erstinstallations-Baseline erzeugt."
        NEW_SERVER_INSTALL=1

    elif /bin/bash "$BASE/activation-preflight.sh" \
        --write-baseline "$BASELINE"
    then
        echo "OK: Servereigene Identity-Baseline erzeugt."

    else
        echo
        echo "===== NEW-SERVER-SICHERHEITSSPERRE ====="

        if [ -r /proc/mdstat ] &&
           grep -qx 'mdNumDisks=0' /proc/mdstat &&
           ! grep -Eq '^diskId\.[0-9]+=.+$' /proc/mdstat &&
           [ -d /boot/config/pools ] &&
           ! compgen -G '/boot/config/pools/*.cfg' > /dev/null; then
            echo "STOP: Leeres Array erkannt, aber New-Server-Preflight fehlgeschlagen."
            echo "Keine automatische Migration."
            exit 1
        fi

        echo
        echo "===== POOL-MIGRATION AUTOMATISCH PRUEFEN ====="
        echo "Normaler Preflight konnte noch keine Baseline erzeugen."
        echo "Pool-Zuweisungen werden jetzt sicher geprueft."

        /bin/bash "$BASE/migrate-pool-ids.sh" --apply || {
            echo "STOP: Automatische Pool-Migration ist fehlgeschlagen."
            exit 1
        }

        echo
        echo "===== VOLLSTAENDIGE TRANSITION-BASELINE ====="

        if /bin/bash "$BASE/pool-migration-baseline.sh" --create
        then
            echo "OK: Vollstaendige Transition-Baseline erzeugt."
        else
            echo
            echo "===== ARRAY-MIGRATION AUTOMATISCH PRUEFEN ====="
            echo "Transition-Baseline konnte noch nicht erzeugt werden."
            echo "Der vorhandene sichere Array-Migrationspfad wird verwendet."
            echo

            /bin/bash "$BASE/unraid-orchestrator.sh" --migrate-array || {
                echo
                echo "STOP: Sichere Array-Migration konnte nicht vorbereitet werden."
                exit 1
            }

            exit 0
        fi
    fi

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

echo
echo "===== STRENGER ACTIVATION-PREFLIGHT ====="

if [ "$NEW_SERVER_INSTALL" -eq 1 ]; then
    echo "New-Server: Keine Array-/Pool-Zuweisungen vorhanden."
    echo "Strenger Activation-Preflight fuer bestehende Zuweisungen entfaellt."
else
    /bin/bash "$BASE/activation-preflight.sh" || {
        echo "STOP: Strenger Activation-Preflight nach Udev-Aktivierung fehlgeschlagen."
        exit 1
    }
fi

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
