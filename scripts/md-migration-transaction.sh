#!/bin/bash
set -euo pipefail

MODUS="${1:-}"
PLAN="${2:-}"

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_ID="$VERZEICHNIS/serial-id.sh"

usage() {
    echo "Verwendung:"
    echo "  /bin/bash $0 --prepare PLAN"
    echo "  /bin/bash $0 --apply   PLAN"
}

fehler() {
    echo
    echo "STOP: $*"
    exit 1
}

plan_laden() {
    [ -r "$PLAN" ] ||
        fehler "Migrationsplan fehlt oder ist nicht lesbar: $PLAN"

    declare -gA IDX=()
    declare -gA ALT=()
    declare -gA NEU=()
    declare -gA SERIAL=()
    declare -gA QUELLE=()
    declare -gA GESEHENE_IDX=()
    declare -ga SLOTS=()

    while IFS=$'\t' read -r SLOT SLOT_IDX ALTE_ID HW_SERIAL NEUE_ID SOURCE REST; do

        [ -n "$SLOT" ] || continue

        case "$SLOT" in
            \#*) continue ;;
        esac

        case "$SLOT_IDX" in
            ''|*[!0-9]*)
                fehler "Ungueltiger Slot-Index fuer $SLOT: $SLOT_IDX"
                ;;
        esac

        case "$SLOT" in
            parity)
                [ "$SLOT_IDX" -eq 0 ] ||
                    fehler "parity muss Slot-Index 0 verwenden."
                ;;
            parity2)
                [ "$SLOT_IDX" -eq 29 ] ||
                    fehler "parity2 muss Slot-Index 29 verwenden."
                ;;
            disk[0-9]*)
                ;;
            *)
                fehler "Nicht unterstuetzter Array-Slot: $SLOT"
                ;;
        esac

        [ -z "${GESEHENE_IDX[$SLOT_IDX]+x}" ] ||
            fehler "Slot-Index $SLOT_IDX ist mehrfach vorhanden."

        [ -n "$ALTE_ID" ] ||
            fehler "Alte ID fuer $SLOT fehlt."

        [ -n "$HW_SERIAL" ] ||
            fehler "Hardware-Seriennummer fuer $SLOT fehlt."

        [ -n "$NEUE_ID" ] ||
            fehler "Neue ID fuer $SLOT fehlt."

        case "$SOURCE" in
            ATA|USB_SAT|NVME|CACHE)
                ;;
            *)
                fehler "Ungueltige Identitaetsquelle fuer $SLOT: $SOURCE"
                ;;
        esac

        GESEHENE_IDX["$SLOT_IDX"]="$SLOT"
        IDX["$SLOT"]="$SLOT_IDX"
        ALT["$SLOT"]="$ALTE_ID"
        NEU["$SLOT"]="$NEUE_ID"
        SERIAL["$SLOT"]="$HW_SERIAL"
        QUELLE["$SLOT"]="$SOURCE"

        SLOTS+=("$SLOT")

    done < "$PLAN"

    [ "${#SLOTS[@]}" -gt 0 ] ||
        fehler "Migrationsplan enthaelt keine Array-Slots."
}

geraet_ermitteln() {
    local ERWARTETE_SERIAL="$1"
    local ERWARTETE_ID="$2"
    local ERWARTETE_QUELLE="$3"

    local DEV
    local AUSGABE
    local IST_SERIAL
    local IST_ID
    local IST_QUELLE
    local BOOT_DEV=""
    local -a TREFFER=()

    if [ -r /proc/mounts ]; then
        BOOT_DEV="$(
            awk '$2 == "/boot" { print $1; exit }' /proc/mounts 2>/dev/null |
            sed -E 's#^/dev/##; s#[0-9]+$##'
        )"
    fi

    for SYSDEV in /sys/class/block/sd* /sys/class/block/nvme*n*; do
        [ -e "$SYSDEV" ] || continue

        DEV="$(basename "$SYSDEV")"

        case "$DEV" in
            sd[a-z]|nvme[0-9]*n[0-9]*)
                ;;
            *)
                continue
                ;;
        esac

        [ "$DEV" = "$BOOT_DEV" ] && continue

        AUSGABE="$(
            timeout 20 /bin/bash "$SERIAL_ID" "/dev/$DEV" 2>/dev/null
        )" || continue

        IST_QUELLE="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
        )"

        IST_SERIAL="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
        )"

        IST_ID="$(
            printf '%s\n' "$AUSGABE" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
        )"

        [ "$IST_SERIAL" = "$ERWARTETE_SERIAL" ] || continue
        [ "$IST_ID" = "$ERWARTETE_ID" ] || continue
        [ "$IST_QUELLE" = "$ERWARTETE_QUELLE" ] || continue

        TREFFER+=("$DEV")
    done

    [ "${#TREFFER[@]}" -eq 1 ] ||
        fehler "Hardware nicht eindeutig aufloesbar: Serial=$ERWARTETE_SERIAL Treffer=${#TREFFER[@]}"

    printf '%s\n' "${TREFFER[0]}"
}

plan_anzeigen() {
    echo "===== VERIFIZIERTER MD-TRANSAKTIONSPLAN ====="
    echo

    local SLOT

    for SLOT in "${SLOTS[@]}"; do
        printf '%-10s idx=%-2s  Quelle=%-7s  %s -> %s\n' \
            "$SLOT" \
            "${IDX[$SLOT]}" \
            "${QUELLE[$SLOT]}" \
            "${ALT[$SLOT]}" \
            "${NEU[$SLOT]}"
    done
}

md_geraeteparameter() {
    local DEV="$1"
    local SLOT_IDX="$2"
    local PART=""
    local START=""
    local SIZE=""

    [ -b "/dev/$DEV" ] ||
        fehler "Blockgeraet existiert nicht: /dev/$DEV"

    case "$SLOT_IDX" in
        ''|*[!0-9]*)
            fehler "Ungueltiger Slot-Index fuer MD-Groesse: $SLOT_IDX"
            ;;
    esac

    case "$DEV" in
        sd[a-z])
            PART="${DEV}1"
            ;;
        nvme[0-9]*n[0-9]*)
            PART="${DEV}p1"
            ;;
        *)
            fehler "Nicht unterstuetztes Blockgeraet: /dev/$DEV"
            ;;
    esac

    [ -r "/sys/class/block/$PART/start" ] ||
        fehler "Partitionsstart fehlt fuer /dev/$DEV ($PART)."

    START="$(cat "/sys/class/block/$PART/start")"

    SIZE="$(
        sed -n \
            "s/^diskSize\\.${SLOT_IDX}=//p" \
            /proc/mdstat |
        head -n 1
    )"

    case "$START" in
        ''|*[!0-9]*)
            fehler "Ungueltiger Partitionsstart fuer /dev/$DEV: $START"
            ;;
    esac

    case "$SIZE" in
        ''|*[!0-9]*)
            fehler "Keine gueltige bestehende MD-Groesse fuer Slot $SLOT_IDX."
            ;;
    esac

    [ "$START" -gt 0 ] ||
        fehler "Partitionsstart fuer /dev/$DEV ist 0."

    [ "$SIZE" -gt 0 ] ||
        fehler "Bestehende MD-Groesse fuer Slot $SLOT_IDX ist 0."

    printf '%s\t%s\n' "$START" "$SIZE"
}


md_import_zeile() {
    local SLOT_IDX="$1"
    local DEV="$2"
    local START="$3"
    local SIZE="$4"
    local ID="$5"

    case "$SLOT_IDX" in
        ''|*[!0-9]*)
            fehler "Ungueltiger md-Slot-Index: $SLOT_IDX"
            ;;
    esac

    case "$DEV" in
        sd[a-z]|nvme[0-9]*n[0-9]*)
            ;;
        *)
            fehler "Ungueltiges md-Blockgeraet: $DEV"
            ;;
    esac

    case "$START" in
        ''|*[!0-9]*)
            fehler "Ungueltiger md-Startsektor: $START"
            ;;
    esac

    case "$SIZE" in
        ''|*[!0-9]*)
            fehler "Ungueltige md-Groesse: $SIZE"
            ;;
    esac

    [ -n "$ID" ] ||
        fehler "Leere md-Geraete-ID."

    printf 'import %s %s %s %s 0 %s\n' \
        "$SLOT_IDX" "$DEV" "$START" "$SIZE" "$ID"
}

prepare() {
    echo "===== MD-MIGRATION – PREPARE ====="
    echo

    plan_laden
    plan_anzeigen

    echo
    echo "===== GERAETEAUFLOESUNG ====="

    [ -r "$SERIAL_ID" ] ||
        fehler "serial-id.sh fehlt oder ist nicht lesbar: $SERIAL_ID"

    local SLOT
    local DEV
    local PARAMETER
    local START
    local SIZE

    for SLOT in "${SLOTS[@]}"; do
        DEV="$(
            geraet_ermitteln \
                "${SERIAL[$SLOT]}" \
                "${NEU[$SLOT]}" \
                "${QUELLE[$SLOT]}"
        )"

        PARAMETER="$(
            md_geraeteparameter                 "$DEV"                 "${IDX[$SLOT]}"
        )"
        START="${PARAMETER%%$'\t'*}"
        SIZE="${PARAMETER#*$'\t'}"

        printf '%-10s -> /dev/%-10s start=%-8s size=%s\n' \
            "$SLOT" "$DEV" "$START" "$SIZE"

        printf '           MD: '
        md_import_zeile \
            "${IDX[$SLOT]}" \
            "$DEV" \
            "$START" \
            "$SIZE" \
            "${NEU[$SLOT]}"
    done

    echo
    echo "===== STATUS ====="
    echo "Plan und aktuelle physische Hardware eindeutig verifiziert."
    echo "Blockgeraete sowie START/SIZE wurden frisch ermittelt."
    echo
    echo "MD-Importdaten wurden vollstaendig vorbereitet, aber NICHT ausgefuehrt."
    echo "Noch KEIN /proc/mdcmd beschrieben."
    echo "Noch KEINE super.dat veraendert."
    echo
    echo "ERGEBNIS: PREPARE_OK"
}


declare -A MD_SOLL_SIZE

transaktion_erzeugen() {
    local SLOT=""
    local DEV=""
    local PARAMETER=""
    local START=""
    local SIZE=""

    echo "===== VOLLSTAENDIGE MD-IMPORTSEQUENZ ====="
    echo

    for SLOT in "${SLOTS[@]}"; do
        DEV="$(
            geraet_ermitteln \
                "${SERIAL[$SLOT]}" \
                "${NEU[$SLOT]}" \
                "${QUELLE[$SLOT]}"
        )"

        PARAMETER="$(
            md_geraeteparameter \
                "$DEV" \
                "${IDX[$SLOT]}"
        )"

        IFS=$'\t' read -r START SIZE <<< "$PARAMETER"

        MD_SOLL_SIZE["${IDX[$SLOT]}"]="$SIZE"

        md_import_zeile \
            "${IDX[$SLOT]}" \
            "$DEV" \
            "$START" \
            "$SIZE" \
            "${NEU[$SLOT]}"
    done

    echo
    echo "OK: Alle geplanten Slots vollstaendig verifiziert."
}



