# DockPeek Preview-Only Redesign

**Datum:** 2026-03-30
**Status:** Approved
**Ziel:** DockPeek auf seinen Kern reduzieren — Dock-Hover-Preview + Desktop-Benennung. Alle Fenster-Management-Features deaktivieren.

---

## 1. Vision

DockPeek zeigt beim Hovern über Dock-Icons eine Preview aller Fenster einer App, gruppiert nach Desktop mit farbiger Zuordnung. Ein Klick auf ein Thumbnail wechselt zum Desktop und bringt das Fenster in den Vordergrund. Desktops werden mit konfigurierbaren Namen und Farben angezeigt (Floating Badge, Notch Badge, Notch Slide).

**Die App verwaltet keine Fenster.** Öffnen, Schließen, Minimieren, Single-Instance — alles wird vom macOS Dock und den Apps selbst erledigt. DockPeek ist ein reines Anzeige-Tool.

---

## 2. Aktive Features

### 2.1 Dock-Hover-Preview
- 50ms Polling erkennt Maus über Dock-Icons
- Preview-Panel zeigt alle Fenster der App, gruppiert nach Desktop
- Farbige Desktop-Header mit Desktop-Name und App-Icon
- Thumbnails via ScreenCaptureKit mit 5s Cache
- Minimierte Fenster: gelbes Badge
- Vollbild-Fenster: lila Badge + Farbe des **Ursprungs-Desktops** (Bug 7 Fix)
- Dialog-Fenster: App-Icon statt dunklem Screenshot
- Extended Hit-Area (20px horizontal, 15px vertikal)

### 2.2 Thumbnail-Klick
- Klick auf Thumbnail → `switchToSpace()` via AppleScript (Ctrl+Arrow) + `app.activate()`
- Fenster auf aktuellem Desktop → direkt fokussieren (kein Space-Wechsel nötig)
- Fenster auf anderem Desktop → Space wechseln + fokussieren

### 2.3 Desktop-Benennung
- Drei Indicator-Styles: Floating Badge, Notch Badge (Drop), Notch Slide
- 6-Farben-Palette (Blue, Green, Purple, Orange, Pink, Teal)
- Konfigurierbare Namen, Positionen, Opacity, Font-Größe, Fade-Delay
- Floating Badge muss auf **allen** Desktops korrekt angezeigt werden (Bug 1 Fix)

### 2.4 Settings
- **Desktops Tab:** Namen, Farben konfigurieren
- **Appearance Tab:** Indicator-Style, Menu-Bar-Icon, Thumbnail-Größe
- **Behavior Tab:** Hover-Delay, Hide-Delay, Max-Windows-per-Group, Space-Switch-Speed
- **System Tab:** Berechtigungen prüfen, `mru-spaces` Status + Konfiguration (siehe 3.1)
- **Help Tab:** Kurze Anleitung

### 2.5 Keyboard
- **Escape:** Preview schließen

---

## 3. macOS-Settings Handling

### 3.1 `mru-spaces=false` (einziges Setting)
DockPeek benötigt eine feste Desktop-Reihenfolge für korrekte Zuordnung.

**Verhalten:**
1. Beim Start prüfen: `defaults read com.apple.dock mru-spaces`
2. Falls `true` oder nicht gesetzt → in Settings auffälligen Hinweis zeigen
3. Hinweis: Gelber/oranger Banner im System-Tab:
   > "Desktop-Reihenfolge ist nicht fixiert. DockPeek benötigt eine feste Reihenfolge für korrekte Desktop-Zuordnung."
   > Button: "Jetzt konfigurieren"
4. Button-Klick setzt `mru-spaces=false` + Dock-Neustart
5. **Nie automatisch ändern** — immer User-Aktion erforderlich

**Nicht mehr setzen (waren vorher aktiv):**
- `workspaces=false` — nicht nötig, Dock verhält sich normal
- `AppleSpacesSwitchOnActivate=false` — nicht nötig, keine eigene Aktivierung
- `show-tooltip=false` — nicht nötig, Dock-Tooltips stören nicht

