import AppKit
import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @EnvironmentObject var store: DesktopStore
    @State private var selectedDesktopID: Int?
    @State private var axGranted = AXIsProcessTrusted()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var autostartEnabled = SMAppService.mainApp.status == .enabled

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            HStack(spacing: 2) {
                tabButton(NSLocalizedString("tab.desktops", comment: ""), icon: "rectangle.split.3x1", tag: 0)
                tabButton(NSLocalizedString("tab.appearance", comment: ""), icon: "paintbrush", tag: 1)
                tabButton(NSLocalizedString("tab.behavior", comment: ""), icon: "gearshape", tag: 2)
                tabButton(NSLocalizedString("tab.system", comment: ""), icon: "wrench.and.screwdriver", tag: 3)
                tabButton(NSLocalizedString("tab.help", comment: ""), icon: "questionmark.circle", tag: 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Divider()

            // Content + Preview side by side
            HStack(spacing: 0) {
                // Tab content (full height)
                ZStack {
                    if selectedTab == 0 { desktopsTab }
                    if selectedTab == 1 { displayTab }
                    if selectedTab == 2 { behaviorTab }
                    if selectedTab == 3 { systemTab }
                    if selectedTab == 4 { helpTab }
                }

                // Live preview sidebar (only on appearance and behavior tabs)
                if selectedTab == 1 || selectedTab == 2 {
                    Divider()
                    MockPreviewScene()
                        .frame(width: 220)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private func tabButton(_ title: String, icon: String, tag: Int) -> some View {
        Button {
            selectedTab = tag
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: selectedTab == tag ? .semibold : .regular))
                .foregroundStyle(selectedTab == tag ? .primary : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedTab == tag ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Desktops

    private var desktopsTab: some View {
        Form {
            Section("Aktive Desktops") {
                ForEach(store.desktops) { desktop in
                    let preset = store.preset(forIndex: desktop.index)
                    let systemName = missionControlName(for: desktop.index)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            // Active indicator
                            Image(systemName: desktop.id == store.currentSpaceID ? "display" : "rectangle")
                                .foregroundStyle(desktop.id == store.currentSpaceID ? Color.accentColor : Color.secondary)
                                .frame(width: 16)

                            // Index badge
                            Text("\(desktop.index)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(presetColor(for: desktop.index)))

                            // Name
                            TextField("Name", text: Binding(
                                get: { preset?.name ?? desktop.customName },
                                set: { store.renameDesktop(id: desktop.id, name: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)

                            // Color popover trigger
                            colorSelector(for: desktop.index)

                            // Fixed-width status area so layout doesn't shift
                            Text(desktop.id == store.currentSpaceID ? "aktiv" : "")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        // Mission Control system name for reference
                        Text(systemName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 46)
                    }
                }
            }

            // Presets for future desktops (not yet active)
            let activeIndices = Set(store.desktops.map(\.index))
            let futurePresets = store.presets.filter { !activeIndices.contains($0.id) }

            if !futurePresets.isEmpty {
                Section("Vordefinierte Desktops") {
                    ForEach(futurePresets) { preset in
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.dashed")
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)

                            Text("\(preset.id)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(presetColor(for: preset.id)))

                            TextField("Name", text: Binding(
                                get: { preset.name },
                                set: { newName in
                                    var p = preset
                                    p.name = newName
                                    store.updatePreset(p)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)

                            colorSelector(for: preset.id)

                            Button(role: .destructive) {
                                store.removePreset(index: preset.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button {
                        store.addPreset()
                    } label: {
                        Label("Desktop vordefinieren", systemImage: "plus.circle")
                    }
                    .disabled(store.presets.count >= 10)

                    Spacer()

                    Text("\(store.presets.count)/10 Presets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Vordefinierte Desktops erhalten automatisch Name und Farbe wenn sie in Mission Control erstellt werden. Reihenfolge wird bei Änderungen in der Schreibtisch-Übersicht automatisch angepasst.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Mission Control Name

    /// Returns the system desktop name as shown in Mission Control.
    /// German: "Schreibtisch 1", English: "Desktop 1", etc.
    private func missionControlName(for index: Int) -> String {
        let lang = Locale.preferredLanguages.first ?? "en"
        let prefix = lang.hasPrefix("de") ? "Schreibtisch" : "Desktop"
        return "\(prefix) \(index)"
    }

    // MARK: - Preset Color Helpers

    /// Curated pastel palette — harmonized tones that work well together.
    private static let pastelSwatches: [(name: String, r: Double, g: Double, b: Double)] = [
        ("Blau",    0.35, 0.60, 0.95),
        ("Grün",    0.40, 0.78, 0.55),
        ("Lila",    0.68, 0.50, 0.90),
        ("Orange",  0.95, 0.60, 0.35),
        ("Rosa",    0.90, 0.45, 0.55),
        ("Teal",    0.50, 0.75, 0.75),
        ("Gelb",    0.92, 0.80, 0.35),
        ("Indigo",  0.45, 0.45, 0.85),
        ("Mint",    0.55, 0.88, 0.72),
        ("Koralle", 0.95, 0.50, 0.45),
        ("Lavendel",0.72, 0.62, 0.88),
        ("Sand",    0.85, 0.75, 0.58),
    ]

    private func presetColor(for index: Int) -> Color {
        Color(nsColor: store.colorForDesktopIndex(index))
    }

    private func setPresetColor(for index: Int, r: Double, g: Double, b: Double) {
        var preset = store.preset(forIndex: index) ?? DesktopPreset(id: index, name: "Desktop \(index)")
        preset.colorR = r
        preset.colorG = g
        preset.colorB = b
        store.updatePreset(preset)
    }

    private func presetColorBinding(for index: Int) -> Binding<Color> {
        Binding {
            presetColor(for: index)
        } set: { newColor in
            if let c = NSColor(newColor).usingColorSpace(.sRGB) {
                setPresetColor(for: index, r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
            }
        }
    }

    /// Color button that opens a popover with pastel swatches + custom picker.
    private func colorSelector(for index: Int) -> some View {
        ColorPopoverButton(
            currentColor: presetColor(for: index),
            swatches: Self.pastelSwatches,
            isSelected: { isSwatchSelected($0, for: index) },
            onSelect: { setPresetColor(for: index, r: $0.r, g: $0.g, b: $0.b) },
            customBinding: presetColorBinding(for: index)
        )
    }

    private func isSwatchSelected(_ swatch: (name: String, r: Double, g: Double, b: Double), for index: Int) -> Bool {
        guard let p = store.preset(forIndex: index), p.hasCustomColor,
              let pr = p.colorR, let pg = p.colorG, let pb = p.colorB else { return false }
        return abs(pr - swatch.r) < 0.02 && abs(pg - swatch.g) < 0.02 && abs(pb - swatch.b) < 0.02
    }

    // MARK: - Darstellung

    private var displayTab: some View {
        Form {
            Section("Men\u{00FC}leiste") {
                Toggle("Icon in der Men\u{00FC}leiste anzeigen", isOn: lb(\.showMenuBarIcon))
                if store.labelSettings.showMenuBarIcon {
                    Toggle("Desktop-Farbe & Name anzeigen", isOn: lb(\.showMenuBarBadge))
                    Text("Zeigt statt dem DockPeek-Icon eine farbige Kugel mit dem Desktop-Namen. \u{00D6}ffne die App erneut (z.B. \u{00FC}ber Spotlight) um die Einstellungen aufzurufen wenn das Icon deaktiviert ist.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("DockPeek l\u{00E4}uft unsichtbar im Hintergrund. \u{00D6}ffne die App erneut (z.B. \u{00FC}ber Spotlight) um die Einstellungen aufzurufen.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Desktop-Anzeige beim Wechsel") {
                Picker("Stil", selection: lb(\.indicatorStyle)) {
                    ForEach(IndicatorStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }

                if store.labelSettings.indicatorStyle == .notchDrop {
                    Text("Beim Desktop-Wechsel gleitet eine Anzeige nach unten aus der Notch heraus.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if store.labelSettings.indicatorStyle == .notchSlide {
                    Text("Beim Desktop-Wechsel gleitet eine Anzeige nach links aus der Notch heraus.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if store.labelSettings.indicatorStyle == .notchDrop || store.labelSettings.indicatorStyle == .notchSlide {
                    LabeledContent("Anzeigedauer") {
                        Slider(value: lb(\.notchDropHold), in: 0.5...5.0, step: 0.1)
                            .frame(width: 150)
                        Text("\(String(format: "%.1f", store.labelSettings.notchDropHold)) s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    LabeledContent("Geschwindigkeit") {
                        Slider(value: lb(\.notchDropSpeed), in: 0.1...1.0, step: 0.05)
                            .frame(width: 150)
                        Text("\(String(format: "%.2f", store.labelSettings.notchDropSpeed)) s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Button("Vorschau testen") {
                    store.testIndicator()
                }
            }

            if store.labelSettings.indicatorStyle == .floatingBadge {
                Section("Floating Badge") {
                    Picker("Modus", selection: lb(\.mode)) {
                        ForEach(LabelMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }

                    Picker("Position", selection: lb(\.position)) {
                        ForEach(LabelPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }

                    LabeledContent("Transparenz") {
                        Slider(value: lb(\.opacity), in: 0.3...1.0)
                            .frame(width: 200)
                        Text("\(Int(store.labelSettings.opacity * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }

                    LabeledContent("Schriftgröße") {
                        Slider(value: lb(\.fontSize), in: 10...24, step: 1)
                            .frame(width: 200)
                        Text("\(Int(store.labelSettings.fontSize)) pt")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }

                    if store.labelSettings.mode == .fadeOut {
                        LabeledContent("Anzeigedauer") {
                            Slider(value: lb(\.fadeOutDelay), in: 1...10, step: 0.5)
                                .frame(width: 200)
                            Text("\(String(format: "%.1f", store.labelSettings.fadeOutDelay)) s")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        LabeledContent("Ausblenddauer") {
                            Slider(value: lb(\.fadeOutDuration), in: 0.2...2.0, step: 0.1)
                                .frame(width: 200)
                            Text("\(String(format: "%.1f", store.labelSettings.fadeOutDuration)) s")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Verhalten

    private var behaviorTab: some View {
        Form {
            Section("Fenster-Vorschau") {
                LabeledContent("Vorschau-Breite") {
                    Slider(value: pv(\.thumbnailWidth), in: 120...300, step: 10)
                        .frame(width: 200)
                    Text("\(Int(store.previewSettings.thumbnailWidth)) px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Vorschau-Höhe") {
                    Slider(value: pv(\.thumbnailHeight), in: 80...200, step: 10)
                        .frame(width: 200)
                    Text("\(Int(store.previewSettings.thumbnailHeight)) px")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Hover-Verzögerung") {
                    Slider(value: pv(\.hoverDelay), in: 0.1...1.5, step: 0.1)
                        .frame(width: 200)
                    Text("\(String(format: "%.1f", store.previewSettings.hoverDelay)) s")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Ausblend-Verzögerung") {
                    Slider(value: pv(\.hideDelay), in: 0.0...1.0, step: 0.1)
                        .frame(width: 200)
                    Text("\(String(format: "%.1f", store.previewSettings.hideDelay)) s")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Max. Fenster pro Gruppe") {
                    Slider(value: pv(\.maxWindowsPerGroup), in: 2...10, step: 1)
                        .frame(width: 200)
                    Text("\(Int(store.previewSettings.maxWindowsPerGroup))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Desktop-Wechsel Speed") {
                    Slider(value: pv(\.spaceSwitchSpeed), in: 30...300, step: 10)
                        .frame(width: 200)
                    Text("\(Int(store.previewSettings.spaceSwitchSpeed)) ms")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Hover über ein Dock-Icon zeigt Fenster-Vorschauen mit Desktop-Name. Klick wechselt zum Fenster.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - System

    private var systemTab: some View {
        Form {
            Section(NSLocalizedString("system.permissions", comment: "")) {
                HStack {
                    Image(systemName: axGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(axGranted ? .green : .red)
                    Text(NSLocalizedString("system.accessibility", comment: ""))
                    Spacer()
                    if !axGranted {
                        Button(NSLocalizedString("system.request", comment: "")) {
                            let key = "AXTrustedCheckOptionPrompt" as CFString
                            let opts = [key: true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(opts)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { axGranted = AXIsProcessTrusted() }
                        }
                    }
                }

                HStack {
                    Image(systemName: screenGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(screenGranted ? .green : .red)
                    Text(NSLocalizedString("system.screenRecording", comment: ""))
                    Spacer()
                    if !screenGranted {
                        Button(NSLocalizedString("system.request", comment: "")) {
                            CGRequestScreenCaptureAccess()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { screenGranted = CGPreflightScreenCaptureAccess() }
                        }
                    }
                }

                Button(NSLocalizedString("system.refreshStatus", comment: "")) {
                    axGranted = AXIsProcessTrusted()
                    screenGranted = CGPreflightScreenCaptureAccess()
                }
            }

            // DEACTIVATED: Preview-Only Mode (2026-03-30)
            // Was: Full macOS config section showing workspaces, AppleSpacesSwitchOnActivate, show-tooltip
            // and "Configure Optimal" button calling store.dockManager.ensureSpaceSwitchDisabled()

            // -- mru-spaces Section --
            Section {
                if store.mruSpacesConfigured {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Desktop-Reihenfolge ist fixiert")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title2)
                            Text("Desktop-Reihenfolge nicht fixiert")
                                .font(.headline)
                                .foregroundColor(.orange)
                        }
                        Text("DockPeek benötigt eine feste Desktop-Reihenfolge für korrekte Zuordnung von Fenstern zu Desktops. Ohne diese Einstellung können Desktops nach Nutzung umsortiert werden.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Jetzt konfigurieren") {
                            store.dockManager.configureMruSpaces()
                            Task {
                                try? await Task.sleep(for: .seconds(2.5))
                                await MainActor.run {
                                    store.mruSpacesConfigured = store.dockManager.checkMruSpacesStatus()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            } header: {
                Text("macOS Konfiguration")
            }

            Section(NSLocalizedString("system.autostart", comment: "")) {
                Toggle(NSLocalizedString("system.startAtLogin", comment: ""), isOn: Binding(
                    get: { autostartEnabled },
                    set: { newVal in
                        do {
                            if newVal {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            autostartEnabled = newVal
                        } catch {}
                    }
                ))
                Text(NSLocalizedString("system.autostartDesc", comment: ""))
                    .font(.callout).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Hilfe

    private var helpTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text("DockPeek")
                            .font(.title2.bold())
                        Text("Dock-Vorschau, Fensterverwaltung & Desktop-Kontrolle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                Divider()

                // 1. Kernfunktion
                helpSection(icon: "desktopcomputer", title: "Kein ungewollter Desktop-Wechsel") {
                    Text("Wenn du im Dock eine App klickst die auf einem anderen Schreibtisch liegt, springt macOS normalerweise dorthin. DockPeek verhindert das und \u{00F6}ffnet stattdessen ein neues Fenster auf deinem aktuellen Desktop. Du bleibst immer dort wo du bist.")
                }

                // 2. Dock-Vorschau
                helpSection(icon: "eye", title: "Fenster-Vorschau im Dock") {
                    Text("Halte die Maus \u{00FC}ber ein App-Icon im Dock. Nach kurzer Verz\u{00F6}gerung erscheint eine Vorschau aller Fenster dieser App \u{2014} sortiert nach Desktop mit farbigen Gruppen-Headern. Jedes Fenster zeigt einen Live-Screenshot.")
                    helpBullet("macwindow", "Linksklick auf ein Fenster wechselt sofort dorthin")
                    helpBullet("xmark.circle", "X-Button oben links schlie\u{00DF}t das Fenster")
                    helpBullet("arrow.down.to.line", "Minimierte Fenster sind mit gelbem Badge markiert")
                    helpBullet("arrow.up.left.and.arrow.down.right", "Vollbild-Fenster zeigen lila Badge + App-Icon")
                    helpBullet("plus.rectangle", "Hat eine App keine Fenster, erscheint ein Neues-Fenster-Button")
                }

                // 3. Dock-Klick Verhalten
                helpSection(icon: "cursorarrow.click", title: "Intelligentes Dock-Klick-Verhalten") {
                    Text("Je nach Situation reagiert ein Dock-Klick unterschiedlich:")
                    helpBullet("macwindow", "App ist vorne + hat Fenster: Alle Fenster minimieren (Toggle)")
                    helpBullet("macwindow.badge.plus", "App nicht vorne + hat Fenster: Normaler Fokus mit Dock-Animation")
                    helpBullet("arrow.up.doc", "App hat nur minimierte Fenster: Fenster wiederherstellen (kein Desktop-Wechsel)")
                    helpBullet("plus.app", "App hat keine Fenster: Neues Fenster \u{00F6}ffnen")
                }

                // 4. Rechtsklick
                helpSection(icon: "contextualmenu.and.cursorarrow", title: "Rechtsklick-Men\u{00FC}") {
                    Text("Rechtsklick auf ein Fenster in der Vorschau:")
                    helpBullet("xmark.square", "Fenster schlie\u{00DF}en \u{2014} schlie\u{00DF}t genau dieses Fenster")
                    helpBullet("xmark.rectangle", "Alle Fenster schlie\u{00DF}en \u{2014} schlie\u{00DF}t alle Fenster der App")
                    helpBullet("power", "App beenden \u{2014} beendet die gesamte Anwendung")
                    helpBullet("pin.fill", "Einzelne Instanz \u{2014} markiert die App als Single-Window")
                    Text("Wenn eine App keine Fenster hat, bietet das Men\u{00FC} stattdessen Neues Fenster und App beenden an.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 5. Einzelne Instanz
                helpSection(icon: "pin.fill", title: "Einzelne Instanz (Single-Window)") {
                    Text("Manche Apps brauchen nur ein Fenster (z.B. Spotify, Teams, Systemeinstellungen). Markiere sie als Einzelne Instanz \u{2014} dann \u{00F6}ffnet ein Dock-Klick kein neues Fenster, sondern wechselt zum vorhandenen auf dem anderen Desktop.")
                    Text("Ein Pin-Symbol im Vorschau-Header zeigt an welche Apps so markiert sind.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 7. Desktop-Presets
                helpSection(icon: "paintpalette", title: "Desktop-Namen & Farben") {
                    Text("Im Tab Desktops vergibst du jedem Schreibtisch einen eigenen Namen und eine Farbe aus der Pastell-Palette oder eine eigene. Name und Farbe erscheinen in:")
                    helpBullet("tag", "Vorschau-Panel: Farbige Gruppen-Header pro Desktop")
                    helpBullet("textformat.size", "Desktop-Anzeige: Farbige Anzeige beim Desktop-Wechsel")
                    Text("Du kannst bis zu 10 Desktops vordefinieren \u{2014} auch f\u{00FC}r Schreibtische die noch nicht existieren. Neue Desktops \u{00FC}bernehmen automatisch den vordefinierten Namen und die Farbe.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 8. Desktop-Anzeige
                helpSection(icon: "textformat.size", title: "Desktop-Anzeige beim Wechsel") {
                    Text("Beim Desktop-Wechsel wird der aktuelle Desktop-Name angezeigt. Drei Stile + Men\u{00FC}leisten-Option:")
                    helpBullet("arrow.down.to.line", "Notch Drop: Gleitet nach unten aus der Notch heraus")
                    helpBullet("arrow.left.to.line", "Notch Slide: Gleitet nach links aus der Notch heraus")
                    helpBullet("text.badge.star", "Floating Badge: Schwebendes Label am oberen Bildschirmrand")
                    helpBullet("circle.fill", "Men\u{00FC}leisten-Badge: Farbige Kugel + Desktop-Name dauerhaft in der Men\u{00FC}leiste (parallel zu den anderen Stilen aktivierbar)")
                    Text("Anzeigedauer und Geschwindigkeit sind f\u{00FC}r alle Notch-Stile einstellbar.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 9. Vollbild
                helpSection(icon: "arrow.up.left.and.arrow.down.right", title: "Vollbild-Fenster") {
                    Text("Vollbild-Apps auf anderen Spaces werden in der Vorschau mit App-Icon statt Screenshot angezeigt (macOS gibt keinen Zugriff auf den Bildschirminhalt anderer Fullscreen-Spaces). Klick wechselt trotzdem dorthin, Schlie\u{00DF}en per X oder Rechtsklick funktioniert.")
                }

                // 10. Reihenfolge
                helpSection(icon: "arrow.left.arrow.right", title: "Desktop-Reihenfolge") {
                    Text("DockPeek erkennt automatisch wenn du in Mission Control Desktops umsortierst, hinzuf\u{00FC}gst oder entfernst. Die Reihenfolge, Namen und Farben passen sich sofort an.")
                    Text("Desktops k\u{00F6}nnen nur in der macOS Schreibtisch-\u{00DC}bersicht (Mission Control) verwaltet werden \u{2014} DockPeek kann sie nicht programmatisch erstellen oder verschieben.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 11. macOS-Einstellungen
                helpSection(icon: "gearshape.2", title: "Automatische macOS-Konfiguration") {
                    Text("DockPeek konfiguriert beim Start automatisch drei macOS-Einstellungen f\u{00FC}r optimale Funktion:")
                    helpBullet("dock.rectangle", "workspaces=false: Dock wechselt nicht den Desktop")
                    helpBullet("app.badge", "AppleSpacesSwitchOnActivate=false: Apps wechseln nicht den Desktop")
                    helpBullet("arrow.up.arrow.down", "mru-spaces=false: Desktop-Reihenfolge bleibt stabil")
                    Text("Diese Einstellungen werden im Tab System angezeigt und k\u{00F6}nnen manuell zur\u{00FC}ckgesetzt werden.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 12. Berechtigungen
                helpSection(icon: "lock.shield", title: "Ben\u{00F6}tigte Berechtigungen") {
                    helpBullet("hand.raised", "Bedienungshilfen: F\u{00FC}r Fenster-Erkennung, Dock-Klick-Abfangen und Schlie\u{00DF}en-Buttons")
                    helpBullet("record.circle", "Bildschirmaufnahme: F\u{00FC}r Live-Screenshots der Fenster in der Vorschau")
                    Text("Beide Berechtigungen k\u{00F6}nnen im Tab System angefordert werden.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
        }
    }

    private func helpSection(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
                .font(.callout)
        }
    }

    private func helpBullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
        }
        .padding(.leading, 4)
    }

    // MARK: - Bindings

    private func lb<V>(_ kp: WritableKeyPath<LabelSettings, V>) -> Binding<V> {
        Binding {
            store.labelSettings[keyPath: kp]
        } set: {
            var s = store.labelSettings
            s[keyPath: kp] = $0
            store.updateLabelSettings(s)
        }
    }

    private func pv<V>(_ kp: WritableKeyPath<PreviewSettings, V>) -> Binding<V> {
        Binding {
            store.previewSettings[keyPath: kp]
        } set: {
            var s = store.previewSettings
            s[keyPath: kp] = $0
            store.updatePreviewSettings(s)
        }
    }
}

// MARK: - Live Preview Mock Scene

struct MockPreviewScene: View {
    @EnvironmentObject var store: DesktopStore

    private var desktopColor: Color {
        if let desktop = store.currentDesktop {
            return Color(nsColor: store.colorForDesktopIndex(desktop.index))
        }
        return Color.blue
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Vorschau").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)

            // Monitor frame
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    // Screen content
                    ZStack(alignment: .top) {
                        // Solid wallpaper in desktop color
                        desktopColor.opacity(0.25)

                        // Menu bar with notch gap
                        ZStack(alignment: .top) {
                            HStack(spacing: 0) {
                                // Left side of menu bar
                                HStack(spacing: 4) {
                                    Image(systemName: "apple.logo")
                                        .font(.system(size: 6, weight: .medium))
                                    Text("Finder")
                                        .font(.system(size: 6, weight: .semibold))
                                    Text("Ablage")
                                        .font(.system(size: 6))
                                }
                                .foregroundStyle(.primary.opacity(0.5))
                                Spacer()
                                // Right side of menu bar
                                HStack(spacing: 3) {
                                    Image(systemName: "wifi").font(.system(size: 5))
                                    Image(systemName: "battery.75percent").font(.system(size: 5))
                                    Text("12:00").font(.system(size: 6, design: .monospaced))
                                }
                                .foregroundStyle(.primary.opacity(0.4))
                            }
                            .padding(.horizontal, 5)
                            .frame(height: 12)
                            .background(.bar)

                            // Notch Drop: notch + badge below
                            if store.labelSettings.indicatorStyle == .notchDrop {
                                VStack(spacing: 0) {
                                    UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                                        .fill(Color.black)
                                        .frame(width: 44, height: 8)
                                    HStack(spacing: 3) {
                                        Circle().fill(desktopColor).frame(width: 4, height: 4)
                                        Text(store.currentDesktopName)
                                            .font(.system(size: 6, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                                            .fill(Color.black)
                                    )
                                }
                            }

                            // Notch Slide: notch + badge to the left
                            if store.labelSettings.indicatorStyle == .notchSlide {
                                HStack(spacing: 0) {
                                    HStack(spacing: 3) {
                                        Circle().fill(desktopColor).frame(width: 4, height: 4)
                                        Text(store.currentDesktopName)
                                            .font(.system(size: 6, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                                            .fill(Color.black)
                                    )
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.black)
                                        .frame(width: 44, height: 8)
                                }
                            }
                        }

                        // Floating Badge preview
                        if store.labelSettings.indicatorStyle == .floatingBadge {
                            mockDesktopLabel
                                .padding(.top, 16)
                        }
                    }
                    .frame(height: 120)

                    // Dock
                    mockDock
                        .padding(.bottom, 5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

                // Monitor stand
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 30, height: 12)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 60, height: 3)
            }
            .frame(maxWidth: 200)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
    }

    private var mockDesktopLabel: some View {
        let ls = store.labelSettings
        let labelColor = Color(nsColor: store.colorForCurrentDesktop())

        return Group {
            if ls.mode != .hidden {
                HStack {
                    if ls.position == .topCenter || ls.position == .topRight { Spacer() }
                    Text("Desktop 1")
                        .font(.system(size: ls.fontSize * 0.7, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: ls.fontSize * 0.5)
                                .fill(labelColor.opacity(ls.opacity))
                        )
                    if ls.position == .topCenter || ls.position == .topLeft { Spacer() }
                }
                .padding(.horizontal, 12)
                .opacity(ls.mode == .fadeOut ? 0.7 : 1.0)
            }
        }
    }

    private var mockDock: some View {
        let tw = store.previewSettings.thumbnailWidth * 0.35
        let th = store.previewSettings.thumbnailHeight * 0.35

        return VStack(spacing: 1) {
            // Mock preview panel (speech bubble)
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    VStack(spacing: 1) {
                        HStack(spacing: 2) {
                            Circle().fill(Color.blue.opacity(0.6)).frame(width: 3, height: 3)
                            Text("D1").font(.system(size: 5)).foregroundStyle(.secondary)
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.08))
                            .frame(width: tw, height: th)
                            .overlay(
                                Image(systemName: "macwindow")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                    VStack(spacing: 1) {
                        HStack(spacing: 2) {
                            Circle().fill(Color.green.opacity(0.6)).frame(width: 3, height: 3)
                            Text("D2").font(.system(size: 5)).foregroundStyle(.secondary)
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.08))
                            .frame(width: tw, height: th)
                            .overlay(
                                Image(systemName: "macwindow")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.thinMaterial)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                )
                Triangle()
                    .fill(.thinMaterial)
                    .frame(width: 8, height: 4)
            }

            // Dock bar — glass pill with realistic app icons
            HStack(spacing: 3) {
                // App icons with distinct colors (like real dock)
                dockIcon("safari", color: .blue)
                dockIcon("envelope.fill", color: .cyan)
                dockIcon("message.fill", color: .green)
                dockIcon("play.circle.fill", color: .pink)
                dockIcon("terminal", color: .primary)

                // Separator
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 1)

                dockIcon("folder.fill", color: .blue)
                dockIcon("trash", color: .gray)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            )
        }
    }

    private func dockIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(color.opacity(0.12))
            )
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

// MARK: - Color Popover

/// A small colored circle that opens a popover with pastel swatches + custom color picker.
struct ColorPopoverButton: View {
    let currentColor: Color
    let swatches: [(name: String, r: Double, g: Double, b: Double)]
    let isSelected: ((name: String, r: Double, g: Double, b: Double)) -> Bool
    let onSelect: ((r: Double, g: Double, b: Double)) -> Void
    @Binding var customBinding: Color
    @State private var showPopover = false

    init(currentColor: Color,
         swatches: [(name: String, r: Double, g: Double, b: Double)],
         isSelected: @escaping ((name: String, r: Double, g: Double, b: Double)) -> Bool,
         onSelect: @escaping ((r: Double, g: Double, b: Double)) -> Void,
         customBinding: Binding<Color>) {
        self.currentColor = currentColor
        self.swatches = swatches
        self.isSelected = isSelected
        self.onSelect = onSelect
        self._customBinding = customBinding
    }

    var body: some View {
        Circle()
            .fill(currentColor)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 1)
            .onTapGesture { showPopover = true }
            .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Farbe wählen").font(.caption).foregroundStyle(.secondary)

                    // Swatch grid: 6 columns x 2 rows
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 6), spacing: 4) {
                        ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                            let selected = isSelected(swatch)
                            Circle()
                                .fill(Color(red: swatch.r, green: swatch.g, blue: swatch.b))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0)
                                )
                                .shadow(color: selected ? .black.opacity(0.3) : .clear, radius: 2)
                                .onTapGesture {
                                    onSelect((swatch.r, swatch.g, swatch.b))
                                }
                                .help(swatch.name)
                        }
                    }

                    Divider()

                    HStack {
                        Text("Eigene Farbe").font(.caption)
                        Spacer()
                        ColorPicker("", selection: $customBinding)
                            .labelsHidden()
                    }
                }
                .padding(10)
                .frame(width: 170)
            }
    }
}