transaktion_absichern() {
    local MD_STATE=""
    local BACKUP_DIR=""
    local ZEIT=""

    [ -r /proc/mdstat ] ||
        fehler "/proc/mdstat ist nicht lesbar."

    MD_STATE="$(
        sed -n 's/^mdState=//p' /proc/mdstat |
        head -n 1
    )"

    [ "$MD_STATE" = "STOPPED" ] ||
        fehler "Array muss fuer die Migration STOPPED sein. Aktuell: ${MD_STATE:-UNBEKANNT}"

    [ -f /boot/config/super.dat ] ||
        fehler "/boot/config/super.dat fehlt."

    ZEIT="$(date '+%Y%m%d-%H%M%S')"
    BACKUP_DIR="/boot/config/custom/array-serial/md-migration-backup-$ZEIT"

    mkdir -p "$BACKUP_DIR" ||
        fehler "Backup-Verzeichnis konnte nicht erstellt werden."

    cp -p /boot/config/super.dat "$BACKUP_DIR/super.dat" ||
        fehler "super.dat konnte nicht gesichert werden."

    sha256sum \
        /boot/config/super.dat \
        "$BACKUP_DIR/super.dat" \
        > "$BACKUP_DIR/super.dat.sha256" ||
        fehler "Backup-Pruefsumme konnte nicht erstellt werden."

    cmp -s \
        /boot/config/super.dat \
        "$BACKUP_DIR/super.dat" ||
        fehler "Backup von super.dat stimmt nicht mit dem Original ueberein."

    printf '%s\n' "$BACKUP_DIR"
}


transaktion_pruefen() {
    local SLOT=""
    local SLOT_IDX=""
    local ERWARTETE_ID=""
    local ERWARTETE_SIZE=""
    local AKTUELLE_ID=""
    local AKTUELLE_SIZE=""

    [ -r /proc/mdstat ] ||
        fehler "/proc/mdstat ist nicht lesbar."

    for SLOT in "${SLOTS[@]}"; do
        SLOT_IDX="${IDX[$SLOT]}"
        ERWARTETE_ID="${NEU[$SLOT]}"

        ERWARTETE_SIZE="${MD_SOLL_SIZE[$SLOT_IDX]:-}"

        case "$ERWARTETE_SIZE" in
            ''|*[!0-9]*)
                fehler "Nachkontrolle: gespeicherte Soll-Groesse fuer Slot $SLOT_IDX fehlt."
                ;;
        esac

        AKTUELLE_ID="$(
            sed -n \
                "s/^diskId\\.${SLOT_IDX}=//p" \
                /proc/mdstat |
            head -n 1
        )"

        AKTUELLE_SIZE="$(
            sed -n \
                "s/^diskSize\\.${SLOT_IDX}=//p" \
                /proc/mdstat |
            head -n 1
        )"

        [ -n "$AKTUELLE_ID" ] ||
            fehler "Nachkontrolle: diskId.$SLOT_IDX fehlt."

        [ "$AKTUELLE_ID" = "$ERWARTETE_ID" ] ||
            fehler "Nachkontrolle: Slot $SLOT_IDX hat unerwartete ID: $AKTUELLE_ID"

        case "$AKTUELLE_SIZE" in
            ''|*[!0-9]*)
                fehler "Nachkontrolle: diskSize.$SLOT_IDX ist ungueltig."
                ;;
        esac

        [ "$AKTUELLE_SIZE" -gt 0 ] ||
            fehler "Nachkontrolle: diskSize.$SLOT_IDX ist 0."

        [ "$AKTUELLE_SIZE" = "$ERWARTETE_SIZE" ] ||
            fehler "Nachkontrolle: Groesse von Slot $SLOT_IDX hat sich geaendert."

        printf 'OK: %-10s idx=%-3s ID=%s size=%s\n' \
            "$SLOT" \
            "$SLOT_IDX" \
            "$AKTUELLE_ID" \
            "$AKTUELLE_SIZE"
    done
}

md_befehl_schreiben() {
    local BEFEHL="$1"

    [ -n "$BEFEHL" ] ||
        fehler "Leerer MD-Befehl."

    [ -w /proc/mdcmd ] ||
        fehler "/proc/mdcmd ist nicht schreibbar."

    printf '%s\n' "$BEFEHL" > /proc/mdcmd ||
        fehler "MD-Befehl fehlgeschlagen: $BEFEHL"
}

md_imports_schreiben() {
    local SLOT_IDX=""
    local SLOT=""
    local DEV=""
    local PARAMETER=""
    local START=""
    local SIZE=""
    local BEFEHL=""
    local GEFUNDEN=""

    # Unraid-Reihenfolge aus dem aufgezeichneten MD-Ablauf:
    # Parity1 (0), Parity2 (29), danach Daten-Slots 1..28.
    for SLOT_IDX in 0 29 $(seq 1 28); do
        GEFUNDEN=""

        for SLOT in "${SLOTS[@]}"; do
            if [ "${IDX[$SLOT]}" = "$SLOT_IDX" ]; then
                GEFUNDEN="$SLOT"
                break
            fi
        done

        if [ -z "$GEFUNDEN" ]; then
            md_befehl_schreiben "import $SLOT_IDX"
            continue
        fi

        DEV="$(
            geraet_ermitteln \
                "${SERIAL[$GEFUNDEN]}" \
                "${NEU[$GEFUNDEN]}" \
                "${QUELLE[$GEFUNDEN]}"
        )"

        PARAMETER="$(
            md_geraeteparameter \
                "$DEV" \
                "$SLOT_IDX"
        )"

        IFS=$'\t' read -r START SIZE <<< "$PARAMETER"

        BEFEHL="$(
            md_import_zeile \
                "$SLOT_IDX" \
                "$DEV" \
                "$START" \
                "$SIZE" \
                "${NEU[$GEFUNDEN]}"
        )"

        md_befehl_schreiben "$BEFEHL"
    done
}


md_persistenz_abschliessen() {
    # Legacy-Pfad:
    # Ein direkter NEW_ARRAY-Start ist hier absichtlich gesperrt.
    #
    # Parity-Policy und NEW_ARRAY duerfen ausschliesslich durch den
    # transaktionsgebundenen Phase-B-Pfad entschieden werden.
    # Dadurch kann dieser historische Helfer keine gueltige Parity
    # versehentlich als neu aufzubauend behandeln.
    fehler "Direkter Persistenzabschluss ist gesperrt. NEW_ARRAY darf nur ueber Phase B gestartet werden."
}





RESUME_STATE="/boot/config/custom/array-serial/md-migration-resume.state"


transaktionsmanifest_schreiben() {
    local PLAN="$1"
    local BACKUP_DIR="$2"
    local MANIFEST=""
    local MANIFEST_TMP=""
    local MANIFEST_HASH=""
    local SLOT_IDX=""
    local SLOT=""
    local CURRENT_ID=""
    local SOLL_SERIAL=""
    local SOLL_SOURCE=""
    local SOLL_ID=""
    local PLAN_SLOT=""
    local PLAN_IDX=""
    local PLAN_ALT=""
    local PLAN_SERIAL=""
    local PLAN_NEU=""
    local PLAN_QUELLE=""
    local PLAN_TREFFER=0
    local DEV=""
    local PARAMS=""
    local START=""
    local SIZE=""

    [ -r "$PLAN" ] ||
        fehler "Migrationsplan fuer Transaktionsmanifest nicht lesbar."

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer Transaktionsmanifest fehlt."

    MANIFEST="$BACKUP_DIR/md-transaction.tsv"
    MANIFEST_TMP="${MANIFEST}.tmp"

    [ ! -e "$MANIFEST" ] ||
        fehler "Transaktionsmanifest existiert bereits: $MANIFEST"

    : > "$MANIFEST_TMP" ||
        fehler "Temporaeres Transaktionsmanifest konnte nicht erstellt werden."

    # Exakte Unraid-Slotreihenfolge:
    # parity1=0, parity2=29, danach data1..data28.
    for SLOT_IDX in 0 29 $(seq 1 28); do
        CURRENT_ID="$(sed -n "s/^diskId\\.${SLOT_IDX}=//p" /proc/mdstat | head -n1)"

        # Leere Slots gehoeren nicht ins persistente Manifest.
        [ -n "$CURRENT_ID" ] || continue

        case "$SLOT_IDX" in
            0)
                SLOT="parity"
                ;;
            29)
                SLOT="parity2"
                ;;
            *)
                SLOT="disk${SLOT_IDX}"
                ;;
        esac

        SOLL_SERIAL=""
        SOLL_SOURCE=""
        SOLL_ID=""
        PLAN_TREFFER=0

        while IFS=$'\t' read -r \
            PLAN_SLOT PLAN_IDX PLAN_ALT PLAN_SERIAL PLAN_NEU PLAN_QUELLE
        do
            [ -n "$PLAN_SLOT" ] || continue

            if [ "$PLAN_IDX" = "$SLOT_IDX" ]; then
                PLAN_TREFFER=$((PLAN_TREFFER + 1))
                SOLL_SERIAL="$PLAN_SERIAL"
                SOLL_SOURCE="$PLAN_QUELLE"
                SOLL_ID="$PLAN_NEU"
            fi
        done < "$PLAN"

        [ "$PLAN_TREFFER" -le 1 ] ||
            fehler "Mehrere Planeintraege fuer Slotindex $SLOT_IDX."

        if [ "$PLAN_TREFFER" -eq 0 ]; then
            # Unveraenderter belegter Slot:
            # Geraet ueber seine aktuell von Unraid gefuehrte ID suchen
            # und anschliessend seine echte Hardwareidentitaet sichern.
            DEV=""

            for SYS in /sys/class/block/sd* /sys/class/block/nvme*n*; do
                [ -e "$SYS" ] || continue

                CANDIDATE="$(basename "$SYS")"

                case "$CANDIDATE" in
                    sd[a-z]|nvme[0-9]*n[0-9]*)
                        ;;
                    *)
                        continue
                        ;;
                esac

                OUT="$(timeout 20 /bin/bash "$SERIAL_ID" "/dev/$CANDIDATE" 2>/dev/null)" ||
                    continue

                CANDIDATE_ID="$(printf '%s\n' "$OUT" |
                    sed -n 's/^ID_SERIAL=//p' | head -n1)"

                if [ "$CANDIDATE_ID" = "$CURRENT_ID" ]; then
                    [ -z "$DEV" ] ||
                        fehler "Aktuelle ID $CURRENT_ID ist nicht eindeutig."

                    DEV="$CANDIDATE"
                    SOLL_SERIAL="$(printf '%s\n' "$OUT" |
                        sed -n 's/^ID_SERIAL_SHORT=//p' | head -n1)"
                    SOLL_SOURCE="$(printf '%s\n' "$OUT" |
                        sed -n 's/^IDENTITY_SOURCE=//p' | head -n1)"
                    SOLL_ID="$CANDIDATE_ID"
                fi
            done

            [ -n "$DEV" ] ||
                fehler "Unveraenderter Slot $SLOT konnte nicht ueber $CURRENT_ID aufgeloest werden."

            [ -n "$SOLL_SERIAL" ] &&
            [ -n "$SOLL_SOURCE" ] &&
            [ -n "$SOLL_ID" ] ||
                fehler "Hardwareidentitaet fuer unveraenderten Slot $SLOT unvollstaendig."
        else
            DEV="$(geraet_ermitteln "$SOLL_SERIAL" "$SOLL_ID" "$SOLL_SOURCE")" ||
                fehler "Geraet fuer Migrationsslot $SLOT konnte nicht eindeutig ermittelt werden."
        fi

        PARAMS="$(md_geraeteparameter "$DEV" "$SLOT_IDX")" ||
            fehler "MD-Parameter fuer Slot $SLOT konnten nicht ermittelt werden."

        IFS=$'\t' read -r START SIZE <<< "$PARAMS"

        [ -n "$START" ] && [ -n "$SIZE" ] ||
            fehler "Unvollstaendige MD-Parameter fuer Slot $SLOT."

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$SLOT_IDX" \
            "$SLOT" \
            "$SOLL_SERIAL" \
            "$SOLL_SOURCE" \
            "$SOLL_ID" \
            "$START" \
            "$SIZE" \
            >> "$MANIFEST_TMP" ||
            fehler "Transaktionsmanifest konnte nicht geschrieben werden."

    done

    [ -s "$MANIFEST_TMP" ] ||
        fehler "Transaktionsmanifest ist leer."

    mv "$MANIFEST_TMP" "$MANIFEST" ||
        fehler "Transaktionsmanifest konnte nicht aktiviert werden."

    MANIFEST_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"

    printf '%s  %s\n' "$MANIFEST_HASH" "$MANIFEST" \
        > "$BACKUP_DIR/md-transaction.tsv.sha256" ||
        fehler "SHA256-Datei des Transaktionsmanifests konnte nicht geschrieben werden."

    sha256sum -c "$BACKUP_DIR/md-transaction.tsv.sha256" >/dev/null ||
        fehler "Transaktionsmanifest konnte nicht verifiziert werden."

    sync

    echo "OK: Vollstaendiges MD-Transaktionsmanifest persistent geschrieben."
    echo "Manifest: $MANIFEST"
    echo "Belegte Slots: $(wc -l < "$MANIFEST")"
    echo "Manifest-SHA256: $MANIFEST_HASH"
}

