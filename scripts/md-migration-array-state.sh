#!/bin/bash
#
# topa-LE Unraid Array Serial
# Persistente Sicherung des MD-Ausgangszustands vor einer ID-Migration.
#
# Sicherheitsregel:
# Die Parity-Policy wird nicht aus einzelnen MD-Laufzeitwerten abgeleitet.
# PRESERVE bedeutet ausschliesslich:
# Die spaetere Phase B darf vorhandene Parity nur dann als gueltig markieren,
# wenn die transaktionsgebundene Hardware-/Slot-/Start-/Size-Pruefung
# vollstaendig erfolgreich war.
#
# Kann Phase B diese Identitaet nicht beweisen, wird die Migration verweigert.
#
# Automatische Policy fuer eine reine ID-Migration:
#   PARITY_POLICY=PRESERVE
#
# Die vorhandenen MD-Werte werden zusaetzlich vollstaendig dokumentiert.

set -euo pipefail

MDSTAT="/proc/mdstat"

fehler() {
    echo "FEHLER: $*" >&2
    exit 1
}

md_wert() {
    local GESUCHT="$1"
    local KEY=""
    local VALUE=""

    [ -r "$MDSTAT" ] ||
        fehler "$MDSTAT ist nicht lesbar."

    while IFS='=' read -r KEY VALUE; do
        if [ "$KEY" = "$GESUCHT" ]; then
            printf '%s\n' "$VALUE"
            return 0
        fi
    done < "$MDSTAT"

    return 1
}

state_schreiben() {
    local ZIEL="$1"
    local TMP="${ZIEL}.tmp"
    local MD_STATE=""
    local MD_NUM_DISKS=""
    local MD_NUM_DISABLED=""
    local MD_NUM_INVALID=""
    local MD_NUM_MISSING=""
    local MD_NUM_NEW=""
    local MD_RESYNC_ACTION=""
    local MD_RESYNC=""
    local MD_RESYNC_POS=""
    local PARITY_POLICY="PRESERVE"

    [ -n "$ZIEL" ] ||
        fehler "Zieldatei fehlt."

    [ ! -e "$ZIEL" ] ||
        fehler "MD-Ausgangszustand existiert bereits: $ZIEL"

    MD_STATE="$(md_wert mdState)" ||
        fehler "mdState fehlt."

    MD_NUM_DISKS="$(md_wert mdNumDisks)" ||
        fehler "mdNumDisks fehlt."

    MD_NUM_DISABLED="$(md_wert mdNumDisabled)" ||
        fehler "mdNumDisabled fehlt."

    MD_NUM_INVALID="$(md_wert mdNumInvalid)" ||
        fehler "mdNumInvalid fehlt."

    MD_NUM_MISSING="$(md_wert mdNumMissing)" ||
        fehler "mdNumMissing fehlt."

    MD_NUM_NEW="$(md_wert mdNumNew)" ||
        fehler "mdNumNew fehlt."

    MD_RESYNC_ACTION="$(md_wert mdResyncAction)" ||
        fehler "mdResyncAction fehlt."

    MD_RESYNC="$(md_wert mdResync)" ||
        fehler "mdResync fehlt."

    MD_RESYNC_POS="$(md_wert mdResyncPos)" ||
        fehler "mdResyncPos fehlt."

    [ "$MD_STATE" = "STOPPED" ] ||
        fehler "Migration erwartet vor Phase A ein gestopptes Array. Aktuell: $MD_STATE"

    for WERT in \
        "$MD_NUM_DISKS" \
        "$MD_NUM_DISABLED" \
        "$MD_NUM_INVALID" \
        "$MD_NUM_MISSING" \
        "$MD_NUM_NEW" \
        "$MD_RESYNC" \
        "$MD_RESYNC_POS"
    do
        case "$WERT" in
            ''|*[!0-9]*)
                fehler "MD-Ausgangszustand enthaelt ungueltigen Zahlenwert: ${WERT:-LEER}"
                ;;
        esac
    done

    [ "$MD_NUM_DISKS" -gt 0 ] ||
        fehler "Keine Array-Datentraeger im MD-Ausgangszustand."

    [ "$MD_NUM_MISSING" -eq 0 ] ||
        fehler "Migration mit fehlenden Array-Datentraegern wird verweigert."

    [ "$MD_NUM_NEW" -eq 0 ] ||
        fehler "Migration mit NEW-Datentraegern wird verweigert."

    {
        printf 'VERSION=2\n'
        printf 'MD_STATE=%s\n' "$MD_STATE"
        printf 'MD_NUM_DISKS=%s\n' "$MD_NUM_DISKS"
        printf 'MD_NUM_DISABLED=%s\n' "$MD_NUM_DISABLED"
        printf 'MD_NUM_INVALID=%s\n' "$MD_NUM_INVALID"
        printf 'MD_NUM_MISSING=%s\n' "$MD_NUM_MISSING"
        printf 'MD_NUM_NEW=%s\n' "$MD_NUM_NEW"
        printf 'MD_RESYNC_ACTION=%s\n' "$MD_RESYNC_ACTION"
        printf 'MD_RESYNC=%s\n' "$MD_RESYNC"
        printf 'MD_RESYNC_POS=%s\n' "$MD_RESYNC_POS"
        printf 'PARITY_POLICY=%s\n' "$PARITY_POLICY"
    } > "$TMP" ||
        fehler "Temporaerer MD-Ausgangszustand konnte nicht geschrieben werden."

    mv "$TMP" "$ZIEL" ||
        fehler "MD-Ausgangszustand konnte nicht aktiviert werden."

    sync

    echo "OK: MD-Ausgangszustand persistent gesichert."
    echo "Datei: $ZIEL"
    echo "Parity-Policy: $PARITY_POLICY"
}