---

## 4. Deaktivierte Features

Alle Features werden **im Code belassen aber nicht ausgeführt**. Kein Code wird gelöscht — nur die Aufrufstellen werden deaktiviert/übersprungen.

### 4.1 CGEventTap / Dock-Click-Interception
- **Was:** `CGEventTapCreate` in DockManager, `vdsDockClickCallback`, `preHandleDockClick`
- **Deaktivierung:** `installEventTap()` nicht aufrufen. Methoden bleiben im Code.
- **Auswirkung:** Dock-Klicks gehen direkt an macOS durch (normales Verhalten)

### 4.2 Activation Observer
- **Was:** `NSWorkspace.didActivateApplicationNotification` Handler in DesktopStore der neue Fenster öffnet
- **Deaktivierung:** Observer nicht registrieren (oder Handler sofort return)
- **Auswirkung:** Keine automatischen neuen Fenster

### 4.3 macOS Settings (außer mru-spaces)
- **Was:** `ensureSpaceSwitchDisabled()` setzt `workspaces`, `AppleSpacesSwitchOnActivate`, `show-tooltip`
- **Deaktivierung:** Funktion nicht aufrufen, oder nur `mru-spaces`-Prüfung behalten
- **Auswirkung:** macOS-Dock-Verhalten bleibt unverändert

### 4.4 Close-Buttons auf Thumbnails
- **Was:** `CloseButton` View auf jeder `ClickableView`, Hover-Animation
- **Deaktivierung:** Close-Button nicht erstellen/hinzufügen
- **Auswirkung:** Thumbnails sind rein visuell

### 4.5 Kontextmenü (Rechtsklick auf Thumbnail)
- **Was:** "Fenster schließen", "Alle Fenster schließen", "App beenden", "Einzelne Instanz"
- **Deaktivierung:** Komplettes Kontextmenü entfernen
- **Auswirkung:** Rechtsklick tut nichts (oder zeigt nur Info)

### 4.6 Empty-State "Neues Fenster"
- **Was:** "+ Neues Fenster" Button wenn App keine Fenster hat
- **Deaktivierung:** Button entfernen, nur "Keine Fenster" Text + App-Icon zeigen
- **Auswirkung:** User muss über Dock neues Fenster öffnen

### 4.7 `openNewWindow()`
- **Was:** AppleScript-Rezepte pro App (Finder, Safari, Chrome, Terminal, etc.)
- **Deaktivierung:** Nicht aufrufen
- **Auswirkung:** Keine Fenster-Erstellung durch DockPeek

### 4.8 Single-Instance Verwaltung
- **Was:** `singleInstanceApps` Array, Toggle im Kontextmenü, Pin-Icon im Header
- **Deaktivierung:** UI entfernen, Array ignorieren
- **Auswirkung:** Keine Single-Instance-Logik

### 4.9 Toggle-Minimize
- **Was:** Frontmost-App Dock-Klick minimiert alle Fenster
- **Deaktivierung:** Teil des CGEventTap, wird mit 4.1 deaktiviert

### 4.10 Close-Animation / Overflow-Cards
- **Was:** Pre-rendered hidden Cards für smooth Close-Animation
- **Deaktivierung:** Overflow-Cards nicht pre-rendern (spart Speicher/Render-Zeit)
- **Auswirkung:** Alle Fenster werden normal angezeigt, kein maxThumbsPerDesktop-Limit nötig

### 4.11 Window Close Logic
- **Was:** 3-Tier Close (AXCloseButton → Multi-PID → Escape)
- **Deaktivierung:** Nicht aufrufen
- **Auswirkung:** DockPeek schließt nie Fenster

