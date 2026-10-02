# Projekt-Historie

## Überblick

Unraid Array Serial entstand schrittweise aus der Untersuchung, wie Unraid Laufwerke identifiziert und wie lesbare, stabile Gerätekennungen erzeugt werden können, ohne sich auf wechselnde Linux-Gerätenamen zu verlassen.

Die Entwicklung erfolgte iterativ mit realen Hardware-, Udev-, Array-, Migrations- und Reboot-Tests.

## Entwicklungsphasen

### Phase 1 – Diagnose und Identitätsanalyse

Zu Beginn entstanden ausschließlich lesende Werkzeuge zum Vergleich von Hardware-, Udev- und SMART-Informationen.

| Commit | Inhalt |
|---|---|
| `9cb6fe6` | Unraid-7.3.2-Referenz zur Serial-Identifikation |
| `382d71a` | Read-only Disk-Identifikationsdiagnose |
| `7b4821a` | Vergleich Hardware- und Udev-Serial |
| `96b3028` | reversible Vorschau lesbarer Disk-IDs |

### Phase 2 – Lesbare Hardware-IDs

Anschließend wurde die Formatierung stabiler und lesbarer Gerätekennungen entwickelt.

| Commit | Inhalt |
|---|---|
| `d17cab8` | lesbare SMART-basierte Disk-ID |
| `85d638d` | Boot-Integration |
| `648eb0a` | WDC-Präfix und Bindestrichformat |
| `7e7abbd` | ATA-Erkennung vor Formatierung |
| `3f74bc5` | vereinheitlichte SATA-, USB- und NVMe-Identifikation |

### Phase 3 – Problematische USB-SATA-Bridges

Für Hardware, die beim Boot keine zuverlässig direkt nutzbare ATA-Identität bereitstellt, wurde ein persistenter Cache-Fallback untersucht und implementiert.

| Commit | Inhalt |
|---|---|
| `159cf32` | persistenter Identity-Cache-Fallback |
| `6dc048d` | Identity-Source und gehärtete Udev-Verarbeitung |
| `2463420` | dynamische Boot-Disk-Erkennung |

Der Cache wurde später bewusst aus der persistierbaren Identity-Baseline ausgeschlossen.

### Phase 4 – Sichere Array-ID-Migration

Die Untersuchung zeigte, dass eine persistente Änderung bestehender Array-Zuweisungen nicht durch einfache Udev-Änderungen erreicht wird.

Es folgte die Entwicklung eines abgesicherten Transaktionsmodells.

| Commit | Inhalt |
|---|---|
| `15aba35` | unsicheren Apply-Pfad sperren |
| `5f52956` | Migrationserkenntnisse dokumentieren |
| `1be9137` | verifiziertes MD-Transaktionsbackend |
| `38340af` | abgesicherte MD-Persistenztransaktion |
| `7f374de` | persistentes Zwei-Phasen-Backend |
| `3e2be77` | Phase-B-Migrationsfluss |
| `cf2d52d` | persistenter Phase-A-Reboot-Einstieg |
| `3d2a34e` | erfolgreicher Zwei-Phasen-Persistenztest |
| `e4a2649` | vollständiger Paritätsarray-Reboottest |

Der Paritätsarray-Test bestätigte die persistente Slot-Zuordnung nach dem Reboot. Er ist keine allgemeine Aussage darüber, dass vorhandene Paritätsdaten nach jedem New-Config-artigen Vorgang automatisch gültig bleiben. Im dokumentierten Test wurde eine Paritäts-Rekonstruktion gestartet.

### Phase 5 – Partitionen, NVMe und Pools

Die stabile Identität wurde auf Partitionen und NVMe-by-id-Links erweitert.

Parallel entstand ein eigener Pool-Migrationspfad.

