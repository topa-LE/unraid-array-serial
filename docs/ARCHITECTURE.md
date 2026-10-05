# Architektur

## Inhaltsverzeichnis

- [Übersicht](#übersicht)
- [Grundprinzip](#grundprinzip)
- [Identity Resolver](#identity-resolver)
- [Identity-Tuple](#identity-tuple)
- [Identity-Baseline](#identity-baseline)
- [Autorisierung vor Udev](#autorisierung-vor-udev)
- [Aktivierungs-Preflight](#aktivierungs-preflight)
- [Boot-Integration](#boot-integration)
- [Boot-Diagnose](#boot-diagnose)
- [Installations-Orchestrator](#installations-orchestrator)
- [Array-Migration](#array-migration)
- [Pool-Migration](#pool-migration)
- [Flash-ID](#flash-id)

## Übersicht

Unraid Array Serial besteht aus mehreren bewusst getrennten Ebenen.

```text
Physisches Laufwerk
        |
        v
Hardware-Erkennung
        |
        v
serial-id.sh
        |
        v
stabile Projekt-ID
        |
        v
Identity-Baseline
        |
        v
Autorisierungs-Wrapper
        |
        v
Udev
        |
        v
Unraid
```

Der Unraid-Bootstick durchläuft einen separaten Pfad:

```text
physisches /boot-Laufwerk
        |
        v
flash-id.sh
        |
        v
64-array-serial-flash.rules
        |
        v
zusätzlicher stabiler USB-by-id-Link
```

## Grundprinzip

Die Architektur trennt vier Dinge voneinander:

| Ebene | Neutrales Beispiel | Persistenz |
|---|---|---|
| Linux-Gerätename | `/dev/sdc` | nicht garantiert |
| Hardware-Seriennummer | `EXAMPLE123456` | Hardwaremerkmal |
| Projekt-ID | `VENDOR-MODEL-EXAMPLE123456` | reproduzierbar |
| Unraid-Zuweisung | gespeicherte Array-/Pool-ID | persistent |

Die Beispiele in dieser Dokumentation sind absichtlich generisch und entsprechen keiner realen Testhardware.

Linux-Gerätenamen dürfen niemals als dauerhafte Identität betrachtet werden.

## Identity Resolver

`serial-id.sh` ist der zentrale Resolver für unterstützte Datenlaufwerke.

Er verwendet weitere Hilfskomponenten:

- `detect-transport.sh`
- `format-disk-id.sh`
- `resolve-cached-id.sh`

Die ermittelte Identität wird unter anderem über folgende Eigenschaften beschrieben:

```text
ID_SERIAL_SHORT
ID_SERIAL
IDENTITY_SOURCE
```

## Identity-Tuple

`identity-tuple.sh` stellt die Identität in einer für weitere Sicherheitsprüfungen geeigneten Form bereit.

Das Tuple besteht logisch aus:

```text
Hardware-Seriennummer
Identitätsquelle
Projekt-ID
```

Diese drei Werte bilden gemeinsam die Grundlage der servereigenen Identity-Baseline.

## Identity-Baseline

Die persistente Baseline liegt standardmäßig unter:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

Jede Zeile besitzt exakt drei durch Tabulator getrennte Felder:

```text
HW_SERIAL    SOURCE    APPROVED_ID
```

Die Baseline ist kein Discovery-Cache.

Sie ist eine explizite servereigene Autorisierungsliste.

Eine bereits vorhandene Baseline wird durch den Installations-Orchestrator validiert, aber nicht automatisch durch eine neu ermittelte Baseline ersetzt.

## Autorisierung vor Udev

Die produktiven Udev-Regeln verwenden Autorisierungs-Wrapper:

```text
udev-authorized-id.sh
udev-authorized-partition-id.sh
```

Diese Wrapper ermitteln die aktuelle Identität und vergleichen sie mit der Baseline.

Nur bei einem exakten autorisierten Treffer werden die Projekt-Eigenschaften an Udev ausgegeben.

```text
Hardware
   |
   v
Identität ermitteln
   |
   v
Baseline prüfen
   |
   +---- nicht autorisiert ---> keine Projekt-ID ausgeben
   |
   v
Udev-Eigenschaften ausgeben
```

Damit reicht die bloße technische Fähigkeit, eine ID zu erzeugen, nicht für deren persistente Autorisierung aus.

## Aktivierungs-Preflight

`activation-preflight.sh` prüft bestehende Array- und Pool-Zuweisungen gegen die aktuell angeschlossene Hardware.

Dabei werden unter anderem ausgewertet:

```text
/var/local/emhttp/disks.ini
/var/local/emhttp/var.ini
/boot/config/pools/*.cfg
```

Das Boot-Laufwerk wird aus dem normalen Datenlaufwerkspfad ausgeschlossen.

Der Preflight muss gespeicherte Zuweisungen eindeutig der physischen Hardware zuordnen können.

Zu den möglichen Ergebnissen gehören:

```text
BEREITS_SAUBER
MIGRATION_ERFORDERLICH
UDEV_NICHT_SAUBER
CACHE_NICHT_BASELINEFAEHIG
```

Nur ein vollständig sauberer Zustand darf zur erstmaligen Baseline-Erstellung führen.

Ein System ohne gespeicherte Array- oder Pool-Zuweisungen liefert dem Preflight keine produktive Zuweisungsgrundlage. Eine völlig unkonfigurierte Neuinstallation darf daher nicht mit einem bereits zugewiesenen, aber noch baseline-losen System verwechselt werden.

## Boot-Integration

Unraid baut wesentliche Teile seines Laufzeitsystems bei jedem Boot neu auf.

Deshalb werden die Runtime-Udev-Regeln bei jedem Start erneut installiert.

Persistente Projektquelle:

```text
/boot/config/custom/array-serial/
```

Runtime-Regeln:

```text
/etc/udev/rules.d/
```

`enable-boot.sh` richtet die Kern-Hooks in `/boot/config/go` ein.

Der zentrale Orchestrator `install.sh` prüft zunächst, ob die Kern-Hooks bereits eindeutig vorhanden sind.

Sind `boot-log.sh`, `boot-capture.sh` und `install-boot.sh` jeweils genau einmal vorhanden, muss `enable-boot.sh` nicht erneut ausgeführt werden.

Der separate persistente Flash-Hook wird ebenfalls durch den Orchestrator geprüft.

## Boot-Diagnose

Zwei Komponenten erfassen den frühen Bootzustand:

```text
boot-log.sh
boot-capture.sh
```

Persistente Diagnoseinformationen werden unter:

```text
/boot/logs/array-serial/
```

abgelegt.

`boot-capture.sh` erstellt mehrere zeitversetzte Snapshots während der Bootphase.

Damit lassen sich Blockgeräte, Udev-Eigenschaften und der Unraid-Zustand während des Starts nachvollziehen.

## Installations-Orchestrator

`scripts/install.sh` koordiniert die Installation beziehungsweise Aktualisierung der bereits auf dem Zielserver bereitgestellten Projektdateien.

Der Ablauf umfasst:

1. erforderliche Projektdateien prüfen,
2. Shell-Syntax prüfen,
3. bestehende Baseline validieren oder nach erfolgreichem Preflight einmalig erzeugen,
4. Kern-Boot-Hooks prüfen,
5. Flash-Boot-Hook prüfen,
6. Runtime-Udev-Regeln installieren beziehungsweise prüfen,
7. baseline-autorisierte Laufwerke initialisieren,
8. Flash-ID aktivieren,
9. Abschlusskontrolle durchführen.

Eine vorhandene Baseline wird nicht automatisch ersetzt.

`install.sh` ist kein Repository-Downloader und keine Git-Synchronisation. Die Projektdateien müssen vor seinem Aufruf bereits vollständig im persistenten Projektverzeichnis liegen.

## Array-Migration

Die Migration bestehender Array-IDs ist vom normalen Installationspfad getrennt.

Zentrale Komponenten sind:

```text
migrate-array-ids.sh
md-migration-transaction.sh
```

Der entwickelte sichere Pfad arbeitet mehrphasig und hält zwischen den Phasen einen persistenten Resume-State.

Der Array-Pfad wurde in realen Zwei-Phasen- und Reboot-Tests entwickelt und verifiziert. Ein erfolgreicher Slot-Persistenztest darf dabei nicht mit einer pauschalen Aussage über die Gültigkeit vorhandener Paritätsdaten verwechselt werden.

Details:

[MIGRATION.md](MIGRATION.md)

## Pool-Migration

Pools besitzen einen eigenen Migrationspfad:

```text
migrate-pool-ids.sh
pool-migration-transaction.sh
```

Array- und Pool-Migration werden intern bewusst als getrennte Transaktionspfade behandelt.

Für den normalen Benutzer orchestriert `install.sh` eine erforderliche Pool-ID-Migration automatisch.

Nach erfolgreicher Pool-Migration erzeugt der kontrollierte Übergangspfad die vollständige Identity-Baseline, bevor die persistenten Udev-Regeln aktiviert und anschließend streng geprüft werden.

Der Pool-Transaktionspfad sichert die betroffenen Konfigurationsdateien und besitzt einen Rollback-Pfad für bereits geschriebene Konfigurationen.

## Flash-ID

Der Unraid-Bootstick gehört nicht zur normalen Datenlaufwerks-Baseline.

Resolver:

```text
flash-id.sh
```

Installation:

```text
install-flash-id.sh
```

Udev-Regel:

```text
64-array-serial-flash.rules
```

Der Flash-Pfad erzeugt einen stabilen Projekt-Link. Nach erfolgreicher Verifikation entfernt `install-flash-id.sh` konkurrierende USB-by-id-Links, die auf dasselbe physische Unraid-Boot-Laufwerk zeigen, bevor `emhttp` gestartet wird.

Details:

[FLASH-ID.md](FLASH-ID.md)
