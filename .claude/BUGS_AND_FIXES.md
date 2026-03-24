# Bug Tracker & Fix Log — macOS Virtual Desktop Suite

## Chronologische Historie

### Phase 0: Grundproblem (Ausgangslage)
**Problem:** macOS wechselt den Desktop wenn man im Dock eine App klickt die auf einem anderen Desktop ein Fenster hat.
**Erster Ansatz:** Activation Observer (`didActivateApplicationNotification`) + `AppleSpacesSwitchOnActivate=false` + `workspaces=false`
**Ergebnis:** Funktionierte unzuverlässig ("mal gehts, mal nicht") wegen Race-Condition — der async `Task` im Observer feuerte NACH dem Space-Switch.

### Phase 1: CGEventTap-Ansatz
**Entscheidung:** CGEventTap am `.cgSessionEventTap` installieren um Dock-Klicks VOR macOS abzufangen.
**Problem 1:** Inline-Closure als @convention(c) Callback funktionierte nicht in Swift 6.
**Lösung:** Top-level `nonisolated func vdsDockClickCallback` + `event.location` vor `MainActor.assumeIsolated` extrahieren (Sendable-Constraint).
**Problem 2:** CGEventTap feuert NICHT für synthetische CGEvents (`CGEvent.post`).
**Erkenntnis:** Alle 54/54 Tests bestanden wegen `workspaces=false`, NICHT wegen CGEventTap.
**Entscheidung:** Duale Architektur beibehalten — `workspaces=false` als Hauptschutz, CGEventTap als Bonus für echte Klicks, Activation Observer als Fallback.

### Phase 2: Minimierte Fenster auf falschem Desktop
**Problem:** `unminimizeWindow` nahm das erste minimierte Fenster unabhängig vom Space → falscher Desktop.
**Fix 1:** `_AXUIElementGetWindow` + `SpaceDetector.spaceForWindow` um Space pro Fenster zu bestimmen.
**Problem:** Safari Multi-Process → `_AXUIElementGetWindow` scheitert oft.
**Fix 2:** Kein Fallback auf zufälliges Fenster wenn preferSpaceID gesetzt. Stattdessen neues Fenster öffnen.

### Phase 3: openNewWindow auf falschem Desktop
**Problem:** Safari `make new document` erstellt Fenster auf dem Hauptdesktop, nicht dem aktuellen.
**Fix:** Safari-Spezialfall: `activate` → Menü-Klick "Neues Fenster/Ablage" statt `make new document`. Mit `AppleSpacesSwitchOnActivate=false` bleibt man auf dem aktuellen Desktop.

### Phase 4: Preview-Design
**Problem:** Preview-Panel überlappt Dock.
**Fix:** py=80 + Sprechblasen-Pfeil (CAShapeLayer-Mask auf NSVisualEffectView).
**Problem:** Preview verschwindet beim Überfahren der Lücke Dock↔Panel.
**Fix:** Toleranzzone — vertikaler Streifen zwischen Panel und Dock, Panel bleibt wenn Maus darin.
**Problem:** Benachbarte App-Preview bleibt stehen statt zu wechseln.
**Fix:** Separate Logik: wenn Panel sichtbar und andere App gehovert → 150ms Delay statt sofort (verhindert Flackern).

---

## Bug-Log

### Bug #1: Single-Instance Dock-Click wechselt nicht den Desktop
**Gefunden:** 2026-03-20
**Schritte:** Teams auf Desktop 2 → Desktop 1 → Rechtsklick Preview → "Nur eine Instanz" → Klick auf Teams Dock-Icon → NICHTS
**Ursache:** `switchToAppWindow` scheiterte:
1. AX findet keine Fenster (Teams-Architektur)
2. `app.activate(options: [])` ohne `.activateAllWindows`
**Fix:** Robusterer `switchToAppWindow`: CGWindowList → Space → AppleScript Ctrl+Arrow → AX unminimize → `app.activate(options: [.activateAllWindows])`
**Status:** ✅ Fixed

