/// DesktopStore.swift — Central state manager that coordinates all subsystems.
///
/// This is the app's single source of truth. It owns the desktop configuration list,
/// observes macOS space-change and app-activation notifications, drives the dock-click
/// interception flow, and persists all settings to JSON.
///
/// ## Desktop Preset System
/// Desktops are identified by **index** (Mission Control order), not by space ID.
/// Users define presets (name + optional color) by index. When spaces change,
/// `syncWithSystem()` rebuilds `desktops` from live CGS data and applies presets
/// by matching the desktop's position to the preset index.
///
/// ## Dock-Click Detection Flow
/// The dock-click pipeline has two parallel paths that converge here:
///
/// 1. **CGEventTap path** (`DockManager.preHandleDockClick`):
///    Fires for real mouse clicks. Handles toggle-minimize and unminimize cases by
///    suppressing the click before the Dock sees it. Calls `onClickIntercepted` or
///    `onNeedNewWindow` back into this store.
///
/// 2. **Activation observer path** (`didActivateApplicationNotification`):
///    Fires for ALL activations (dock click, Cmd+Tab, Spotlight, etc.).
///    Checks `isMouseInDockArea()` to distinguish dock clicks from other activations.
///    Handles the "app has no window on current space" case by opening a new window.
import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class DesktopStore: ObservableObject {
    static let shared = DesktopStore()
    @Published var desktops: [DesktopConfig] = []
    @Published var presets: [DesktopPreset] = []
    @Published var currentSpaceID: Int = 0
    let autoNewWindowEnabled: Bool = true
    @Published var singleInstanceApps: [String] = []
    @Published var labelSettings: LabelSettings = LabelSettings()
    @Published var previewSettings: PreviewSettings = PreviewSettings()
    @Published var mruSpacesConfigured: Bool = false

    private let detector = SpaceDetector.shared
    let dockManager = DockManager()
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var labelController = DesktopNameLabelController()
    private var notchBadge = NotchBadgeController()
    private var notchSlide = NotchSlideController()
    var dockPreviewController: DockPreviewController?
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Activation Tracking

    private var ignoreActivationsUntil: Date = .distantPast
    private var lastActivatedBundleID: String?
    private var lastActivationTime: Date = .distantPast
    private var labelDebounceTask: Task<Void, Never>?
    private var lastActivationWasDockClick: Bool = false
    private var lastKnownSpaceCount: Int = 0
    private var spaceSyncTimer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = support.appendingPathComponent("DockPeek")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("desktop-config.json")

        loadConfig()
        syncWithSystem()
        lastKnownSpaceCount = desktops.count
        installObservers()
        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: CGEventTap für Dock-Click-Interception
        // Grund: App reduziert auf Preview + Desktop-Benennung
        // installClickInterceptor()
        updateLabel()
        enableAutostartIfNeeded()
        startSpaceSyncTimer()

        mruSpacesConfigured = dockManager.checkMruSpacesStatus()

        Task {
            try? await Task.sleep(for: .seconds(2))
            self.dockPreviewController = DockPreviewController(store: self)
        }
    }

    private func installClickInterceptor() {
        dockManager.onClickIntercepted = { [weak self] _ in
            self?.ignoreActivationsUntil = Date().addingTimeInterval(0.5)
            self?.lastActivationWasDockClick = false
        }
        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: Callback für neue Fenster öffnen
        // Grund: App reduziert auf Preview + Desktop-Benennung
        // dockManager.onNeedNewWindow = { [weak self] bundleID in
        //     guard let self else { return }
        //     self.ignoreActivationsUntil = Date().addingTimeInterval(0.5)
        //     self.lastActivationWasDockClick = false
        //     Task { @MainActor in
        //         if self.isSingleInstance(bundleID) {
        //             self.switchToAppWindow(bundleID: bundleID)
        //             return
        //         }
        //         let success = self.dockManager.openNewWindow(bundleIdentifier: bundleID)
        //         if !success {
        //             self.switchToAppWindow(bundleID: bundleID)
        //         }
        //     }
        // }
        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: CGEventTap für Dock-Click-Interception
        // Grund: App reduziert auf Preview + Desktop-Benennung
        // dockManager.installClickInterceptor()
    }

    var currentDesktop: DesktopConfig? {
        desktops.first(where: { $0.id == currentSpaceID })
    }

    var currentDesktopName: String {
        // Check if the synced currentSpaceID is a fullscreen space
        let allSpaces = detector.detectSpaces()
        if let space = allSpaces.first(where: { $0.spaceID == currentSpaceID }), space.isFullscreen {
            return "Vollbild"
        }
        return currentDesktop?.customName ?? "Desktop"
    }

    // MARK: - Preset Management

    /// Returns the preset for the given 1-based desktop index, or nil.
    func preset(forIndex index: Int) -> DesktopPreset? {
        presets.first(where: { $0.id == index })
    }

    /// Updates or creates a preset for the given index.
    func updatePreset(_ preset: DesktopPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
            presets.sort { $0.id < $1.id }
        }
        // Apply preset to active desktop with this index
        if let dIdx = desktops.firstIndex(where: { $0.index == preset.id }) {
            desktops[dIdx].customName = preset.name
        }
        save()
        updateLabel()
    }

    /// Adds a new preset with the next available index.
    func addPreset() {
        let nextIndex = (presets.map(\.id).max() ?? 0) + 1
        guard nextIndex <= 10 else { return }
        let c = Self.desktopPalette[(nextIndex - 1) % Self.desktopPalette.count]
        let preset = DesktopPreset(id: nextIndex, name: "Desktop \(nextIndex)",
                                   colorR: c.r, colorG: c.g, colorB: c.b)
        presets.append(preset)
        presets.sort { $0.id < $1.id }
        save()
    }

    /// Removes a preset at the given index.
    func removePreset(index: Int) {
        presets.removeAll { $0.id == index }
        save()
    }

    // MARK: - Space Management

    /// Reconciles the in-memory `desktops` array with live CGS space data.
    /// Assigns preset names/colors by matching desktop position to preset index.
    /// Ensures order always matches Mission Control order.
    func syncWithSystem() {
        let allSpaces = detector.detectMainDisplaySpaces()
        // Track the REAL current space (including fullscreen)
        currentSpaceID = allSpaces.first(where: \.isCurrentSpace)?.spaceID ?? 0
        let detected = allSpaces.filter { !$0.isFullscreen }

        // Rebuild desktops from live space data, applying presets by index
        var newDesktops: [DesktopConfig] = []
        for (i, space) in detected.enumerated() {
            let desktopIndex = i + 1 // 1-based
            let presetName = preset(forIndex: desktopIndex)?.name
            let name = presetName ?? "Desktop \(space.index)"
            newDesktops.append(DesktopConfig(id: space.spaceID, index: desktopIndex, customName: name))
        }
        // Only update @Published if actually changed (avoids unnecessary SwiftUI re-renders)
        if newDesktops != desktops {
            desktops = newDesktops
        }
        lastKnownSpaceCount = desktops.count

        // Ensure presets exist for all active desktops (create defaults if missing)
        for desktop in desktops {
            if preset(forIndex: desktop.index) == nil {
                let c = Self.desktopPalette[(desktop.index - 1) % Self.desktopPalette.count]
                presets.append(DesktopPreset(id: desktop.index, name: desktop.customName,
                                             colorR: c.r, colorG: c.g, colorB: c.b))
            }
        }
        presets.sort { $0.id < $1.id }
        save()
    }

    private func onSpaceChanged() {
        let oldID = currentSpaceID
        syncWithSystem()
        guard currentSpaceID != oldID, oldID != 0 else { return }

        let dockClickCaused = autoNewWindowEnabled
            && lastActivationWasDockClick
            && Date().timeIntervalSince(lastActivationTime) < 0.5
            && lastActivatedBundleID != nil

        if dockClickCaused, let bundleID = lastActivatedBundleID {
            _ = dockManager.openNewWindow(bundleIdentifier: bundleID)
            lastActivatedBundleID = nil
            lastActivationWasDockClick = false
            ignoreActivationsUntil = Date().addingTimeInterval(0.8)
        } else {
            ignoreActivationsUntil = Date().addingTimeInterval(0.8)
        }

        // Show immediately
        updateLabel()

        // Re-check after 500ms in case the transition wasn't complete
        // (fullscreen → desktop can report wrong space initially)
        labelDebounceTask?.cancel()
        labelDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let beforeID = currentSpaceID
            syncWithSystem()
            if currentSpaceID != beforeID {
                updateLabel()
            }
        }
    }

    // MARK: - Desktop Colors

    /// Fixed color palette cycled by desktop index (fallback when no custom color is set).
    static let desktopPalette: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.35, 0.60, 0.95),  // Blue
        (0.40, 0.78, 0.55),  // Green
        (0.68, 0.50, 0.90),  // Purple
        (0.95, 0.60, 0.35),  // Orange
        (0.90, 0.45, 0.55),  // Pink
        (0.50, 0.75, 0.75),  // Teal
    ]

    /// Returns the color for a desktop at the given 1-based index.
    /// Uses preset custom color if defined, otherwise falls back to palette.
    func colorForDesktopIndex(_ index: Int) -> NSColor {
        if let p = preset(forIndex: index), p.hasCustomColor,
           let r = p.colorR, let g = p.colorG, let b = p.colorB {
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        }
        let c = Self.desktopPalette[(index - 1) % Self.desktopPalette.count]
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
    }

    /// Returns the color for the current desktop.
    func colorForCurrentDesktop() -> NSColor {
        if let desktop = currentDesktop {
            return colorForDesktopIndex(desktop.index)
        }
        // Fullscreen space: find origin desktop
        let allSpaces = detector.detectSpaces()
        var lastRegularIndex = 1
        for space in allSpaces {
            if !space.isFullscreen {
                if let d = desktops.first(where: { $0.id == space.spaceID }) {
                    lastRegularIndex = d.index
                }
            } else if space.spaceID == currentSpaceID {
                return colorForDesktopIndex(lastRegularIndex)
            }
        }
        return colorForDesktopIndex(1)
    }

    // MARK: - Label

    func updateLabel() {
        let color = colorForCurrentDesktop()
        let name = currentDesktopName

        switch labelSettings.indicatorStyle {
        case .notchDrop:
            labelController.hide()
            notchBadge.show(name: name, color: color,
                           holdDuration: labelSettings.notchDropHold,
                           animationSpeed: labelSettings.notchDropSpeed)
        case .notchSlide:
            labelController.hide()
            notchSlide.show(name: name, color: color,
                           holdDuration: labelSettings.notchDropHold,
                           animationSpeed: labelSettings.notchDropSpeed)
        case .floatingBadge:
            labelController.update(name: name, settings: labelSettings, desktopColor: color)
        }
    }

    func testIndicator() {
        let color = colorForCurrentDesktop()
        let name = currentDesktopName
        switch labelSettings.indicatorStyle {
        case .notchDrop:
            notchBadge.show(name: name, color: color,
                           holdDuration: labelSettings.notchDropHold,
                           animationSpeed: labelSettings.notchDropSpeed)
        case .notchSlide:
            notchSlide.show(name: name, color: color,
                           holdDuration: labelSettings.notchDropHold,
                           animationSpeed: labelSettings.notchDropSpeed)
        case .floatingBadge:
            labelController.update(name: name, settings: labelSettings, desktopColor: color)
        }
    }

    func updateLabelSettings(_ settings: LabelSettings) {
        self.labelSettings = settings
        updateLabel()
        save()
    }

    func updatePreviewSettings(_ settings: PreviewSettings) {
        self.previewSettings = settings
        save()
    }

    // MARK: - Desktop Configuration

    func renameDesktop(id: Int, name: String) {
        guard let dIdx = desktops.firstIndex(where: { $0.id == id }) else { return }
        desktops[dIdx].customName = name
        // Also update the preset
        let index = desktops[dIdx].index
        if var p = preset(forIndex: index) {
            p.name = name
            updatePreset(p)
        }
        if id == currentSpaceID { updateLabel() }
    }

    func ignoreNextActivation() {
        ignoreActivationsUntil = Date().addingTimeInterval(1.0)
    }

    // MARK: - Observers

    private func installObservers() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.onSpaceChanged() }
        }

        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: Activation Observer für automatische neue Fenster
        // Grund: App reduziert auf Preview + Desktop-Benennung
        // activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        //     forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        // ) { notification in
        //     let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        //     let bundleID = app?.bundleIdentifier
        //
        //     Task { @MainActor [weak self] in
        //         guard let self, self.autoNewWindowEnabled,
        //               let bundleID,
        //               bundleID != Bundle.main.bundleIdentifier,
        //               Date() > self.ignoreActivationsUntil
        //         else { return }
        //
        //         let isDockClick = self.dockManager.isMouseInDockArea()
        //
        //         self.lastActivatedBundleID = bundleID
        //         self.lastActivationTime = Date()
        //         self.lastActivationWasDockClick = isDockClick
        //
        //         guard isDockClick else { return }
        //
        //         if let app, let launchDate = app.launchDate,
        //            Date().timeIntervalSince(launchDate) < 2.0 {
        //             return
        //         }
        //
        //         if self.isSingleInstance(bundleID) {
        //             if !self.dockManager.appHasWindowsOnCurrentSpace(bundleID) {
        //                 self.switchToAppWindow(bundleID: bundleID)
        //                 self.ignoreActivationsUntil = Date().addingTimeInterval(1.0)
        //             }
        //             return
        //         }
        //
        //         try? await Task.sleep(for: .milliseconds(300))
        //         guard Date() > self.ignoreActivationsUntil else { return }
        //
        //         if !self.dockManager.appHasWindowsOnCurrentSpace(bundleID) {
        //             if self.dockManager.hasMinimizedWindows(for: bundleID) {
        //                 let currentSpaceID = self.detector.currentSpaceID()
        //                 if !self.dockManager.unminimizeWindow(for: bundleID, preferSpaceID: currentSpaceID) {
        //                     _ = self.dockManager.openNewWindow(bundleIdentifier: bundleID)
        //                 }
        //             } else {
        //                 _ = self.dockManager.openNewWindow(bundleIdentifier: bundleID)
        //             }
        //             self.ignoreActivationsUntil = Date().addingTimeInterval(1.0)
        //         }
        //     }
        // }
    }

    // MARK: - Single Instance Apps

    func isSingleInstance(_ bundleID: String) -> Bool {
        singleInstanceApps.contains(bundleID)
    }

    func toggleSingleInstance(_ bundleID: String) {
        if let idx = singleInstanceApps.firstIndex(of: bundleID) {
            singleInstanceApps.remove(at: idx)
        } else {
            singleInstanceApps.append(bundleID)
        }
        save()
    }

    func switchToAppWindow(bundleID: String) {
        let spaces = detector.detectMainDisplaySpaces().filter { !$0.isFullscreen }
        let pids = dockManager.pidsForApp(bundleID)

        var targetSpace: Int?
        if let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            for w in windowList {
                guard let wPID = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(wPID),
                      let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let wID = w[kCGWindowNumber as String] as? CGWindowID else { continue }
                if let space = detector.spaceForWindow(wID), space != 0 {
                    targetSpace = space
                    break
                }
            }
        }

        if let targetSpace, targetSpace != currentSpaceID {
            guard let currentIdx = spaces.firstIndex(where: \.isCurrentSpace),
                  let targetIdx = spaces.firstIndex(where: { $0.spaceID == targetSpace }) else {
                activateApp(bundleID)
                return
            }
            let diff = targetIdx - currentIdx
            if diff != 0 {
                let keyCode = diff > 0 ? 124 : 123
                for _ in 0..<abs(diff) {
                    var error: NSDictionary?
                    NSAppleScript(source: "tell application \"System Events\" to key code \(keyCode) using control down")?
                        .executeAndReturnError(&error)
                    usleep(500_000)
                }
            }
        }

        if let pid = pids.first {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let windows = ref as? [AXUIElement], let first = windows.first {
                AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(first, kAXRaiseAction as CFString)
            }
        }

        activateApp(bundleID)
        ignoreActivationsUntil = Date().addingTimeInterval(1.0)
    }

    private func activateApp(_ bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateAllWindows])
        }
    }

    // MARK: - Persistence

    private func save() {
        let state = DesktopState(
            desktops: desktops,
            presets: presets,
            singleInstanceApps: singleInstanceApps,
            labelSettings: labelSettings, previewSettings: previewSettings)
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(DesktopState.self, from: data) else { return }
        desktops = state.desktops
        presets = state.presets
        singleInstanceApps = state.singleInstanceApps
        labelSettings = state.labelSettings
        previewSettings = state.previewSettings
    }

    // MARK: - Space Sync Timer

    /// Periodically checks if the number of spaces changed (e.g., after Mission Control
    /// add/remove) and triggers a sync. Needed because `activeSpaceDidChangeNotification`
    /// doesn't fire when the user returns to the SAME space after Mission Control.
    private func startSpaceSyncTimer() {
        spaceSyncTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentCount = self.detector.detectMainDisplaySpaces().filter({ !$0.isFullscreen }).count
                if currentCount != self.lastKnownSpaceCount {
                    self.lastKnownSpaceCount = currentCount
                    self.syncWithSystem()
                    self.updateLabel()
                }
            }
        }
    }

    // MARK: - Autostart

    /// Enables login-item autostart on first launch. Silently skips if already registered.
    private func enableAutostartIfNeeded() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

}
