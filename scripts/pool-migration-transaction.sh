#!/bin/bash

# Pool Migration Transaction Backend
#
# Fuehrt spaeter ausschliesslich den Schreibteil einer bereits
# vollstaendig verifizierten Pool-Migration aus.
#
# Sicherheitsprinzip:
#   1. kompletter Plan vorhanden
#   2. alle CFG-Dateien vorab verifizieren
#   3. alle Originale sichern
#   4. Backups bytegleich pruefen
#   5. erst danach schreiben
#   6. bei Fehler alle bereits geschriebenen CFGs zurueckrollen
#
# Keine Partitionierung.
# Keine Dateisystem-Aenderung.
# Keine UUID-Aenderung.
# Keine Abhaengigkeit von persistenten sdX-/nvmeX-Namen.

set -u

PLAN="${1:-}"

fehler()
{
    echo "STOP: $*" >&2
    return 1
}

[ -n "$PLAN" ] || {
    echo "Verwendung: $0 PLAN"
    exit 1
}

[ -r "$PLAN" ] || {
    echo "STOP: Plan nicht lesbar: $PLAN"
    exit 1
}

[ -s "$PLAN" ] || {
    echo "STOP: Plan ist leer: $PLAN"
    exit 1
}

BACKUP_ROOT="${POOL_MIGRATION_BACKUP_ROOT:-/boot/config/custom/array-serial}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/pool-migration-$STAMP"

declare -a CFGS
declare -a UUIDS
declare -a CFG_KEYS
declare -a OLD_IDS
declare -a NEW_IDS
declare -a BACKUPS
declare -a SOURCES
declare -a SERIALS
declare -a PARENTS

SERIAL_ID="/boot/config/custom/array-serial/serial-id.sh"

COUNT=0

echo "===== POOL-TRANSAKTION – PREFLIGHT ====="

while IFS="$(printf '\t')" read -r CFG UUID CFG_KEY OLD_ID NEW_ID SOURCE SERIAL PARENT REST; do
    [ -n "$CFG" ] || continue

    [ -z "${REST:-}" ] || {
        fehler "Unerwartete Zusatzfelder im Plan."
        exit 1
    }

    [ -r "$CFG" ] || {
        fehler "CFG nicht lesbar: $CFG"
        exit 1
    }

    [ -n "$UUID" ] || {
        fehler "diskUUID fehlt fuer $CFG"
        exit 1
    }

    case "$CFG_KEY" in
        diskId|diskId.[0-9]*)
            ;;
        *)
            fehler "Ungueltiger Pool-diskId-Key fuer $CFG: $CFG_KEY"
            exit 1
            ;;
    esac

    [ -n "$OLD_ID" ] || {
        fehler "alte diskId fehlt fuer $CFG / $CFG_KEY"
        exit 1
    }

    [ -n "$NEW_ID" ] || {
        fehler "neue diskId fehlt fuer $CFG"
        exit 1
    }

    [ -n "$SOURCE" ] && [ -n "$SERIAL" ] && [ -n "$PARENT" ] || {
        fehler "Hardware-Daten fehlen fuer $CFG"
        exit 1
    }

    [ -b "/dev/$PARENT" ] || {
        fehler "Parent nicht vorhanden: /dev/$PARENT"
        exit 1
    }

    IDENT="$(timeout 20 /bin/bash "$SERIAL_ID" "/dev/$PARENT" 2>/dev/null)" || {
        fehler "Hardware-Verifikation fehlgeschlagen: /dev/$PARENT"
        exit 1
    }

    CHECK_SOURCE="$(printf '%s\n' "$IDENT" | awk -F= '$1=="IDENTITY_SOURCE"{print substr($0,index($0,"=")+1); exit}')"
    CHECK_SERIAL="$(printf '%s\n' "$IDENT" | awk -F= '$1=="ID_SERIAL_SHORT"{print substr($0,index($0,"=")+1); exit}')"
    CHECK_ID="$(printf '%s\n' "$IDENT" | awk -F= '$1=="ID_SERIAL"{print substr($0,index($0,"=")+1); exit}')"

    [ "$CHECK_SOURCE" = "$SOURCE" ] &&
    [ "$CHECK_SERIAL" = "$SERIAL" ] &&
    [ "$CHECK_ID" = "$NEW_ID" ] || {
        fehler "Hardware stimmt nicht mehr mit Plan ueberein: $CFG"
        exit 1
    }

    CURRENT_UUID="$(
        awk -v key="diskUUID" '
            index($0,key "=\"")==1 {
                x=substr($0,length(key)+3)
                sub(/\r$/, "", x)
                sub(/"$/, "", x)
                print x
                exit
            }
        ' "$CFG"
    )"

    CURRENT_ID="$(
        awk -v key="$CFG_KEY" '
            index($0,key "=\"")==1 {
                x=substr($0,length(key)+3)
                sub(/\r$/, "", x)
                sub(/"$/, "", x)
                print x
                exit
            }
        ' "$CFG"
    )"

    [ "$CURRENT_UUID" = "$UUID" ] || {
        fehler "diskUUID stimmt nicht mehr: $CFG"
        exit 1
    }

    [ "$CURRENT_ID" = "$OLD_ID" ] || {
        fehler "$CFG_KEY stimmt nicht mehr: $CFG"
        exit 1
    }

    CFGS[$COUNT]="$CFG"
    UUIDS[$COUNT]="$UUID"
    CFG_KEYS[$COUNT]="$CFG_KEY"
    OLD_IDS[$COUNT]="$OLD_ID"
    NEW_IDS[$COUNT]="$NEW_ID"
    SOURCES[$COUNT]="$SOURCE"
    SERIALS[$COUNT]="$SERIAL"
    PARENTS[$COUNT]="$PARENT"

    COUNT=$((COUNT + 1))