### Bug #2: Preview-Klick fokussiert nicht korrekt
**Gefunden:** 2026-03-20
**Schritte:** Preview → Klick auf Teams → Desktop wechselt, Teams hinter Finder
**Ursache:** `app.activate(options: [])` ohne `.activateAllWindows`
**Fix:** `.activateAllWindows` in `activateAndFocusWindow` und `switchToAppWindow`
**Status:** ✅ Fixed

### Bug #3: Zweiter Preview-Klick tut nichts
**Gefunden:** 2026-03-20
**Schritte:** Preview → Klick → Desktop wechselt → zurück → Preview → Klick → NICHTS
**Ursache:** `ignoreActivationsUntil` 2s zu lang
**Fix:** Von 2s auf 1s reduziert
**Status:** ✅ Fixed

### Bug #4: Preview flackert / zeigt falsche App
**Gefunden:** 2026-03-20
**Schritte:** Hover über Spotify → Preview zeigt auch Finder
**Ursache:** Sofortiger async `showPreview`-Aufruf bei App-Wechsel, mehrere parallel
**Fix:** `isLoadingPreview` Flag + Stale-Preview-Guard + 150ms Delay bei App-Switch
**Status:** ✅ Fixed

### Bug #5: Preview-Klick erfordert Doppelklick
**Gefunden:** 2026-03-20
**Ursache:** NSPanel `nonActivatingPanel` konsumiert ersten Klick für Fokus
**Fix:** `acceptsFirstMouse(for:)` auf ClickableView + `becomesKeyOnlyIfNeeded` auf KeyablePanel
**Status:** ✅ Fixed

### Bug #6: Preview träge bei vielen Fenstern
**Gefunden:** 2026-03-20
**Ursache:** Jeder Thumbnail einzeln via ScreenCaptureKit erfasst (~100ms pro Fenster)
**Fix:** Thumbnail-Caching (5s), Retina-Capture (2x), Poll 50ms statt 100ms, Dock-Refresh 0.5s statt 2s
**Status:** ✅ Fixed

---

## Design-Entscheidungen

### Bug #7: Preview Header zu eng bei wenigen Fenstern
**Gefunden:** 2026-03-20
**Ursache:** GroupW = thumbnailW bei nur 1 Fenster → Desktop-Name und App-Name überlappen
**Fix:** `minGroupW = tw + 40` — Mindestbreite für lesbare Header
**Status:** ✅ Fixed

### Bug #8: Preview schließt beim Ansteuern äußerer Thumbnails
**Gefunden:** 2026-03-20
**Ursache:** Panel-Frame exakt = Panel-Größe. Kleinste Mausbewegung außerhalb → hide
**Fix:** Extended hit-area: `panel.frame.insetBy(dx: -20, dy: -15)` — 20px horizontaler, 15px vertikaler Toleranzbereich (wie Windows 11)
**Status:** ✅ Fixed

### Bug #9: Settings-Tabs kaputt (Sidebar-Toggle-Icon, langsames Laden)
**Gefunden:** 2026-03-20
**Ursache:** NavigationSplitView im Desktops-Tab erzeugte Sidebar-Toggle-Icon oben links. `.tabItem` SwiftUI-Rendering langsam.
**Fix:** Komplett eigener Tab-Bar mit Buttons + `selectedTab` State. NavigationSplitView durch Form mit inline-Editing ersetzt. Kein DesktopDetailView mehr nötig.
**Verworfene Alternative:** `.tabItem` beibehalten → löste das Sidebar-Icon-Problem nicht.
**Status:** ✅ Fixed

### Warum `workspaces=false` UND `AppleSpacesSwitchOnActivate=false`?
- `workspaces=false`: Verhindert Dock-Klick Space-Switches. Reicht für die meisten Fälle.
- `AppleSpacesSwitchOnActivate=false`: Verhindert dass `openNewWindow` (via AppleScript activate) den Space wechselt.
- Ohne letzteres würde Safari-Aktivierung via AppleScript den Space wechseln.

