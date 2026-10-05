#!/bin/bash
#
# topa-LE Unraid Array Serial
#
# Kontrollierter Uebergang zwischen bereits migrierten Pool-CFGs und
# der anschliessenden Aktivierung der persistenten Udev-Identitaeten.
#
# Dieses Skript erzeugt keine Pool-only-Baseline.
# Die Identity-Baseline muss immer alle aktuell gespeicherten
# Array- und Pool-Zuweisungen vollstaendig abdecken.
#
# Sicherheitsprinzip:
# - Eine vorhandene Baseline wird niemals ersetzt.
# - Der normale Activation-Preflight bleibt unveraendert streng.
# - Fuer diesen kontrollierten Uebergang darf ausschliesslich die
#   aktuelle Udev-ID noch von der Projekt-ID abweichen.
# - Gespeicherte Assignment-ID und Projekt-ID muessen bereits
#   uebereinstimmen.
# - Hardware-Zuordnung, Quellen, Eindeutigkeit und Vollstaendigkeit
#   werden durch activation-preflight.sh geprueft.
# - Die erzeugte Baseline wird danach erneut validiert.
#
# Dieses Skript veraendert keine Pool-CFGs und keine Udev-Regeln.
#

set -euo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFLIGHT="$BASE/activation-preflight.sh"
BASELINE_HELPER="$BASE/identity-baseline.sh"
BASELINE="$BASE/identity-baseline.tsv"

case "${1:-}" in
    --create)
        [ "$#" -eq 1 ] || {
            echo "Verwendung: $0 --create" >&2
            exit 2
        }
        ;;
    *)
        echo "Verwendung: $0 --create" >&2
        exit 2
        ;;
esac

[ -f "$PREFLIGHT" ] || {
    echo "STOP: activation-preflight.sh fehlt: $PREFLIGHT" >&2
    exit 1
}

[ -f "$BASELINE_HELPER" ] || {
    echo "STOP: identity-baseline.sh fehlt: $BASELINE_HELPER" >&2
    exit 1
}

if [ -e "$BASELINE" ]; then
    echo "STOP: Persistente Identity-Baseline existiert bereits:" >&2
    echo "$BASELINE" >&2
    exit 1
fi

echo "===== POOL-MIGRATION – VOLLSTAENDIGE TRANSITION-BASELINE ====="
echo

/bin/bash "$PREFLIGHT" \
    --write-transition-baseline "$BASELINE" || {
        echo "STOP: Vollstaendige Transition-Baseline konnte nicht erzeugt werden." >&2
        exit 1
    }

echo
echo "===== TRANSITION-BASELINE VALIDIEREN ====="

/bin/bash "$BASELINE_HELPER" \
    --validate "$BASELINE" || {
        echo "STOP: Erzeugte Transition-Baseline ist ungueltig." >&2
        exit 1
    }

sync

echo
echo "Identity-Baseline: $BASELINE"
echo "ERGEBNIS: POOL_MIGRATION_BASELINE_OK"
