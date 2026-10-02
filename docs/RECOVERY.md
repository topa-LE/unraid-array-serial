# Recovery und Fehlerfälle

## Inhaltsverzeichnis

- [Grundprinzip](#grundprinzip)
- [Baseline-Fehler](#installation-stoppt-wegen-baseline)
- [Migration erforderlich](#activation-preflight-meldet-migration-erforderlich)
- [Udev nicht sauber](#udev-nicht-sauber)
- [CACHE nicht baseline-fähig](#cache-nicht-baseline-fähig)
- [Boot-Hooks](#boot-hooks)
- [Boot-Logs](#boot-logs)
- [Runtime-Udev-Regeln](#runtime-udev-regeln)
- [Flash-ID fehlt](#flash-id-fehlt-nach-reboot)
- [Migrations-Backups](#migrations-backups)
- [super.dat](#superdat)
- [Vor einer Wiederherstellung](#vor-einer-wiederherstellung)
- [Nach einer Wiederherstellung](#nach-einer-wiederherstellung)

## Grundprinzip

Bei einem Fehler soll nicht versucht werden, eine Geräteidentität oder Unraid-Zuweisung zu erraten.

Zuerst wird der Zustand erfasst.

Erst danach wird entschieden, ob Installation, Migration oder Wiederherstellung fortgesetzt werden darf.

## Installation stoppt wegen Baseline

Wenn `identity-baseline.sh` eine vorhandene Baseline ablehnt, darf diese nicht automatisch gelöscht oder neu erzeugt werden.

Zu prüfen sind unter anderem:

- TSV-Struktur
- doppelte Hardware-Seriennummern
- doppelte Projekt-IDs
- zulässige Identitätsquelle
- Übereinstimmung mit der erwarteten Serverhardware

Eine vorhandene Baseline ist eine Sicherheitsgrenze und keine temporäre Cache-Datei.

## Activation-Preflight meldet Migration erforderlich

Meldet der Preflight:

```text
MIGRATION_ERFORDERLICH
```

ist die gespeicherte Unraid-ID noch nicht identisch mit der erwarteten Projekt-ID.

In diesem Zustand darf keine neue Baseline als Abkürzung erzeugt werden.

Siehe:

[MIGRATION.md](MIGRATION.md)

## Udev nicht sauber

Meldet der Preflight:

```text
UDEV_NICHT_SAUBER
```

muss zunächst geprüft werden, warum die aktuelle Udev-ID nicht der erwarteten Projekt-ID entspricht.

Mögliche Prüfpunkte sind:

- installierte Runtime-Regeln
- Reihenfolge der Udev-Regeln
- Autorisierungs-Wrapper
- Hardwareidentität
- Boot-Ablauf

## CACHE nicht baseline-fähig

Meldet der Preflight:

```text
CACHE_NICHT_BASELINEFAEHIG
```

darf dieser Eintrag nicht in die persistente Baseline übernommen werden.

Ein Cache-Fallback ist keine dauerhafte Autorisierung einer Hardwareidentität.

## Boot-Hooks

Der produktive Boot-Ablauf erwartet jeweils genau einen Aufruf von:

```text
boot-log.sh
boot-capture.sh
install-boot.sh
install-flash-id.sh
```

Doppelte oder fehlende Hooks müssen vor einem produktiven Reboot geklärt werden.

## Boot-Logs

Persistente Diagnoseinformationen befinden sich unter:

```text
/boot/logs/array-serial/
```

`boot-log.sh` zeichnet den frühen Bootzustand auf.

`boot-capture.sh` erstellt mehrere zeitversetzte Snapshots während der Bootphase.

Die konkrete Aufbewahrungs- beziehungsweise Rotationslogik sollte bei einer Recovery direkt gegen den aktuell eingesetzten Skriptstand geprüft werden.

## Runtime-Udev-Regeln

Nach jedem Boot müssen die Projektregeln erneut unter:

```text
/etc/udev/rules.d/
```

vorhanden sein.

Zu erwarten sind:

```text
59-array-serial.rules
61-array-serial-nvme.rules
62-array-serial-partitions.rules
63-array-serial-nvme-links.rules
64-array-serial-flash.rules
```

Der Installations-Orchestrator vergleicht die erwarteten Runtime-Regeln mit den persistenten Projektdateien.

## Flash-ID fehlt nach Reboot

Wenn der zusätzliche Flash-by-id-Link nach einem Reboot fehlt, sind insbesondere zu prüfen:

1. Existiert `install-flash-id.sh` genau einmal in `/boot/config/go`?
2. Existiert Regel 64 zur Laufzeit?
3. Wird `/boot` vom erwarteten physischen Gerät bereitgestellt?
4. Welche Eigenschaften liefert `udevadm` für die Boot-Disk?
5. Existieren die nativen USB-by-id-Links?

Der native Hersteller-Link darf parallel zum Projekt-Link existieren.

## Migrations-Backups

Migrations-Transaktionen erzeugen bewusst Backups und Zustandsinformationen.

Diese dürfen nicht während einer noch laufenden oder ungeklärten Transaktion automatisch bereinigt werden.

Insbesondere ein vorhandener Resume-State muss als Hinweis auf eine möglicherweise noch nicht abgeschlossene Transaktion behandelt werden.

Transaktionszustände dürfen nicht allein deshalb gelöscht werden, weil eine Installation oder Aktualisierung durchgeführt werden soll.

## super.dat

`super.dat` ist ein kritischer Bestandteil der persistenten Unraid-Arraykonfiguration.

Historische Entwicklungsversuche haben gezeigt, dass ein bloßes direktes Ersetzen eines ID-Feldes keine allgemeine sichere Migration darstellt.

Die aktuelle Array-Migrationsarchitektur verwendet deshalb einen kontrollierten Transaktionspfad mit Backups, Manifesten, Hashprüfungen und Validierung.

`super.dat` sollte außerhalb dieses dafür vorgesehenen Transaktionspfades nicht experimentell verändert werden.

## Vor einer Wiederherstellung

Vor schreibenden Recovery-Schritten sollten mindestens gesichert beziehungsweise dokumentiert werden:

- aktuelle Unraid-Zuweisungen
- relevante Pool-CFGs
- vorhandene Identity-Baseline
- vorhandene Migrations-Backups
- vorhandener Resume-State
- `/boot/config/go`
- aktuelle Projektversion beziehungsweise Git-Commit

Bei einer laufenden oder unklaren Migration muss zuerst der vorhandene Transaktionszustand verstanden werden.

## Nach einer Wiederherstellung

Eine Wiederherstellung ist erst abgeschlossen, wenn der Zustand nach einem normalen Reboot erneut geprüft wurde.

Ein ausschließlich im laufenden System korrekt aussehender Zustand beweist noch keine Persistenz.