resume_state_schreiben() {
    local PLAN="$1"
    local BACKUP_DIR="$2"
    local PLAN_HASH=""
    local MANIFEST=""
    local MANIFEST_HASH=""
    local STATE_TMP=""

    [ -r "$PLAN" ] ||
        fehler "Migrationsplan fuer Resume-State nicht lesbar: $PLAN"

    [ -d "$BACKUP_DIR" ] ||
        fehler "Transaktionsverzeichnis fuer Resume-State fehlt: $BACKUP_DIR"

    [ -f "$BACKUP_DIR/super.dat" ] ||
        fehler "super.dat-Backup fuer Resume-State fehlt."

    [ ! -e "$RESUME_STATE" ] ||
        fehler "Es existiert bereits ein Resume-State: $RESUME_STATE"

    PLAN_HASH="$(sha256sum "$PLAN" | awk '{print $1}')"

    [ -n "$PLAN_HASH" ] ||
        fehler "SHA256 des Migrationsplans konnte nicht ermittelt werden."

    MANIFEST="$BACKUP_DIR/md-transaction.tsv"

    [ -r "$MANIFEST" ] ||
        fehler "Transaktionsmanifest fuer Resume-State fehlt."

    [ -r "$BACKUP_DIR/md-transaction.tsv.sha256" ] ||
        fehler "SHA256-Datei des Transaktionsmanifests fehlt."

    sha256sum -c "$BACKUP_DIR/md-transaction.tsv.sha256" >/dev/null ||
        fehler "Transaktionsmanifest ist vor Resume-State ungueltig."

    MANIFEST_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"

    [ -n "$MANIFEST_HASH" ] ||
        fehler "SHA256 des Transaktionsmanifests konnte nicht ermittelt werden."

    cp -p "$PLAN" "$BACKUP_DIR/migration-plan.tsv" ||
        fehler "Migrationsplan konnte nicht ins Transaktionsverzeichnis kopiert werden."

    echo "$PLAN_HASH  $BACKUP_DIR/migration-plan.tsv" \
        > "$BACKUP_DIR/migration-plan.tsv.sha256"

    sha256sum -c "$BACKUP_DIR/migration-plan.tsv.sha256" >/dev/null ||
        fehler "Gesicherter Migrationsplan konnte nicht verifiziert werden."

    STATE_TMP="${RESUME_STATE}.tmp"

    {
        printf 'VERSION=1\n'
        printf 'PHASE=AWAITING_REBOOT\n'
        printf 'BACKUP_DIR=%s\n' "$BACKUP_DIR"
        printf 'PLAN=%s\n' "$BACKUP_DIR/migration-plan.tsv"
        printf 'PLAN_SHA256=%s\n' "$PLAN_HASH"
        printf 'MANIFEST=%s\n' "$MANIFEST"
        printf 'MANIFEST_SHA256=%s\n' "$MANIFEST_HASH"
    } > "$STATE_TMP" ||
        fehler "Temporaerer Resume-State konnte nicht geschrieben werden."

    mv "$STATE_TMP" "$RESUME_STATE" ||
        fehler "Resume-State konnte nicht persistent aktiviert werden."

    sync

    echo "OK: Persistenter Resume-State geschrieben."
    echo "Resume-State: $RESUME_STATE"
    echo "Phase: AWAITING_REBOOT"
    echo "Plan-SHA256: $PLAN_HASH"
    echo "Manifest-SHA256: $MANIFEST_HASH"
}

resume_state_laden() {
    local VERSION=""
    local PHASE=""
    local BACKUP_DIR=""
    local PLAN=""
    local PLAN_SHA256=""
    local MANIFEST=""
    local MANIFEST_SHA256=""
    local IST_HASH=""
    local IST_MANIFEST_HASH=""
    local KEY=""
    local VALUE=""

    [ -r "$RESUME_STATE" ] ||
        fehler "Resume-State nicht lesbar: $RESUME_STATE"

    while IFS='=' read -r KEY VALUE; do
        case "$KEY" in
            VERSION)
                VERSION="$VALUE"
                ;;
            PHASE)
                PHASE="$VALUE"
                ;;
            BACKUP_DIR)
                BACKUP_DIR="$VALUE"
                ;;
            PLAN)
                PLAN="$VALUE"
                ;;
            PLAN_SHA256)
                PLAN_SHA256="$VALUE"
                ;;
            MANIFEST)
                MANIFEST="$VALUE"
                ;;
            MANIFEST_SHA256)
                MANIFEST_SHA256="$VALUE"
                ;;
            "")
                ;;
            *)
                fehler "Unbekannter Eintrag im Resume-State: $KEY"
                ;;
        esac
    done < "$RESUME_STATE"

    [ "$VERSION" = "1" ] ||
        fehler "Nicht unterstuetzte Resume-State-Version: ${VERSION:-LEER}"

    [ "$PHASE" = "AWAITING_REBOOT" ] ||
        fehler "Ungueltige Resume-Phase: ${PHASE:-LEER}"

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Resume-Backup-Verzeichnis fehlt."

    [ -r "$BACKUP_DIR/super.dat" ] ||
        fehler "Original-super.dat-Backup fehlt."

    [ -n "$PLAN" ] && [ -r "$PLAN" ] ||
        fehler "Gesicherter Resume-Migrationsplan fehlt."

    [ "$PLAN" = "$BACKUP_DIR/migration-plan.tsv" ] ||
        fehler "Resume-Plan liegt nicht im erwarteten Transaktionsverzeichnis."

    [ -n "$PLAN_SHA256" ] ||
        fehler "PLAN_SHA256 fehlt im Resume-State."

    IST_HASH="$(sha256sum "$PLAN" | awk '{print $1}')"

    [ "$IST_HASH" = "$PLAN_SHA256" ] ||
        fehler "Gesicherter Migrationsplan stimmt nicht mit PLAN_SHA256 ueberein."

    [ -r "$BACKUP_DIR/migration-plan.tsv.sha256" ] ||
        fehler "Gesicherte SHA256-Datei des Migrationsplans fehlt."

    sha256sum -c "$BACKUP_DIR/migration-plan.tsv.sha256" >/dev/null ||
        fehler "SHA256-Verifikation des gesicherten Migrationsplans fehlgeschlagen."

    [ -n "$MANIFEST" ] && [ -r "$MANIFEST" ] ||
        fehler "Gesichertes Resume-Transaktionsmanifest fehlt."

    [ "$MANIFEST" = "$BACKUP_DIR/md-transaction.tsv" ] ||
        fehler "Resume-Manifest liegt nicht im erwarteten Transaktionsverzeichnis."

    [ -n "$MANIFEST_SHA256" ] ||
        fehler "MANIFEST_SHA256 fehlt im Resume-State."

    IST_MANIFEST_HASH="$(sha256sum "$MANIFEST" | awk '{print $1}')"

    [ "$IST_MANIFEST_HASH" = "$MANIFEST_SHA256" ] ||
        fehler "Transaktionsmanifest stimmt nicht mit MANIFEST_SHA256 ueberein."

    [ -r "$BACKUP_DIR/md-transaction.tsv.sha256" ] ||
        fehler "SHA256-Datei des Resume-Transaktionsmanifests fehlt."

    sha256sum -c "$BACKUP_DIR/md-transaction.tsv.sha256" >/dev/null ||
        fehler "SHA256-Verifikation des Resume-Transaktionsmanifests fehlgeschlagen."

    printf '%s\t%s\t%s\n' "$BACKUP_DIR" "$PLAN" "$MANIFEST"
}


PHASE_A_ROLLBACK_AKTIV=0
PHASE_A_BACKUP_DIR=""

