import AppKit
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError


enum WindowState {
    case normal       // visible on desktop
    case minimized    // in dock
    case fullscreen   // own space
}

struct WindowThumbnail {
    var windowID: CGWindowID
    var title: String
    var thumbnail: NSImage?
    var appIcon: NSImage?
    var appName: String
    var spaceID: Int
    var desktopName: String
    var pid: Int32
    var state: WindowState = .normal
    var bundleID: String = ""
    var originDesktopIndex: Int = 0 // for fullscreen: index of the source desktop
}

private struct DockItem {
    var name: String
    var bundleID: String?
    var frame: CGRect
}

@MainActor
class DockPreviewController {
    private var panel: KeyablePanel?
    private var contentView: NSView?
    private var clickableViews: [ClickableView] = []
    private var titleLabels: [NSTextField] = []
    private var cardGroupIndex: [Int] = [] // which group each card belongs to
    private var groupViews: [[NSView]] = [] // all views per group (header, overflow, etc.)
    private var focusedIndex: Int = -1
    private var pollTimer: Timer?
    private var lastHoveredBundleID: String?
    private var hoverStartTime: Date?
    private var isLoadingPreview = false
    private var loadingStartTime: Date = .distantPast
    private var lastShownBundleID: String?
    private var lastShownBundleIDForPanel: String = ""
    private var currentThumbnails: [WindowThumbnail] = []
    private var currentMousePoint: NSPoint = .zero
    private var pendingRefreshTask: DispatchWorkItem?
    private var isAnimatingClose = false
    private var stableWindowOrder: [CGWindowID] = [] // persistent sort order
    private var displayGeneration: Int = 0 // incremented on close to invalidate in-flight refreshes
    private var lastPanelIconCenter: NSPoint = .zero
    private var lastStateRefresh: Date = .distantPast
    private var rightClickCooldownUntil: Date = .distantPast
    private var closeCooldownUntil: Date = .distantPast
    private var recentlyClosedDialogIDs: [CGWindowID: Date] = [:]
    private var thumbnailCache: [CGWindowID: (image: NSImage, time: Date)] = [:]
    private let cacheMaxAge: TimeInterval = 5.0
    private weak var store: DesktopStore?
    private let detector = SpaceDetector.shared
    private var accessibilityGranted = false
    private var dockItems: [DockItem] = []
    private var lastDockRefresh: Date = .distantPast

    init(store: DesktopStore) {
        self.store = store
        checkAccessibility()
        startPolling()
    }

    private func checkAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    private var hoverDelay: Double { store?.previewSettings.hoverDelay ?? 0.4 }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Debug: programmatically open preview for a specific app
    func showPreviewForDebug(bundleID: String, appName: String, at point: NSPoint) async {
        isLoadingPreview = true
        await showPreview(for: bundleID, appName: appName, at: point)
        isLoadingPreview = false
        lastShownBundleID = bundleID
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Dock Items via AX

    private func refreshDockItems() {
        guard Date().timeIntervalSince(lastDockRefresh) > 0.5 else { return }
        lastDockRefresh = Date()

        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return }

        let dockAX = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let lists = axChildren(of: dockAX) else { return }

        var items: [DockItem] = []
        for list in lists {
            guard axRole(of: list) == "AXList", let children = axChildren(of: list) else { continue }
            for child in children {
                guard let pos = axPosition(of: child), let size = axSize(of: child) else { continue }
                let name = axTitle(of: child) ?? ""
                if name.isEmpty { continue }

                var bundleID: String?
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, "AXURL" as CFString, &urlRef) == .success,
                   let urlValue = urlRef {
                    let url: URL?
                    if CFGetTypeID(urlValue) == CFURLGetTypeID() {
                        url = (urlValue as! CFURL) as URL
                    } else if let str = urlValue as? String {
                        url = URL(string: str)
                    } else { url = nil }
                    bundleID = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
                }
                if bundleID == nil {
                    bundleID = NSWorkspace.shared.runningApplications
                        .first(where: { $0.localizedName == name })?.bundleIdentifier
                }

                items.append(DockItem(name: name, bundleID: bundleID,
                                      frame: CGRect(origin: pos, size: size)))
            }
        }
        dockItems = items