done < "$PLAN"

[ "$COUNT" -gt 0 ] || {
    fehler "Keine Migrationseintraege im Plan."
    exit 1
}

echo "OK: $COUNT Migrationseintraege vollstaendig vorgeprueft."

echo
echo "===== BACKUP-PHASE ====="

mkdir -p "$BACKUP_DIR" || {
    fehler "Backup-Verzeichnis konnte nicht erstellt werden."
    exit 1
}

for ((I=0; I<COUNT; I++)); do
    CFG="${CFGS[$I]}"
    BACKUP=""

    for ((J=0; J<I; J++)); do
        if [ "${CFGS[$J]}" = "$CFG" ]; then
            BACKUP="${BACKUPS[$J]}"
            break
        fi
    done

    if [ -n "$BACKUP" ]; then
        BACKUPS[$I]="$BACKUP"
        echo "OK: Backup bereits vorhanden: $(basename "$CFG")"
        continue
    fi

    BACKUP="$BACKUP_DIR/$(basename "$CFG")"

    [ ! -e "$BACKUP" ] || {
        fehler "Backup-Ziel existiert bereits: $BACKUP"
        exit 1
    }

    cp -p "$CFG" "$BACKUP" || {
        fehler "Backup fehlgeschlagen: $CFG"
        exit 1
    }

    ORIGINAL_HASH="$(sha256sum "$CFG" | awk '{print $1}')"
    BACKUP_HASH="$(sha256sum "$BACKUP" | awk '{print $1}')"

    [ "$ORIGINAL_HASH" = "$BACKUP_HASH" ] || {
        fehler "Backup nicht bytegleich: $CFG"
        exit 1
    }

    BACKUPS[$I]="$BACKUP"
done

sync

echo "OK: Alle Original-CFGs bytegleich gesichert."
echo
echo "===== WRITE-GATE ====="

if [ "${POOL_MIGRATION_WRITE_GATE:-0}" != "1" ]; then
    echo "STOP: Schreibphase ist in diesem Entwicklungsstand noch gesperrt."
    echo "Backup-Verzeichnis: $BACKUP_DIR"
    echo "ERGEBNIS: POOL_TRANSACTION_PREFLIGHT_OK"
    exit 0
