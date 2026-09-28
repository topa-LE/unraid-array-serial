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
    local MD_STATE=""

    MD_STATE="$(
        sed -n 's/^mdState=//p' /proc/mdstat |
        head -n 1
    )"

    [ "$MD_STATE" = "STOPPED" ] ||
        fehler "Persistenzabschluss nur bei STOPPED erlaubt. Aktuell: ${MD_STATE:-UNBEKANNT}"

    md_befehl_schreiben "start NEW_ARRAY"
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
