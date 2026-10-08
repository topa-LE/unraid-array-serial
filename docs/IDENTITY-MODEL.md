# Identity-Modell

## Inhaltsverzeichnis

- [Warum eine eigene Geräteidentität?](#warum-eine-eigene-geräteidentität)
- [Drei zentrale Werte](#drei-zentrale-werte)
- [Identitätsquellen](#identitätsquellen)
- [Projekt-ID](#projekt-id)
- [Identity-Baseline](#identity-baseline)
- [Baseline-Erstellung](#baseline-erstellung)
- [Baseline-Validierung](#baseline-validierung)
- [Udev-Autorisierung](#udev-autorisierung)
- [Partitionen](#partitionen)
- [Fail-Closed](#fail-closed)

## Warum eine eigene Geräteidentität?

Linux-Gerätenamen werden während der Geräteerkennung vergeben.

Bezeichnungen wie:

```text
/dev/sda
/dev/sdb
/dev/sdc
/dev/nvme0n1
```

beschreiben deshalb nicht dauerhaft ein bestimmtes physisches Laufwerk.

Unraid benötigt dagegen reproduzierbare Gerätekennungen.

Unraid Array Serial erzeugt solche Kennungen aus verifizierten Hardwareinformationen.

## Drei zentrale Werte

Für die Autorisierung werden drei Werte gemeinsam betrachtet:

| Wert | Bedeutung |
|---|---|
| `ID_SERIAL_SHORT` | echte beziehungsweise verifizierte Hardware-Seriennummer |
| `IDENTITY_SOURCE` | Herkunft der Identität |
| `ID_SERIAL` | normalisierte Projekt-ID |

Diese Werte bilden gemeinsam eine Identität.

## Identitätsquellen

### ATA

Direkte SATA/ATA-Laufwerke können ihre Hardwareidentität über den ATA-Pfad bereitstellen.

```text
ATA
```

### USB-SAT

Bei geeigneten USB-SATA-Bridges kann die ATA/SAT-Identität des dahinterliegenden Laufwerks ermittelt werden.

```text
USB_SAT
```

Die USB-Bridge selbst darf nicht mit der Identität der eingebauten Festplatte verwechselt werden.

### NVMe

NVMe-Laufwerke werden über ihren nativen NVMe-Pfad behandelt.

```text
NVME
```

Da die Standard-Udev-Verarbeitung die NVMe-ID später erneut verändern kann, besitzt das Projekt eine gezielte Nachbearbeitung über Regel 61.

### CACHE

Für problematische Hardwarepfade existiert ein persistenter Identity-Cache-Fallback.

```text
CACHE
```

Dieser Fallback kann eine zuvor verifizierte Identität bereitstellen.

`CACHE` ist jedoch ausdrücklich **nicht** für die persistente Identity-Baseline zugelassen.

Der Cache ist kein automatisches Lernsystem und ersetzt keine belastbare Hardwareidentität.

### FLASH

Der physische Unraid-Bootstick besitzt eine getrennte Identitätsquelle:

```text
FLASH
```

Er gehört nicht in die normale Datenlaufwerks-Baseline.

## Projekt-ID

Die Projekt-ID ist eine normalisierte, lesbare Gerätekennung.

Neutrales Beispiel:

```text
VENDOR-MODEL-EXAMPLE123456
```

Das Beispiel entspricht keiner realen Testhardware.

Die Projekt-ID soll unabhängig davon bleiben, ob das Laufwerk während eines bestimmten Boots beispielsweise als `/dev/sdc` oder `/dev/sdh` erkannt wird.

## Identity-Baseline

Die Baseline befindet sich standardmäßig unter:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

Sie enthält exakt drei TSV-Felder:

```text
HW_SERIAL    SOURCE    APPROVED_ID
```

Logisch beschreibt jede Zeile:

```text
Hardware-Seriennummer
        +
erlaubte Identitätsquelle
        +
erlaubte Projekt-ID
```

Die Baseline ist damit eine servereigene Autorisierungsliste.

## Was die Baseline nicht ist

Die Baseline ist nicht:

- eine Liste aktueller `/dev/sdX`-Namen
- eine automatische Hardware-Lerndatenbank
- ein Ersatz für eine Migration
- ein Mechanismus zum automatischen Übernehmen eines Ersatzlaufwerks
- eine Liste des Unraid-Bootsticks

## Baseline-Erstellung

Vor einer erstmaligen Baseline-Erstellung prüft `activation-preflight.sh` die bestehenden gespeicherten Unraid-Zuweisungen.

Jede gespeicherte Array- oder Pool-ID muss eindeutig einem physischen Laufwerk zugeordnet werden können.

Eine Baseline darf erst entstehen, wenn die gespeicherten Zuweisungen bereits mit den erwarteten Projekt-IDs übereinstimmen und die verwendeten Quellen baseline-fähig sind.

Sind überhaupt keine gespeicherten Array-/Pool-Zuweisungen vorhanden, fehlt dem Preflight die Grundlage für diese Freigabe.

## Baseline-Validierung

`identity-baseline.sh` prüft unter anderem Struktur, Eindeutigkeit und Zulässigkeit der Einträge.

Persistente Baseline-Quellen sind:

```text
ATA
NVME
USB_SAT
```

`CACHE` wird als persistente Baseline-Quelle abgewiesen.

Eine vorhandene Baseline wird durch `unraid-orchestrator.sh` validiert, aber nicht automatisch neu aus der aktuellen Hardwarebelegung erzeugt.

## Udev-Autorisierung

Die Udev-Regeln verwenden die Wrapper:

```text
udev-authorized-id.sh
udev-authorized-partition-id.sh
```

Der Wrapper ermittelt die aktuelle Identität und vergleicht sie exakt mit der Baseline.

Nur bei einem autorisierten Treffer werden die Projekt-Eigenschaften ausgegeben.

## Partitionen

Partitionen erhalten die stabile Identität ihres Whole-Disk-Parents über den dafür vorgesehenen Partitionspfad.

```text
udev-authorized-partition-id.sh
        |
        v
partition-id.sh
        |
        v
Parent-Disk
```

Dabei werden keine Partitionstabellen, Dateisysteme, UUIDs oder Nutzdaten verändert.

## Fail-Closed

Kann eine Identität nicht eindeutig bestimmt oder autorisiert werden, ist das gewünschte Verhalten ein Abbruch beziehungsweise das Nicht-Ausgeben der Projektidentität.

Das Projekt soll niemals aufgrund eines wechselnden Linux-Gerätenamens eine persistente Identität erraten.
