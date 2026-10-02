# Filelio 1.0.0

Autor: CreativTechnik

Filelio ist eine native macOS-Menüleisten-App zum Benennen, Sortieren und
Verwalten von Dateien. Alle Dateioperationen laufen lokal auf dem Mac. Die App
überträgt keine Dateien und verwendet keine Analyse- oder Werbedienste.

## Funktionen

- mehrere unabhängige Ordnerstrukturen überwachen
- vollständige Namensvorschau und gemeinsame Warteschlange
- Namensschema, Präfix, Trennzeichen und Datumsformat je Struktur
- Ordner, Dateinamen und Dateitypen gezielt ausschließen
- Umbenennungsverlauf mit sicherer Rückgängig-Funktion
- Konfiguration exportieren und importieren
- Downloads und Screenshots einmalig oder dauerhaft sortieren
- Dateien regelbasiert verschieben und den Schreibtisch organisieren
- große Dateien und inhaltsgleiche Duplikate finden
- externe Datenträger sicher auswerfen
- PDFs zusammenfügen sowie Bilder verkleinern und konvertieren
- Finder-Symbolleistenschaltfläche und zwei Finder-Dienste

Temporäre Dateien, unvollständige Downloads und noch nicht lokal verfügbare
Cloud-Dateien werden übersprungen. Leerzeichen in Datei- und Ordnernamen bleiben
erhalten. Dateien werden niemals automatisch gelöscht.

## Finder-Integration

Die Erweiterung „Filelio Finder“ stellt in Finder-Fenstern diese Aktionen bereit:

- Filelio öffnen
- Auswahl zur Umbenennung prüfen
- neue Dateinamen vorschauen
- aktuellen Ordner einmalig organisieren
- aktuellen Ordner dauerhaft überwachen

Aktivierung: Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen →
Finder → Filelio Finder.

Die Erweiterung führt selbst keine Dateiscans aus und besitzt keine
Abfrage-Timer. Sie übergibt lediglich die aktuelle Finder-Auswahl an Filelio.

## Sicherheit und Ressourcen

Filelio verwendet die macOS App Sandbox und speichert Zugriffsrechte nur für
Ordner, die im Systemdialog ausdrücklich bestätigt wurden. Ordneränderungen
werden ereignisbasiert mit FSEvents verarbeitet und gebündelt. Aufwendige
Analysen laufen mit energiesparender Hintergrundpriorität und nur auf Anforderung.

## Installation

1. Öffne `Filelio-1.0.0.dmg`.
2. Ziehe `Filelio.app` in den Ordner „Programme“.
3. Starte Filelio und richte die gewünschten Ordnerstrukturen ein.
4. Aktiviere bei Bedarf „Filelio Finder“ in den Systemeinstellungen.

Die lokal erzeugte Ausgabe ist ad-hoc signiert. Für eine öffentliche Verteilung
ohne Gatekeeper-Warnung werden ein Apple-Developer-ID-Zertifikat und eine
Apple-Notarisierung benötigt.

## Build

```bash
Packaging/build.sh
Packaging/build-installer.sh
Packaging/build-dmg.sh
```

Ergebnisse:

- `build/Filelio.app`
- `dist/Filelio-1.0.0.pkg`
- `dist/Filelio-1.0.0.dmg`

## Tests

Die automatisierten Tests befinden sich in `Tests/`. Sie prüfen unter anderem
Umbenennung, Ausnahmen, OneDrive-/Temporärdateien, native Ordnerereignisse,
mehrere Strukturen, Finder-Kommunikation, Ressourcenverhalten, PDF-/Bildwerkzeuge
und die vollständige Oberfläche. Testdaten werden ausschließlich in eindeutig
benannten temporären Ordnern angelegt und nach dem jeweiligen Test entfernt.
