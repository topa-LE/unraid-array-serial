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
declare -a OLD_IDS
declare -a NEW_IDS
declare -a BACKUPS

COUNT=0

echo "===== POOL-TRANSAKTION – PREFLIGHT ====="

while IFS="$(printf '\t')" read -r CFG UUID OLD_ID NEW_ID REST; do
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

    [ -n "$OLD_ID" ] || {
        fehler "alte diskId fehlt fuer $CFG"
        exit 1
    }

    [ -n "$NEW_ID" ] || {
        fehler "neue diskId fehlt fuer $CFG"
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
        awk -v key="diskId" '
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
        fehler "diskId stimmt nicht mehr: $CFG"
        exit 1
    }

    CFGS[$COUNT]="$CFG"
    UUIDS[$COUNT]="$UUID"
    OLD_IDS[$COUNT]="$OLD_ID"
    NEW_IDS[$COUNT]="$NEW_ID"

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
    OLD_ID="${OLD_IDS[$I]}"
    NEW_ID="${NEW_IDS[$I]}"
    TMP="${CFG}.array-serial.$$"

    python3 - "$CFG" "$TMP" "$OLD_ID" "$NEW_ID" <<'PYWRITE'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
old = sys.argv[3].encode()
new = sys.argv[4].encode()

data = src.read_bytes()

needle = b'diskId="' + old + b'"'
replacement = b'diskId="' + new + b'"'

if data.count(needle) != 1:
    raise SystemExit(42)

if data.count(b'diskId="') != 1:
    raise SystemExit(43)

dst.write_bytes(data.replace(needle, replacement, 1))
PYWRITE

    RC=$?

    if [ "$RC" -ne 0 ]; then
        rm -f "$TMP"
        echo "STOP: Bytegenaue diskId-Aenderung fehlgeschlagen: $CFG"
        rollback
        exit 1
    fi

    BEFORE_NORMALIZED="$(
        python3 - "$CFG" "$OLD_ID" <<'PYCHECK'
from pathlib import Path
import hashlib
import sys

data = Path(sys.argv[1]).read_bytes()
old = sys.argv[2].encode()
needle = b'diskId="' + old + b'"'
data = data.replace(needle, b'diskId="__IDENTITY__"', 1)
print(hashlib.sha256(data).hexdigest())
PYCHECK
    )"

    AFTER_NORMALIZED="$(
        python3 - "$TMP" "$NEW_ID" <<'PYCHECK'
from pathlib import Path
import hashlib
import sys

data = Path(sys.argv[1]).read_bytes()
new = sys.argv[2].encode()
needle = b'diskId="' + new + b'"'
data = data.replace(needle, b'diskId="__IDENTITY__"', 1)
print(hashlib.sha256(data).hexdigest())
PYCHECK
    )"

    if [ "$BEFORE_NORMALIZED" != "$AFTER_NORMALIZED" ]; then
        rm -f "$TMP"
        echo "STOP: Neben diskId wuerde weiterer Dateiinhalt geaendert: $CFG"
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
        awk -v key="diskId" '
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
    NEW_ID="${NEW_IDS[$I]}"

    CURRENT_ID="$(
        awk -v key="diskId" '
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
        echo "STOP: Finale diskId-Pruefung fehlgeschlagen: $CFG"
        rollback
        exit 1
    }
done

sync

echo "OK: Alle Pool-CFGs erfolgreich migriert."
echo "Backup-Verzeichnis: $BACKUP_DIR"
echo "ERGEBNIS: POOL_TRANSACTION_APPLY_OK"
exit 0