state_pruefen() {
    local DATEI="$1"
    local VERSION=""
    local MD_STATE=""
    local MD_NUM_DISKS=""
    local MD_NUM_DISABLED=""
    local MD_NUM_INVALID=""
    local MD_NUM_MISSING=""
    local MD_NUM_NEW=""
    local MD_RESYNC_ACTION=""
    local MD_RESYNC=""
    local MD_RESYNC_POS=""
    local PARITY_POLICY=""
    local KEY=""
    local VALUE=""

    [ -r "$DATEI" ] ||
        fehler "MD-Ausgangszustand nicht lesbar: $DATEI"

    while IFS='=' read -r KEY VALUE; do
        case "$KEY" in
            VERSION) VERSION="$VALUE" ;;
            MD_STATE) MD_STATE="$VALUE" ;;
            MD_NUM_DISKS) MD_NUM_DISKS="$VALUE" ;;
            MD_NUM_DISABLED) MD_NUM_DISABLED="$VALUE" ;;
            MD_NUM_INVALID) MD_NUM_INVALID="$VALUE" ;;
            MD_NUM_MISSING) MD_NUM_MISSING="$VALUE" ;;
            MD_NUM_NEW) MD_NUM_NEW="$VALUE" ;;
            MD_RESYNC_ACTION) MD_RESYNC_ACTION="$VALUE" ;;
            MD_RESYNC) MD_RESYNC="$VALUE" ;;
            MD_RESYNC_POS) MD_RESYNC_POS="$VALUE" ;;
            PARITY_POLICY) PARITY_POLICY="$VALUE" ;;
            "")
                ;;
            *)
                fehler "Unbekannter Eintrag im MD-Ausgangszustand: $KEY"
                ;;
        esac
    done < "$DATEI"

    [ "$VERSION" = "2" ] ||
        fehler "Nicht unterstuetzte State-Version: ${VERSION:-LEER}"

    [ "$MD_STATE" = "STOPPED" ] ||
        fehler "Gesicherter MD-Zustand ist nicht STOPPED."

    for WERT in \
        "$MD_NUM_DISKS" \
        "$MD_NUM_DISABLED" \
        "$MD_NUM_INVALID" \
        "$MD_NUM_MISSING" \
        "$MD_NUM_NEW" \
        "$MD_RESYNC" \
        "$MD_RESYNC_POS"
    do
        case "$WERT" in
            ''|*[!0-9]*)
                fehler "Ungueltiger Zahlenwert im gesicherten MD-Zustand: ${WERT:-LEER}"
                ;;
        esac
    done

    [ "$MD_NUM_DISKS" -gt 0 ] ||
        fehler "Gesicherter MD-Zustand enthaelt keine Array-Datentraeger."

    [ "$MD_NUM_MISSING" -eq 0 ] ||
        fehler "Gesicherter MD-Zustand enthaelt fehlende Datentraeger."

    [ "$MD_NUM_NEW" -eq 0 ] ||
        fehler "Gesicherter MD-Zustand enthaelt NEW-Datentraeger."

    case "$PARITY_POLICY" in
        PRESERVE|SYNC)
            ;;
        *)
            fehler "Ungueltige oder unsichere Parity-Policy: ${PARITY_POLICY:-LEER}"
            ;;
    esac

    echo "OK: MD-Ausgangszustand verifiziert."
    echo "mdNumDisks=$MD_NUM_DISKS"
    echo "mdNumDisabled=$MD_NUM_DISABLED"
    echo "mdNumInvalid=$MD_NUM_INVALID"
    echo "mdResyncAction=$MD_RESYNC_ACTION"
    echo "Parity-Policy=$PARITY_POLICY"
}

parity_policy_lesen() {
    local DATEI="$1"
    local KEY=""
    local VALUE=""
    local PARITY_POLICY=""

    state_pruefen "$DATEI" >/dev/null

    while IFS='=' read -r KEY VALUE; do
        if [ "$KEY" = "PARITY_POLICY" ]; then
            PARITY_POLICY="$VALUE"
        fi
    done < "$DATEI"

    case "$PARITY_POLICY" in
        PRESERVE|SYNC)
            ;;
        *)
            fehler "Keine sichere Parity-Policy im MD-Ausgangszustand."
            ;;
    esac

    printf '%s\n' "$PARITY_POLICY"
}

case "${1:-}" in
    --write)
        [ "$#" -eq 2 ] ||
            fehler "Verwendung: $0 --write DATEI"
        state_schreiben "$2"
        ;;
    --validate)
        [ "$#" -eq 2 ] ||
            fehler "Verwendung: $0 --validate DATEI"
        state_pruefen "$2"
        ;;
    --parity-policy)
        [ "$#" -eq 2 ] ||
            fehler "Verwendung: $0 --parity-policy DATEI"
        parity_policy_lesen "$2"
        ;;
    *)
        fehler "Verwendung: $0 --write DATEI | --validate DATEI | --parity-policy DATEI"
        ;;
esac
