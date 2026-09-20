# Unraid Array Serial

Stabile Laufwerksidentifikation fuer Unraid.

## Projektstatus

Entwicklung. Noch kein universeller Installer und keine Freigabe
fuer den Einsatz auf weiteren Unraid-Servern.

## Bisher getesteter Stand

Unraid 7.3.2, USB-SATA-Adapter VIA Labs 2109:0715.

Die Referenzimplementierung liest die ATA-Seriennummer ueber
smartctl und uebergibt sie an udev.

## Geplante Erweiterungen

- Geraetekennung aus Hersteller, Modell und echter Seriennummer
- Unterstuetzung weiterer USB-SATA-Adapter
- Pruefung der Identifikation von Array-, Cache- und Pool-Laufwerken
- Versionspruefung, Installation, Sicherung und Deinstallation

Bestehende Laufwerkszuordnungen und ZFS-Metadaten werden nicht
automatisch veraendert.