phase_a_rollback() {
    local RC=$?
    local PARKED_SUPER=""

    [ "$PHASE_A_ROLLBACK_AKTIV" = "1" ] || return "$RC"

    trap - EXIT
    PHASE_A_ROLLBACK_AKTIV=0

    echo >&2
    echo "===== PHASE-A-ROLLBACK =====" >&2

    PARKED_SUPER="$PHASE_A_BACKUP_DIR/super.dat.pre-new-config"

    if [ ! -e /boot/config/super.dat ]; then
        if [ -f "$PARKED_SUPER" ]; then
            cp -p "$PARKED_SUPER" /boot/config/super.dat || {
                echo "FEHLER: super.dat konnte nicht wiederhergestellt werden." >&2
                return 1
            }
        elif [ -f "$PHASE_A_BACKUP_DIR/super.dat" ]; then
            cp -p "$PHASE_A_BACKUP_DIR/super.dat" /boot/config/super.dat || {
                echo "FEHLER: super.dat konnte nicht aus Backup wiederhergestellt werden." >&2
                return 1
            }
        else
            echo "FEHLER: Keine wiederherstellbare Original-super.dat vorhanden." >&2
            return 1
        fi
    fi

    if [ -f "$PHASE_A_BACKUP_DIR/super.dat" ]; then
        cmp -s /boot/config/super.dat "$PHASE_A_BACKUP_DIR/super.dat" || {
            echo "FEHLER: Wiederhergestellte super.dat ist nicht bytegleich zum Backup." >&2
            return 1
        }
    fi

    rm -f "$RESUME_STATE" "${RESUME_STATE}.tmp"
    sync

    echo "OK: Phase A wurde persistent zurueckgerollt." >&2
    echo "OK: Resume-State entfernt." >&2

    return "$RC"
}

phase_a_rollback_scharfschalten() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer Phase-A-Rollback fehlt."

    [ -f "$BACKUP_DIR/super.dat" ] ||
        fehler "Original-super.dat-Backup fuer Phase-A-Rollback fehlt."

    PHASE_A_BACKUP_DIR="$BACKUP_DIR"
    PHASE_A_ROLLBACK_AKTIV=1
    trap phase_a_rollback EXIT
}

phase_a_rollback_entschaerfen() {
    PHASE_A_ROLLBACK_AKTIV=0
    PHASE_A_BACKUP_DIR=""
    trap - EXIT
}

phase_a_vorbereiten() {
    local PLAN="$1"
    local BACKUP_DIR="$2"

    [ -n "$PLAN" ] ||
        fehler "Migrationsplan fuer Phase A fehlt."

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer Phase A fehlt."

    [ -f /boot/config/super.dat ] ||
        fehler "Phase A erwartet eine aktive super.dat."

    phase_a_rollback_scharfschalten "$BACKUP_DIR"

    transaktionsmanifest_schreiben "$PLAN" "$BACKUP_DIR"

    resume_state_schreiben "$PLAN" "$BACKUP_DIR"

    new_config_vorbereiten "$BACKUP_DIR"

    [ -r "$RESUME_STATE" ] ||
        fehler "Resume-State fehlt nach Phase-A-Vorbereitung."

    [ ! -e /boot/config/super.dat ] ||
        fehler "super.dat ist nach Phase A weiterhin aktiv."

    sync

    phase_a_rollback_entschaerfen

    echo "OK: Phase A persistent vorbereitet."
    echo "Resume-State vorhanden."
    echo "Original-super.dat geparkt."
    echo "Naechster erforderlicher Schritt: Reboot."
}


phase_b_manifest_pruefen() {
    local MANIFEST="$1"
    local SLOT_IDX=""
    local SLOT=""
    local SERIAL=""
    local SOURCE=""
    local NEWID=""
    local START=""
    local SIZE=""
    local DEV=""
    local ANZAHL=0

    [ -r "$MANIFEST" ] ||
        fehler "Phase-B-Transaktionsmanifest nicht lesbar."

    while IFS=$'\t' read -r \
        SLOT_IDX SLOT SERIAL SOURCE NEWID START SIZE
    do
        [ -n "$SLOT_IDX" ] || continue

        case "$SLOT_IDX" in
            0|29|[1-9]|1[0-9]|2[0-8])
                ;;
            *)
                fehler "Ungueltiger Slotindex im Phase-B-Manifest: $SLOT_IDX"
                ;;
        esac

        [ -n "$SLOT" ] &&
        [ -n "$SERIAL" ] &&
        [ -n "$SOURCE" ] &&
        [ -n "$NEWID" ] &&
        [ -n "$START" ] &&
        [ -n "$SIZE" ] ||
            fehler "Unvollstaendige Zeile im Phase-B-Manifest fuer Slotindex $SLOT_IDX."

        case "$SOURCE" in
            ATA|USB_SAT|NVME|CACHE)
                ;;
            *)
                fehler "Ungueltige Identity-Quelle im Phase-B-Manifest: $SOURCE"
                ;;
        esac

        case "$START" in
            ''|*[!0-9]*)
                fehler "Ungueltiger Partitionsstart fuer $SLOT: $START"
                ;;
        esac

        case "$SIZE" in
            ''|*[!0-9]*)
                fehler "Ungueltige MD-Groesse fuer $SLOT: $SIZE"
                ;;
        esac

        [ "$START" -gt 0 ] ||
            fehler "Partitionsstart fuer $SLOT ist nicht groesser als 0."

        [ "$SIZE" -gt 0 ] ||
            fehler "MD-Groesse fuer $SLOT ist nicht groesser als 0."

        # Nach dem Reboot niemals sdX aus Phase A vertrauen.
        # Physisches Laufwerk erneut ueber Hardwareidentitaet aufloesen.
        DEV="$(geraet_ermitteln "$SERIAL" "$NEWID" "$SOURCE")" ||
            fehler "Phase B konnte $SLOT nicht eindeutig neu aufloesen."

        [ -b "/dev/$DEV" ] ||
            fehler "Phase-B-Geraet fuer $SLOT existiert nicht: /dev/$DEV"

        local PART=""
        local AKTUELLER_START=""

        case "$DEV" in
            sd[a-z])
                PART="${DEV}1"
                ;;
            nvme[0-9]*n[0-9]*)
                PART="${DEV}p1"
                ;;
            *)
                fehler "Phase B kennt das Partitionsschema fuer $DEV nicht."
                ;;
        esac

        [ -r "/sys/class/block/$PART/start" ] ||
            fehler "Phase B kann Partitionsstart fuer $SLOT nicht lesen: $PART"

        AKTUELLER_START="$(cat "/sys/class/block/$PART/start")"

        case "$AKTUELLER_START" in
            ''|*[!0-9]*)
                fehler "Aktueller Partitionsstart fuer $SLOT ist ungueltig."
                ;;
        esac

        [ "$AKTUELLER_START" = "$START" ] ||
            fehler "Partitionsstart fuer $SLOT hat sich geaendert: erwartet=$START aktuell=$AKTUELLER_START"

        printf 'PHASE_B_SLOT\t%s\t%s\t%s\t%s\t%s\n' \
            "$SLOT_IDX" "$SLOT" "$DEV" "$START" "$SIZE"

        printf 'PHASE_B_IMPORT\timport %s %s %s %s 0 %s\n' \
            "$SLOT_IDX" "$DEV" "$START" "$SIZE" "$NEWID"

        ANZAHL=$((ANZAHL + 1))

    done < "$MANIFEST"

    [ "$ANZAHL" -gt 0 ] ||
        fehler "Phase-B-Manifest enthaelt keine belegten Slots."

    echo "OK: Phase-B-Manifest vollstaendig gegen aktuelle Hardware aufgeloest."
    echo "Belegte Slots: $ANZAHL"
}



phase_b_importdatei_erzeugen() {
    local MANIFEST="$1"
    local IMPORTDATEI="$2"
    local TMP="${IMPORTDATEI}.tmp"
    local AUFGELOEST=""
    local SLOT_IDX=""
    local SLOT=""
    local SERIAL=""
    local SOURCE=""
    local NEWID=""
    local START=""
    local SIZE=""
    local DEV=""
    local PART=""
    local AKTUELLER_START=""
    local IDX=""
    local TREFFER=0

    [ -r "$MANIFEST" ] ||
        fehler "Manifest fuer Phase-B-Importdatei nicht lesbar."

    [ -n "$IMPORTDATEI" ] ||
        fehler "Pfad fuer Phase-B-Importdatei fehlt."

    AUFGELOEST="${IMPORTDATEI}.resolved"

    : > "$AUFGELOEST" ||
        fehler "Temporaere Phase-B-Aufloesung konnte nicht erstellt werden."

    # Zuerst ALLE belegten Slots vollstaendig pruefen und neu aufloesen.
    # Bis dieser Durchlauf erfolgreich beendet ist, wird nichts geschrieben.
    while IFS=$'\t' read -r \
        SLOT_IDX SLOT SERIAL SOURCE NEWID START SIZE
    do
        [ -n "$SLOT_IDX" ] || continue

        case "$SLOT_IDX" in
            0|29|[1-9]|1[0-9]|2[0-8])
                ;;
            *)
                rm -f "$AUFGELOEST"
                fehler "Ungueltiger Slotindex im Phase-B-Manifest: $SLOT_IDX"
                ;;
        esac

        [ -n "$SLOT" ] &&
        [ -n "$SERIAL" ] &&
        [ -n "$SOURCE" ] &&
        [ -n "$NEWID" ] &&
        [ -n "$START" ] &&
        [ -n "$SIZE" ] || {
            rm -f "$AUFGELOEST"
            fehler "Unvollstaendige Phase-B-Manifestzeile fuer Slot $SLOT_IDX."
        }

        case "$SOURCE" in
            ATA|USB_SAT|NVME|CACHE)
                ;;
            *)
                rm -f "$AUFGELOEST"
                fehler "Ungueltige Identity-Quelle fuer $SLOT: $SOURCE"
                ;;
        esac

        DEV="$(geraet_ermitteln "$SERIAL" "$NEWID" "$SOURCE")" || {
            rm -f "$AUFGELOEST"
            fehler "Phase B konnte $SLOT nicht eindeutig neu aufloesen."
        }

        case "$DEV" in
            sd[a-z])
                PART="${DEV}1"
                ;;
            nvme[0-9]*n[0-9]*)
                PART="${DEV}p1"
                ;;
            *)
                rm -f "$AUFGELOEST"
                fehler "Unbekanntes Partitionsschema fuer $DEV."
                ;;
        esac

        [ -r "/sys/class/block/$PART/start" ] || {
            rm -f "$AUFGELOEST"
            fehler "Partitionsstart fuer $SLOT nicht lesbar."
        }

        AKTUELLER_START="$(cat "/sys/class/block/$PART/start")"

        [ "$AKTUELLER_START" = "$START" ] || {
            rm -f "$AUFGELOEST"
            fehler "Partitionsstart fuer $SLOT stimmt nicht mehr: erwartet=$START aktuell=$AKTUELLER_START"
        }

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$SLOT_IDX" "$DEV" "$START" "$SIZE" "$NEWID" \
            >> "$AUFGELOEST" || {
                rm -f "$AUFGELOEST"
                fehler "Phase-B-Aufloesung konnte nicht gespeichert werden."
            }

    done < "$MANIFEST"

    [ -s "$AUFGELOEST" ] || {
        rm -f "$AUFGELOEST"
        fehler "Phase-B-Aufloesung ist leer."
    }

    : > "$TMP" || {
        rm -f "$AUFGELOEST"
        fehler "Temporaere Phase-B-Importdatei konnte nicht erstellt werden."
    }

    # Erst nach erfolgreicher Gesamtpruefung die komplette Importfolge bauen.
    for IDX in 0 29 $(seq 1 28); do
        TREFFER="$(awk -F '\t' -v idx="$IDX" '$1 == idx {n++} END {print n+0}' "$AUFGELOEST")"

        [ "$TREFFER" -le 1 ] || {
            rm -f "$AUFGELOEST" "$TMP"
            fehler "Mehrfachbelegung fuer Slotindex $IDX in Phase-B-Aufloesung."
        }

        if [ "$TREFFER" -eq 0 ]; then
            printf 'import %s\n' "$IDX" >> "$TMP" || {
                rm -f "$AUFGELOEST" "$TMP"
                fehler "Leerer Import fuer Slotindex $IDX konnte nicht geschrieben werden."
            }
        else
            awk -F '\t' -v idx="$IDX" '
                $1 == idx {
                    printf "import %s %s %s %s 0 %s\n",
                           $1, $2, $3, $4, $5
                }
            ' "$AUFGELOEST" >> "$TMP" || {
                rm -f "$AUFGELOEST" "$TMP"
                fehler "Belegter Import fuer Slotindex $IDX konnte nicht geschrieben werden."
            }
        fi
    done

    [ "$(wc -l < "$TMP")" -eq 30 ] || {
        rm -f "$AUFGELOEST" "$TMP"
        fehler "Phase-B-Importdatei enthaelt nicht exakt 30 Importbefehle."
    }

    mv "$TMP" "$IMPORTDATEI" || {
        rm -f "$AUFGELOEST" "$TMP"
        fehler "Phase-B-Importdatei konnte nicht aktiviert werden."
    }

    rm -f "$AUFGELOEST"

    local IMPORT_HASH=""
    local HASHDATEI="${IMPORTDATEI}.sha256"

    IMPORT_HASH="$(sha256sum "$IMPORTDATEI" | awk '{print $1}')"

    [ -n "$IMPORT_HASH" ] ||
        fehler "SHA256 der Phase-B-Importdatei konnte nicht ermittelt werden."

    printf '%s  %s\n' "$IMPORT_HASH" "$IMPORTDATEI" > "$HASHDATEI" ||
        fehler "SHA256-Datei der Phase-B-Importdatei konnte nicht geschrieben werden."

    sha256sum -c "$HASHDATEI" >/dev/null ||
        fehler "Phase-B-Importdatei konnte nach dem Schreiben nicht verifiziert werden."

    sync

    echo "OK: Vollstaendige Phase-B-Importdatei erzeugt."
    echo "Importdatei: $IMPORTDATEI"
    echo "Importbefehle: $(wc -l < "$IMPORTDATEI")"
    echo "Import-SHA256: $IMPORT_HASH"
}