        // Update DockManager's fast cache for CGEventTap hit-testing
        store?.dockManager.cachedDockItems = items.compactMap { item in
            guard let bid = item.bundleID else { return nil }
            return (bundleID: bid, frame: item.frame)
        }
    }

    private func dockItemAtMouse() -> DockItem? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return nil }
        let cgY = screen.frame.height - mouse.y
        let cgPoint = CGPoint(x: mouse.x, y: cgY)

        for item in dockItems {
            // Shrink hit area at top edge (closest to app windows) so preview
            // doesn't trigger when the cursor barely grazes the dock icon.
            // CG coordinates: origin top-left, so minY is the top edge.
            let shrunk = CGRect(x: item.frame.minX,
                                y: item.frame.minY + 6,
                                width: item.frame.width,
                                height: item.frame.height - 6)
            if shrunk.contains(cgPoint) { return item }
        }
        return nil
    }

    // MARK: - Tick

    private func dockItemCenter(_ item: DockItem) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return NSPoint(x: item.frame.midX, y: screen.frame.height - item.frame.midY)
    }

    private func tick() {
        if !accessibilityGranted {
            accessibilityGranted = AXIsProcessTrusted()
            if !accessibilityGranted { return }
            lastDockRefresh = .distantPast
        }

        guard let store else { return }

        let mouse = NSEvent.mouseLocation

        // Mouse over or near preview panel? Keep it (and the dock) visible.
        // This MUST run before the isDockVisible() check — when the user moves
        // the mouse from the dock to the panel, the dock may start hiding,
        // but the panel should stay as long as the mouse is on it.
        if let panel, panel.isVisible {
            let extended = panel.frame.insetBy(dx: -20, dy: -15)
            if extended.contains(mouse) {
                // Still refresh if showing empty state (app may have opened a window)
                if currentThumbnails.isEmpty, !isLoadingPreview,
                   Date().timeIntervalSince(lastStateRefresh) > 0.5,
                   let bid = lastShownBundleIDForPanel.isEmpty ? nil : lastShownBundleIDForPanel,
                   let item = dockItems.first(where: { $0.bundleID == bid }) {
                    lastStateRefresh = Date()
                    thumbnailCache.removeAll()
                    loadPreview(for: bid, appName: item.name, at: lastPanelIconCenter)
                }
                return
            }
        }

        // Dock auto-hide: Preview schließen wenn Dock nicht sichtbar
        // (only when mouse is NOT on the panel — that case is handled above)
        if panel?.isVisible == true && !isDockVisible() {
            hidePanel()
            return
        }

        // Hide if any mouse button pressed outside preview
        let pressedButtons = NSEvent.pressedMouseButtons
        if pressedButtons != 0 && panel?.isVisible == true {
            let overPanel = panel?.frame.contains(mouse) ?? false
            // Right-click anywhere outside panel → hide and set cooldown
            if pressedButtons & 2 != 0 && !overPanel {
                hidePanel()
                lastHoveredBundleID = nil
                hoverStartTime = nil
                rightClickCooldownUntil = Date().addingTimeInterval(1.5)
                return
            }
            if !overPanel { hidePanel() }
            return
        }

        // Block re-show during cooldowns or while right button held
        if NSEvent.pressedMouseButtons & 2 != 0 || Date() < rightClickCooldownUntil || Date() < closeCooldownUntil {
            return
        }

        // Context menu? Hide.
        if isDockContextMenuVisible() {
            if panel?.isVisible == true { hidePanel() }
            lastHoveredBundleID = nil
            hoverStartTime = nil
            return
        }

        // Not near dock? Hide.
        if !store.dockManager.isMouseInDockArea() {
            if panel?.isVisible == true { hidePanel() }
            lastHoveredBundleID = nil
            hoverStartTime = nil
            return
        }

        refreshDockItems()

        guard let item = dockItemAtMouse(), let bundleID = item.bundleID,
              bundleID != "com.apple.dock",
              bundleID != Bundle.main.bundleIdentifier else {
            // Not over an app icon — but if mouse is between panel and dock, keep panel
            if let panel, panel.isVisible {
                let verticalStrip = NSRect(x: panel.frame.minX, y: 0,
                                           width: panel.frame.width, height: panel.frame.maxY)
                if verticalStrip.contains(mouse) { return }
                // Don't hide while a refresh is loading (panel size may be changing)
                if isLoadingPreview { return }
            }
            if panel?.isVisible == true { hidePanel() }
            lastHoveredBundleID = nil
            hoverStartTime = nil
            return
        }

        let iconCenter = dockItemCenter(item)

        if bundleID == lastHoveredBundleID {
            if panel?.isVisible != true && !isLoadingPreview,
               let start = hoverStartTime,
               Date().timeIntervalSince(start) >= hoverDelay {
                loadPreview(for: bundleID, appName: item.name, at: iconCenter)
            }
            if let panel, panel.isVisible {
                // Reposition if dock icon moved
                let dist = hypot(iconCenter.x - lastPanelIconCenter.x, iconCenter.y - lastPanelIconCenter.y)
                if dist > 5 {
                    repositionPanel(to: iconCenter)
                }
                // Auto-refresh: 0.5s when showing "Keine Fenster" (app just launched), 3s otherwise
                let refreshInterval: TimeInterval = currentThumbnails.isEmpty ? 0.5 : 1.5
                if !isLoadingPreview && Date().timeIntervalSince(lastStateRefresh) > refreshInterval {
                    lastStateRefresh = Date()
                    thumbnailCache.removeAll()
                    loadPreview(for: bundleID, appName: item.name, at: iconCenter)
                }
            }
        } else {
            // Different app
            lastHoveredBundleID = bundleID
            if panel?.isVisible == true {
                // Preview was showing for another app — use short delay for switch
                hoverStartTime = Date().addingTimeInterval(-hoverDelay + 0.15)
            } else {
                hoverStartTime = Date()
            }
            hidePanel()
        }
    }

    private func loadPreview(for bundleID: String, appName: String, at point: NSPoint) {
        // Safety: reset stuck loading state after 3s
        if isLoadingPreview && Date().timeIntervalSince(loadingStartTime) > 3.0 {
            isLoadingPreview = false
        }
        guard !isLoadingPreview else { return }
        isLoadingPreview = true
        loadingStartTime = Date()
        let gen = displayGeneration
        Task {
            await showPreview(for: bundleID, appName: appName, at: point, generation: gen)
            isLoadingPreview = false
            if self.displayGeneration != gen { return }
            if lastHoveredBundleID != bundleID {
                hidePanel()
            } else {
                lastShownBundleID = bundleID
            }
        }
    }

    // MARK: - Dock Visibility

    /// Prüft ob der Dock sichtbar ist (nicht auto-hidden).
    /// Der Dock-Prozess hat sein Hauptfenster bei Layer 20 (nicht 0).
    /// Bei Auto-Hide verschwindet es aus der OnScreen-Liste.
    private func isDockVisible() -> Bool {
        let dockPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first?.processIdentifier ?? 0

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return true }

        // Dock bar is at layer ~20, context menus are higher (>25)
        return windowList.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == dockPID &&
            (info[kCGWindowLayer as String] as? Int) == 20
        }
    }

    // MARK: - Context Menu Detection

    private func isDockContextMenuVisible() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        guard let dockPID = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier else { return false }

        return windowList.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid == dockPID,
                  let layer = w[kCGWindowLayer as String] as? Int else { return false }
            return layer > 25 // Dock bar is ~20, context menus are higher
        }
    }

    // MARK: - AX Helpers

    private func axChildren(of el: AXUIElement) -> [AXUIElement]? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &r) == .success else { return nil }
        return r as? [AXUIElement]
    }
    private func axRole(of el: AXUIElement) -> String? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success else { return nil }
        return r as? String
    }
    private func axTitle(of el: AXUIElement) -> String? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &r) == .success else { return nil }
        return r as? String
    }
    private func axPosition(of el: AXUIElement) -> CGPoint? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &r) == .success,
              let val = r else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &p)
        return p
    }
    private func axSize(of el: AXUIElement) -> CGSize? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &r) == .success,
              let val = r else { return nil }
        var s = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &s)
        return s
    }

    // MARK: - Preview

    private func showPreview(for bundleIdentifier: String, appName: String, at mousePoint: NSPoint, generation: Int? = nil) async {
        // If a close happened since this refresh started, bail out
        if let gen = generation, gen != displayGeneration { return }
        guard let store else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch { return }

        let appIcon: NSImage? = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        // Collect AX window IDs and track which ones are dialogs (no AXCloseButton)
        var axWindowIDs = Set<CGWindowID>()
        var axDialogIDs = Set<CGWindowID>()
        let appPids = store.dockManager.pidsForApp(bundleIdentifier)
        for pid in appPids {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let axWindows = ref as? [AXUIElement] {
                for w in axWindows {
                    var wid: CGWindowID = 0
                    guard _AXUIElementGetWindow(w, &wid) == .success else { continue }
                    axWindowIDs.insert(wid)
                    var closeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, "AXCloseButton" as CFString, &closeRef) != .success {
                        axDialogIDs.insert(wid)
                    }
                }
            }
        }

        // CGWindowList as additional reliable source — works even when AX tree
        // isn't fully available yet (e.g., WhatsApp, Mail at app startup).
        // AX requires app activation to fully populate; CGWindowList does not.
        var cgWindowIDs = Set<CGWindowID>()
        if let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in windowList {
                guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                      appPids.contains(pid),
                      let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                      let wid = w[kCGWindowNumber as String] as? CGWindowID else { continue }
                cgWindowIDs.insert(wid)
            }
        }

        let appWindows = content.windows.filter { w in
            guard w.owningApplication?.bundleIdentifier == bundleIdentifier,
                  !(w.title ?? "").isEmpty,
                  w.frame.width > 200, w.frame.height > 100 else { return false }
            // Exclude dialog windows — we handle them separately below
            if axDialogIDs.contains(w.windowID) { return false }
            // Real AX window (has AXCloseButton)
            if axWindowIDs.contains(w.windowID) { return true }
            // Window confirmed by CGWindowList (layer 0, matching PID) —
            // reliable even when AX tree isn't ready at startup
            if cgWindowIDs.contains(w.windowID) { return true }
            // On-screen fallback: only if neither AX nor CGWindowList found any windows
            if w.isOnScreen && axWindowIDs.isEmpty && cgWindowIDs.isEmpty && axDialogIDs.isEmpty { return true }
            return false
        }

        // Prune expired entries from recently closed dialogs (2s TTL)
        let now = Date()
        recentlyClosedDialogIDs = recentlyClosedDialogIDs.filter { now.timeIntervalSince($0.value) < 2.0 }

        // No real windows but has dialogs → show dialog with app icon as thumbnail
        if appWindows.isEmpty && !axDialogIDs.isEmpty {
            // Build dialog entries directly from AX (consistent, no SCShareableContent flicker)
            var dialogInfos: [WindowThumbnail] = []
            for pid in appPids {
                let axApp = AXUIElementCreateApplication(pid)
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                      let axWindows = ref as? [AXUIElement] else { continue }
                for w in axWindows {
                    var wid: CGWindowID = 0
                    guard _AXUIElementGetWindow(w, &wid) == .success, axDialogIDs.contains(wid) else { continue }
                    // Skip recently closed dialogs (still in AX but closing)
                    if recentlyClosedDialogIDs[wid] != nil { continue }
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
                    let title = titleRef as? String ?? appName
                    let spaceID = detector.spaceForWindow(wid) ?? detector.currentSpaceID()
                    let desktopName = detector.desktopName(for: spaceID, desktops: store.desktops)
                    dialogInfos.append(WindowThumbnail(
                        windowID: wid, title: title,
                        thumbnail: appIcon, appIcon: appIcon, appName: appName,
                        spaceID: spaceID, desktopName: desktopName,
                        pid: pid, state: .normal, bundleID: bundleIdentifier
                    ))
                }
            }
            if !dialogInfos.isEmpty {
                if let gen = generation, gen != displayGeneration { return }
                displayPanel(dialogInfos, bundleID: bundleIdentifier, at: mousePoint)
                return
            }
        }

        // App running but no windows → show placeholder preview
        if appWindows.isEmpty {
            if let gen = generation, gen != displayGeneration { return }
            let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
            if isRunning {
                displayEmptyAppPanel(bundleID: bundleIdentifier, appName: appName, appIcon: appIcon, at: mousePoint)
            } else {
                hidePanel()
            }
            return
        }

        // Build metadata and capture thumbnails
        struct WindowInfo {
            let windowID: CGWindowID; let title: String; let spaceID: Int
            let desktopName: String; let pid: Int32
        }
        var infos: [WindowInfo] = []
        var captures: [CGWindowID: NSImage?] = [:]

        // Detect minimized windows via AX
        var minimizedWIDs = Set<CGWindowID>()
        let pids = store.dockManager.pidsForApp(bundleIdentifier)
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let axWindows = ref as? [AXUIElement] {
                for w in axWindows {
                    var minRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef) == .success,
                       (minRef as? Bool) == true {
                        var wid: CGWindowID = 0
                        if _AXUIElementGetWindow(w, &wid) == .success { minimizedWIDs.insert(wid) }
                    }
                }
            }
        }

        // Detect fullscreen spaces and map them to their origin desktop.
        // macOS places fullscreen spaces AFTER their origin desktop in the space list.
        let allSpaces = detector.detectSpaces()
        let fullscreenSpaceIDs = Set(allSpaces.filter(\.isFullscreen).map(\.spaceID))

        // Map fullscreen spaces to origin desktop using space list order.
        // macOS places fullscreen spaces AFTER their origin desktop in the list,
        // so we track the last regular desktop and assign it to each following fullscreen.
        let currentDesktopID = detector.currentSpaceID()
        var fullscreenToDesktop: [Int: Int] = [:]
        var lastRegularSpaceID = currentDesktopID
        for space in allSpaces {
            if !space.isFullscreen {
                lastRegularSpaceID = space.spaceID
            } else if fullscreenSpaceIDs.contains(space.spaceID) {
                fullscreenToDesktop[space.spaceID] = lastRegularSpaceID
            }
        }

        for window in appWindows {
            let spaceID = detector.spaceForWindow(window.windowID) ?? 0
            if spaceID == 0 { continue }

            let state: WindowState
            if fullscreenSpaceIDs.contains(spaceID) { state = .fullscreen }
            else if minimizedWIDs.contains(window.windowID) { state = .minimized }
            else { state = .normal }

            let desktopName: String
            if state == .fullscreen {
                desktopName = "Vollbild"
            } else {
                desktopName = detector.desktopName(for: spaceID, desktops: store.desktops)
            }

            infos.append(WindowInfo(
                windowID: window.windowID, title: window.title ?? "",
                spaceID: spaceID, desktopName: desktopName,
                pid: window.owningApplication?.processID ?? 0
            ))
            // Fullscreen windows on other spaces can't be captured (macOS limitation) —
            // skip capture entirely and use app icon + title info card instead.
            // Dialogs (no AXCloseButton) also produce dark thumbnails → use app icon.
            if fullscreenSpaceIDs.contains(spaceID) || axDialogIDs.contains(window.windowID) {
                captures[window.windowID] = appIcon
            } else {
                captures[window.windowID] = await captureThumb(window)
            }
        }
        guard !infos.isEmpty else { hidePanel(); return }

        // Map space IDs to 1-based desktop indices for color lookup
        let spaceToIndex: [Int: Int] = Dictionary(uniqueKeysWithValues:
            store.desktops.map { ($0.id, $0.index) })
        var thumbnails: [WindowThumbnail] = []
        for info in infos {
            let state: WindowState
            if fullscreenSpaceIDs.contains(info.spaceID) { state = .fullscreen }
            else if minimizedWIDs.contains(info.windowID) { state = .minimized }
            else { state = .normal }

            thumbnails.append(WindowThumbnail(
                windowID: info.windowID, title: info.title,
                thumbnail: captures[info.windowID] ?? nil,
                appIcon: appIcon, appName: appName,
                spaceID: info.spaceID, desktopName: info.desktopName,
                pid: info.pid, state: state, bundleID: bundleIdentifier,
                originDesktopIndex: {
                    if state == .fullscreen, let originID = fullscreenToDesktop[info.spaceID] {
                        return spaceToIndex[originID] ?? 1
                    }
                    return spaceToIndex[info.spaceID] ?? 1
                }()
            ))
        }

        guard !thumbnails.isEmpty else { hidePanel(); return }

        // Stable sort: desktop order first, then by persistent window order within each desktop
        let desktopOrder = store.desktops.map(\.id)

        // Add new windowIDs to stable order (preserves existing order, appends new ones)
        for thumb in thumbnails {
            if !stableWindowOrder.contains(thumb.windowID) {
                stableWindowOrder.append(thumb.windowID)
            }
        }
        // Remove closed windows from stable order
        let activeIDs = Set(thumbnails.map(\.windowID))
        stableWindowOrder.removeAll { !activeIDs.contains($0) }

        thumbnails.sort { a, b in
            let aDesktop = desktopOrder.firstIndex(of: a.spaceID) ?? Int.max
            let bDesktop = desktopOrder.firstIndex(of: b.spaceID) ?? Int.max
            if aDesktop != bDesktop { return aDesktop < bDesktop }
            let aOrder = stableWindowOrder.firstIndex(of: a.windowID) ?? Int.max
            let bOrder = stableWindowOrder.firstIndex(of: b.windowID) ?? Int.max
            return aOrder < bOrder
        }

        if let gen = generation, gen != displayGeneration { return }
        displayPanel(thumbnails, bundleID: bundleIdentifier, at: mousePoint)
    }

    private func captureThumb(_ window: SCWindow) async -> NSImage? {
        // Return cached thumbnail if fresh enough
        if let cached = thumbnailCache[window.windowID],
           Date().timeIntervalSince(cached.time) < cacheMaxAge {
            return cached.image
        }

        let tw = store?.previewSettings.thumbnailWidth ?? 120
        // Guard against zero-dimension frames (can happen for off-screen windows)
        let frameW = max(window.frame.width, 1)
        let frameH = max(window.frame.height, 1)
        let aspect = frameH / frameW

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(tw * 2) // capture at 2x for retina
        config.height = max(Int(tw * 2 * aspect), 1)
        config.scalesToFit = true
        config.showsCursor = false
        do {
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let nsImage = NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2))
            thumbnailCache[window.windowID] = (nsImage, Date())
            return nsImage
        } catch { return nil }
    }

    // MARK: - Desktop Colors

    /// Delegates to DesktopStore's preset-aware color lookup.
    /// The index parameter is 1-based (DesktopConfig.index / DesktopPreset.id).
    private func colorForDesktop(index: Int) -> NSColor {
        store?.colorForDesktopIndex(index) ?? NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 1.0)
    }

    // MARK: - Display

    // DEACTIVATED: Preview-Only Mode (2026-03-30)
    // Was: maxThumbsPerDesktop und maxHiddenOverflow — Limits für sichtbare/versteckte Karten
    // private var maxThumbsPerDesktop: Int { Int(store?.previewSettings.maxWindowsPerGroup ?? 5) }
    // private let maxHiddenOverflow = 5

    /// Placeholder when app is running but has no windows
    private func displayEmptyAppPanel(bundleID: String, appName: String, appIcon: NSImage?, at mousePoint: NSPoint) {
        if panel == nil { createPanel() }
        guard let contentView, let panel, let screen = NSScreen.main, let store else { return }

        contentView.subviews.forEach { $0.removeFromSuperview() }

        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: desktopColor, isQuittable, bid — nur für Buttons/Kontextmenü benötigt

        // Same dimensions as a single-window preview
        let tw = CGFloat(store.previewSettings.thumbnailWidth)
        let th = CGFloat(store.previewSettings.thumbnailHeight)
        let headerH: CGFloat = 20
        let titleH: CGFloat = 12
        let pad: CGFloat = 8
        let panelW = pad + tw + pad
        let contentH = headerH + th + titleH + 4 + pad * 2
        let markerH: CGFloat = 4
        let totalH = contentH + markerH

        panel.setContentSize(NSSize(width: panelW, height: totalH))
        contentView.frame = NSRect(x: 0, y: markerH, width: panelW, height: contentH)

        // Layout group: icon + text, centered vertically (read-only, no buttons)
        let iconSize: CGFloat = 36
        let textH: CGFloat = 14
        let gapIconText: CGFloat = 6
        let groupH = iconSize + gapIconText + textH
        let usableTop = contentH - headerH
        let usableBottom: CGFloat = pad
        let groupStartY = usableBottom + (usableTop - usableBottom - groupH) / 2

        // "Keine Fenster" text
        let textY = groupStartY
        let label = NSTextField(labelWithString: "\(appName) \u{00B7} Keine Fenster")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 4, y: textY, width: panelW - 8, height: textH)
        contentView.addSubview(label)

        // App icon (above text)
        if let icon = appIcon {
            let iconY = textY + textH + gapIconText
            let iv = NSImageView(frame: NSRect(
                x: panelW/2 - iconSize/2, y: iconY,
                width: iconSize, height: iconSize))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            contentView.addSubview(iv)
        }

        // DEACTIVATED: Preview-Only Mode (2026-03-30)
        // Was: "+ Neues Fenster" Button im Empty-State
        // Was: Rechtsklick-Kontextmenü im Empty-State
        // Was: Red Quit-Button (CloseButton) im Empty-State

        // Position
        var px = mousePoint.x - panelW / 2
        px = max(screen.frame.minX + 4, min(px, screen.frame.maxX - panelW - 4))
        panel.setFrameOrigin(NSPoint(x: px, y: 78))
        updateMarker(panelWidth: panelW, panelHeight: totalH, markerCenterX: mousePoint.x - px)

        lastPanelIconCenter = mousePoint
        currentThumbnails = []
        currentMousePoint = mousePoint
        lastShownBundleIDForPanel = bundleID

        if panel.isVisible {
            panel.orderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    @objc func openNewWindowFromMenu(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        _ = store?.dockManager.openNewWindow(bundleIdentifier: bid)
        hidePanel()
    }

    private func displayPanel(_ thumbnails: [WindowThumbnail], bundleID appBundleID: String = "", at mousePoint: NSPoint) {
        if panel == nil { createPanel() }
        guard let contentView, let panel, let screen = NSScreen.main, let store else { return }

        let tw = CGFloat(store.previewSettings.thumbnailWidth)
        let th = CGFloat(store.previewSettings.thumbnailHeight)

        let isRefresh = panel.isVisible
        contentView.subviews.forEach { $0.removeFromSuperview() }

        // Group thumbnails by desktop (already sorted by desktop order)
        var groups: [(spaceID: Int, desktopName: String, desktopIndex: Int, windows: [WindowThumbnail])] = []
        for thumb in thumbnails {
            if let idx = groups.firstIndex(where: { $0.spaceID == thumb.spaceID }) {
                groups[idx].windows.append(thumb)
            } else {
                let spaceToIdx: [Int: Int] = Dictionary(uniqueKeysWithValues: store.desktops.map { ($0.id, $0.index) })
                let dIdx = thumb.state == .fullscreen ? thumb.originDesktopIndex : (spaceToIdx[thumb.spaceID] ?? 1)
                groups.append((thumb.spaceID, thumb.desktopName, dIdx, [thumb]))
            }
        }

        // Layout constants
        let headerH: CGFloat = 20
        let titleH: CGFloat = 12
        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let groupGap: CGFloat = 10
        let maxPanelW = screen.frame.width - 40

        // Calculate content width — show ALL windows (no overflow limit)
        var contentW: CGFloat = pad
        for group in groups {
            let count = group.windows.count
            let groupW = CGFloat(count) * (tw + gap) - gap
            contentW += groupW + groupGap
        }
        contentW = contentW - groupGap + pad
        let contentH = headerH + th + titleH + 4 + pad * 2

        let panelW = min(contentW, maxPanelW)
        let needsScroll = contentW > panelW

        // Set up scroll view if needed
        panel.setContentSize(NSSize(width: panelW, height: contentH))

        let innerView: NSView
        if needsScroll {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: panelW, height: contentH))
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.scrollerStyle = .overlay

            let docView = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
            scrollView.documentView = docView
            contentView.addSubview(scrollView)
            contentView.frame = NSRect(x: 0, y: 0, width: panelW, height: contentH)

            // Scroll fade indicator on right edge
            let fadeW: CGFloat = 20
            let fade = NSView(frame: NSRect(x: panelW - fadeW, y: 0, width: fadeW, height: contentH))
            fade.wantsLayer = true
            let gradient = CAGradientLayer()
            gradient.frame = fade.bounds
            gradient.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.4).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            fade.layer?.addSublayer(gradient)
            contentView.addSubview(fade)
            innerView = docView
        } else {
            contentView.frame = NSRect(x: 0, y: 0, width: panelW, height: contentH)
            innerView = contentView
        }

        clickableViews = []
        titleLabels = []
        cardGroupIndex = []
        groupViews = []
        focusedIndex = -1
        var xOffset: CGFloat = pad
        let appIcon = thumbnails.first?.appIcon
        let appName = thumbnails.first?.appName ?? ""

        for (groupIdx, group) in groups.enumerated() {
            var currentGroupViews: [NSView] = []
            let color = colorForDesktop(index: group.desktopIndex)
            // DEACTIVATED: Preview-Only Mode — show all windows
            // Was: let count = min(group.windows.count, maxThumbsPerDesktop)
            let count = group.windows.count
            let groupW = CGFloat(count) * (tw + gap) - gap

            // Header: [● DesktopName ... (🔒) AppIcon (AppName)]
            let hdr = NSView(frame: NSRect(x: xOffset, y: contentH - pad - headerH, width: groupW, height: headerH))
            hdr.wantsLayer = true
            hdr.layer?.cornerRadius = 4
            hdr.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
            innerView.addSubview(hdr)
            currentGroupViews.append(hdr)

            // Color dot
            let dot = NSView(frame: NSRect(x: 4, y: 5, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = color.withAlphaComponent(0.7).cgColor
            hdr.addSubview(dot)

            // App icon ALWAYS visible (right side)
            var rightEdge = groupW - 4
            if let icon = appIcon {
                rightEdge -= 14
                let ico = NSImageView(frame: NSRect(x: rightEdge, y: 3, width: 14, height: 14))
                ico.image = icon
                ico.imageScaling = .scaleProportionallyUpOrDown
                hdr.addSubview(ico)
            }

            // Single-instance indicator (pin icon)
            let isSingle = store.isSingleInstance(appBundleID)
            if isSingle {
                rightEdge -= 14
                let pin = NSImageView(frame: NSRect(x: rightEdge, y: 3, width: 12, height: 12))
                pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Einzelne Instanz")
                pin.contentTintColor = color.withAlphaComponent(0.7)
                pin.imageScaling = .scaleProportionallyUpOrDown
                hdr.addSubview(pin)
            }

            // App name only if ≥2 windows AND enough space
            let showAppName = count >= 2 && groupW > 160
            if showAppName {
                rightEdge -= 2
                let aLbl = NSTextField(labelWithString: appName)
                aLbl.font = .systemFont(ofSize: 8, weight: .medium)
                aLbl.textColor = .secondaryLabelColor
                aLbl.alignment = .right
                aLbl.lineBreakMode = .byTruncatingTail
                let aW = min(CGFloat(rightEdge - 60), 70)
                aLbl.frame = NSRect(x: rightEdge - aW, y: 3, width: aW, height: 12)
                hdr.addSubview(aLbl)
                rightEdge -= aW
            }

            // Desktop name with truncation (...)
            let dLbl = NSTextField(labelWithString: group.desktopName)
            dLbl.font = .systemFont(ofSize: 9, weight: .semibold)
            dLbl.textColor = .labelColor
            dLbl.lineBreakMode = .byTruncatingTail
            dLbl.frame = NSRect(x: 17, y: 2, width: max(rightEdge - 20, 30), height: 14)
            hdr.addSubview(dLbl)

            // DEACTIVATED: Preview-Only Mode — show all windows, no overflow limit
            // Was: let renderCount = min(group.windows.count, maxThumbsPerDesktop + maxHiddenOverflow)
            let renderCount = group.windows.count
            for (i, thumb) in group.windows.prefix(renderCount).enumerated() {
                let x = xOffset + CGFloat(i) * (tw + gap)

                let card = ClickableView(frame: NSRect(
                    x: x, y: contentH - pad - headerH - th - 2, width: tw, height: th
                ))
                card.wantsLayer = true
                card.layer?.cornerRadius = 5
                card.layer?.masksToBounds = false // allow close button to overflow
                card.layer?.borderWidth = 1
                card.layer?.borderColor = color.withAlphaComponent(0.3).cgColor
                card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
                // DEACTIVATED: Preview-Only Mode (2026-03-30)
                // Was: Overflow-Karten unsichtbar machen
                // if isOverflow { card.alphaValue = 0; card.layer?.zPosition = -1 }

                // Thumbnail image (clipped)
                let clipView = NSView(frame: NSRect(x: 0, y: 0, width: tw, height: th))
                clipView.wantsLayer = true
                clipView.layer?.cornerRadius = 5
                clipView.layer?.masksToBounds = true
                card.addSubview(clipView)

                if thumb.state == .fullscreen {
                    // Fullscreen: just centered app icon (no screenshot possible on other spaces)
                    clipView.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
                    let iconSize: CGFloat = 36
                    if let icon = thumb.appIcon {
                        let iv = NSImageView(frame: NSRect(
                            x: (tw - iconSize) / 2, y: (th - iconSize) / 2,
                            width: iconSize, height: iconSize))
                        iv.image = icon
                        iv.imageScaling = .scaleProportionallyUpOrDown
                        clipView.addSubview(iv)
                    }
                } else if let img = thumb.thumbnail {
                    let iv = NSImageView(frame: clipView.bounds)
                    iv.image = img
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.autoresizingMask = [.width, .height]
                    clipView.addSubview(iv)
                } else if let icon = thumb.appIcon {
                    let iv = NSImageView(frame: NSRect(x: (tw-32)/2, y: (th-32)/2, width: 32, height: 32))
                    iv.image = icon
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    clipView.addSubview(iv)
                }

                // Window state badge with background (bottom-right)
                let badgeColor: NSColor
                let badgeSymbol: String
                let badgeTooltip: String
                switch thumb.state {
                case .normal:
                    badgeColor = NSColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0)
                    badgeSymbol = "macwindow"
                    badgeTooltip = "Normal"
                case .minimized:
                    badgeColor = NSColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0)
                    badgeSymbol = "arrow.down.to.line"
                    badgeTooltip = "Minimiert"
                case .fullscreen:
                    badgeColor = NSColor(red: 0.6, green: 0.4, blue: 0.9, alpha: 1.0)
                    badgeSymbol = "arrow.up.left.and.arrow.down.right"
                    badgeTooltip = "Vollbild"
                }
                // State icon — subtle, integrated into thumbnail corner
                let stateIcon = NSImageView(frame: NSRect(x: tw - 16, y: 2, width: 12, height: 12))
                stateIcon.image = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)
                stateIcon.contentTintColor = badgeColor
                stateIcon.imageScaling = .scaleProportionallyUpOrDown
                stateIcon.wantsLayer = true
                stateIcon.shadow = {
                    let s = NSShadow()
                    s.shadowColor = NSColor.black.withAlphaComponent(0.7)
                    s.shadowBlurRadius = 3
                    s.shadowOffset = NSSize(width: 0, height: -1)
                    return s
                }()
                stateIcon.toolTip = badgeTooltip
                card.addSubview(stateIcon)

                // Click handler — focus window + switch desktop
                let windowID = thumb.windowID
                let spaceID = thumb.spaceID
                let pid = thumb.pid
                let bid = thumb.bundleID
                // DEACTIVATED: Preview-Only Mode (2026-03-30)
                // Was: wID, wPID — nur für Close-Button und Kontextmenü benötigt
                card.onClick = { [weak self] in
                    guard let self, let store = self.store else { return }
                    if store.isSingleInstance(bid) {
                        store.switchToAppWindow(bundleID: bid)
                    } else {
                        self.activateAndFocusWindow(windowID: windowID, spaceID: spaceID, pid: pid)
                    }
                    self.hidePanel()
                }
                // DEACTIVATED: Preview-Only Mode (2026-03-30)
                // Was: Rechtsklick-Kontextmenü (Close, Quit, Single-Instance)
                // card.onRightClick = { ... }
                clickableViews.append(card)
                cardGroupIndex.append(groupIdx)
                innerView.addSubview(card)

                // DEACTIVATED: Preview-Only Mode (2026-03-30)
                // Was: Close-Button auf jedem Thumbnail + Close-Animation-Logik
                // CloseButton, closeBtn.onClose handler, card.associatedCloseButton — all removed

                let tl = NSTextField(labelWithString: thumb.title.isEmpty ? "Fenster" : thumb.title)
                tl.font = .systemFont(ofSize: 8)
                tl.textColor = .secondaryLabelColor
                tl.alignment = .center
                tl.lineBreakMode = .byTruncatingMiddle
                tl.frame = NSRect(x: x, y: contentH - pad - headerH - th - titleH - 4, width: tw, height: titleH)
                // DEACTIVATED: Preview-Only Mode (2026-03-30)
                // Was: Overflow-Titel unsichtbar machen
                // if isOverflow { tl.alphaValue = 0 }
                titleLabels.append(tl)
                innerView.addSubview(tl)
            }

            // DEACTIVATED: Preview-Only Mode (2026-03-30)
            // Was: "+N" Overflow-Indikator mit Klick-Menü für versteckte Fenster

            groupViews.append(currentGroupViews)
            xOffset += groupW + groupGap
        }

        // Panel sits directly above dock — no gap, no speech bubble arrow
        let markerH: CGFloat = 4
        let totalPanelH = contentH + markerH

        panel.setContentSize(NSSize(width: panelW, height: totalPanelH))
        if needsScroll {
            for sub in contentView.subviews where sub is NSScrollView {
                sub.frame = NSRect(x: 0, y: markerH, width: panelW, height: contentH)
            }
        }
        contentView.frame = NSRect(x: 0, y: markerH, width: panelW, height: contentH)

        // Position: directly above dock (no gap)
        var px = mousePoint.x - panelW / 2
        px = max(screen.frame.minX + 4, min(px, screen.frame.maxX - panelW - 4))
        let py: CGFloat = 78

        // Small marker triangle pointing down at the hovered app
        let markerX = mousePoint.x - px
        lastPanelIconCenter = mousePoint
        lastStateRefresh = Date()
        currentThumbnails = thumbnails
        currentMousePoint = mousePoint
        lastShownBundleIDForPanel = appBundleID

        if isRefresh {
            // Panel already visible — smoothly animate to new position/size
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(NSRect(x: px, y: py, width: panelW, height: totalPanelH), display: true)
            }
            updateMarker(panelWidth: panelW, panelHeight: totalPanelH, markerCenterX: markerX)
            panel.orderFront(nil)
        } else {
            // First show — position instantly, fade panel in
            panel.setFrameOrigin(NSPoint(x: px, y: py))
            updateMarker(panelWidth: panelW, panelHeight: totalPanelH, markerCenterX: markerX)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    private func activateAndFocusWindow(windowID: CGWindowID, spaceID: Int, pid: Int32) {
        let currentSpaceID = detector.currentSpaceID()

        // Switch space if needed
        if spaceID != currentSpaceID {
            switchToSpace(spaceID)
        }

        // Try to find and unminimize the specific window by windowID
        let axApp = AXUIElementCreateApplication(pid)
        var wRef: CFTypeRef?
        var found = false
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wRef) == .success,
           let windows = wRef as? [AXUIElement] {
            for w in windows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(w, &wid) == .success, wid == windowID {
                    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    found = true
                    break
                }
            }
            if !found, let first = windows.first {
                AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(first, kAXRaiseAction as CFString)
            }
        }

        // Activate with all windows — ensures app comes to front
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            app.activate(options: [.activateAllWindows])
        }

        // Brief ignore to prevent activation observer from interfering with the switch
        store?.ignoreNextActivation()
    }

    private func switchToSpace(_ targetSpaceID: Int) {
        // Include ALL spaces (also fullscreen) so we can switch to fullscreen apps
        let spaces = detector.detectMainDisplaySpaces()
        guard let currentIdx = spaces.firstIndex(where: \.isCurrentSpace),
              let targetIdx = spaces.firstIndex(where: { $0.spaceID == targetSpaceID }) else { return }

        let diff = targetIdx - currentIdx
        if diff == 0 { return }

        // CGEvent keyboard posting doesn't work for system shortcuts on modern macOS.
        // Use System Events via AppleScript instead.
        let keyCode = diff > 0 ? 124 : 123 // right : left arrow
        for _ in 0..<abs(diff) {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to key code \(keyCode) using control down")?
                .executeAndReturnError(&error)
            let speedMs = UInt32(store?.previewSettings.spaceSwitchSpeed ?? 80)
            usleep(speedMs * 1000)
        }
    }

    /// Reposition panel when dock icon moves (dock resize, app launch/quit)
    private func repositionPanel(to iconCenter: NSPoint) {
        guard let panel, let screen = NSScreen.main else { return }
        let panelW = panel.frame.width
        let panelH = panel.frame.height

        var px = iconCenter.x - panelW / 2
        px = max(screen.frame.minX + 4, min(px, screen.frame.maxX - panelW - 4))

        let py: CGFloat = 78
        panel.setFrameOrigin(NSPoint(x: px, y: py))

        // Only move the marker, not the whole panel
        let markerX = iconCenter.x - px
        updateMarker(panelWidth: panelW, panelHeight: panelH, markerCenterX: markerX)
        lastPanelIconCenter = iconCenter
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        lastShownBundleID = nil
        isLoadingPreview = false
        // Prune old cache entries
        let now = Date()
        thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.time) < cacheMaxAge * 2 }
    }

    @objc func quitAppFromMenu(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        terminateApp(bundleID: bundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hidePanel()
        }
    }

    @objc func overflowWindowClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let wid = info["wid"] as? CGWindowID,
              let sid = info["sid"] as? Int,
              let pid = info["pid"] as? Int32 else { return }
        activateAndFocusWindow(windowID: wid, spaceID: sid, pid: pid)
        hidePanel()
    }

    @objc func toggleSingleInstanceFromMenu(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        store?.toggleSingleInstance(bundleID)
    }

    @objc func closeWindowFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let wid = info["wid"] as? CGWindowID,
              let pid = info["pid"] as? Int32 else { return }
        let title = info["title"] as? String ?? ""
        closeWindow(windowID: wid, pid: pid, title: title)
        currentThumbnails.removeAll { $0.windowID == wid }
        // Block tick() from hiding the panel while we rebuild after menu close
        rightClickCooldownUntil = Date().addingTimeInterval(0.5)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.currentThumbnails.isEmpty {
                self.hidePanel()
            } else {
                self.displayPanel(self.currentThumbnails, bundleID: self.lastShownBundleIDForPanel, at: self.currentMousePoint)
            }
        }
    }

    @objc func closeAllWindowsFromMenu(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let pids = store?.dockManager.pidsForApp(bundleID) ?? []
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let windows = ref as? [AXUIElement] {
                for w in windows { pressCloseButton(of: w) }
            }
        }
        currentThumbnails.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.hidePanel()
        }
    }

    private func refreshPreviewAfterClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let bid = self.lastHoveredBundleID else { return }
            // Invalidate thumbnail cache so state badges refresh
            self.thumbnailCache.removeAll()
            self.isLoadingPreview = false
            self.lastShownBundleID = nil
            if let item = self.dockItems.first(where: { $0.bundleID == bid }) {
                self.loadPreview(for: bid, appName: item.name, at: self.dockItemCenter(item))
            } else {
                // App might have been terminated — hide preview
                self.hidePanel()
            }
        }
    }

    /// Returns true if closed via AX (real window), false if Escape fallback (dialog)
    @discardableResult
    private func closeWindow(windowID: CGWindowID, pid: Int32, title: String = "") -> Bool {
        // Strategy 1: AX close on this PID (match by windowID, then title)
        if closeWindowForPID(windowID: windowID, pid: pid, title: title) { return true }

        // Strategy 2: try ALL PIDs (Electron apps have multiple processes)
        let bundleID = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid })?.bundleIdentifier
        if let bundleID {
            let allPIDs = store?.dockManager.pidsForApp(bundleID) ?? []
            for otherPID in allPIDs where otherPID != pid {
                if closeWindowForPID(windowID: windowID, pid: otherPID, title: title) { return true }
            }
        }

        // Strategy 3: AppleScript close by window title — works when AX can't
        // reach the window (e.g., detected via CGWindowList but not in AX tree,
        // or fullscreen windows on other spaces)
        if let bundleID, !title.isEmpty {
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application id "\(bundleID)"
                try
                    close (first window whose name is "\(escapedTitle)")
                end try
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return true }
        }

        // Strategy 4: Last resort — send Escape to dismiss dialogs/sheets
        let targetPID = pid != 0 ? pid : (store?.dockManager.pidsForApp(bundleID ?? "").first ?? 0)
        if targetPID != 0 {
            let src = CGEventSource(stateID: .hidSystemState)
            if let esc = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true) {
                esc.postToPid(targetPID)
            }
            if let escUp = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                escUp.postToPid(targetPID)
            }
        }
        return false
    }

    private func closeWindowForPID(windowID: CGWindowID, pid: Int32, title: String = "") -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], !windows.isEmpty else { return false }

        // Match 1: by windowID (most reliable)
        for w in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == windowID {
                // Check if this is a real window (has AXCloseButton) or a dialog
                var closeCheck: CFTypeRef?
                let isRealWindow = AXUIElementCopyAttributeValue(w, "AXCloseButton" as CFString, &closeCheck) == .success
                pressCloseButton(of: w)
                return isRealWindow // false for dialogs → triggers cooldown in caller
            }
        }

        // Match 2: by title (fallback when windowID doesn't match)
        if !title.isEmpty {
            for w in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let wTitle = titleRef as? String, wTitle == title {
                    var closeCheck: CFTypeRef?
                    let isRealWindow = AXUIElementCopyAttributeValue(w, "AXCloseButton" as CFString, &closeCheck) == .success
                    pressCloseButton(of: w)
                    return isRealWindow
                }
            }
        }

        // Match 3: close first window that HAS a close button (last resort)
        for w in windows {
            var closeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, "AXCloseButton" as CFString, &closeRef) == .success {
                pressCloseButton(of: w)
                return true
            }
        }
        return false
    }

    private func pressCloseButton(of window: AXUIElement) {
        // Strategy 1: Standard close button (works for most windows)
        var closeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXCloseButton" as CFString, &closeRef) == .success {
            AXUIElementPerformAction(closeRef as! AXUIElement, kAXPressAction as CFString)
            return
        }

        // Strategy 2: Dialog/Sheet — find Cancel/Abbrechen button
        if pressCancelButton(in: window) { return }

        // Strategy 3: Send Escape key to dismiss dialog
        var pidValue: pid_t = 0
        AXUIElementGetPid(window, &pidValue)
        if pidValue != 0 {
            let src = CGEventSource(stateID: .hidSystemState)
            if let esc = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true) {
                esc.postToPid(pidValue)
            }
            if let escUp = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                escUp.postToPid(pidValue)
            }
        }
    }

    /// Try to find and press Cancel/Abbrechen button in a dialog window
    private func pressCancelButton(in element: AXUIElement) -> Bool {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXButton" {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title == "Abbrechen" || title == "Cancel" || title == "Schließen" || title == "Close" {
                    AXUIElementPerformAction(child, kAXPressAction as CFString)
                    return true
                }
            }
            // Recurse into groups/containers
            if pressCancelButton(in: child) { return true }
        }
        return false
    }

    /// Fallback close: try AX close on all PIDs, then terminate as last resort
    private func terminateApp(bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.terminate()
        }
    }

    func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { hidePanel() } // Esc
    }

    private var bgView: NSVisualEffectView?
    private var markerView: NSView?

    private func createPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.previewController = self

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        p.contentView?.addSubview(bg)
        bgView = bg

        let cv = PanelContentView(frame: p.contentView!.bounds)
        cv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(cv)
        contentView = cv
        panel = p
    }

    /// Small marker triangle at the bottom of the panel pointing at the hovered dock icon
    private func updateMarker(panelWidth: CGFloat, panelHeight: CGFloat, markerCenterX: CGFloat) {
        guard let bg = bgView else { return }
        bg.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        bg.layer?.cornerRadius = 10
        bg.layer?.mask = nil // no complex mask needed

        // Remove old marker
        markerView?.removeFromSuperview()

        // Small triangle marker
        let mw: CGFloat = 12
        let mh: CGFloat = 4
        let mx = max(6, min(markerCenterX - mw/2, panelWidth - mw - 6))
        let marker = NSView(frame: NSRect(x: mx, y: 0, width: mw, height: mh))
        marker.wantsLayer = true

        let tri = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: mh))
        path.addLine(to: CGPoint(x: mw/2, y: 0))
        path.addLine(to: CGPoint(x: mw, y: mh))
        path.closeSubpath()
        tri.path = path
        tri.fillColor = NSColor.white.withAlphaComponent(0.5).cgColor
        marker.layer?.addSublayer(tri)

        panel?.contentView?.addSubview(marker)
        markerView = marker
    }
}
