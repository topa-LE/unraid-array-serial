#!/bin/bash
#
# topa-LE Unraid Array Serial
# GitHub-Bootstrap fuer Installation und Update.

set -euo pipefail

REPO="topa-LE/unraid-array-serial"
BRANCH="main"
BASE="/boot/config/custom/array-serial"
TMP="$(mktemp -d /tmp/array-serial-bootstrap.XXXXXXXX)"

DEPLOY_STARTED=0
DEPLOY_COMPLETE=0

cleanup() {
    status=$?

    trap - EXIT

    if [ "$DEPLOY_STARTED" -eq 1 ] &&
       [ "$DEPLOY_COMPLETE" -eq 0 ]; then
        restore_files
    fi

    rm -rf -- "$TMP"
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "===== ARRAY-SERIAL – GITHUB BOOTSTRAP ====="

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

[ -d /boot/config ] || {
    echo "STOP: Unraid-Bootstick nicht gefunden."
    exit 1
}

echo "===== GITHUB-ARCHIV HERUNTERLADEN ====="

curl -fLsS \
    "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
    -o "$TMP/repository.tar.gz"

tar -xzf "$TMP/repository.tar.gz" -C "$TMP"

SOURCE="$TMP/unraid-array-serial-$BRANCH/scripts"

[ -f "$SOURCE/unraid-orchestrator.sh" ] || {
    echo "STOP: Orchestrator fehlt im Archiv."
    exit 1
}

[ -f "$SOURCE/install-new-server.sh" ] || {
    echo "STOP: New-Server-Installer fehlt im Archiv."
    exit 1
}

echo "===== PROJEKTDATEIEN PRUEFEN ====="

[ -d "$SOURCE" ] || {
    echo "STOP: Skriptverzeichnis fehlt."
    exit 1
}

for FILE in "$SOURCE"/*; do
    [ -f "$FILE" ] || continue

    case "$FILE" in
        *.sh)
            /bin/bash -n "$FILE" || {
                echo "STOP: Syntaxfehler: $FILE"
                exit 1
            }
            ;;
    esac
done

echo "===== PROJEKTDATEIEN INSTALLIEREN ====="

if [ -L "$BASE" ]; then
    echo "STOP: Projektverzeichnis ist ein Symlink."
    exit 1
fi

mkdir -p "$BASE"

for FILE in "$SOURCE"/*; do
    [ -f "$FILE" ] || continue
    NAME="${FILE##*/}"

    if [ -L "$BASE/$NAME" ]; then
        echo "STOP: Symlink im Projektverzeichnis: $NAME"
        exit 1
    fi
done

BACKUP="$TMP/backup"
mkdir -p "$BACKUP"

for FILE in "$SOURCE"/*; do
    [ -f "$FILE" ] || continue
    NAME="${FILE##*/}"

    if [ -e "$BASE/$NAME" ]; then
        cp -p -- "$BASE/$NAME" "$BACKUP/$NAME"
    fi
done

restore_files() {
    echo "STOP: Bereitstellung fehlgeschlagen – Wiederherstellung."

    for FILE in "$SOURCE"/*; do
        [ -f "$FILE" ] || continue
        NAME="${FILE##*/}"

        rm -f -- "$BASE/.${NAME}.bootstrap.$$" || true

        if [ -f "$BACKUP/$NAME" ]; then
            cp -p -- "$BACKUP/$NAME" "$BASE/$NAME" ||
                echo "WARNUNG: Wiederherstellung fehlgeschlagen: $NAME"
        else
            rm -f -- "$BASE/$NAME" ||
                echo "WARNUNG: Entfernen fehlgeschlagen: $NAME"
        fi
    done
}

DEPLOY_STARTED=1

for FILE in "$SOURCE"/*; do
    [ -f "$FILE" ] || continue

    NAME="${FILE##*/}"
    STAGED="$BASE/.${NAME}.bootstrap.$$"

    cp -- "$FILE" "$STAGED"
    chmod 755 "$STAGED" || {
        rm -f -- "$STAGED"
        exit 1
    }

    mv -f -- "$STAGED" "$BASE/$NAME"
done

DEPLOY_COMPLETE=1

echo "===== ORCHESTRATOR STARTEN ====="

/bin/bash "$BASE/unraid-orchestrator.sh" "$@"