PHASE_B_ROLLBACK_AKTIV=0
PHASE_B_BACKUP_DIR=""
PHASE_B_WRITE_GESTARTET=0

phase_b_rollback() {
    local RC=$?
    local BACKUP_DIR="$PHASE_B_BACKUP_DIR"
    local ORIGINAL=""
    local RESTORE_TMP="/boot/config/super.dat.phase-b-rollback.tmp"

    [ "$PHASE_B_ROLLBACK_AKTIV" -eq 1 ] || return "$RC"

    echo
    echo "===== PHASE-B-ROLLBACK ====="
    echo "FEHLER: Phase B wurde nicht erfolgreich abgeschlossen."

    if [ "$PHASE_B_WRITE_GESTARTET" -eq 1 ]; then
        echo "WARNUNG: MD-Runtime kann bereits teilweise veraendert sein."
        echo "Nach Wiederherstellung der Persistenz ist ein Reboot erforderlich."
    fi

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || {
        echo "ROLLBACK-FEHLER: Backup-Verzeichnis fehlt."
        return "$RC"
    }

    ORIGINAL="$BACKUP_DIR/super.dat"

    [ -r "$ORIGINAL" ] || {
        echo "ROLLBACK-FEHLER: Original-super.dat fehlt: $ORIGINAL"
        return "$RC"
    }

    rm -f "$RESTORE_TMP"

    cp -p "$ORIGINAL" "$RESTORE_TMP" || {
        echo "ROLLBACK-FEHLER: super.dat konnte nicht vorbereitet werden."
        rm -f "$RESTORE_TMP"
        return "$RC"
    }

    cmp -s "$ORIGINAL" "$RESTORE_TMP" || {
        echo "ROLLBACK-FEHLER: Vorbereitete super.dat ist nicht bytegleich."
        rm -f "$RESTORE_TMP"
        return "$RC"
    }

    mv -f "$RESTORE_TMP" /boot/config/super.dat || {
        echo "ROLLBACK-FEHLER: Original-super.dat konnte nicht aktiviert werden."
        rm -f "$RESTORE_TMP"
        return "$RC"
    }

    cmp -s "$ORIGINAL" /boot/config/super.dat || {
        echo "ROLLBACK-FEHLER: Wiederhergestellte super.dat ist nicht bytegleich."
        return "$RC"
    }

    sync

    echo "OK: Original-super.dat bytegleich wiederhergestellt."

    if [ -r "$RESUME_STATE" ]; then
        echo "OK: Resume-State bleibt zur Fehlerdiagnose erhalten."
    else
        echo "WARNUNG: Resume-State ist nicht mehr vorhanden."
    fi

    echo "ERGEBNIS: PHASE_B_ROLLBACK_AKTIV"
    echo "ERFORDERLICH: Reboot vor einem weiteren Migrationsversuch."

    return "$RC"
}

phase_b_rollback_scharfschalten() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Phase-B-Rollback kann ohne Backup-Verzeichnis nicht aktiviert werden."

    [ -r "$BACKUP_DIR/super.dat" ] ||
        fehler "Phase-B-Rollback findet Original-super.dat nicht."

    PHASE_B_BACKUP_DIR="$BACKUP_DIR"
    PHASE_B_WRITE_GESTARTET=0
    PHASE_B_ROLLBACK_AKTIV=1

    trap phase_b_rollback EXIT

    echo "OK: Phase-B-Rollback scharf."
}

phase_b_write_markieren() {
    [ "$PHASE_B_ROLLBACK_AKTIV" -eq 1 ] ||
        fehler "Phase-B-Schreibphase darf ohne scharfen Rollback nicht beginnen."

    PHASE_B_WRITE_GESTARTET=1
}

phase_b_rollback_entschaerfen() {
    PHASE_B_ROLLBACK_AKTIV=0
    PHASE_B_WRITE_GESTARTET=0
    PHASE_B_BACKUP_DIR=""

    trap - EXIT

    echo "OK: Phase-B-Rollback entschaerft."
}

phase_b_importdatei_schreiben() {
    local IMPORTDATEI="$1"
    local HASHDATEI="${IMPORTDATEI}.sha256"
    local ZEILE=""
    local NR=0
    local IDX=""
    local ERWARTET=""

    [ -r "$IMPORTDATEI" ] ||
        fehler "Phase-B-Importdatei nicht lesbar: $IMPORTDATEI"

    [ -r "$HASHDATEI" ] ||
        fehler "SHA256-Datei der Phase-B-Importdatei fehlt: $HASHDATEI"

    sha256sum -c "$HASHDATEI" >/dev/null ||
        fehler "Phase-B-Importdatei stimmt nicht mit ihrer SHA256-Datei ueberein."

    [ "$(wc -l < "$IMPORTDATEI")" -eq 30 ] ||
        fehler "Phase-B-Importdatei enthaelt nicht exakt 30 Befehle."

    # Vor dem ersten Schreibzugriff jede einzelne Zeile nochmals
    # syntaktisch und in der erwarteten Unraid-Slotreihenfolge pruefen.
    while IFS= read -r ZEILE; do
        NR=$((NR + 1))

        case "$NR" in
            1)
                ERWARTET=0
                ;;
            2)
                ERWARTET=29
                ;;
            *)
                ERWARTET=$((NR - 2))
                ;;
        esac

        case "$ZEILE" in
            "import $ERWARTET")
                ;;
            "import $ERWARTET "*)
                set -- $ZEILE

                [ "$#" -eq 7 ] ||
                    fehler "Ungueltiger belegter Import in Zeile $NR."

                [ "$1" = "import" ] ||
                    fehler "Ungueltiger Befehl in Zeile $NR."

                [ "$2" = "$ERWARTET" ] ||
                    fehler "Falscher Slotindex in Zeile $NR."

                case "$3" in
                    sd[a-z]|nvme[0-9]*n[0-9]*)
                        ;;
                    *)
                        fehler "Ungueltiges Blockgeraet in Zeile $NR: $3"
                        ;;
                esac

                case "$4" in
                    ''|*[!0-9]*)
                        fehler "Ungueltiger Partitionsstart in Zeile $NR."
                        ;;
                esac

                case "$5" in
                    ''|*[!0-9]*)
                        fehler "Ungueltige MD-Groesse in Zeile $NR."
                        ;;
                esac

                [ "$4" -gt 0 ] ||
                    fehler "Partitionsstart in Zeile $NR ist 0."

                [ "$5" -gt 0 ] ||
                    fehler "MD-Groesse in Zeile $NR ist 0."

                [ "$6" = "0" ] ||
                    fehler "Ungueltiges Import-Flag in Zeile $NR."

                [ -n "$7" ] ||
                    fehler "Disk-ID in Zeile $NR fehlt."
                ;;
            *)
                fehler "Importreihenfolge oder Syntax in Zeile $NR ungueltig."
                ;;
        esac
    done < "$IMPORTDATEI"

    [ "$NR" -eq 30 ] ||
        fehler "Phase-B-Vorpruefung hat nicht exakt 30 Befehle gesehen."

    [ -w /proc/mdcmd ] ||
        fehler "/proc/mdcmd ist fuer Phase B nicht schreibbar."

    # Erst ab hier findet der erste MD-Schreibzugriff statt.
    NR=0

    while IFS= read -r ZEILE; do
        NR=$((NR + 1))

        echo "MD-WRITE $NR/30: $ZEILE"

        md_befehl_schreiben "$ZEILE" ||
            fehler "Phase-B-MD-Import fehlgeschlagen in Zeile $NR."
    done < "$IMPORTDATEI"

    echo "OK: Alle 30 verifizierten Phase-B-Importbefehle geschrieben."
}



