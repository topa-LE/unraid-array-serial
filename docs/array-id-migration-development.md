# Array-ID-Migration – Entwicklungsstand

## Ziel

Bestehende Unraid-Array-Zuweisungen sollen bei einer Aenderung der
Geraete-ID erhalten bleiben, wenn dieselbe physische Platte anhand ihrer
echten Hardware-Seriennummer eindeutig wiedererkannt wurde.

Die Migration muss fail-safe sein. Bei Mehrdeutigkeit wird abgebrochen.

## Bestaetigte Erkenntnisse

### Hardware- und Udev-Seite

Die neue ID wird unabhaengig vom Linux-Geraetenamen ermittelt.

Unterstuetzte Identitaetsquellen:

- ATA
- USB-SAT
- NVMe
- persistenter Identity-Cache

`sdX` oder `nvmeXnY` duerfen nicht als persistente Identitaet verwendet
werden.

### changeDevice=apply

Der Aufruf

    emcmd "changeDevice=apply&slotId.<idx>=<ID>"

kann den Unraid-Laufzeitzustand bzw. die WebGUI-Zuweisung veraendern.

In den Tests wurde dadurch die bestehende `super.dat` jedoch nicht
zuverlaessig auf die neue ID migriert.

Dieser Weg darf deshalb nicht als persistente Migration verwendet werden.

### Direktes Patchen von super.dat

Das ID-Feld eines Slotblocks konnte bytegenau lokalisiert und veraendert
werden.

Ein Test zeigte jedoch:

- das geaenderte Slotfeld war nach dem Schreiben korrekt,
- nach dem Reboot akzeptierte Unraid die so veraenderte Konfiguration
  nicht,
- Unraid entfernte die nicht akzeptierte Slotzuweisung wieder.

Nur das ID-Feld in `super.dat` zu ersetzen ist daher keine gueltige
Migration.

### Unraid-Neukonfiguration

Bei einer neuen Array-Konfiguration wurde beobachtet:

1. Unraid importiert die Slots ueber `/proc/mdcmd`.
2. Parity 1 verwendet Index 0.
3. Parity 2 verwendet Index 29.
4. Datenplatten verwenden die Indizes 1 bis 28.
5. Der Array-Start erfolgt mit:

       start NEW_ARRAY

6. Dabei erzeugt der md-/Kernel-Pfad eine gueltige `super.dat`.

`start NEW_ARRAY` ist keine zulaessige Abkuerzung fuer die Migration
eines bestehenden produktiven Arrays.

### Bestehendes gueltiges Array

Bei einem normalen bestehenden Array wurde beobachtet:

1. Beim Stoppen werden die Slotzuweisungen erneut importiert.
2. Der normale Start verwendet:

       start STOPPED

3. Eine bereits gueltige `super.dat` bleibt dabei als Arraykonfiguration
   erhalten.

### Manuelle import-Versuche

Das manuelle Importieren einer anderen ID fuer denselben Slot reicht
nicht aus, um eine bestehende Array-ID umzubenennen.

Der md-Treiber prueft weitere persistente bzw. interne Zustandsdaten.

Auch das Wiederholen der kompletten sichtbaren Importfolge stellte einen
zuvor absichtlich gestoerten md-Laufzeitzustand nicht vollstaendig wieder
her.

### Reboot-Test

Nach absichtlich gestoerten manuellen `mdcmd import`-Versuchen wurde
Unraid neu gestartet.

Die persistente Array-Konfiguration war weiterhin gueltig.

Nach dem Boot:

- `configValid=yes`
- `mdNumDisks=1`
- `mdNumMissing=0`
- `mdNumNew=0`
- `mdState=STOPPED`

Die korrekte Disk-ID wurde wieder dem richtigen Slot zugeordnet.

Damit ist bestaetigt, dass der beim Experiment gestoerte md-Zustand
fluechtig war und beim Boot aus der gueltigen persistenten Konfiguration
sauber rekonstruiert wurde.

Die `super.dat` wurde beim Boot in globalen Feldern von Block 0
veraendert. Das ID-Feld des getesteten Slots blieb unveraendert.

## Aktuelle Sicherheitsregel

`migrate-array-ids.sh --apply` ist absichtlich gesperrt.

Weder

- `changeDevice=apply`,
- direktes Patchen von `super.dat`,
- noch `start NEW_ARRAY`

darf derzeit fuer eine bestehende Array-ID-Migration verwendet werden.

## Offene Kernfrage

Es muss noch ermittelt werden, welchen von Unraid akzeptierten
Persistenzmechanismus ein bestehendes Array verwenden kann, um dieselbe
eindeutig verifizierte physische Platte unter ihrer neuen ID zu
uebernehmen, ohne New-Config-Semantik, Datenverlust oder ungewollte
Parity-Neuerstellung.
