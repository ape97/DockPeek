/// DockManager.swift — Dock click interception via CGEventTap + AX window operations.
///
/// This file implements the core dock-click interception that prevents macOS from
/// switching spaces when a dock icon is clicked. It uses a CGEventTap installed at
/// `cgSessionEventTap` (head-insert) to see mouse-down events before the Dock process.
///
/// ## Hybrid Event Tap Strategy (CRITICAL — read before modifying)
///
/// The event tap uses a carefully tuned 3-case decision tree in `preHandleDockClick`:
///
/// | Situation | Action | Why |
/// |-----------|--------|-----|
/// | App has visible window on current space AND is frontmost | SUPPRESS click + toggle-minimize | Standard dock behavior, but we control it to avoid space switch |
/// | App has visible window but is NOT frontmost | PASS THROUGH | Let the Dock handle focus with its native bounce animation |
/// | App has ONLY minimized windows | SUPPRESS + unminimize ourselves | macOS ignores `workspaces=false` for minimized windows — if we pass through, it switches spaces |
/// | App has NO windows at all | PASS THROUGH | Dock launches the app naturally |
///
/// **Gotcha:** macOS disables event taps after ~5s of unresponsiveness or if the
/// system detects abuse. We re-enable on `.tapDisabledByTimeout`/`.tapDisabledByUserInput`.
///
/// **Gotcha:** CGEventTap callbacks ONLY fire for real hardware mouse events, NOT for
/// `CGEvent.post()` synthetic events. Automated tests cannot trigger this path.
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Private API to extract the CGWindowID from an AXUIElement.
/// Used by `unminimizeWindow` to match AX windows to CGS space IDs.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Top-level C-compatible callback for the CGEventTap. Must be `nonisolated` because
/// CGEventTap invokes it from the run loop without actor context. We bridge back to
/// `@MainActor` via `MainActor.assumeIsolated` (safe because the tap is on the main run loop).
///
/// Returns `nil` to suppress the event, or `Unmanaged.passRetained(event)` to pass through.
nonisolated func vdsDockClickCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let mgr = Unmanaged<DockManager>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS auto-disables taps if they take too long or misbehave — re-enable immediately
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { mgr.reEnableClickInterceptor() }
        return Unmanaged.passRetained(event)
    }

    guard type == .leftMouseDown else { return Unmanaged.passRetained(event) }

    let location = event.location
    let handled = MainActor.assumeIsolated {
        mgr.preHandleDockClick(at: location)
    }
    return handled ? nil : Unmanaged.passRetained(event)
}

/// Manages dock click interception, window state queries (via Accessibility APIs),
/// and new-window creation (via AppleScript). Owned by `DesktopStore`.
@MainActor
final class DockManager {
    private var clickTap: CFMachPort?
    private var clickTapSource: CFRunLoopSource?

    /// Callback when the interceptor handled a dock click (bundleID of the app)
    var onClickIntercepted: ((String) -> Void)?
    /// Callback when a new window should be opened (bundleID)
    var onNeedNewWindow: ((String) -> Void)?

    /// Cached dock item positions from DockPreviewController for fast hit-testing
    /// in the CGEventTap callback. Updated every 0.5s by the preview's refreshDockItems().
    /// Using this cache avoids slow AX queries in the click path.
    var cachedDockItems: [(bundleID: String, frame: CGRect)] = []

    private let dockPlistPath: String = {
        NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
    }()

    init() {
        ensureSpaceSwitchDisabled()
    }

    // MARK: - Click Interceptor (CGEventTap)