### Warum AppleScript statt CGEvent für Space-Switch?
- `CGEvent.post` für Ctrl+Arrow funktioniert NICHT auf macOS Tahoe für System-Shortcuts.
- `osascript 'tell application "System Events" to key code ...'` funktioniert zuverlässig.
- Getestet und bestätigt am 2026-03-20.

### Warum kein Fallback auf falsches Fenster?
- Safari hat Multi-Process-Architektur → `_AXUIElementGetWindow` scheitert für manche Fenster.
- Wenn kein Fenster dem Space zugeordnet werden kann, öffnen wir ein NEUES statt ein zufälliges zu unminimieren.
- Ein zufälliges Fenster könnte auf dem falschen Desktop sein → Space-Switch (genau das Problem das wir lösen wollen).

### Warum `.hudWindow` Material statt `.popover`?
- User wollte Dock-ähnlichen Glas-Effekt.
- `.hudWindow` gibt dunkleren, transluzenteren Look.
- Passt besser zum macOS Tahoe Design-Language.

---

## Session 2 Features (2026-03-20, Abend)

### Feature: Window-State-Badges
- Farbige Dots auf jedem Thumbnail: blau=normal, orange=minimiert, lila=fullscreen
- Farben bewusst NICHT rot/gelb/grün um Verwechslung mit macOS Ampel-Buttons zu vermeiden
- Kleines SF-Symbol-Icon neben dem Dot (macwindow, arrow.down.to.line, arrows)
- Tooltip bei Hover ("Normal", "Minimiert", "Vollbild")

### Feature: Close-Button (Mission Control Style)
- Weißer X auf dunklem halbtransparentem Kreis, top-left des Thumbnails
- Nur bei Hover sichtbar (CloseButton.alphaValue animiert)
- Nutzt AX "AXCloseButton" + kAXPressAction (nicht kAXCloseAction das existiert nicht)

### Feature: Erweitertes Rechtsklick-Menü
- "Fenster schließen" — schließt das spezifische Fenster via AX
- "Alle Fenster schließen" — iteriert alle AX-Fenster der App
- "Einzelne Instanz" — Toggle (vorher "Nur eine Instanz (Desktop wechseln)")

### Feature: Fullscreen-Handling
- SpaceDetector erkennt fullscreen Spaces (type==4)
- Fullscreen-Fenster bekommen lila Badge + "Vollbild" als Desktop-Name
- Klick auf Fullscreen-Preview wechselt zum Fullscreen-Space

### Feature: Live-Preview in Settings
- MockPreviewScene SwiftUI View am unteren Rand der Settings (außer System-Tab)
- Zeigt: Mock-Desktop mit Label (Position, Farbe, Größe live), Mock-Dock mit Icons, Mock-Preview-Panel
- Label reagiert live auf Darstellungs-Slider
- Preview-Thumbnails reagiert live auf Größen-Slider

### Feature: Header-Spacing Fix
- minGroupW entfernt (verursachte zu breiten Header)
- Bei 1 Fenster: nur "●DesktopName"
- Bei ≥2 Fenstern: "●DesktopName — AppIcon AppName"
- Keine unnötige Breite mehr

### Feature: mru-spaces=false
- Neue macOS-Setting: verhindert automatisches Umordnen der Desktops nach Nutzung
- Wichtig: ohne dies ändern sich Space-IDs nach Nutzungsreihenfolge
- In ensureSpaceSwitchDisabled + Settings-Anzeige integriert

### Bug #10: Close-Button funktioniert nicht
**Gefunden:** 2026-03-20
**Ursache:** `_AXUIElementGetWindow` WindowID-Match scheitert bei vielen Apps → Loop findet kein Fenster zum Schließen
**Fix:** Fallback: wenn WindowID-Match fehlschlägt → erstes Fenster schließen. Separate `pressCloseButton(of:)` Methode.
**Status:** ✅ Fixed

### Bug #11: Close-Button Stil falsch (dark circle + white X)
**Gefunden:** 2026-03-20
**Fix:** Umgestellt auf Mission-Control-Stil: weißer Kreis (0.95 alpha) mit Schatten + grauer X (0.35)
**Status:** ✅ Fixed