### 4.12 Keyboard Navigation (Tab/Enter)
- **Was:** Tab/Shift+Tab/Arrows zum Navigieren, Enter/Space zum Aktivieren
- **Deaktivierung:** Optional — schadet nicht, aber ohne Close/Context-Menu weniger nützlich. Escape bleibt.
- **Entscheidung:** Tab-Navigation deaktivieren, nur Escape behalten.

---

## 5. Bug-Fixes

### Bug 1: Floating Badge falscher Desktop
**Symptom:** Badge zeigt nur auf einem Desktop, nicht auf dem aktuellen.
**Vermutung:** `canJoinAllSpaces` oder Space-Change-Observer funktioniert nicht korrekt.
**Fix:** Im Code analysieren warum der Badge nicht auf Space-Wechsel reagiert.

### Bug 3: Dock Auto-Hide vs Preview
**Symptom:** Wenn Dock auf Auto-Hide steht, blendet er aus während Preview noch aktiv ist.
**Fix:** Prüfen ob man den Dock am Ausblenden hindern kann solange die Preview sichtbar ist. Mögliche Ansätze:
- Maus-Position im Dock-Bereich halten (simuliert Hover)
- `NSEvent.addGlobalMonitorForEvents` um Dock-Hide zu erkennen und Preview zu schließen
- Falls Dock-Hide nicht verhinderbar: Preview schließen wenn Dock verschwindet

### Bug 7: Fullscreen-Farbe falsch
**Symptom:** Vollbild-App zeigt falsche Desktop-Farbe in Preview/Badge.
**Root Cause:** macOS ordnet Fullscreen-Spaces am Ende der Space-Liste ein, nicht neben dem Ursprungs-Desktop. Aktuell wird die Farbe des aktuellen Desktops verwendet.
**Fix:** Beim Wechsel in Fullscreen merken, von welchem Desktop die App kam. Mapping `fullscreenSpaceID → originDesktopIndex` pflegen.

---

## 6. Settings-Aufräumung

Features die deaktiviert werden, müssen auch aus den Settings verschwinden:

- **System Tab:** `workspaces`, `AppleSpacesSwitchOnActivate`, `show-tooltip` Anzeigen entfernen. Nur `mru-spaces` mit Hinweis + Button behalten.
- **Behavior Tab:** "Space Switch Speed" kann bleiben (wird für Thumbnail-Klick gebraucht). Alles was sich auf Close/New-Window bezieht entfernen.
- **Debug Tab:** "Test Close" Button entfernen. "Open Preview for frontmost" kann bleiben.
- **Kontextmenü-Einträge** in Settings entfernen falls vorhanden.

---

## 7. Deaktivierungsstrategie

**Prinzip:** Code bleibt erhalten, wird aber nicht ausgeführt. Deaktivierung erfolgt an den Aufrufstellen, nicht durch Löschen der Implementierung.

**Markierung im Code:**
```swift
// DEACTIVATED: Preview-Only Mode — feature disabled, code preserved
// Was: CGEventTap für Dock-Click-Interception
// Grund: App reduziert auf Preview + Desktop-Benennung (2026-03-30)
```

**Warum nicht löschen:** Falls Features in Zukunft reaktiviert werden sollen, ist der getestete Code noch da. Außerdem dient er als Referenz für die Architektur-Dokumentation.

---

## 8. Nicht betroffen (bleibt wie es ist)

- `SpaceDetector.swift` — wird weiterhin für Desktop-Erkennung gebraucht
- `DesktopModels.swift` — Datenmodelle bleiben (DesktopConfig, LabelSettings, PreviewSettings)
- `DesktopNameLabel.swift` — Floating Badge Feature bleibt aktiv
- `SpaceNameOverlay.swift` — Space-Switch HUD bleibt aktiv
- `NotchBadge.swift` / `NotchSlide.swift` — Notch-Indikatoren bleiben aktiv
- Thumbnail-Capture via ScreenCaptureKit — Kern des Preview-Features
- Persistence nach `desktop-config.json` — bleibt aktiv
- Desktop-Farbpalette — bleibt aktiv
