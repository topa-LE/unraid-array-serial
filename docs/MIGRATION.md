# Migration bestehender Geräte-IDs

## Zweck

Eine Installation der neuen Udev-Identitäten allein reicht bei einem bereits bestehenden Unraid-System nicht zwangsläufig aus.

Unraid kann bestehende Array- oder Pool-Zuweisungen noch unter älteren Geräte-IDs gespeichert haben.

In diesem Fall müssen die persistenten Unraid-Zuweisungen kontrolliert auf die neue Projekt-ID migriert werden.

## Grundregel

Eine notwendige Migration darf niemals durch das Erzeugen einer neuen Baseline umgangen werden.

Der korrekte Ablauf lautet:

    bestehende Unraid-Zuweisung
            |
            v
    physische Hardware eindeutig identifizieren
            |
            v
    erwartete Projekt-ID bestimmen
            |
            v
    sichere Migration
            |
            v
    persistenten Zustand verifizieren
            |
            v
    Baseline freigeben

## Array und Pools sind getrennt

Das Projekt verwendet getrennte Pfade:

| Bereich | Hauptkomponenten |
|---|---|
| Array | `migrate-array-ids.sh`, `md-migration-transaction.sh` |
| Pools | `migrate-pool-ids.sh`, `pool-migration-transaction.sh` |

Eine Pool-Migration darf nicht mit der MD-/Array-Migration vermischt werden.

## Array-Migration

### Hintergrund

Frühe Untersuchungen zeigten, dass weder ein einfaches Ändern der sichtbaren Laufzeitzuweisung noch ein direktes binäres Ersetzen eines ID-Feldes in `super.dat` als allgemeiner sicherer Migrationsmechanismus ausreicht.

Deshalb wurde ein kontrollierter Transaktionspfad entwickelt.

Die vollständige Entwicklungsgeschichte befindet sich in:

[ARRAY-ID-MIGRATION-DEVELOPMENT.md](ARRAY-ID-MIGRATION-DEVELOPMENT.md)

### Zwei-Phasen-Modell

Der entwickelte Array-Pfad arbeitet in zwei logisch getrennten Phasen.

#### Phase A

Phase A bereitet die Transaktion vor.

Dabei werden unter anderem:

- Plan und Hardwarezuordnung geprüft,
- die bestehende Konfiguration gesichert,
- Hashes und Manifestinformationen festgehalten,
- der für den Reboot notwendige Resume-Zustand persistent gespeichert.

Nach Phase A ist ein Reboot Bestandteil der Transaktion.

#### Phase B

Nach dem Reboot darf Phase B nur fortfahren, wenn der gespeicherte Transaktionszustand vollständig zu den erwarteten Daten passt.

Dabei werden die Geräte erneut anhand ihrer Hardwareidentität aufgelöst.

Erst danach erfolgt der kontrollierte Aufbau der neuen persistenten Array-Zuordnung.

Der Resume-State wird erst nach erfolgreicher Validierung entfernt.

## Sicherheitsmerkmale der Array-Transaktion

Die Transaktion verwendet unter anderem:

- persistente Backups,
- Hashprüfung,
- Planprüfung,
- Manifestprüfung,
- erneute Hardwareauflösung nach dem Reboot,
- Prüfung der erwarteten Slots,
- Prüfung der MD-Größen,
- Prüfung auf fehlende beziehungsweise neue Laufwerke.

Bei einer Abweichung soll die Transaktion stoppen.

## Verifizierte Entwicklungstests

### Ein-Disk-Test

Der vollständige Zwei-Phasen-Pfad wurde auf einem Testsystem mit einem Datenlaufwerk erfolgreich ausgeführt.

Nach einem weiteren normalen Reboot blieb die neue persistente Zuordnung erhalten.

### Paritätsarray

Anschließend wurde ein Array mit:

    1 Paritätsplatte
    7 Datenplatten

getestet.

Nach einem normalen Reboot blieben Parität und alle sieben Datenplatten den erwarteten Slots mit den bereinigten IDs zugeordnet.

Dieser Test bestätigte die Persistenz der Gerätezuordnung.

Er darf nicht mit einer Aussage verwechselt werden, dass vorhandene Paritätsdaten nach jedem New-Config-artigen Vorgang automatisch als gültig betrachtet werden können.

Im dokumentierten Test wurde eine Paritäts-Rekonstruktion gestartet.

## Pool-Migration

`migrate-pool-ids.sh` löst persistente Poolkonfigurationen über Pool-UUID, vorhandene Partition und Parent-Disk auf.

Der schreibende Backend-Pfad liegt in:

    pool-migration-transaction.sh

Der Transaktionspfad prüft die geplanten Änderungen, sichert die ursprünglichen Pool-Konfigurationsdateien und besitzt einen Rollback-Pfad für bereits geschriebene Konfigurationen.

Er verändert keine Partitionierung, Dateisystem-UUID oder Nutzdaten.

## Vor einer produktiven Migration

Vor jeder produktiven Migration müssen der aktuelle Zustand und die vorhandenen Backups geprüft werden.

Insbesondere darf kein Migrationslauf aufgrund einer bloßen Annahme über `/dev/sdX` oder `/dev/nvmeXnY` gestartet werden.

Die Hardwareauflösung muss eindeutig sein.

## Nach einer Migration

Nach erfolgreicher Migration sind mindestens zu prüfen:

- gespeicherte Unraid-Zuweisungen,
- erwartete Projekt-IDs,
- Slot-Zuordnung,
- fehlende beziehungsweise neue Laufwerke,
- Pool-Konfiguration,
- Reboot-Persistenz.

Erst ein erfolgreicher Reboot-Test bestätigt die persistente Übernahme der neuen Geräteidentitäten.
