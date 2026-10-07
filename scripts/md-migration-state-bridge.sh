#!/bin/bash
#
# topa-LE Unraid Array Serial
# Verbindet den gesicherten MD-Ausgangszustand mit der Migrationstransaktion.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
STATE_TOOL="$BASE/md-migration-array-state.sh"

fehler() {
    echo "FEHLER: $*" >&2
    exit 1
}

state_datei() {
    local BACKUP_DIR="$1"

    [ -n "$BACKUP_DIR" ] ||
        fehler "Transaktionsverzeichnis fehlt."

    case "$BACKUP_DIR" in
        "$BASE"/md-migration-*)
            ;;
        *)
            fehler "Unerwartetes Transaktionsverzeichnis: $BACKUP_DIR"
            ;;
    esac

    printf '%s\n' "$BACKUP_DIR/md-array-state"
}

state_sha_datei() {
    local BACKUP_DIR="$1"

    printf '%s\n' "$(state_datei "$BACKUP_DIR").sha256"
}

capture() {
    local BACKUP_DIR="$1"
    local STATE=""
    local STATE_SHA=""

    [ -r "$STATE_TOOL" ] ||
        fehler "MD-State-Modul fehlt oder ist nicht ausfuehrbar: $STATE_TOOL"

    [ -d "$BACKUP_DIR" ] ||
        fehler "Transaktionsverzeichnis fehlt: $BACKUP_DIR"

    STATE="$(state_datei "$BACKUP_DIR")"
    STATE_SHA="$(state_sha_datei "$BACKUP_DIR")"

    [ ! -e "$STATE" ] ||
        fehler "MD-Ausgangszustand existiert bereits: $STATE"

    [ ! -e "$STATE_SHA" ] ||
        fehler "MD-Ausgangszustand-SHA256 existiert bereits: $STATE_SHA"

    /bin/bash "$STATE_TOOL" --write "$STATE"

    /bin/bash "$STATE_TOOL" --validate "$STATE"

    sha256sum "$STATE" > "$STATE_SHA" ||
        fehler "SHA256 des MD-Ausgangszustands konnte nicht geschrieben werden."

    sha256sum -c "$STATE_SHA" >/dev/null ||
        fehler "SHA256-Pruefung des MD-Ausgangszustands fehlgeschlagen."

    sync

    echo "OK: MD-Ausgangszustand transaktionsfest gesichert."
    echo "State:  $STATE"
    echo "SHA256: $STATE_SHA"
}

validate() {
    local BACKUP_DIR="$1"
    local STATE=""
    local STATE_SHA=""

    [ -r "$STATE_TOOL" ] ||
        fehler "MD-State-Modul fehlt oder ist nicht ausfuehrbar: $STATE_TOOL"

    [ -d "$BACKUP_DIR" ] ||
        fehler "Transaktionsverzeichnis fehlt: $BACKUP_DIR"

    STATE="$(state_datei "$BACKUP_DIR")"
    STATE_SHA="$(state_sha_datei "$BACKUP_DIR")"

    [ -r "$STATE" ] ||
        fehler "Gesicherter MD-Ausgangszustand fehlt: $STATE"

    [ -r "$STATE_SHA" ] ||
        fehler "SHA256-Datei des MD-Ausgangszustands fehlt: $STATE_SHA"

    sha256sum -c "$STATE_SHA" >/dev/null ||
        fehler "SHA256-Pruefung des MD-Ausgangszustands fehlgeschlagen."

    /bin/bash "$STATE_TOOL" --validate "$STATE"

    echo "OK: Transaktionsgebundener MD-Ausgangszustand verifiziert."
}

case "${1:-}" in
    --capture)
        [ "$#" -eq 2 ] ||
            fehler "Verwendung: $0 --capture TRANSAKTIONSVERZEICHNIS"
        capture "$2"
        ;;
    --validate)
        [ "$#" -eq 2 ] ||
            fehler "Verwendung: $0 --validate TRANSAKTIONSVERZEICHNIS"
        validate "$2"
        ;;
    *)
        fehler "Verwendung: $0 --capture TRANSAKTIONSVERZEICHNIS | --validate TRANSAKTIONSVERZEICHNIS"
        ;;
esac
