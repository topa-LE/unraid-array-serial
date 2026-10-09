# Installation und Update

## Inhaltsverzeichnis

- [Ziel](#ziel)
- [Voraussetzungen](#voraussetzungen)
- [Repository als Quelle](#repository-als-quelle)
- [Erstinstallation](#erstinstallation)
- [Ablauf des Orchestrators](#ablauf-des-orchestrators)
- [Reboot](#reboot)
- [Update](#update-eines-bereits-eingerichteten-systems)
- [Wichtige Grenze](#wichtige-grenze)
- [Unkonfiguriertes Neusystem](#unkonfiguriertes-neusystem)
- [Erfolgreicher Referenzlauf](#erfolgreicher-referenzlauf)

## Ziel

Dieses Dokument beschreibt die Installation beziehungsweise Aktualisierung von Unraid Array Serial auf einem Zielsystem.

Der GitHub-Bootstrap stellt die Repository-Dateien automatisch bereit. Bei manueller Installation müssen sie vor dem Aufruf des Orchestrators vollständig unter folgendem Verzeichnis vorhanden sein:

```text
/boot/config/custom/array-serial/
```

## Voraussetzungen

Vor der Installation sollten mindestens folgende Bedingungen erfüllt sein:

- Zielsystem läuft mit einem vorgesehenen und geprüften Unraid-Stand.
- Array- und Pool-Zuweisungen sind bekannt.
- Die Projektdateien stammen aus einem kontrollierten Repository-Stand.
- Der Administrator besitzt Root-Zugriff.
- Vor produktiven Migrationen existiert ein aktuelles Backup.
- Bestehende Gerätezuweisungen werden nicht manuell verändert.

Referenztests mit bestehenden Array-/Pool-Zuweisungen und Reboot wurden unter **Unraid 7.3.2** durchgeführt. Eine vollständige GitHub-Erstinstallation auf einem neuen Server mit sieben Datenlaufwerken wurde unter **Unraid 7.3.3** erfolgreich abgeschlossen; der Reboot-Test steht noch aus.

## Repository als Quelle

Die Projektdateien sollen aus dem Repository stammen.

Ein Zielserver soll nicht als Quelle für einen anderen Zielserver verwendet werden.

```text
Entwicklungs-/Build-System
        |
        v
Git-Repository
        |
        v
Zielserver
```

> [!IMPORTANT]
> `unraid-orchestrator.sh` synchronisiert das Repository nicht selbst. Der GitHub-Bootstrap übernimmt die Bereitstellung der Projektdateien vor dem Start des Orchestrators.

## Erstinstallation

### Direkte Installation über GitHub

Auf dem Unraid-Server als `root`:

~~~bash
curl -fsSL https://raw.githubusercontent.com/topa-LE/unraid-array-serial/main/scripts/bootstrap.sh | bash
~~~

Der Bootstrap lädt den Repository-Stand herunter, prüft die
Shell-Syntax der Skripte, installiert die Projektdateien unter
`/boot/config/custom/array-serial/` und startet den Orchestrator.

Dieser Weg ist für Erstinstallation und Update vorgesehen.
Bei bestehenden Array- oder Pool-Zuweisungen gelten weiterhin
die Sicherheits- und Migrationsprüfungen des Orchestrators.

### Manueller Aufruf des Orchestrators

Alternativ zum GitHub-Bootstrap wird nach manueller Bereitstellung der Projektdateien auf dem Zielserver als `root` ausgeführt:

```bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh
```

Der Orchestrator führt die Prüfungen in definierter Reihenfolge aus.

## Ablauf des Orchestrators

### 1. Projektdateien

Zunächst wird geprüft, ob die für die Installation notwendigen Skripte und Udev-Regeln vorhanden sind.

Fehlt eine Pflichtdatei, wird die Installation abgebrochen.

### 2. Shell-Syntax

Die zentralen Shell-Skripte werden mit Bash syntaktisch geprüft.

Bei einem Syntaxfehler wird nicht weiter installiert.

### 3. Server-Identity und Baseline

Existiert bereits:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

wird diese validiert.

Eine vorhandene Baseline wird nicht automatisch ersetzt.

Existiert noch keine Baseline, ruft der Orchestrator den Activation-Preflight auf und verwendet dessen validierten Baseline-Writer.

Nur wenn die gespeicherten Array- und Pool-Zuweisungen eindeutig, bereits sauber und baseline-fähig sind, darf eine neue Baseline geschrieben werden.

> [!IMPORTANT]
> Bei einer bereits vorhandenen Baseline validiert `unraid-orchestrator.sh` die Baseline selbst. Der Orchestrator führt in diesem Zweig nicht automatisch erneut den vollständigen Assignment-Preflight gegen die aktuelle Hardwarebelegung aus. Eine Hardware- oder Zuweisungsänderung darf deshalb nicht dadurch „bestätigt“ werden, dass lediglich der Installer erneut gestartet wird.

### 4. Persistenter Kern-Boot-Ablauf

Geprüft werden:

```text
boot-log.sh
boot-capture.sh
install-boot.sh
```

Sind diese Hooks bereits jeweils genau einmal vorhanden, wird der bestehende Kern-Boot-Ablauf beibehalten.

Andernfalls wird `enable-boot.sh` verwendet.

Mehrfach vorhandene beziehungsweise widersprüchliche Hooks werden nicht stillschweigend akzeptiert.

### 5. Flash-Boot-Persistenz

Zusätzlich wird geprüft, ob:

```text
install-flash-id.sh
```

genau einmal im persistenten Bootablauf vorhanden ist.

Der Flash-Hook wird vor dem Start der Unraid Management Utility eingebunden.

### 6. Array-/Pool-Udev

`install-boot.sh` installiert beziehungsweise aktualisiert die Runtime-Regeln:

```text
59-array-serial.rules
61-array-serial-nvme.rules
62-array-serial-partitions.rules
63-array-serial-nvme-links.rules
```

Anschließend werden nur baseline-autorisierte Geräte initialisiert.

Das physische Boot-Laufwerk wird aus diesem normalen Laufwerkspfad ausgeschlossen.

### 7. Flash-ID

`install-flash-id.sh` installiert:

```text
64-array-serial-flash.rules
```

und initialisiert ausschließlich das physische Laufwerk, auf dem `/boot` liegt.

### 8. Abschlusskontrolle

Zum Abschluss werden unter anderem geprüft:

- Identity-Baseline
- Runtime-Udev-Regeln
- persistente Boot-Hooks
- Flash-ID Runtime
- Flash-ID Boot-Persistenz

Ein erfolgreicher Installationslauf endet mit:

```text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
```

## Reboot

Erst nach vollständig erfolgreicher Installation sollte das System normal neu gestartet werden.

Nach dem Neustart müssen mindestens geprüft werden:

- Host ist wieder erreichbar.
- Array-Serial-Boot-Hooks sind weiterhin jeweils genau einmal vorhanden.
- Runtime-Udev-Regeln wurden erneut installiert.
- Identity-Baseline ist weiterhin gültig.
- Flash-by-id-Link wurde erneut erzeugt.
- Array- und Pool-Zuweisungen entsprechen dem erwarteten Zustand.
- Array kann normal gestartet werden.

## Update eines bereits eingerichteten Systems

Bei einem Update werden die aktuellen Repository-Dateien erneut vollständig unter:

```text
/boot/config/custom/array-serial/
```

bereitgestellt.

Anschließend wird derselbe Orchestrator erneut ausgeführt:

```bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh
```

Der Orchestrator ist für wiederholte Ausführung ausgelegt.

Eine vorhandene gültige Baseline wird dabei nicht automatisch ersetzt.

Bereits korrekt vorhandene Kern-Boot-Hooks werden nicht unnötig neu aufgebaut.

> [!NOTE]
> Der Orchestrator ist kein allgemeiner Dateisynchronisierer und entfernt nicht automatisch jede möglicherweise aus älteren Entwicklungsständen übrig gebliebene Datei. Die Bereitstellung des Repository-Standes und die Installation sind getrennte Aufgaben.

## Wichtige Grenze

`unraid-orchestrator.sh` ist kein Ersatz für eine notwendige Array- oder Pool-ID-Migration.

Meldet der Activation-Preflight:

```text
MIGRATION_ERFORDERLICH
```

muss zuerst der dafür vorgesehene Array-Migrationspfad verwendet werden.

Auf dem Unraid-Server als `root`:

~~~bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh --migrate-array
~~~

Nur wenn dieser Lauf erfolgreich abgeschlossen wurde und

~~~text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
~~~

ausgibt, wird Unraid normal neu gestartet:

~~~bash
reboot
~~~

Nach dem Neustart wird Phase B automatisch über den persistenten Resume-Hook
fortgesetzt. Interne Migrationsskripte müssen nicht manuell aufgerufen werden.

Der sichere Migrationspfad verwendet anschließend eine
Paritäts-Synchronisation und markiert vorhandene Paritätsdaten nicht ungeprüft
als gültig.

Eine neue Baseline darf nicht dazu benutzt werden, eine noch nicht migrierte gespeicherte Unraid-Zuweisung zu übergehen.

Siehe:

[MIGRATION.md](MIGRATION.md)

## Unkonfiguriertes Neusystem

Ein „neuer Server“ kann zwei unterschiedliche Zustände bedeuten:

1. Unraid besitzt bereits gespeicherte Array-/Pool-Zuweisungen, aber noch keine Array-Serial-Baseline.
2. Das System ist vollständig unkonfiguriert und besitzt noch keine gespeicherten Array-/Pool-Zuweisungen.

Der Activation-Preflight benötigt gespeicherte Zuweisungen als Grundlage seiner Sicherheitsprüfung.

Ein vollständig unkonfiguriertes System ohne gespeicherte Array-/Pool-Zuweisungen wird über den gesonderten New-Server-Pfad behandelt.

`install-new-server.sh` prüft diesen Zustand und ermittelt die stabilen Gerätekennungen. Die Baseline darf nur nach erfolgreicher Prüfung erstellt werden.

Bestehende Array-/Pool-Zuweisungen dürfen nicht über diesen Pfad umgangen werden.

## Erfolgreicher Referenzlauf

Der aktuelle Orchestrator wurde auf einem Unraid-7.3.2-System vollständig ausgeführt.

Der Test umfasste:

- vorhandenes Array
- Pools
- NVMe
- USB-SATA
- servereigene Baseline
- persistenten Bootablauf
- separaten Flash-ID-Pfad
- vollständigen Reboot

Nach dem Reboot waren die Projekt-Hooks weiterhin vorhanden, die Baseline unverändert gültig und der zusätzliche Flash-by-id-Link erneut vorhanden.

Anschließend konnte das Array normal gestartet werden.
