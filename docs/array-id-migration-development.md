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

## Erfolgreicher Zwei-Phasen-Persistenztest auf Unraid .12

Stand: 28.09.2026

Der vollständige Zwei-Phasen-Migrationspfad wurde auf dem
Ein-Disk-Testsystem `.12` ohne Parität erfolgreich durchgeführt.

Ablauf:

1. Phase A verifizierte Plan, Manifest und Originalkonfiguration.
2. Die originale `super.dat` wurde gesichert und für den
   New-Config-Übergang geparkt.
3. Nach dem Reboot befand sich der MD-Runtime-Zustand vollständig leer:
   `mdState=STOPPED`, `mdNumDisks=0`, `mdNumMissing=0`, `mdNumNew=0`.
4. Unraid erzeugte dabei selbst eine leere aktive 4096-Byte-`super.dat`.
5. Phase B löste die Hardware erneut anhand der echten Identität auf.
6. Eine vollständige Importfolge für alle 30 Array-Slots wurde erzeugt.
7. Alle 30 Importbefehle wurden geschrieben.
8. `start NEW_ARRAY` erzeugte eine neue gültige persistente Konfiguration.
9. Die Phase-B-Nachprüfung bestätigte den erwarteten Slot, die neue ID,
   die ursprüngliche MD-Größe sowie `Missing=0` und `New=0`.
10. Der Resume-State wurde erst nach erfolgreicher Validierung entfernt.
11. Ein weiterer normaler Reboot bestätigte die Persistenz.

Verifizierter Zustand nach dem abschließenden Reboot:

- `mdState=STOPPED`
- `mdNumDisks=1`
- `mdNumMissing=0`
- `mdNumNew=0`
- `diskName.1=md1p1`
- `diskSize.1=9766436812`
- `rdevSize.1=9766436812`
- `diskState.1=7`
- `diskId.1=WDC-WD101EFBX-68B0AN0-VH0ATR0M`

Neue persistente `super.dat`:

`03fec99a51d7b028f6497891977cc20348e5d680f663151d0983a0e50ba318a7`

Die Datei blieb über den abschließenden Reboot bytegleich.

Originale `super.dat` vor der Migration:

`ba893f9db5c8bb9ac60a79a8b58cb0f7e1004342dc9b17b72c7909f65cc4961d`

Das Original und die geparkte Originalkopie blieben im
Transaktionsbackup erhalten.

### Schlussfolgerung

Für das getestete Array ohne Parität ist damit bewiesen, dass die
bereinigte Geräte-ID über einen kontrollierten New-Config-Zyklus in
eine vom Unraid-MD-System selbst erzeugte `super.dat` übernommen werden
kann und nach einem normalen Reboot persistent wieder geladen wird.

Ein direktes binäres Patchen von `super.dat` ist hierfür nicht
erforderlich und bleibt ausgeschlossen.

Dieser Test beweist noch nicht die Semantik für Arrays mit Parität.
Vor Einsatz auf einem produktiven Paritätsarray muss der gleiche
Transaktionspfad kontrolliert mit Parität getestet werden.