phase_b_nachpruefen() {
    local MANIFEST="$1"
    local SLOT_IDX=""
    local SLOT=""
    local SERIAL=""
    local SOURCE=""
    local NEWID=""
    local START=""
    local SIZE=""
    local AKT_ID=""
    local AKT_SIZE=""
    local MANIFEST_ANZAHL=0
    local MD_ANZAHL=""
    local MD_MISSING=""
    local MD_NEW=""
    local SUPER_HASH=""

    echo "===== PHASE B – NACHPRUEFUNG ====="

    [ -r "$MANIFEST" ] ||
        fehler "Phase-B-Nachpruefung: Manifest nicht lesbar."

    [ -r /boot/config/super.dat ] ||
        fehler "Phase-B-Nachpruefung: neue super.dat fehlt."

    [ -s /boot/config/super.dat ] ||
        fehler "Phase-B-Nachpruefung: neue super.dat ist leer."

    SUPER_HASH="$(sha256sum /boot/config/super.dat | awk '{print $1}')"

    [ -n "$SUPER_HASH" ] ||
        fehler "Phase-B-Nachpruefung: SHA256 der neuen super.dat fehlt."

    while IFS=$'\t' read -r \
        SLOT_IDX SLOT SERIAL SOURCE NEWID START SIZE
    do
        [ -n "$SLOT_IDX" ] || continue

        MANIFEST_ANZAHL=$((MANIFEST_ANZAHL + 1))

        AKT_ID="$(awk -F= -v KEY="diskId.$SLOT_IDX" '$1==KEY{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
        AKT_SIZE="$(awk -F= -v KEY="diskSize.$SLOT_IDX" '$1==KEY{print substr($0,index($0,"=")+1)}' /proc/mdstat)"

        [ "$AKT_ID" = "$NEWID" ] ||
            fehler "Phase-B-Nachpruefung: ID fuer $SLOT stimmt nicht: erwartet=$NEWID aktuell=$AKT_ID"

        [ "$AKT_SIZE" = "$SIZE" ] ||
            fehler "Phase-B-Nachpruefung: MD-Groesse fuer $SLOT stimmt nicht: erwartet=$SIZE aktuell=$AKT_SIZE"

        echo "OK: $SLOT / Slot $SLOT_IDX"
        echo "    ID:   $AKT_ID"
        echo "    SIZE: $AKT_SIZE"

    done < "$MANIFEST"

    [ "$MANIFEST_ANZAHL" -gt 0 ] ||
        fehler "Phase-B-Nachpruefung: Manifest enthaelt keine belegten Slots."

    MD_ANZAHL="$(awk -F= '$1=="mdNumDisks"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
    MD_MISSING="$(awk -F= '$1=="mdNumMissing"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
    MD_NEW="$(awk -F= '$1=="mdNumNew"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"

    case "$MD_ANZAHL" in
        ''|*[!0-9]*)
            fehler "Phase-B-Nachpruefung: mdNumDisks ist ungueltig."
            ;;
    esac

    case "$MD_MISSING" in
        ''|*[!0-9]*)
            fehler "Phase-B-Nachpruefung: mdNumMissing ist ungueltig."
            ;;
    esac

    case "$MD_NEW" in
        ''|*[!0-9]*)
            fehler "Phase-B-Nachpruefung: mdNumNew ist ungueltig."
            ;;
    esac

    # mdNumDisks ist kein verlaesslicher Zaehler der tatsaechlich
    # belegten Array-Slots. Entscheidend ist die reale diskId-Belegung.
    SLOT_IDX=0
    while [ "$SLOT_IDX" -le 29 ]; do
        AKT_ID="$(awk -F= -v KEY="diskId.$SLOT_IDX" '$1==KEY{print substr($0,index($0,"=")+1)}' /proc/mdstat)"

        if [ -n "$AKT_ID" ]; then
            if ! awk -F '\t' -v IDX="$SLOT_IDX" '$1 == IDX { found=1 } END { exit(found ? 0 : 1) }' "$MANIFEST"; then
                fehler "Phase-B-Nachpruefung: unerwartet belegter Slot $SLOT_IDX mit ID $AKT_ID."
            fi
        fi

        SLOT_IDX=$((SLOT_IDX + 1))
    done

    [ "$MD_MISSING" -eq 0 ] ||
        fehler "Phase-B-Nachpruefung: mdNumMissing=$MD_MISSING."

    [ "$MD_NEW" -eq 0 ] ||
        fehler "Phase-B-Nachpruefung: mdNumNew=$MD_NEW."

    echo
    echo "Neue super.dat SHA256: $SUPER_HASH"
    echo "Belegte Manifest-Slots: $MANIFEST_ANZAHL"
    echo "mdNumDisks: $MD_ANZAHL"
    echo "mdNumMissing: $MD_MISSING"
    echo "mdNumNew: $MD_NEW"
    echo
    echo "ERGEBNIS: PHASE_B_NACHPRUEFUNG_OK"
}

phase_b_transaktion_ausfuehren() {
    local RESUME=""
    local BACKUP_DIR=""
    local PLAN=""
    local MANIFEST=""
    local IMPORTDATEI=""

    echo "===== PHASE B – TRANSAKTION ====="

    # Nach dem Phase-A-Reboot muss der MD-Runtimezustand leer sein.
    # Unraid darf dabei selbst bereits eine neue leere super.dat
    # angelegt haben.
    local MD_STATE=""
    local MD_NUM_DISKS=""
    local MD_NUM_MISSING=""
    local MD_NUM_NEW=""
    local SLOT_IDX=""
    local SLOT_ID=""

    MD_STATE="$(awk -F= '$1=="mdState"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
    MD_NUM_DISKS="$(awk -F= '$1=="mdNumDisks"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
    MD_NUM_MISSING="$(awk -F= '$1=="mdNumMissing"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"
    MD_NUM_NEW="$(awk -F= '$1=="mdNumNew"{print substr($0,index($0,"=")+1)}' /proc/mdstat)"

    case "$MD_STATE" in
        STOPPED)
            [ "$MD_NUM_DISKS" = "0" ] ||
                fehler "Phase B verweigert STOPPED-Zustand: mdNumDisks ist nicht 0."

            [ "$MD_NUM_NEW" = "0" ] ||
                fehler "Phase B verweigert STOPPED-Zustand: mdNumNew ist nicht 0."
            ;;
        NEW_ARRAY)
            case "$MD_NUM_DISKS" in
                ''|*[!0-9]*)
                    fehler "Phase B verweigert NEW_ARRAY-Zustand: mdNumDisks ist ungueltig."
                    ;;
            esac

            [ "$MD_NUM_NEW" = "$MD_NUM_DISKS" ] ||
                fehler "Phase B verweigert NEW_ARRAY-Zustand: nicht alle Disks sind NEW."
            ;;
        *)
            fehler "Phase B verweigert Start: unzulaessiger mdState $MD_STATE."
            ;;
    esac

    [ "$MD_NUM_MISSING" = "0" ] ||
        fehler "Phase B verweigert Start: mdNumMissing ist nicht 0."

    SLOT_IDX=0
    while [ "$SLOT_IDX" -le 29 ]; do
        SLOT_ID="$(awk -F= -v KEY="diskId.$SLOT_IDX" '$1==KEY{print substr($0,index($0,"=")+1)}' /proc/mdstat)"

        [ -z "$SLOT_ID" ] ||
            fehler "Phase B verweigert Start: diskId.$SLOT_IDX ist bereits belegt."

        SLOT_IDX=$((SLOT_IDX + 1))
    done

    echo "OK: Leerer MD-New-Config-Zustand fuer Phase B bestaetigt."

    if [ -e /boot/config/super.dat ]; then
        [ -r /boot/config/super.dat ] ||
            fehler "Phase B verweigert Start: aktive super.dat ist nicht lesbar."

        [ -s /boot/config/super.dat ] ||
            fehler "Phase B verweigert Start: aktive super.dat ist leer."

        echo "INFO: Unraid hat bereits eine leere aktive super.dat erzeugt."
    else
        echo "INFO: Aktive super.dat ist noch nicht vorhanden."
    fi

    [ -r "$RESUME_STATE" ] ||
        fehler "Phase B verweigert Start: Resume-State fehlt."

    RESUME="$(resume_state_laden)" ||
        fehler "Phase-B-Resume-State konnte nicht verifiziert werden."

    IFS=$'\t' read -r BACKUP_DIR PLAN MANIFEST <<EOF