fi

echo "WRITE-GATE: freigegeben."

rollback()
{
    echo "===== ROLLBACK ====="

    for ((R=0; R<COUNT; R++)); do
        CFG="${CFGS[$R]}"
        BACKUP="${BACKUPS[$R]:-}"
        BEREITS_WIEDERHERGESTELLT=0

        for ((J=0; J<R; J++)); do
            if [ "${CFGS[$J]}" = "$CFG" ]; then
                BEREITS_WIEDERHERGESTELLT=1
                break
            fi
        done

        [ "$BEREITS_WIEDERHERGESTELLT" -eq 0 ] || continue
        [ -n "$BACKUP" ] || continue
        [ -r "$BACKUP" ] || continue

        cp -p "$BACKUP" "$CFG" || {
            echo "ROLLBACK-FEHLER: $CFG" >&2
            continue
        }

        sync
        echo "ROLLBACK: $(basename "$CFG")"
    done
}

echo
echo "===== WRITE-PHASE ====="

for ((I=0; I<COUNT; I++)); do
    CFG="${CFGS[$I]}"
    UUID="${UUIDS[$I]}"
    CFG_KEY="${CFG_KEYS[$I]}"
    OLD_ID="${OLD_IDS[$I]}"
    NEW_ID="${NEW_IDS[$I]}"
    TMP="${CFG}.array-serial.$$"

    KEY_COUNT="$(
        awk -v key="$CFG_KEY" '
            {
                line=$0
                sub(/\r$/, "", line)
                if (index(line,key "=\"")==1)
                    n++
            }
            END { print n+0 }
        ' "$CFG"
    )"

    OLD_COUNT="$(
        awk -v key="$CFG_KEY" -v old="$OLD_ID" '
            {
                line=$0
                sub(/\r$/, "", line)
                if (line == key "=\"" old "\"")
                    n++
            }
            END { print n+0 }
        ' "$CFG"
    )"

    if [ "$KEY_COUNT" -ne 1 ] || [ "$OLD_COUNT" -ne 1 ]; then
        echo "STOP: $CFG_KEY ist nicht eindeutig: $CFG"
        rollback
        exit 1
    fi

    awk -v key="$CFG_KEY" -v old="$OLD_ID" -v new="$NEW_ID" '
        {
            cr=""
            line=$0

            if (sub(/\r$/, "", line))
                cr="\r"

            if (line == key "=\"" old "\"")
                line=key "=\"" new "\""

            printf "%s%s\n", line, cr
        }
    ' "$CFG" > "$TMP" || {
        rm -f "$TMP"
        echo "STOP: $CFG_KEY-Aenderung fehlgeschlagen: $CFG"
        rollback
        exit 1
    }

    BEFORE_NORMALIZED="$(
        awk -v key="$CFG_KEY" -v old="$OLD_ID" '
            {
                cr=""
                line=$0
                if (sub(/\r$/, "", line))
                    cr="\r"
                if (line == key "=\"" old "\"")
                    line=key "=\"__IDENTITY__\""
                printf "%s%s\n", line, cr
            }
        ' "$CFG" | sha256sum | awk '{print $1}'
    )"

    AFTER_NORMALIZED="$(
        awk -v key="$CFG_KEY" -v new="$NEW_ID" '
            {
                cr=""
                line=$0
                if (sub(/\r$/, "", line))
                    cr="\r"
                if (line == key "=\"" new "\"")
                    line=key "=\"__IDENTITY__\""
                printf "%s%s\n", line, cr
            }
        ' "$TMP" | sha256sum | awk '{print $1}'
    )"

    if [ "$BEFORE_NORMALIZED" != "$AFTER_NORMALIZED" ]; then
        rm -f "$TMP"
        echo "STOP: Neben $CFG_KEY wuerde weiterer Dateiinhalt geaendert: $CFG"
        rollback
        exit 1
    fi

    mv -f "$TMP" "$CFG" || {
        rm -f "$TMP"
        echo "STOP: Austausch fehlgeschlagen: $CFG"
        rollback
        exit 1
    }

    sync

    CURRENT_UUID="$(
        awk -v key="diskUUID" '
            index($0,key "=\"")==1 {
                x=substr($0,length(key)+3)
                sub(/\r$/, "", x)
                sub(/"$/, "", x)
                print x
                exit
            }
        ' "$CFG"
    )"

    CURRENT_ID="$(
        awk -v key="$CFG_KEY" '
            index($0,key "=\"")==1 {
                x=substr($0,length(key)+3)
                sub(/\r$/, "", x)
                sub(/"$/, "", x)
                print x
                exit
            }
        ' "$CFG"
    )"

    if [ "$CURRENT_UUID" != "$UUID" ] || [ "$CURRENT_ID" != "$NEW_ID" ]; then
        echo "STOP: Nachpruefung fehlgeschlagen: $CFG"
        rollback
        exit 1
    fi

    echo "OK: $(basename "$CFG")"