### Bug #12: Preview schließt sich nach Window-Close
**Gefunden:** 2026-03-20
**Ursache:** `hidePanel()` nach jedem closeWindow-Aufruf
**Fix:** `refreshPreviewAfterClose()` — wartet 0.5s, lädt Preview mit den verbleibenden Fenstern neu. `closeAllWindows` hide Panel (keine Fenster mehr).
**Status:** ✅ Fixed

### Stress-Test: 20 Fenster auf 2 Desktops
- 10 Finder-Fenster auf Desktop 1 + 10 auf Desktop 2
- Dock-Klick nach Minimize: Space bleibt ✅
- Full regression: 54/54 PASS ✅

### Bug #13: Close-Button empfängt keine Mouse-Events (Z-Order)
**Gefunden:** 2026-03-20
**Ursache:** Close-Button war Subview der ClickableView (card) bei x=-4 (außerhalb bounds) → macOS liefert keine Events an Views außerhalb der Superview-Bounds
**Fix:** Close-Button direkt auf `innerView` platzieren (NACH der card → höherer Z-Index). `card.associatedCloseButton` schwache Referenz für Hover-Animation.
**Verworfene Alternative:** `hitTest` Override in ClickableView — zu komplex, fragil
**Status:** ✅ Fixed

### Bug #14: Kein Overflow-Indikator bei >5 Fenstern
**Gefunden:** 2026-03-20
**Fix:** "+N" Label am Ende der Gruppe wenn `group.windows.count > maxThumbsPerDesktop`. contentW-Berechnung berücksichtigt den Extra-Space.
**Status:** ✅ Fixed

### Feature: mru-spaces=false
- Neue macOS-Einstellung in ensureSpaceSwitchDisabled: verhindert automatisches Umordnen der Desktops
- In Settings-Anzeige integriert

### Stress-Test: 5 Desktops, 10 Finder-Fenster
- 5 Desktops (spaceIDs: 1, 3, 80, 81, 82)
- 2 Finder-Fenster pro Desktop
- Dock-Click Regression: 54/54 PASS ✅

### Bug #15: Preview-Position aktualisiert nicht bei Dock-Resize
**Gefunden:** 2026-03-20
**Ursache:** Panel-Position wurde nur einmal beim Öffnen gesetzt, danach nie aktualisiert
**Fix:** In `tick()`: wenn Panel sichtbar und Icon-Position sich um >5px verschoben hat → `repositionPanel(to:)` aufrufen. Nutzt `lastPanelIconCenter` zum Vergleich.
**Status:** ✅ Fixed

### Bug #16: Desktop-Overlay hat feste Farbe statt Desktop-Palette
**Gefunden:** 2026-03-20
**Fix:** `SpaceNameOverlayController.show(color:)` Parameter. Color-Tint-Layer auf NSVisualEffectView. `DesktopStore.colorForCurrentDesktop()` liefert die Palette-Farbe.
**Status:** ✅ Fixed

### Bug #17: Close-Button Z-Order hinter Selection-Border
**Gefunden:** 2026-03-20
**Ursache:** Close-Button war Subview der ClickableView → hinter dem Border-Layer
**Fix:** Close-Button direkt auf `innerView` platziert (höherer Z-Index). `card.associatedCloseButton` schwache Referenz für Hover-Animation.
**Status:** ✅ Fixed

### Bug #18: Dock-Bounce-Animation fehlt (Event-Tap suppresst alles)
**Gefunden:** 2026-03-20
**Ursache:** `preHandleDockClick` gab `true` für alle Fälle zurück → Dock sah den Klick nie → keine Bounce-Animation
**Fix:** Hybrid-Ansatz:
- Sichtbare Fenster auf aktuellem Desktop: Klick DURCHLASSEN (natürliche Dock-Animation)
- Frontmost + sichtbar: SUPPRESS + Toggle-Minimize
- Nur minimierte Fenster: SUPPRESS + Unminimize (macOS ignoriert workspaces=false für minimierte)
- Keine Fenster: DURCHLASSEN (Dock launcht natürlich)
**Erkenntnis:** macOS ignoriert `workspaces=false` wenn ALLE Fenster minimiert sind. Nur für diesen Fall muss der Event-Tap supprimieren.
**Status:** ✅ Fixed