$RESUME
EOF

    [ -n "$BACKUP_DIR" ] &&
    [ -n "$PLAN" ] &&
    [ -n "$MANIFEST" ] ||
        fehler "Phase-B-Resume-State ist unvollstaendig."

    [ -r "$BACKUP_DIR/super.dat" ] ||
        fehler "Phase B findet Original-super.dat im Backup nicht."

    [ -r "$PLAN" ] ||
        fehler "Phase B findet persistierten Migrationsplan nicht."

    [ -r "$MANIFEST" ] ||
        fehler "Phase B findet persistiertes Transaktionsmanifest nicht."

    IMPORTDATEI="$BACKUP_DIR/phase-b-imports.tsv"

    echo "Backup:   $BACKUP_DIR"
    echo "Plan:     $PLAN"
    echo "Manifest: $MANIFEST"

    echo
    echo "===== PHASE B – KOMPLETTE VORPRUEFUNG ====="

    echo
    echo "===== PHASE B – MD-AUSGANGSZUSTAND ====="

    [ -r "/boot/config/custom/array-serial/md-migration-state-bridge.sh" ] ||
        fehler "MD-State-Bridge fehlt oder ist nicht ausfuehrbar."

    /bin/bash "/boot/config/custom/array-serial/md-migration-state-bridge.sh" \
        --validate "$BACKUP_DIR" ||
        fehler "Transaktionsgebundener MD-Ausgangszustand ist ungueltig."

    echo "OK: MD-Ausgangszustand gehoert verifiziert zu dieser Transaktion."

    echo
    echo "===== PHASE B – HARDWAREPRUEFUNG ====="

    # Diese Funktion löst ALLE belegten Slots gegen die aktuelle
    # Hardware neu auf und prüft u.a. den Partitionsstart.
    phase_b_manifest_pruefen "$MANIFEST" ||
        fehler "Phase-B-Hardwarepruefung fehlgeschlagen."

    echo
    echo "===== PHASE B – IMPORTFOLGE ERZEUGEN ====="

    rm -f \
        "$IMPORTDATEI" \
        "${IMPORTDATEI}.tmp" \
        "${IMPORTDATEI}.resolved" \
        "${IMPORTDATEI}.sha256"

    phase_b_importdatei_erzeugen "$MANIFEST" "$IMPORTDATEI" ||
        fehler "Phase-B-Importfolge konnte nicht erzeugt werden."

    [ -r "$IMPORTDATEI" ] &&
    [ -r "${IMPORTDATEI}.sha256" ] ||
        fehler "Phase-B-Importfolge oder SHA256 fehlt."

    sha256sum -c "${IMPORTDATEI}.sha256" >/dev/null ||
        fehler "Phase-B-Importfolge ist vor Schreibbeginn nicht mehr bytegleich."

    echo
    echo "===== PHASE B – ROLLBACK SCHARF ====="

    phase_b_rollback_scharfschalten "$BACKUP_DIR"

    # Ab hier muss jeder Fehler den persistenten Rollback auslösen.
    phase_b_write_markieren

    echo
    echo "===== PHASE B – MD-IMPORTS ====="

    phase_b_importdatei_schreiben "$IMPORTDATEI" ||
        fehler "Phase-B-Importfolge konnte nicht vollstaendig geschrieben werden."

    echo
    echo "===== PHASE B – NEW_ARRAY ====="

    local MD_STATE_DATEI="$BACKUP_DIR/md-array-state"
    local PARITY_POLICY=""

    PARITY_POLICY="$(
        /bin/bash "/boot/config/custom/array-serial/md-migration-array-state.sh" \
            --parity-policy "$MD_STATE_DATEI"
    )" ||
        fehler "Parity-Policy konnte nicht sicher gelesen werden."

    case "$PARITY_POLICY" in
        PRESERVE)
            echo "Parity-Policy: $PARITY_POLICY"
            echo "Aktion: NEW_ARRAY mit als gueltig bestaetigter vorhandener Parity."

            # Unraid verwendet invalidslot=99 fuer:
            # "Parity is already valid".
            # Dieser Pfad ist nur erreichbar, nachdem das komplette
            # Transaktionsmanifest gegen Hardware, Slots, Partitionsstart
            # und Groesse erfolgreich verifiziert wurde.
            md_befehl_schreiben "set invalidslot 99" ||
                fehler "Phase-B invalidslot=99 fehlgeschlagen."

            md_befehl_schreiben "start NEW_ARRAY" ||
                fehler "Phase-B start NEW_ARRAY mit Parity-Preserve fehlgeschlagen."
            ;;
        SYNC)
            echo "Parity-Policy: $PARITY_POLICY"
            echo "Aktion: NEW_ARRAY mit sicherer Parity-Synchronisation."

            md_befehl_schreiben "start NEW_ARRAY" ||
                fehler "Phase-B start NEW_ARRAY fehlgeschlagen."
            ;;
        *)
            fehler "Nicht unterstuetzte Parity-Policy: ${PARITY_POLICY:-LEER}"
            ;;
    esac

    echo
    echo "===== PHASE B – NACHPRUEFUNG ====="

    phase_b_nachpruefen "$MANIFEST" ||
        fehler "Phase-B-Nachpruefung fehlgeschlagen."

    echo
    echo "===== PHASE B – NEUE PERSISTENZ SICHERN ====="

    local NEUER_SUPER_HASH=""
    local NEUER_SUPER_HASHDATEI="$BACKUP_DIR/super.dat.after-migration.sha256"

    NEUER_SUPER_HASH="$(sha256sum /boot/config/super.dat | awk '{print $1}')"

    [ -n "$NEUER_SUPER_HASH" ] ||
        fehler "SHA256 der neuen super.dat konnte nicht ermittelt werden."

    printf '%s  %s\n'         "$NEUER_SUPER_HASH"         "/boot/config/super.dat"         > "$NEUER_SUPER_HASHDATEI" ||
        fehler "SHA256 der neuen super.dat konnte nicht persistent gespeichert werden."

    sha256sum -c "$NEUER_SUPER_HASHDATEI" >/dev/null ||
        fehler "Neue super.dat stimmt nicht mit gespeichertem SHA256 ueberein."

    sync

    echo "Neue super.dat SHA256: $NEUER_SUPER_HASH"
    echo "OK: Neue Persistenz verifiziert."

    echo
    echo "===== PHASE B – TRANSAKTION ABSCHLIESSEN ====="

    # Erst JETZT darf der EXIT-Rollback abgeschaltet werden.
    phase_b_rollback_entschaerfen

    rm -f "$RESUME_STATE" "${RESUME_STATE}.tmp" ||
        fehler "Resume-State konnte nach erfolgreicher Migration nicht entfernt werden."

    sync

    [ ! -e "$RESUME_STATE" ] ||
        fehler "Resume-State ist nach Abschluss noch vorhanden."

    echo
    echo "ERGEBNIS: PHASE_B_TRANSAKTION_OK"
    echo "Neue super.dat ist vorhanden und vollstaendig verifiziert."
    echo "Alle Manifest-Slots stimmen."
    echo "Rollback ist entschaerft."
    echo "Resume-State ist entfernt."

    return 0
}

test_phase_b_rollback() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Phase-B-Rollback-Testverzeichnis fehlt."

    [ -r "$BACKUP_DIR/super.dat" ] ||
        fehler "Original-super.dat im Testverzeichnis fehlt."

    [ -r /boot/config/super.dat ] ||
        fehler "Aktive super.dat fehlt vor Rollback-Test."

    cmp -s "$BACKUP_DIR/super.dat" /boot/config/super.dat ||
        fehler "Aktive super.dat stimmt vor Rollback-Test nicht mit Backup ueberein."

    echo "===== PHASE-B-ROLLBACK-TEST ====="

    phase_b_rollback_scharfschalten "$BACKUP_DIR"

    rm -f /boot/config/super.dat ||
        fehler "Aktive super.dat konnte fuer Rollback-Test nicht entfernt werden."

    [ ! -e /boot/config/super.dat ] ||
        fehler "Aktive super.dat ist im Rollback-Test noch vorhanden."

    echo "OK: Aktive super.dat kontrolliert entfernt."
    echo "TEST: Jetzt wird absichtlich ein Fehler ausgeloest."

    false

    # Darf niemals erreicht werden.
    phase_b_rollback_entschaerfen
    return 0
}
test_phase_b_importdatei() {
    local BACKUP_DIR="$1"
    local MANIFEST=""
    local IMPORTDATEI=""

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Phase-B-Testverzeichnis fehlt: $BACKUP_DIR"

    MANIFEST="$BACKUP_DIR/md-transaction.tsv"
    IMPORTDATEI="$BACKUP_DIR/phase-b-imports.test"

    [ -r "$MANIFEST" ] ||
        fehler "Manifest fuer Phase-B-Importdateitest fehlt."

    [ -r "$BACKUP_DIR/md-transaction.tsv.sha256" ] ||
        fehler "Manifest-SHA256 fuer Phase-B-Importdateitest fehlt."

    sha256sum -c "$BACKUP_DIR/md-transaction.tsv.sha256" >/dev/null ||
        fehler "Manifest-SHA256 fuer Phase-B-Importdateitest ungueltig."

    rm -f "$IMPORTDATEI" "${IMPORTDATEI}.tmp" "${IMPORTDATEI}.resolved"

    echo "===== PHASE-B-IMPORTDATEI-TEST ====="

    phase_b_importdatei_erzeugen "$MANIFEST" "$IMPORTDATEI"

    echo
    echo "===== IMPORTDATEI ====="
    cat "$IMPORTDATEI"

    echo
    echo "ERGEBNIS: PHASE_B_IMPORTDATEI_TEST_OK"
}
test_phase_b_manifest() {
    local BACKUP_DIR="$1"
    local MANIFEST=""

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] ||
        fehler "Phase-B-Testverzeichnis fehlt: $BACKUP_DIR"

    MANIFEST="$BACKUP_DIR/md-transaction.tsv"

    [ -r "$BACKUP_DIR/migration-plan.tsv" ] ||
        fehler "Gesicherter Migrationsplan fuer Phase-B-Test fehlt."

    [ -r "$BACKUP_DIR/migration-plan.tsv.sha256" ] ||
        fehler "Plan-SHA256 fuer Phase-B-Test fehlt."

    sha256sum -c "$BACKUP_DIR/migration-plan.tsv.sha256" >/dev/null ||
        fehler "Plan-SHA256 fuer Phase-B-Test ungueltig."

    [ -r "$MANIFEST" ] ||
        fehler "Manifest fuer Phase-B-Test fehlt."

    [ -r "$BACKUP_DIR/md-transaction.tsv.sha256" ] ||
        fehler "Manifest-SHA256 fuer Phase-B-Test fehlt."

    sha256sum -c "$BACKUP_DIR/md-transaction.tsv.sha256" >/dev/null ||
        fehler "Manifest-SHA256 fuer Phase-B-Test ungueltig."

    echo "===== PHASE-B-DRY-RUN ====="
    echo "Transaktionsverzeichnis: $BACKUP_DIR"

    phase_b_manifest_pruefen "$MANIFEST"

    echo "ERGEBNIS: PHASE_B_DRY_RUN_OK"
}
phase_b_fortsetzen() {
    local RESUME_INFO=""
    local BACKUP_DIR=""
    local PLAN=""

    [ ! -e /boot/config/super.dat ] ||
        fehler "Phase B verweigert Start: aktive super.dat vorhanden."

    RESUME_INFO="$(resume_state_laden)" ||
        fehler "Resume-State konnte nicht verifiziert werden."

    IFS=$'\t' read -r BACKUP_DIR PLAN <<< "$RESUME_INFO"

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis aus Resume-State fehlt."

    [ -n "$PLAN" ] ||
        fehler "Migrationsplan aus Resume-State fehlt."

    echo "OK: Phase B wurde eindeutig verifiziert."
    echo "Backup: $BACKUP_DIR"
    echo "Plan: $PLAN"

    # Noch absichtlich KEINE MD-Schreibphase.
    # Freigabe erfolgt erst nach separatem Phase-B-Kontrolltest.
}

ROLLBACK_AKTIV=0
ROLLBACK_BACKUP_DIR=""

persistenz_rollback() {
    local RC=$?
    local PARKED_SUPER=""

    [ "$ROLLBACK_AKTIV" = "1" ] || return "$RC"

    trap - EXIT
    ROLLBACK_AKTIV=0

    echo >&2
    echo "===== PERSISTENZ-ROLLBACK =====" >&2

    PARKED_SUPER="$ROLLBACK_BACKUP_DIR/super.dat.pre-new-config"

    if [ ! -f "$PARKED_SUPER" ]; then
        echo "FEHLER: Geparkte Original-super.dat fehlt." >&2
        echo "STOP: Manueller Eingriff erforderlich." >&2
        return 1
    fi

    if [ -e /boot/config/super.dat ]; then
        rm -f /boot/config/super.dat || {
            echo "FEHLER: Neue/teilweise super.dat konnte nicht entfernt werden." >&2
            return 1
        }
    fi

    cp -p "$PARKED_SUPER" /boot/config/super.dat || {
        echo "FEHLER: Original-super.dat konnte nicht wiederhergestellt werden." >&2
        return 1
    }

    cmp -s /boot/config/super.dat "$PARKED_SUPER" || {
        echo "FEHLER: Wiederhergestellte super.dat ist nicht bytegleich." >&2
        return 1
    }

    sync

    echo "OK: Urspruengliche super.dat persistent wiederhergestellt." >&2
    echo "HINWEIS: MD-Runtime kann veraendert sein; vor weiterer Nutzung ist ein Reboot erforderlich." >&2

    return "$RC"
}

rollback_scharfschalten() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer Rollback fehlt."

    [ -f "$BACKUP_DIR/super.dat" ] ||
        fehler "Rollback-Backup fehlt: $BACKUP_DIR/super.dat"

    ROLLBACK_BACKUP_DIR="$BACKUP_DIR"
    ROLLBACK_AKTIV=1
    trap persistenz_rollback EXIT
}

rollback_entschaerfen() {
    ROLLBACK_AKTIV=0
    ROLLBACK_BACKUP_DIR=""
    trap - EXIT
}

