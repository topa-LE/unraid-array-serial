![Unraid](https://img.shields.io/badge/Unraid-7.3.2%20Tested-orange?style=for-the-badge)
![Shell](https://img.shields.io/badge/Shell-Bash-blue?style=for-the-badge&logo=gnubash&logoColor=white)
![Architecture](https://img.shields.io/badge/ARCH-x86__64-blueviolet?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Reference%20Tested-brightgreen?style=for-the-badge)

[![🇩🇪 Deutsch](https://img.shields.io/badge/lang-DE-blue)](./README.md)
[![🇬🇧 English](https://img.shields.io/badge/lang-EN-red)](./docs/README-EN.md)
![Stars](https://img.shields.io/github/stars/topa-LE/unraid-array-serial)

# 🗄️ Unraid Serial – Eindeutige Gerätezuordnung

**Stabile, lesbare und reproduzierbare Laufwerksidentitäten für Unraid.**

> [!NOTE]
> ### Über Unraid
>
> **[Unraid OS](https://unraid.net/)** ist ein flexibles Betriebssystem für selbst gehostete Server und Network-Attached Storage (NAS). Es ermöglicht unter anderem den Aufbau von Arrays und Pools mit unterschiedlichen Laufwerken und bietet darüber hinaus eine Plattform für Docker-Anwendungen und virtuelle Maschinen.
>
> **Unraid Serial** ergänzt diese Plattform um stabile, lesbare und reproduzierbare Geräteidentitäten für Array-Laufwerke, Pools und Boot-Geräte.

Unraid Serial erzeugt aus verifizierten Hardwaremerkmalen stabile Gerätekennungen für SATA/ATA-, USB-SATA- und NVMe-Laufwerke.

Die Kennungen werden über Udev in den laufenden Unraid-Betrieb integriert und durch eine servereigene **Identity-Baseline** gegen unbeabsichtigte Identitätsänderungen abgesichert.

Das Projekt enthält zusätzlich einen getrennten Identitätspfad für den Unraid-USB-Bootstick, Werkzeuge zur kontrollierten Migration bestehender Array- und Pool-Zuweisungen sowie persistente Boot-Diagnosefunktionen.

> [!IMPORTANT]
> Dieses Projekt verändert beziehungsweise ergänzt Geräteidentitäten, die Unraid für persistente Laufwerkszuweisungen verwenden kann. Bestehende Systeme müssen deshalb vor der Aktivierung eindeutig geprüft beziehungsweise kontrolliert migriert werden.

---

## 📑 Inhaltsverzeichnis

- [Projektstatus](#-projektstatus)
- [Ziel des Projekts](#-ziel-des-projekts)
- [Sicherheitsprinzip](#-sicherheitsprinzip)
- [Identitätsquellen](#-unterstützte-persistente-identitätsquellen)
- [Udev-Regeln](#-udev-regeln)
- [Boot-Ablauf](#-boot-ablauf)
- [Installation](#-installation)
- [Dokumentation](#-dokumentation)
- [Repository-Struktur](#-repository-struktur)
- [Migrationen](#-wichtiger-hinweis-zu-migrationen)
- [Getestete Referenz](#-getestete-referenz)

---

## 🚦 Projektstatus

Der aktuelle Entwicklungsstand wurde praktisch unter **Unraid 7.3.2** getestet.

Verifiziert wurden unter anderem:

- direkte SATA/ATA-Laufwerke
- SATA-Laufwerke hinter USB-SATA-Bridges
- NVMe-Laufwerke
- Partitionen unterstützter Laufwerke
- persistente Udev-Regeln über einen Reboot
- servereigene Identity-Baseline
- separater persistenter Flash-ID-Pfad
- Zwei-Phasen-Migration von Array-Zuweisungen
- Reboot-Persistenz eines Arrays mit Parität und sieben Datenplatten
- Pool-ID-Migrationsmechanismen im Projekt
- idempotenter Installations-Orchestrator

**👉 Der zentrale Installations-Orchestrator ist:**

```bash
/boot/config/custom/array-serial/install.sh
```

**👉 Ein erfolgreicher Lauf endet mit:**

```text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
```

> [!NOTE]
> Die Angabe „Unraid 7.3.2 Tested“ beschreibt den praktisch verifizierten Referenzstand. Sie ist keine pauschale Aussage über jede ältere oder zukünftige Unraid-Version.

---

## 🎯 Ziel des Projekts

Linux-Gerätenamen wie:

```text
/dev/sda
/dev/sdb
/dev/sdc
/dev/nvme0n1
```

sind keine dauerhaft geeigneten Geräteidentitäten.

Ihre Zuordnung kann sich durch Bootreihenfolge, Controller, USB-Bridges oder Änderungen an der Hardwareerkennung verändern.

Unraid Array Serial trennt deshalb konsequent zwischen:

> **1 · Linux-Gerätename**
>
> Flüchtige Bezeichnung des aktuell erkannten Blockgeräts, z. B. `/dev/sda`.
>
> **2 · Hardwareidentität**
>
> Die tatsächlich vom Gerät ermittelte Identität.
>
> **3 · Projekt-ID**
>
> Die daraus erzeugte stabile und lesbare Geräte-ID.
>
> **4 · Unraid-Zuweisung**
>
> Die von Unraid gespeicherte Zuordnung des Geräts.
>
> **5 · Identity-Baseline**
>
> Die explizit autorisierte, servereigene Identität.

Eine Geräte-ID wird nicht allein deshalb persistent freigegeben, weil sie technisch erzeugt werden kann.

---

## 🛡️ Sicherheitsprinzip

Das Projekt arbeitet nach einem **Fail-Closed-Prinzip**.

Bei fehlender, widersprüchlicher oder mehrdeutiger Hardwareidentität soll die Verarbeitung stoppen, anstatt eine persistente Gerätezuordnung zu erraten.

Vor der erstmaligen Baseline-Erstellung werden bestehende Array- und Pool-Zuweisungen durch den Activation-Preflight geprüft.

Eine bereits vorhandene gültige Baseline wird vom Installations-Orchestrator **nicht automatisch ersetzt**.

> [!WARNING]
> Eine notwendige Migration darf niemals dadurch umgangen werden, dass eine neue Baseline über bestehende, noch nicht migrierte Unraid-Zuweisungen gelegt wird.

---

## 🧬 Unterstützte persistente Identitätsquellen

| Quelle | Bedeutung | Baseline-fähig |
|---|---|---:|
| `ATA` | direkte ATA/SATA-Hardwareidentität | Ja |
| `USB_SAT` | ATA/SAT-Identität hinter USB-SATA | Ja |
| `NVME` | native NVMe-Hardwareidentität | Ja |
| `CACHE` | vorher verifizierter Fallback | Nein |
| `FLASH` | separater Unraid-Bootstick-Pfad | Separate Behandlung |

`CACHE` ist bewusst nicht für die persistente Identity-Baseline zugelassen.

Der Unraid-Bootstick wird ebenfalls nicht in die normale Laufwerks-Baseline aufgenommen. Er besitzt einen eigenen isolierten Flash-ID-Pfad.

Mehr dazu:

➡️ [Identity-Modell](docs/IDENTITY-MODEL.md)

---

## ⚙️ Udev-Regeln

| Regel | Aufgabe |
|---|---|
| `59-array-serial.rules` | autorisierte Whole-Disk-Identitäten für SATA/ATA, USB-SATA und NVMe |
| `61-array-serial-nvme.rules` | erneute NVMe-Normalisierung nach der systemweiten Regel 60 |
| `62-array-serial-partitions.rules` | stabile Identität für Partitionen |
| `63-array-serial-nvme-links.rules` | zusätzliche stabile NVMe-by-id-Links |
| `64-array-serial-flash.rules` | isolierte Identität des Unraid-Bootsticks |

Die Regeln werden aus der persistenten Projektinstallation bei jedem Boot wieder in das Unraid-Laufzeitsystem eingebracht.

---

## 🚀 Boot-Ablauf

Der persistente Boot-Ablauf wird über:

```text
/boot/config/go
```

eingebunden.

Die Projektkomponenten sind:

```text
boot-log.sh
boot-capture.sh
install-boot.sh
install-flash-id.sh
```

`install-boot.sh` installiert die Laufwerksregeln und initialisiert nur Geräte, deren ermittelte Identität zur gültigen servereigenen Baseline passt.

`install-flash-id.sh` behandelt ausschließlich das physische Laufwerk, auf dem `/boot` liegt.

Der Bootstick bleibt damit technisch vom normalen Array-/Pool-Identity-Pfad getrennt.

---

## 📦 Installation

Die Projektdateien müssen zunächst vollständig unter:

```text
/boot/config/custom/array-serial/
```

auf dem Unraid-Zielsystem vorhanden sein.

Danach wird als `root` ausgeführt:

```bash
/bin/bash /boot/config/custom/array-serial/install.sh
```

> [!IMPORTANT]
> `install.sh` lädt das Git-Repository nicht selbst herunter und synchronisiert es nicht selbst. Der Orchestrator setzt voraus, dass die aktuellen Projektdateien bereits vollständig im Projektverzeichnis vorhanden sind.

Bei einer erstmaligen Baseline-Erstellung müssen bereits gespeicherte Array- beziehungsweise Pool-Zuweisungen vorhanden und eindeutig prüfbar sein.

Ein vollständig jungfräuliches System ohne gespeicherte Zuweisungen ist daher noch **nicht** der Zustand, in dem automatisch eine produktive Baseline erzeugt werden kann.

Die vollständige Anleitung befindet sich unter:

➡️ [Installation und Update](docs/INSTALLATION.md)

---

## 📚 Dokumentation

| Dokument | Inhalt |
|---|---|
| [Architektur](docs/ARCHITECTURE.md) | Komponenten, Sicherheitsgrenzen und Datenfluss |
| [Installation](docs/INSTALLATION.md) | Installation, Update und Reboot-Kontrolle |
| [Identity-Modell](docs/IDENTITY-MODEL.md) | Hardwareidentität, Projekt-ID und Baseline |
| [Flash-ID](docs/FLASH-ID.md) | separater Identitätspfad des Bootsticks |
| [Migration](docs/MIGRATION.md) | Array- und Pool-ID-Migration |
| [Recovery](docs/RECOVERY.md) | Fehlerfälle, Backups und Wiederherstellung |
| [Historie](docs/HISTORY.md) | Entwicklung und wichtige Meilensteine |
| [Entwicklungsprotokoll](docs/ARRAY-ID-MIGRATION-DEVELOPMENT.md) | historische technische Untersuchungen und Entwicklungstests |

---

## 🗂️ Repository-Struktur

```text
unraid-array-serial/
├── README.md
├── config/
│   ├── README.md
│   └── verified-manufacturers.tsv
├── docs/
│   ├── ARCHITECTURE.md
│   ├── ARRAY-ID-MIGRATION-DEVELOPMENT.md
│   ├── FLASH-ID.md
│   ├── HISTORY.md
│   ├── IDENTITY-MODEL.md
│   ├── INSTALLATION.md
│   ├── MIGRATION.md
│   └── RECOVERY.md
├── reference/
│   └── unraid-7.3.2/
└── scripts/
    └── ...
```

`reference/` enthält Referenzmaterial des untersuchten Unraid-Standes.

Die produktive Projektlogik befindet sich unter `scripts/`.

---

## ⚠️ Wichtiger Hinweis zu Migrationen

Die Installation des Projekts und die Migration bestehender Unraid-Zuweisungen sind zwei unterschiedliche Vorgänge.

Wenn eine bestehende gespeicherte Unraid-ID nicht bereits der erwarteten Projekt-ID entspricht, darf nicht einfach eine neue Baseline darübergelegt werden.

In diesem Fall muss zuerst der dafür vorgesehene Migrationspfad verwendet werden.

➡️ [Migration bestehender Geräte-IDs](docs/MIGRATION.md)

Bei der Array-Migration wird ein kontrollierter mehrphasiger Transaktionspfad verwendet. Die Entwicklungstests bestätigten die persistente Slot-Zuordnung nach dem Reboot.

Das bedeutet ausdrücklich **nicht**, dass vorhandene Paritätsdaten nach jedem New-Config-artigen Vorgang automatisch als gültig angesehen werden dürfen. Im dokumentierten Paritätstest wurde eine Paritäts-Rekonstruktion gestartet.

---

## ✅ Getestete Referenz

Der aktuelle Installations-Orchestrator wurde auf einem **Unraid-7.3.2-System** mit bestehendem Array, Pools, NVMe, USB-SATA und USB-Bootstick vollständig ausgeführt und über einen normalen Reboot geprüft.

Nach dem Reboot wurden unter anderem bestätigt:

- alle vier persistenten Projekt-Hooks vorhanden
- Runtime-Udev-Regeln erneut installiert
- servereigene Identity-Baseline weiterhin gültig
- Baseline unverändert
- separater Flash-by-id-Link erneut vorhanden
- keine offene Array-Migrations-Resume-Datei
- Array anschließend normal gestartet

Damit ist der vollständige Installations-, Boot- und Reboot-Pfad des aktuellen Orchestrators auf dem Referenzsystem praktisch bestätigt.

---

## 📖 Weiterführende Informationen

Die Dokumente unter [`docs/`](docs/) beschreiben Architektur, Installation, Identity-Modell, Flash-ID, Migration, Recovery und Entwicklungshistorie im Detail.

Die historische Datei [ARRAY-ID-MIGRATION-DEVELOPMENT.md](docs/ARRAY-ID-MIGRATION-DEVELOPMENT.md) bleibt bewusst erhalten. Sie dokumentiert auch frühere Untersuchungen und verworfene Ansätze und ist daher als Entwicklungsprotokoll zu lesen.

---

## Lizenz

Dieses Projekt wird unter der **MIT-Lizenz** veröffentlicht.

Copyright © 2026 **topa-LE**

Siehe [`LICENSE`](./LICENSE) für den vollständigen Lizenztext.