### Bug #19: AppleSpacesSwitchOnActivate nicht korrekt gesetzt
**Gefunden:** 2026-03-20
**Ursache:** `UserDefaults.standard.bool(forKey:)` gibt `false` für fehlende Keys zurück → Code dachte es sei bereits gesetzt
**Fix:** `UserDefaults(suiteName: "NSGlobalDomain")?.object(forKey:) as? Bool != false` — prüft ob Key EXISTIERT und false ist
**Status:** ✅ Fixed

### Bug #20: Notizen-App reagiert nicht auf Dock-Klick
**Ursache:** Event-Tap suppresste den Klick → Notizen wurde nie aktiviert → AX-Operationen scheiterten
**Fix:** Klick wird jetzt durchgelassen für Apps ohne minimierte Fenster auf dem aktuellen Space
**Status:** ✅ Fixed (durch Bug #18 Fix)

### Bug #21: Close-Button funktioniert nicht bei Electron-Apps (GitHub, Spotify)
**Gefunden:** 2026-03-20
**Ursache:** Electron-Apps haben 0 AX-Windows beim Haupt-PID. Kein AXCloseButton verfügbar.
**Fix:** 3-Strategie Close:
1. AXCloseButton auf gegebenem PID
2. Alle PIDs der App durchsuchen (Electron Multi-Process)
3. Fallback: Cmd+W via AppleScript (`keystroke "w" using command down`)
**Status:** ✅ Fixed

### Bug #22: Desktop-Overlay-Farbe immer Blau
**Gefunden:** 2026-03-20
**Ursache:** `colorLayer.frame` wurde nie gesetzt → Layer war 0×0 → Farbe unsichtbar
**Fix:** `colorLayer?.frame = NSRect(origin: .zero, size: window.frame.size)` in `doShow` nach Window-Resize
**Status:** ✅ Fixed

### Bug #23: Close für Electron-Apps (Spotify, GitHub) — Cmd+W funktioniert nicht zuverlässig
**Gefunden:** 2026-03-20
**Ursache:** Cmd+W Keystroke-Simulation ist unzuverlässig und nicht Apple-konform
**Fix:** 3-Stufen Close: AXCloseButton → alle PIDs → `NSRunningApplication.terminate()` als letzter Fallback
**Entscheidung:** terminate() ist das macOS-native Äquivalent zu Rechtsklick→Beenden. Kein Keystroke-Hacking.
**Status:** ✅ Fixed

### Bug #24: Overlay-Farbe immer blau (3. Versuch)
**Gescheiterte Versuche:** CALayer Sublayer auf NSVisualEffectView → unsichtbar (VFX rendert darüber)
**Finaler Fix:** NSVisualEffectView komplett entfernt. Direktes NSView mit `layer.backgroundColor` = Desktop-Farbe (0.7 alpha). Sichtbar und korrekt.
**Status:** ✅ Fixed

### Bug #25: Preview nicht hidden bei Rechtsklick auf Dock-Icon
**Fix:** `NSEvent.pressedMouseButtons & 2 != 0` (Rechtsklick-Bit) → sofort hidePanel + lastHoveredBundleID reset
**Status:** ✅ Fixed

### Rechtsklick-Menü: "App beenden" hinzugefügt
- Für Apps die sich nicht per Fenster-Close schließen lassen (Spotify, Teams)
- Nutzt `NSRunningApplication.terminate()` — macOS-native Methode

### Spotify Close-Verhalten (KEIN Bug, dokumentiert)
**Beobachtung:** AXCloseButton press → Spotify ignoriert/versteckt Fenster statt zu schließen
**Erklärung:** Spotify konfiguriert seinen Close-Button zum Verstecken (wie viele Streaming-Apps)
**Unser Verhalten:**
1. Klick X → AXCloseButton → Spotify versteckt → Preview refresht (zeigt neuen State)
2. Klick X nochmal → AX findet Fenster immer noch → terminate() Fallback → Spotify beendet
**Alternative:** Rechtsklick → "App beenden" → sofortige Terminierung
**Entscheidung:** Korrekt so. Wir respektieren das native Close-Verhalten der App.

### Cache-Invalidierung nach Close
**Fix:** `thumbnailCache.removeAll()` in `refreshPreviewAfterClose()` → State-Badges aktualisieren sofort nach Window-Close/Minimize. Refresh-Delay von 0.5s auf 0.3s reduziert.

---

## Session 3 (2026-03-20, Nachmittag)

### A1: Desktop-Name Truncation + App-Icon immer sichtbar
- Desktop-Name: `lineBreakMode = .byTruncatingTail` (zeigt "..." wenn zu lang)
- App-Icon: IMMER rechts im Header, auch bei 1 Fenster
- App-Name: nur bei ≥2 Fenstern UND genug Platz (groupW > 160)
- Layout: rightEdge-basiert, Icon/Pin/Name werden von rechts nach links platziert

### A4: Window-State-Badges mit dunklem Hintergrund
- Dunkle Pill-Badge (NSColor(white: 0.0, alpha: 0.55)) mit cornerRadius=7
- Icon + farbiger Dot darin → sichtbar auf allen Hintergründen
- Tooltip zeigt "Normal"/"Minimiert"/"Vollbild"

### A11: Single-Instance Pin-Icon
- Pin-Fill SF Symbol im Header wenn App als Einzelne Instanz markiert
- Farbe = Desktop-Palette-Farbe

### A6: Rechtsklick-Cooldown
- `rightClickCooldownUntil` Property — 1.5s nach Rechtsklick keine neue Preview
- Verhindert dass Preview über Dock-Kontextmenü zurückkommt

### A7+A8: Close-Animation
- Thumbnail animiert sofort raus (0.2s alphaValue→0)
- Close-Befehl wird async ausgeführt
- Nach 0.6s: Preview refresht sich mit verbleibenden Fenstern

### A3: Dock-Animation Timeout
- `ignoreActivationsUntil` von 2.0s auf 0.5-0.8s reduziert
- Dock-Bounce-Animation kommt bei häufigeren Klicks zurück

### A10: Terminal neues Fenster
- Terminal bundleID `com.apple.Terminal` hat speziellen `openNewWindow` case: `do script ""`
- Funktioniert wenn Activation Observer den Dock-Klick erkennt

### Screenshot-Fähigkeit: ✅
- `screencapture -x` funktioniert nach Screen Recording Permission
- Visuelle Verifikation der Overlay-Farben bestätigt: D1=Blau, D2=Grün, D3=Lila, D4=Orange

### Bug #26: Dock-Animation fehlt bei minimierten Fenstern
**Analyse:** CGEventTap suppresst den Klick → Dock sieht ihn nie → kein visuelles Feedback
**Versuchte Lösungen:**
1. Nicht supprimieren → Dock-Animation ✅ aber macOS switcht Space ❌ (8 Failures)
2. Nicht supprimieren + Space-Switch-Back → flackert, Tests brechen ❌ (6 Failures)
3. **Final:** Supprimieren + `app.activate()` nach Unminimize → Dock-Icon leuchtet kurz auf ✅
**Erkenntnis:** macOS ignoriert `workspaces=false` für minimierte Fenster. Suppression ist NOTWENDIG. `app.activate()` gibt visuelles Feedback als Kompromiss.
**Status:** ✅ Best möglich gelöst (54/54 PASS)

### Bug #27: Close-Button verschwindet bei Hover (UX-Problem)
**Analyse:** CloseButton lag auf innerView AUSSERHALB der Card-Bounds → mouseExited der Card versteckt den CloseButton wenn Maus zum X wandert
**Fix:** CloseButton zurück INNERHALB der Card (bei x=-2, y=th-16). ClickableView.hitTest override für erweiterten Klickbereich. updateTrackingAreas mit erweitertem Rect.
**Status:** ✅ Fixed

### Bug #28: Spotify X-Button schließt nicht beim ersten Klick
**Analyse per Video+AX Debug:** AXCloseButton entfernt Spotify-Fenster (0 AX windows) aber App läuft weiter
**Root Cause:** Check `countAfter >= countBefore` (0 >= 1 = false) → terminate nie aufgerufen
**Fix:** Check `countAfter == 0 && app.isRunning` → terminate()
**Status:** ✅ Fixed

### Bug #29: Close schließt falsches Fenster
**Analyse:** SCShareableContent WindowIDs stimmen nicht immer mit AX WindowIDs überein
**Root Cause:** Fallback `pressCloseButton(of: windows[0])` schließt das erste statt das richtige Fenster
**Fix:** 3-stufiges Matching: WindowID → Titel → Erst dann Fallback auf erstes
**Status:** ✅ Fixed

### Bug #30: Preview-Rebuild flackert nach Close
**Analyse per Video-Frames:** Panel faded komplett (alpha 0→1) bei jedem Rebuild
**Root Cause:** `panel.alphaValue = 0` + fade-in auch bei Refresh (nicht nur bei erstem Erscheinen)
**Fix:** `isRefresh` Flag — bei Refresh kein Panel-Fade, nur Content-Austausch
**Status:** ✅ Fixed

### Bug #31: Close-Animation — Cards überlagern sich beim Sliden
**Analyse:** Einzelne Cards manuell sliden funktioniert nicht weil Labels, Header, Close-Buttons nicht mitsliden
**Verworfener Ansatz:** Individuelles Sliding jeder Card → visuelle Fehler
**Finaler Ansatz:** Card fade-out (0.15s) → sofortiger Rebuild (0.18s) ohne Panel-Fade
**Status:** ✅ Fixed

### Feature: Auto-Refresh der Preview (alle 3s)
- Erkennt neue Fenster während Preview offen ist
- Erkennt geschlossene Fenster
- `lastStateRefresh` Timestamp verhindert zu häufige Refreshes

### Feature: Neue Fenster Slide-in Animation
- `previousWindowIDs` Set trackt welche Fenster vorher angezeigt wurden
- Neue Fenster (aus Overflow oder neu geöffnet) sliden von rechts rein (0.25s)

### Feature: Video-Recording für Debugging
- ffmpeg via Homebrew installiert
- `/tmp/vds_record.sh start/stop` Helper-Skript
- Frame-Extraktion: `ffmpeg -vf "fps=4"` für Analyse

### Bug #32: KRITISCH — pressCloseButton terminiert ganze App bei Multi-Window
**Gefunden:** 2026-03-20 (User schloss 1 TextEdit → alle 10 weg)
**Root Cause:** Auto-terminate Check `countAfter == 0` feuerte während TextEdit das Fenster schloss. AX meldete kurzzeitig 0 Fenster → terminate() killte die gesamte App.
**Fix:** Auto-terminate NUR wenn `countBefore == 1` (App hatte genau 1 Fenster). Multi-Window-Apps werden NIEMALS auto-terminiert.
**Erkenntnis:** AX Window-Count ist während Close-Animationen UNZUVERLÄSSIG. Nie als alleiniges Kriterium für terminate() verwenden.
**Status:** ✅ Fixed

### Bug #33: Close-Animation — Reihenfolge durcheinander
**Root Cause:** Nach Close wurde SCShareableContent neu geladen → zufällige Reihenfolge
**Fix:** `currentThumbnails` Array cachen. Beim Close: Window aus Array filtern → `displayPanel` mit gefilterter Liste. Kein SCShareableContent-Reload. Voller Refresh erst nach 2s.
**Status:** ✅ Fixed

### Test-Ergebnis: 54/54 PASS ✅
