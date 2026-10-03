#!/bin/bash
#
# topa-LE Unraid Array Serial
# Boot-Orchestrator fuer eine bereits vorbereitete MD-Migration.
#
# Startet selbst KEINE Migration.
# Nur ein von Phase A erzeugter persistenter Resume-State aktiviert
# die automatische Fortsetzung von Phase B nach dem Reboot.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
RESUME_STATE="$BASE/md-migration-resume.state"
TRANSACTION="$BASE/md-migration-transaction.sh"
MDSTAT="/proc/mdstat"

MAX_VERSUCHE=120
WARTEZEIT=1

echo "===== ARRAY-SERIAL – MD-MIGRATION BOOT-RESUME ====="

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

if [ ! -e "$RESUME_STATE" ]; then
    echo "Kein Resume-State vorhanden."
    echo "Keine MD-Migration fortzusetzen."
    echo "ERGEBNIS: KEIN_RESUME_ERFORDERLICH"
    exit 0
fi

if [ ! -r "$RESUME_STATE" ]; then
    echo "STOP: Resume-State existiert, ist aber nicht lesbar:"
    echo "$RESUME_STATE"
    exit 1
fi

if [ ! -r "$TRANSACTION" ]; then
    echo "STOP: MD-Transaktionsskript fehlt oder ist nicht lesbar:"
    echo "$TRANSACTION"
    exit 1
fi

if ! /bin/bash -n "$TRANSACTION"; then
    echo "STOP: MD-Transaktionsskript hat einen Syntaxfehler."
    exit 1
fi

echo "Resume-State gefunden:"
echo "$RESUME_STATE"
echo
echo "Warte auf initialisierten Unraid-MD-Runtimezustand ..."

for ((VERSUCH=1; VERSUCH<=MAX_VERSUCHE; VERSUCH++)); do

    MD_STATE=""
    MD_NUM_DISKS=""
    MD_NUM_MISSING=""
    MD_NUM_NEW=""

    if [ -r "$MDSTAT" ]; then

        while IFS='=' read -r SCHLUESSEL WERT; do
            case "$SCHLUESSEL" in
                mdState)
                    MD_STATE="$WERT"
                    ;;
                mdNumDisks)
                    MD_NUM_DISKS="$WERT"
                    ;;
                mdNumMissing)
                    MD_NUM_MISSING="$WERT"
                    ;;
                mdNumNew)
                    MD_NUM_NEW="$WERT"
                    ;;
            esac
        done < "$MDSTAT"

        case "$MD_STATE" in
            STOPPED)
                if [ "$MD_NUM_DISKS" = "0" ] &&
                   [ "$MD_NUM_NEW" = "0" ] &&
                   [ "$MD_NUM_MISSING" = "0" ]; then

                    echo "MD-Runtime bereit: STOPPED / leer."
                    echo
                    exec /bin/bash "$TRANSACTION" --resume-phase-b
                fi
                ;;

            NEW_ARRAY)
                case "$MD_NUM_DISKS" in
                    ''|*[!0-9]*)
                        ;;
                    *)
                        if [ "$MD_NUM_NEW" = "$MD_NUM_DISKS" ] &&
                           [ "$MD_NUM_MISSING" = "0" ]; then

                            echo "MD-Runtime bereit: NEW_ARRAY / alle Disks NEW."
                            echo
                            exec /bin/bash "$TRANSACTION" --resume-phase-b
                        fi
                        ;;
                esac
                ;;
        esac
    fi

    sleep "$WARTEZEIT"
done

echo
echo "STOP: Unraid-MD-Runtime wurde nicht rechtzeitig fuer Phase B bereit."
echo "Resume-State bleibt unangetastet:"
echo "$RESUME_STATE"
exit 1
