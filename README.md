<div align="center">
  <img src="Resources/AppIcon-master.png" width="160" alt="Filelio App-Icon">
  <h1>Filelio</h1>
  <p><strong>Dateien auf dem Mac sicher benennen, sortieren und organisieren.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-native-000000?logo=apple&amp;logoColor=white" alt="Native macOS-App">
    <img src="https://img.shields.io/badge/Swift-App-F05138?logo=swift&amp;logoColor=white" alt="In Swift entwickelt">
    <img src="https://img.shields.io/badge/Datenschutz-lokal-6F5AA8" alt="Alle Daten bleiben lokal">
    <img src="https://img.shields.io/badge/Version-1.0.0-4C8BF5" alt="Version 1.0.0">
  </p>
</div>

Filelio ist eine native macOS-Menüleisten-App für wiederkehrende Dateiabläufe. Sie überwacht ausgewählte Ordner, zeigt jede geplante Umbenennung vorab und organisiert Dateien nach nachvollziehbaren Regeln. Alle Vorgänge laufen lokal – ohne Konto, Cloud-Dienst, Werbung oder Analyse-Tracking.

> [!NOTE]
> Dieses Repository enthält den Quellcode. Ein notarisiertes GitHub-Release mit fertiger DMG-Datei ist noch nicht veröffentlicht.

## Was Filelio kann

| Bereich | Funktionen |
|---|---|
| Benennen | Vorschau, Präfixe, Trennzeichen, Datumsformate und Ausschlussregeln |
| Sortieren | Mehrere Ordnerstrukturen, Downloads, Screenshots und regelbasiertes Verschieben |
| Sicherheit | Gemeinsame Warteschlange, Verlauf und Rückgängig-Funktion |
| Finder | Symbolleistenschaltfläche, Finder-Erweiterung und zwei Finder-Dienste |
| Werkzeuge | Große Dateien und Duplikate finden, PDFs verbinden, Bilder konvertieren |
| Geräte | Externe Datenträger kontrolliert auswerfen |

Temporäre Dateien, unvollständige Downloads und noch nicht lokal verfügbare Cloud-Dateien werden übersprungen. Leerzeichen in Datei- und Ordnernamen bleiben erhalten. Filelio löscht Dateien niemals automatisch.

## Installation

Ein fertiges, notarisiertes Installationspaket ist noch nicht über GitHub Releases verfügbar. Für einen lokalen Build wird ein aktuelles macOS mit den Apple Command Line Tools benötigt.

```bash
Packaging/build.sh
```

Anschließend liegt die App unter `build/Filelio.app`. Für lokale Installer-Artefakte:

```bash
Packaging/build-installer.sh
Packaging/build-dmg.sh
```

Erzeugte Dateien:

- `build/Filelio.app`
- `dist/Filelio-1.0.0.pkg`
- `dist/Filelio-1.0.0.dmg`

Die lokalen Builds sind ad-hoc signiert. Für eine öffentliche Verteilung ohne Gatekeeper-Warnung werden ein Apple-Developer-ID-Zertifikat und eine Apple-Notarisierung benötigt.

## Finder-Integration

Die Erweiterung **Filelio Finder** bietet direkt im Finder:

- Filelio öffnen
- Auswahl zur Umbenennung prüfen
- neue Dateinamen vorab anzeigen
- den aktuellen Ordner einmalig organisieren
- den aktuellen Ordner dauerhaft überwachen

Aktivierung: **Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Finder → Filelio Finder**.

Die Erweiterung scannt nicht selbst. Sie übergibt ausschließlich die aktuelle Finder-Auswahl an die Haupt-App.

## Datenschutz und Ressourcen

- Alle Dateioperationen laufen lokal auf dem Mac.
- Es werden keine Dateien übertragen und keine Nutzungsdaten erfasst.
- Ordnerzugriffe werden nur nach ausdrücklicher Auswahl im Systemdialog gespeichert.
- Die App verwendet die macOS App Sandbox.
- Ordneränderungen werden ereignisbasiert über FSEvents verarbeitet.
- Aufwendige Analysen starten nur auf Anforderung und mit energiesparender Hintergrundpriorität.

## Tests

Die Selbsttests unter [`Tests/`](Tests/) decken unter anderem Umbenennung, Ausnahmen, temporäre Dateien, native Ordnerereignisse, Finder-Kommunikation, mehrere überwachte Strukturen, Ressourcenverhalten sowie PDF- und Bildwerkzeuge ab.

Eine schnelle Syntaxprüfung aller Swift-Quellen:

```bash
swiftc -parse Sources/*.swift Tests/*.swift
```

Testdaten entstehen ausschließlich in eindeutig benannten temporären Ordnern und werden anschließend wieder entfernt.

## Projektstruktur

```text
.
├── Sources/       # App, Dateilogik, Finder- und Werkzeugfunktionen
├── Resources/     # Icons, Entitlements und App-Metadaten
├── Tests/         # Selbsttests
└── Packaging/     # App-, PKG- und DMG-Erstellung
```

## Lizenz

Für dieses Repository ist derzeit keine Open-Source-Lizenz hinterlegt. Der öffentlich sichtbare Quellcode darf daher nicht automatisch als frei nutzbar oder weiterverteilbar verstanden werden.

---

Entwickelt von **CreativTechnik**.