| Commit | Inhalt |
|---|---|
| `745bbce` | stabile Identity-Vererbung für Partitionen |
| `36923a8` | Pool-Migrationsvorschau |
| `9b2e90a` | Pool-Transaktionsbackend |
| `a984be6` | verifizierte Pool-Migrationsplanung |
| `4d4d882` | Pool-ID-Migration Apply |
| `e55947f` | persistente Partition-Udev-Regeln |
| `f8d3fc5` | stabile NVMe-by-id-Links |

### Phase 6 – Persistenter Bootablauf

Der Bootpfad wurde erweitert, bereinigt und mit Diagnosefunktionen versehen.

| Commit | Inhalt |
|---|---|
| `9e581b9` | persistenter Boot- und Multi-Device-Pool-Pfad |
| `320119a` | sichere Bereinigung alter Boot-Hooks |
| `4edfe04` | Bereinigung verwaister Hook-Reste |
| `7b42a45` | sichere Bereinigung alter Hook-Blöcke |
| `fecbbb6` | Boot-Diagnose vor Unraid-Initialisierung |

### Phase 7 – Separater Flash-ID-Pfad

Der Unraid-Bootstick wurde bewusst aus dem normalen Laufwerkspfad herausgelöst.

| Commit | Inhalt |
|---|---|
| `0439400` | isolierte Boot-Flash-Identität |
| `dbc41a2` | Flash-Installer auf FAT-Bootmedium |

### Phase 8 – Autorisierte Identity-Baseline

Die Identitätserzeugung wurde anschließend mit einer expliziten servereigenen Autorisierungsschicht versehen.

| Commit | Inhalt |
|---|---|
| `7810e46` | persistente Identity-Autorisierungshelfer |
| `58741bb` | Activation-Preflight und Baseline-Preview |
| `39d1156` | gehärtetes Baseline-TSV-Parsing |
| `ed57fc2` | CACHE aus persistenter Baseline ausschließen |
| `0541f5b` | Assignment-Auflösung über Hardwareidentität |
| `d230295` | validierter Baseline-Writer |
| `909c642` | Udev-Identitäten durch Baseline autorisieren |

### Phase 9 – Zentraler Installations-Orchestrator

Mit Commit:

```text
7bb03ed – Add idempotent installation orchestrator
```

wurde `install.sh` als zentraler Installations- und Update-Einstieg ergänzt.

Der Orchestrator verbindet:

- Projektprüfung
- Syntaxprüfung
- Identity-Baseline
- Boot-Hooks
- Runtime-Udev
- Flash-ID
- Abschlussvalidierung

## Referenztest des Orchestrators

Der aktuelle Orchestrator wurde anschließend auf einem Unraid-7.3.2-Referenzsystem vollständig installiert und über einen normalen Reboot geprüft.

Vor dem Reboot bestätigte der Installer:

```text
INSTALLATION ERFOLGREICH
BEREIT_FUER_REBOOT
```

Nach dem Reboot wurden unter anderem bestätigt:

- alle vier persistenten Boot-Hooks jeweils genau einmal vorhanden
- Projektregeln erneut aktiv
- Identity-Baseline weiterhin gültig
- Baseline unverändert
- separater Flash-by-id-Link erneut vorhanden
- keine offene Array-Migrations-Resume-Datei
- Array anschließend normal gestartet

Damit wurde der vollständige Installations-, Boot- und Reboot-Pfad des aktuellen Orchestrators praktisch bestätigt.

## Historische Entwicklungsdokumentation

Die detaillierten Untersuchungen der Array-ID-Migration befinden sich weiterhin in:

[ARRAY-ID-MIGRATION-DEVELOPMENT.md](ARRAY-ID-MIGRATION-DEVELOPMENT.md)

Diese Datei bleibt bewusst erhalten, weil sie Entwicklung, verworfene Ansätze und die später erfolgreichen Tests dokumentiert.

Sie ist ein Entwicklungsprotokoll und nicht als alleinige aktuelle Installationsanleitung zu verstehen.