new_config_vorbereiten() {
    local BACKUP_DIR="$1"
    local PARKED_SUPER=""

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer New-Config-Umschaltung fehlt."

    [ -f "$BACKUP_DIR/super.dat" ] ||
        fehler "Verifiziertes super.dat-Backup fehlt: $BACKUP_DIR/super.dat"

    [ -f /boot/config/super.dat ] ||
        fehler "Aktive super.dat fehlt bereits."

    cmp -s /boot/config/super.dat "$BACKUP_DIR/super.dat" ||
        fehler "Aktive super.dat stimmt nicht mehr mit dem verifizierten Backup ueberein."

    PARKED_SUPER="$BACKUP_DIR/super.dat.pre-new-config"

    [ ! -e "$PARKED_SUPER" ] ||
        fehler "Parkdatei existiert bereits: $PARKED_SUPER"

    mv /boot/config/super.dat "$PARKED_SUPER" ||
        fehler "Aktive super.dat konnte nicht sicher geparkt werden."

    [ ! -e /boot/config/super.dat ] ||
        fehler "Aktive super.dat ist nach dem Parken weiterhin vorhanden."

    cmp -s "$PARKED_SUPER" "$BACKUP_DIR/super.dat" ||
        fehler "Geparkte super.dat stimmt nicht mit dem Backup ueberein."

    echo "OK: Aktive super.dat kontrolliert aus dem Persistenzpfad genommen."
    echo "Geparkt: $PARKED_SUPER"
}

md_transaktion_ausfuehren() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis fuer MD-Transaktion fehlt."

    echo "===== MD-SCHREIBPHASE ====="
    echo

    echo "===== 0. NEW-CONFIG-SICHERHEIT ====="

    rollback_scharfschalten "$BACKUP_DIR"
    new_config_vorbereiten "$BACKUP_DIR"

    echo
    echo "===== 1. VOLLSTAENDIGE IMPORTSEQUENZ ====="
    md_imports_schreiben ||
        fehler "MD-Importsequenz fehlgeschlagen."

    echo
    echo "===== 2. PERSISTENZABSCHLUSS ====="
    md_persistenz_abschliessen ||
        fehler "MD-Persistenzabschluss fehlgeschlagen."

    echo
    echo "===== 3. NACHKONTROLLE ====="
    transaktion_pruefen ||
        fehler "MD-Nachkontrolle fehlgeschlagen."

    rollback_entschaerfen

    echo
    echo "ERGEBNIS: MD_TRANSAKTION_OK"
}


test_phase_a() {
    local PLAN="$1"
    local TESTDIR=""
    local VOR_HASH=""
    local NACH_HASH=""

    [ -r "$PLAN" ] ||
        fehler "Migrationsplan fuer Phase-A-Test nicht lesbar."

    [ -f /boot/config/super.dat ] ||
        fehler "Phase-A-Test erwartet aktive super.dat."

    VOR_HASH="$(sha256sum /boot/config/super.dat | awk '{print $1}')"

    TESTDIR="/boot/config/custom/array-serial/phase-a-test-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$TESTDIR" ||
        fehler "Phase-A-Testverzeichnis konnte nicht erstellt werden."

    cp -p /boot/config/super.dat "$TESTDIR/super.dat" ||
        fehler "Phase-A-Testbackup konnte nicht erstellt werden."

    cmp -s /boot/config/super.dat "$TESTDIR/super.dat" ||
        fehler "Phase-A-Testbackup ist nicht bytegleich."

    echo "===== PHASE-A-TEST ====="
    echo "Backup: $TESTDIR"
    echo

    phase_a_vorbereiten "$PLAN" "$TESTDIR"

    [ ! -e /boot/config/super.dat ] ||
        fehler "Phase-A-Test: super.dat wurde nicht geparkt."

    [ -f "$TESTDIR/super.dat.pre-new-config" ] ||
        fehler "Phase-A-Test: Parkdatei fehlt."

    [ -r "$RESUME_STATE" ] ||
        fehler "Phase-A-Test: Resume-State fehlt."

    resume_state_laden >/dev/null ||
        fehler "Phase-A-Test: Resume-State ist ungueltig."

    echo
    echo "===== PHASE-A-TESTROLLBACK ====="

    cp -p "$TESTDIR/super.dat.pre-new-config" /boot/config/super.dat ||
        fehler "Phase-A-Test: Original-super.dat konnte nicht zurueckgelegt werden."

    cmp -s /boot/config/super.dat "$TESTDIR/super.dat" ||
        fehler "Phase-A-Test: wiederhergestellte super.dat ist nicht bytegleich."

    rm -f "$RESUME_STATE" "${RESUME_STATE}.tmp"
    sync

    NACH_HASH="$(sha256sum /boot/config/super.dat | awk '{print $1}')"

    [ "$NACH_HASH" = "$VOR_HASH" ] ||
        fehler "Phase-A-Test: super.dat-Hash stimmt nach Rollback nicht."

    echo "OK: Phase A ausgefuehrt."
    echo "OK: Resume-State verifiziert."
    echo "OK: Original-super.dat bytegleich wiederhergestellt."
    echo "ERGEBNIS: PHASE_A_TEST_OK"
}


if [ "${1:-}" = "--prepare-reboot" ]; then
    [ "$#" -eq 2 ] || usage

    PLAN="$2"

    echo "===== PHASE A – REBOOT VORBEREITEN ====="

    [ -r "$PLAN" ] ||
        fehler "Phase-A-Vorbereitung verweigert: Plan nicht lesbar."

    [ ! -e "$RESUME_STATE" ] ||
        fehler "Phase-A-Vorbereitung verweigert: Resume-State existiert bereits."

    [ -r /boot/config/super.dat ] ||
        fehler "Phase-A-Vorbereitung verweigert: aktive super.dat fehlt."

    BACKUP_DIR="/boot/config/custom/array-serial/md-migration-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$BACKUP_DIR" ||
        fehler "Phase-A-Backupverzeichnis konnte nicht erstellt werden."

    cp -p /boot/config/super.dat "$BACKUP_DIR/super.dat" ||
        fehler "Original-super.dat konnte nicht ins Transaktionsbackup kopiert werden."

    cmp -s /boot/config/super.dat "$BACKUP_DIR/super.dat" ||
        fehler "Original-super.dat im Transaktionsbackup ist nicht bytegleich."

    sync

    echo "OK: Original-super.dat bytegleich im Transaktionsbackup gesichert."

    echo
    echo "===== PHASE A – MD-AUSGANGSZUSTAND ====="

    [ -r "/boot/config/custom/array-serial/md-migration-array-state.sh" ] ||
        fehler "MD-State-Modul fehlt oder ist nicht ausfuehrbar."

    [ -r "/boot/config/custom/array-serial/md-migration-state-bridge.sh" ] ||
        fehler "MD-State-Bridge fehlt oder ist nicht ausfuehrbar."

    /bin/bash "/boot/config/custom/array-serial/md-migration-state-bridge.sh" \
        --capture "$BACKUP_DIR" ||
        fehler "MD-Ausgangszustand konnte nicht transaktionsfest gesichert werden."

    /bin/bash "/boot/config/custom/array-serial/md-migration-state-bridge.sh" \
        --validate "$BACKUP_DIR" ||
        fehler "Gesicherter MD-Ausgangszustand konnte nicht verifiziert werden."

    echo "OK: MD-Ausgangszustand gehoert zur Migrationstransaktion."

    phase_a_vorbereiten "$PLAN" "$BACKUP_DIR" ||
        fehler "Phase A konnte nicht persistent vorbereitet werden."

    [ -r "$RESUME_STATE" ] ||
        fehler "Phase A abgeschlossen, aber Resume-State fehlt."

    [ ! -e /boot/config/super.dat ] ||
        fehler "Phase A abgeschlossen, aber aktive super.dat ist noch vorhanden."

    echo
    echo "ERGEBNIS: PHASE_A_PREPARE_REBOOT_OK"
    echo "Backup: $BACKUP_DIR"
    echo "Resume-State: $RESUME_STATE"
    echo
    echo "WICHTIG:"
    echo "Jetzt ist ein Reboot erforderlich."
    echo "Dieser Befehl fuehrt selbst KEINEN Reboot aus."

    exit 0
fi

if [ "${1:-}" = "--resume-phase-b" ]; then
    [ "$#" -eq 1 ] || usage

    echo "===== MANUELLER PHASE-B-RESUME ====="

    [ -r "$RESUME_STATE" ] ||
        fehler "Phase-B-Resume verweigert: Resume-State fehlt."

    phase_b_transaktion_ausfuehren
    exit $?
fi

if [ "${1:-}" = "--test-phase-b-rollback" ]; then
    [ "$#" -eq 2 ] || usage
    test_phase_b_rollback "$2"
    RC=$?
    exit "$RC"
fi

if [ "${1:-}" = "--test-phase-b-importdatei" ]; then
    [ "$#" -eq 2 ] || usage
    test_phase_b_importdatei "$2"
    exit $?
fi

if [ "${1:-}" = "--test-phase-b-manifest" ]; then
    [ "$#" -eq 2 ] || usage
    test_phase_b_manifest "$2"
    exit $?
fi

if [ "${1:-}" = "--test-phase-a" ]; then
    [ "$#" -eq 2 ] || usage
    test_phase_a "$2"
    exit $?
fi

apply() {
    local BACKUP_DIR=""

    echo "===== MD-MIGRATION – APPLY ====="
    echo

    plan_laden
    plan_anzeigen

    echo
    echo "===== TRANSAKTIONSVORPRUEFUNG ====="
    echo

    transaktion_erzeugen

    echo
    echo "===== TRANSAKTION ABSICHERN ====="
    echo

    BACKUP_DIR="$(transaktion_absichern)" ||
        fehler "Transaktionsabsicherung fehlgeschlagen."

    [ -n "$BACKUP_DIR" ] ||
        fehler "Backup-Verzeichnis wurde nicht ermittelt."

    echo "OK: Array ist STOPPED."
    echo "OK: super.dat wurde gesichert und verifiziert."
    echo "Backup: $BACKUP_DIR"

    echo
    echo "===== LETZTE SCHREIBSPERRE ====="
    echo
    echo "Alle Vorbedingungen fuer die MD-Transaktion sind erfuellt."
    echo "MD-Schreibbackend wurde NICHT aufgerufen."
    echo "Noch KEIN /proc/mdcmd beschrieben."
    echo "Noch KEINE super.dat durch MD veraendert."
    echo
    echo "STOP: Schreibphase bleibt fuer den Kontrolllauf gesperrt."
    echo "ERGEBNIS: WRITE_GATE_OK"
    exit 1

    # Erst nach separater Freigabe:
    # md_imports_schreiben
    # transaktion_pruefen
}

case "$MODUS" in
    --prepare)
        [ -n "$PLAN" ] || {
            usage
            exit 1
        }
        prepare
        ;;
    --apply)
        [ -n "$PLAN" ] || {
            usage
            exit 1
        }
        apply
        ;;
    *)
        usage
        exit 1
        ;;
esac