    /// Creates a session-level CGEventTap for left-mouse-down events, inserted at the
    /// head of the event stream so we see clicks before the Dock. Requires Accessibility
    /// permission (TCC). The tap's `userInfo` pointer is an unretained reference to `self`.
    func installClickInterceptor() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: vdsDockClickCallback,
            userInfo: ptr
        ) else { return }

        clickTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        clickTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reEnableClickInterceptor() {
        guard let tap = clickTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Called from CGEventTap BEFORE the Dock sees the click.
    /// Returns `true` to suppress the event (click consumed), `false` to pass through.
    ///
    /// Implements the 3-case hybrid strategy documented in the file header.
    /// **Case 1:** Visible + frontmost → suppress + minimize all (toggle behavior).
    /// **Case 2:** Only minimized windows → suppress + unminimize (prevents space switch).
    /// **Case 3:** No windows / not frontmost → pass through (dock handles naturally).
    func preHandleDockClick(at cgPoint: CGPoint) -> Bool {
        guard isCGPointInDockArea(cgPoint) else { return false }

        // Fast path: use cached dock items from preview controller (no AX query)
        var bundleID: String?
        for item in cachedDockItems {
            let expanded = item.frame.insetBy(dx: -4, dy: -8)
            if expanded.contains(cgPoint) {
                bundleID = item.bundleID
                break
            }
        }
        // Slow fallback: AX hit-test (only when cache is empty or miss)
        if bundleID == nil {
            bundleID = identifyDockAppAtPoint(cgPoint)
        }

        guard let bundleID,
              bundleID != "com.apple.dock",
              bundleID != Bundle.main.bundleIdentifier else { return false }

        let hasNonMinimized = hasNonMinimizedWindows(for: bundleID)
        let hasOnScreen = appHasWindowsOnCurrentSpace(bundleID)

        // Case 1: App has visible window on current space + is frontmost → toggle minimize
        if hasNonMinimized && hasOnScreen {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                let bid = bundleID
                DispatchQueue.main.async { [weak self] in
                    self?.minimizeAllWindows(for: bid)
                }
                onClickIntercepted?(bundleID)
                return true // suppress
            }
            // Has visible window but not frontmost → let dock focus it (natural animation)
            return false
        }

        // Case 2: All windows minimized → suppress to prevent space switch
        // (macOS ignores workspaces=false for minimized windows).
        // We unminimize and activate the app ourselves.
        // The app.activate() causes the dock icon to briefly highlight,
        // giving the user visual feedback that the click was registered.
        if hasMinimizedWindows(for: bundleID) {
            let currentSpaceID = SpaceDetector.shared.currentSpaceID()
            let bid = bundleID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.unminimizeWindow(for: bid, preferSpaceID: currentSpaceID) {
                    self.onNeedNewWindow?(bid)
                }
                // Brief dock icon highlight as visual feedback
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                    app.activate(options: [])
                }
            }
            onClickIntercepted?(bundleID)
            return true
        }

        // Case 3: No windows at all → let dock handle naturally
        return false
    }

    private func isCGPointInDockArea(_ cgPoint: CGPoint) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let orientation = dockOrientation()
        let dockZone: CGFloat = 90
        let frame = screen.frame

        switch orientation {
        case "left":   return cgPoint.x < dockZone
        case "right":  return frame.width - cgPoint.x < dockZone
        default:       return cgPoint.y > frame.height - dockZone // bottom, CG origin top-left
        }
    }

    /// Uses Accessibility API to identify which dock icon is under the given CG-coordinate.
    /// Dock icons expose an `AXURL` attribute pointing to the app bundle — we extract
    /// the bundle identifier from that. Falls back to matching by AX title if AXURL is absent.
    private func identifyDockAppAtPoint(_ cgPoint: CGPoint) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(cgPoint.x), Float(cgPoint.y), &elementRef
        ) == .success, let element = elementRef else { return nil }

        // Try AXURL (dock icons expose this)
        var urlRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success,
           let urlValue = urlRef {
            let url: URL?
            if CFGetTypeID(urlValue) == CFURLGetTypeID() {
                url = (urlValue as! CFURL) as URL
            } else if let str = urlValue as? String {
                url = URL(string: str)
            } else { url = nil }
            if let bid = url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) {
                return bid
            }
        }

        // Fallback: match by title
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            return NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == title })?.bundleIdentifier
        }

        return nil
    }

    // MARK: - Dock-Click Detection

    /// Determines if the mouse cursor is currently in the Dock area.
    /// Works for bottom, left, and right dock orientations.
    func isMouseInDockArea() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return false }
        let orientation = dockOrientation()
        let dockZone: CGFloat = 90

        switch orientation {
        case "left":   return mouse.x - screen.frame.minX < dockZone
        case "right":  return screen.frame.maxX - mouse.x < dockZone
        default:       return mouse.y - screen.frame.minY < dockZone // bottom
        }
    }

    /// Read dock orientation from preferences
    func dockOrientation() -> String {
        guard let prefs = UserDefaults(suiteName: "com.apple.dock") else { return "bottom" }
        return prefs.string(forKey: "orientation") ?? "bottom"
    }

    // MARK: - Space Switch Prevention

    /// Writes macOS defaults to prevent the Dock from auto-switching spaces.
    /// Sets `workspaces=false`, `show-tooltip=false`, `mru-spaces=false` in com.apple.dock,
    /// and `AppleSpacesSwitchOnActivate=false` in NSGlobalDomain. Restarts the Dock if changes were made.
    ///
    /// **Gotcha:** `bool(forKey:)` returns `false` for missing keys — use `object(forKey:) as? Bool`
    /// to distinguish "key missing" from "key is false". See CLAUDE.md for details.
    ///
    /// **Gotcha:** `workspaces=false` does NOT prevent space switches for minimized windows.
    /// That case is handled by the CGEventTap (Case 2 in `preHandleDockClick`).
    func ensureSpaceSwitchDisabled() {
        var needsDockRestart = false

        if let dockPlist = NSMutableDictionary(contentsOfFile: dockPlistPath) {
            var changed = false
            if dockPlist["workspaces"] as? Bool != false {
                dockPlist["workspaces"] = false
                changed = true
            }
            // Disable dock tooltips (they conflict with our preview)
            if dockPlist["show-tooltip"] as? Bool != false {
                dockPlist["show-tooltip"] = false
                changed = true
            }
            // Disable auto-rearrange of Spaces based on usage (keeps desktop order stable)
            if dockPlist["mru-spaces"] as? Bool != false {
                dockPlist["mru-spaces"] = false
                changed = true
            }
            if changed {
                dockPlist.write(toFile: dockPlistPath, atomically: true)
                needsDockRestart = true
            }
        }

        // Disable AppleSpacesSwitchOnActivate — needed so openNewWindow can activate an app
        // without switching spaces. The CGEventTap handles dock click interception.
        // Preview panel handles intentional space switching via keyboard simulation.
        // Always ensure this is set — bool(forKey:) returns false for missing keys too
        let globalDefaults = UserDefaults(suiteName: "NSGlobalDomain")
        if globalDefaults?.object(forKey: "AppleSpacesSwitchOnActivate") as? Bool != false {
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p1.arguments = ["write", "NSGlobalDomain", "AppleSpacesSwitchOnActivate", "-bool", "false"]
            try? p1.run()
            p1.waitUntilExit()
            needsDockRestart = true
        }

        if needsDockRestart {
            Task.detached {
                try? await Task.sleep(for: .seconds(1.5))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = ["Dock"]
                try? p.run()
            }
        }
    }

    // MARK: - Window Detection

    /// Checks if the app has at least one visible, non-minimized window on the current space.
    /// Uses `CGWindowListCopyWindowInfo` with `optionOnScreenOnly` — this only returns
    /// windows on the active space. Filters to layer 0 (normal windows) and minimum 50x50
    /// to exclude menu bar extras, status items, and invisible helper windows.
    func appHasWindowsOnCurrentSpace(_ bundleIdentifier: String) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let pids = pidsForApp(bundleIdentifier)
        return windowList.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let h = bounds["Height"] as? Int, h > 50,
                  let w2 = bounds["Width"] as? Int, w2 > 50
            else { return false }
            return pids.contains(pid)
        }
    }

    func hasMinimizedWindows(for bundleIdentifier: String) -> Bool {
        guard let pid = pidsForApp(bundleIdentifier).first else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axWindowsFor(axApp) else { return false }
        return axWindows.contains { axIsMinimized($0) }
    }

    func minimizeAllWindows(for bundleIdentifier: String) {
        guard let pid = pidsForApp(bundleIdentifier).first else { return }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axWindowsFor(axApp) else { return }
        for w in axWindows where !axIsMinimized(w) {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func hasNonMinimizedWindows(for bundleIdentifier: String) -> Bool {
        guard let pid = pidsForApp(bundleIdentifier).first else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axWindowsFor(axApp) else { return false }
        return axWindows.contains { !axIsMinimized($0) }
    }

    /// Unminimizes a window for the given app, preferring one on `preferSpaceID`.
    /// If `preferSpaceID` is set but no minimized window exists on that space,
    /// returns `false` rather than unminimizing a window from a different space —
    /// doing so would cause macOS to switch desktops (the exact behavior we prevent).
    func unminimizeWindow(for bundleIdentifier: String, preferSpaceID: Int? = nil) -> Bool {
        guard let pid = pidsForApp(bundleIdentifier).first else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axWindowsFor(axApp) else { return false }

        let minimized = axWindows.filter { axIsMinimized($0) }
        guard !minimized.isEmpty else { return false }

        // Try to find a minimized window on the preferred space first
        var target: AXUIElement?
        if let preferSpaceID {
            for w in minimized {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(w, &wid) == .success else { continue }
                if let space = SpaceDetector.shared.spaceForWindow(wid), space == preferSpaceID {
                    target = w
                    break
                }
            }
        }

        // If preferSpaceID was set but no window found on that space,
        // do NOT fall back to a random window — it might be on a different
        // space and cause macOS to switch desktops.
        guard let w = target ?? (preferSpaceID == nil ? minimized.first : nil) else {
            return false
        }

        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            app.activate(options: [])
        }
        return true
    }

    func focusLocalWindow(for bundleIdentifier: String) -> Bool {
        guard let pid = pidsForApp(bundleIdentifier).first else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        guard let axWindows = axWindowsFor(axApp), let w = axWindows.first else { return false }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) {
            app.activate(options: [])
        }
        return true
    }

    // MARK: - New Window

    /// Opens a new window for the given app using AppleScript.
    ///
    /// **Why AppleScript instead of AX or NSWorkspace?**
    /// There is no universal macOS API for "open a new window." Each app has its own
    /// AppleScript dictionary (or none). The approach:
    /// - Apps with native scripting support (Finder, Chrome, Terminal): use their
    ///   specific AppleScript command (e.g., `make new Finder window`).
    /// - Safari: must use System Events menu-click because Safari's `make new document`
    ///   creates a tab, not a window.
    /// - Generic fallback: activate the app, then click File > New Window via System Events.
    ///   Tries German menu names first ("Neues Fenster" / "Ablage"), then English.
    /// - Single-window apps (Spotify, Mail): just activate — opening a "new window" would
    ///   create an unwanted compose sheet or is simply impossible.
    ///
    /// Returns `true` if the script executed without error (does not guarantee a window appeared).
    func openNewWindow(bundleIdentifier: String) -> Bool {
        let scriptSource: String
        switch bundleIdentifier {
        case "com.apple.finder":
            scriptSource = #"tell application id "com.apple.finder" to make new Finder window"#
        case "com.apple.Safari":
            scriptSource = """
            tell application id "com.apple.Safari" to activate
            delay 0.3
            tell application "System Events"
                tell (first application process whose bundle identifier is "com.apple.Safari")
                    try
                        click menu item "Neues Fenster" of menu "Ablage" of menu bar 1
                    on error
                        try
                            click menu item "New Window" of menu "File" of menu bar 1
                        end try
                    end try
                end tell
            end tell
            """
        case "com.google.Chrome":
            scriptSource = #"tell application id "com.google.Chrome" to make new window"#
        case "com.microsoft.edgemac":
            scriptSource = #"tell application id "com.microsoft.edgemac" to make new window"#
        case "com.apple.Terminal":
            scriptSource = #"tell application id "com.apple.Terminal" to do script ""#
        case "com.apple.TextEdit":
            scriptSource = #"tell application id "com.apple.TextEdit" to make new document"#
        case "com.apple.mail":
            // Mail: just activate, don't open new compose window
            scriptSource = #"tell application id "com.apple.mail" to activate"#
        case "com.spotify.client":
            // Spotify is single-window, just activate
            scriptSource = #"tell application id "com.spotify.client" to activate"#
        default:
            // Generic: try File > New Window via System Events
            scriptSource = """
            tell application id "\(bundleIdentifier)" to activate
            delay 0.2
            tell application "System Events"
                tell (first application process whose bundle identifier is "\(bundleIdentifier)")
                    try
                        click menu item "Neues Fenster" of menu "Ablage" of menu bar 1
                    on error
                        try
                            click menu item "New Window" of menu "File" of menu bar 1
                        end try
                    end try
                end tell
            end tell
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Helpers

    func pidsForApp(_ bundleIdentifier: String) -> Set<Int32> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map { $0.processIdentifier })
    }

    private func axWindowsFor(_ app: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private func axIsMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success else { return false }
        return (ref as? Bool) == true
    }
}