done

echo
echo "===== ABSCHLUSSPRUEFUNG ====="

for ((I=0; I<COUNT; I++)); do
    CFG="${CFGS[$I]}"
    CFG_KEY="${CFG_KEYS[$I]}"
    NEW_ID="${NEW_IDS[$I]}"

    CURRENT_ID="$(
        awk -v key="$CFG_KEY" '
            index($0,key "=\"")==1 {
                x=substr($0,length(key)+3)
                sub(/\r$/, "", x)
                sub(/"$/, "", x)
                print x
                exit
            }
        ' "$CFG"
    )"

    [ "$CURRENT_ID" = "$NEW_ID" ] || {
        echo "STOP: Finale $CFG_KEY-Pruefung fehlgeschlagen: $CFG"
        rollback
        exit 1
    }
done

sync

echo
echo "===== VERIFIZIERTEN MIGRATIONSPLAN SICHERN ====="

PERSISTENTER_PLAN="$BACKUP_DIR/migration-plan.tsv"
PERSISTENTER_PLAN_SHA="$BACKUP_DIR/migration-plan.tsv.sha256"

[ ! -e "$PERSISTENTER_PLAN" ] || {
    echo "STOP: Persistenter Migrationsplan existiert bereits: $PERSISTENTER_PLAN"
    rollback
    exit 1
}

[ ! -e "$PERSISTENTER_PLAN_SHA" ] || {
    echo "STOP: Persistenter Plan-Hash existiert bereits: $PERSISTENTER_PLAN_SHA"
    rollback
    exit 1
}

cp -p "$PLAN" "$PERSISTENTER_PLAN" || {
    echo "STOP: Verifizierter Migrationsplan konnte nicht gesichert werden."
    rollback
    exit 1
}

read -r PLAN_HASH _ < <(sha256sum "$PERSISTENTER_PLAN")

[ -n "$PLAN_HASH" ] || {
    echo "STOP: Hash des verifizierten Migrationsplans konnte nicht ermittelt werden."
    rollback
    exit 1
}

printf '%s  %s\n' "$PLAN_HASH" "$PERSISTENTER_PLAN" > "$PERSISTENTER_PLAN_SHA" || {
    echo "STOP: Hashdatei fuer verifizierten Migrationsplan konnte nicht geschrieben werden."
    rollback
    exit 1
}

sha256sum -c "$PERSISTENTER_PLAN_SHA" >/dev/null || {
    echo "STOP: Verifizierter Migrationsplan besteht die Hashpruefung nicht."
    rollback
    exit 1
}

sync

echo "OK: Verifizierter Migrationsplan persistent gesichert."
echo "Migrationsplan: $PERSISTENTER_PLAN"
echo "Migrationsplan-SHA: $PERSISTENTER_PLAN_SHA"

echo
echo "OK: Alle Pool-CFGs erfolgreich migriert."
echo "Backup-Verzeichnis: $BACKUP_DIR"
echo "ERGEBNIS: POOL_TRANSACTION_APPLY_OK"
exit 0
