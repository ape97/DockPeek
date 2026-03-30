# DockPeek Preview-Only Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce DockPeek to a pure display app — dock hover preview + desktop naming only. Disable all window management features.

**Architecture:** Deactivation at call-sites, not deletion. Feature code stays in place but is never executed. Three bugs fixed (floating badge, dock auto-hide, fullscreen color). Settings UI cleaned up to match reduced feature set.

**Tech Stack:** Swift, SwiftUI, AppKit, ScreenCaptureKit, private CGS APIs

**Spec:** `.claude/specs/2026-03-30-preview-only-redesign.md`

**Build command:**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "DockPeek.xcodeproj" -scheme "DockPeek" \
  -configuration Debug -derivedDataPath /tmp/vds-build build 2>&1 | tail -5
```

**Run command:**
```bash
pkill -f "DockPeek" 2>/dev/null; sleep 0.5; open /tmp/vds-build/Build/Products/Debug/DockPeek.app
```

---

## File Map

| File | Action | What Changes |
|------|--------|-------------|
| `DockPeek/Services/DockManager.swift` | Modify | Disable CGEventTap, rewrite `ensureSpaceSwitchDisabled()` to only check `mru-spaces` |
| `DockPeek/Services/DesktopStore.swift` | Modify | Remove activation observer, remove single-instance logic, don't call event tap |
| `DockPeek/Views/DockPreviewPanel.swift` | Modify | Remove close buttons, context menus, empty-state button, overflow cards, keyboard nav |
| `DockPeek/Views/PreviewComponents.swift` | Modify | Remove close button hover logic from ClickableView |
| `DockPeek/Views/PreferencesView.swift` | Modify | Rewrite System tab (mru-spaces only with warning), clean Behavior tab |
| `DockPeek/Views/DesktopNameLabel.swift` | Modify | Fix floating badge to show on correct desktop (Bug 1) |
| `DockPeek/Views/DebugView.swift` | Modify | Remove "Test Close" button |

---

## Task 1: Disable CGEventTap and macOS Settings in DockManager

**Files:**
- Modify: `DockPeek/Services/DockManager.swift`

This task disables the core dock-click interception. Dock clicks will pass through to macOS normally.

- [ ] **Step 1: Read DockManager.swift to confirm exact line numbers**

```bash
# Verify the lines we need to modify
grep -n "installClickInterceptor\|ensureSpaceSwitchDisabled\|CGEvent.tapCreate" DockPeek/Services/DockManager.swift
```

- [ ] **Step 2: Disable `installClickInterceptor()` call**

In `DockManager.init()`, comment out the call to `installClickInterceptor()`. Add deactivation comment:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Was: CGEventTap für Dock-Click-Interception
// Grund: App reduziert auf Preview + Desktop-Benennung
// self.installClickInterceptor()
```

- [ ] **Step 3: Rewrite `ensureSpaceSwitchDisabled()` to only check mru-spaces**

Replace the entire method body. It no longer writes any settings — only reads `mru-spaces` and returns the status. The actual writing happens in Settings via user action.

```swift
/// Prüft ob mru-spaces deaktiviert ist (Voraussetzung für stabile Desktop-Reihenfolge).
/// Setzt NICHTS automatisch — User muss in Settings aktiv konfigurieren.
func checkMruSpacesStatus() -> Bool {
    let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    // object(forKey:) um nil (nicht gesetzt) von false zu unterscheiden
    guard let value = dockDefaults?.object(forKey: "mru-spaces") as? Bool else {
        return false // nicht gesetzt = nicht konfiguriert
    }
    return !value // mru-spaces=false → return true (korrekt konfiguriert)
}

/// Setzt mru-spaces=false und startet den Dock neu.
/// Nur auf explizite User-Aktion aufrufen (Button in Settings).
func configureMruSpaces() {
    let plistPath = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
    let dict = NSMutableDictionary(contentsOfFile: plistPath) ?? NSMutableDictionary()
    dict["mru-spaces"] = false
    dict.write(toFile: plistPath, atomically: true)

    Task.detached {
        try? await Task.sleep(for: .seconds(1.5))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
```

Keep the old `ensureSpaceSwitchDisabled()` method but comment it out with deactivation marker.

- [ ] **Step 4: Build and verify 0 errors, 0 warnings**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "DockPeek.xcodeproj" -scheme "DockPeek" \
  -configuration Debug -derivedDataPath /tmp/vds-build build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add DockPeek/Services/DockManager.swift
git commit -m "feat: disable CGEventTap and rewrite macOS settings to mru-spaces check only"
```

---

## Task 2: Disable Activation Observer and Single-Instance in DesktopStore

**Files:**
- Modify: `DockPeek/Services/DesktopStore.swift`

- [ ] **Step 1: Read DesktopStore.swift to confirm exact lines**

```bash
grep -n "didActivateApplication\|singleInstance\|installClickInterceptor\|ensureSpaceSwitchDisabled\|onNeedNewWindow" DockPeek/Services/DesktopStore.swift
```

- [ ] **Step 2: Disable activation observer registration**

Find the `NSWorkspace.shared.notificationCenter.addObserver` for `didActivateApplicationNotification` and comment it out:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Was: Activation Observer für automatische neue Fenster
// Grund: App öffnet/verwaltet keine Fenster mehr
// NSWorkspace.shared.notificationCenter.addObserver(
//     forName: NSWorkspace.didActivateApplicationNotification, ...
```

- [ ] **Step 3: Disable `ensureSpaceSwitchDisabled()` call**

Find where `ensureSpaceSwitchDisabled()` or `dockManager.ensureSpaceSwitchDisabled()` is called and replace:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// dockManager.ensureSpaceSwitchDisabled()
```

- [ ] **Step 4: Disable onNeedNewWindow callback**

If `dockManager.onNeedNewWindow` is set somewhere, comment it out:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// dockManager.onNeedNewWindow = { [weak self] bundleID in ... }
```

- [ ] **Step 5: Add `@Published var mruSpacesConfigured: Bool` property**

Add a published property so Settings can show the warning:

```swift
@Published var mruSpacesConfigured: Bool = false
```

In `init()`, after existing setup:

```swift
mruSpacesConfigured = dockManager.checkMruSpacesStatus()
```

- [ ] **Step 6: Build and verify 0 errors, 0 warnings**

Fix any compiler errors from removed callbacks. Methods like `isSingleInstance()` and `toggleSingleInstance()` stay but are unused — that's fine.

- [ ] **Step 7: Commit**

```bash
git add DockPeek/Services/DesktopStore.swift
git commit -m "feat: disable activation observer, single-instance, and auto macOS settings"
```

---

## Task 3: Remove Close Buttons, Context Menus, and Overflow Cards from Preview

**Files:**
- Modify: `DockPeek/Views/DockPreviewPanel.swift`
- Modify: `DockPeek/Views/PreviewComponents.swift`

This is the largest task. The preview panel becomes read-only.

- [ ] **Step 1: Read the card creation section in DockPreviewPanel.swift**

Find where `CloseButton` instances are created and added to cards. Find where context menus are set up. Find the overflow card rendering.

```bash
grep -n "CloseButton\|closeButton\|rightClick\|contextMenu\|NSMenu\|maxThumbsPerDesktop\|maxHiddenOverflow\|Neues Fenster\|closeWindow\|closeAllWindows" DockPeek/Views/DockPreviewPanel.swift
```

- [ ] **Step 2: Remove CloseButton creation from card rendering**

In the card layout section, find where `CloseButton` is created and added as subview. Comment out the entire block:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Was: Close-Button auf jedem Thumbnail
// let closeBtn = CloseButton(...)
// card.addSubview(closeBtn)
// card.associatedCloseButton = closeBtn
```

- [ ] **Step 3: Remove context menu setup**

Find where `NSMenu` is created for right-click on cards. Comment out the entire menu creation:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Was: Rechtsklick-Kontextmenü (Close, Quit, Single-Instance)
```

Also remove the right-click handler assignment on `ClickableView`:

```swift
// card.onRightClick = { ... }  // DEACTIVATED
```

- [ ] **Step 4: Remove empty-state "Neues Fenster" button**

Find the empty-state view that shows "+ Neues Fenster". Keep the "Keine Fenster" text + app icon, remove the button:

```swift
// Show only app icon + "Keine Fenster" text, no action button
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Was: "+ Neues Fenster" Button im Empty-State
```

- [ ] **Step 5: Remove overflow card pre-rendering**

Find where `maxThumbsPerDesktop + maxHiddenOverflow` determines the render count. Change to render ALL windows (no limit, no hidden overflow):

```swift
// DEACTIVATED: Preview-Only Mode — show all windows, no overflow limit
// Was: let renderCount = min(group.windows.count, maxThumbsPerDesktop + maxHiddenOverflow)
let renderCount = group.windows.count
```

Remove the `if isOverflow { card.alphaValue = 0; card.layer?.zPosition = -1 }` block.

Remove the "+N" overflow indicator if it exists.

- [ ] **Step 6: Simplify keyboard handling to Escape only**

Find `handleKeyDown` or `keyDown`. Keep only Escape (keyCode 53), remove Tab/Arrow/Enter handling:

```swift
func handleKeyDown(_ event: NSEvent) {
    if event.keyCode == 53 { // Escape
        hidePanel()
    }
    // DEACTIVATED: Preview-Only Mode — no Tab/Arrow/Enter navigation
}
```

- [ ] **Step 7: Remove close button hover logic from ClickableView**

In `PreviewComponents.swift`, remove the `associatedCloseButton` property and the hover show/hide animation for close buttons in `mouseEntered`/`mouseExited`:

```swift
// DEACTIVATED: Preview-Only Mode — no close buttons
// weak var associatedCloseButton: CloseButton?
```

Keep the hover highlight effect on the card itself (visual feedback is good).

- [ ] **Step 8: Build and verify 0 errors, 0 warnings**

This will likely produce several errors from removed references. Fix each one by removing the calling code (not the method definitions — those stay).

- [ ] **Step 9: Commit**

```bash
git add DockPeek/Views/DockPreviewPanel.swift DockPeek/Views/PreviewComponents.swift
git commit -m "feat: remove close buttons, context menus, overflow cards from preview panel"
```

---

## Task 4: Clean Up Settings UI

**Files:**
- Modify: `DockPeek/Views/PreferencesView.swift`
- Modify: `DockPeek/Views/DebugView.swift`

- [ ] **Step 1: Read PreferencesView.swift System tab section**

```bash
grep -n "workspaces\|AppleSpacesSwitchOnActivate\|mru-spaces\|ensureSpaceSwitchDisabled\|show-tooltip\|Optimal" DockPeek/Views/PreferencesView.swift
```

- [ ] **Step 2: Rewrite System tab**

Replace the macOS config section. Remove `workspaces`, `AppleSpacesSwitchOnActivate`, `show-tooltip` displays. Keep permissions section. Add prominent `mru-spaces` warning:

```swift
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
                // Update status after short delay (Dock restart)
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
```

Remove the old "Configure Optimal" button that called `ensureSpaceSwitchDisabled()`.

- [ ] **Step 3: Clean Behavior tab**

Remove any settings related to close/new-window if present. Keep: thumbnail size, hover delay, hide delay, max windows per group, space switch speed.

- [ ] **Step 4: Remove "Test Close" from DebugView**

In `DebugView.swift`, find and comment out the "Test Close" button:

```swift
// DEACTIVATED: Preview-Only Mode (2026-03-30)
// Button("Test Close (TextEdit)") { ... }
```

Keep "Open Preview for frontmost" — it's useful for testing.

- [ ] **Step 5: Build and verify 0 errors, 0 warnings**

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Views/PreferencesView.swift DockPeek/Views/DebugView.swift
git commit -m "feat: rewrite Settings system tab with mru-spaces warning, remove close test button"
```

---

## Task 5: Fix Bug 1 — Floating Badge falscher Desktop

**Files:**
- Modify: `DockPeek/Views/DesktopNameLabel.swift`
- Modify: `DockPeek/Services/DesktopStore.swift` (if space-change handler needs fix)

- [ ] **Step 1: Read DesktopNameLabel.swift completely**

```bash
cat -n DockPeek/Views/DesktopNameLabel.swift
```

Understand how `show()` is called and whether it updates on space change.

- [ ] **Step 2: Read the space-change handler in DesktopStore**

```bash
grep -n "activeSpaceDidChange\|onSpaceChanged\|updateLabel\|DesktopNameLabel" DockPeek/Services/DesktopStore.swift
```

Understand the chain: space change notification → handler → label update.

- [ ] **Step 3: Diagnose the bug**

The floating badge uses `canJoinAllSpaces` + `stationary` collection behavior. It should be visible on ALL spaces. Check:
1. Is `canJoinAllSpaces` actually set on the window?
2. Is `updateLabel()` called on every space change?
3. Does the label content (name + color) update correctly?

- [ ] **Step 4: Fix the root cause**

Most likely one of:
- (a) Window collection behavior not set correctly → set `.canJoinAllSpaces` + `.stationary`
- (b) `updateLabel()` not called on space change → ensure it's called in `onSpaceChanged`
- (c) Color/name not refreshed → ensure `applyStyle()` is called with current desktop info

Apply the fix based on diagnosis.

- [ ] **Step 5: Build, run, and test**

Build, launch the app. Switch between desktops and verify the floating badge:
1. Shows on every desktop
2. Shows the correct desktop name
3. Shows the correct desktop color

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Views/DesktopNameLabel.swift DockPeek/Services/DesktopStore.swift
git commit -m "fix: floating badge now shows correctly on all desktops"
```

---

## Task 6: Fix Bug 3 — Dock Auto-Hide vs Preview

**Files:**
- Modify: `DockPeek/Views/DockPreviewPanel.swift`

- [ ] **Step 1: Understand the problem**

When the dock is set to auto-hide, it disappears after inactivity — even while the preview panel is showing. The preview then floats alone without the dock beneath it.

- [ ] **Step 2: Research approach**

Check if we can detect dock auto-hide state:

```bash
defaults read com.apple.dock autohide
```

Options:
1. **Detect dock hiding → hide preview:** In `tick()`, check if dock is visible (via window list or AX). If dock hides, hide preview too.
2. **Keep mouse in dock area:** If preview is visible, the mouse IS near the dock, which should prevent auto-hide. If this doesn't work, the timing may be off.
3. **Disable auto-hide while preview is showing:** Too invasive.

Best approach: Option 1 — detect dock visibility and close preview when dock hides.

- [ ] **Step 3: Implement dock-hide detection in tick()**

In the `tick()` polling method, add a check for dock visibility. The dock app has a window that can be checked via `CGWindowListCopyWindowInfo`:

```swift
/// Prüft ob der Dock sichtbar ist (nicht auto-hidden)
private func isDockVisible() -> Bool {
    let dockPID = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
    ).first?.processIdentifier ?? 0

    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly], kCGNullWindowID
    ) as? [[String: Any]] else { return true }

    return windowList.contains { info in
        (info[kCGWindowOwnerPID as String] as? pid_t) == dockPID &&
        (info[kCGWindowLayer as String] as? Int) == 0
    }
}
```

In `tick()`, after the dock-area check:

```swift
// Dock auto-hide: Preview schließen wenn Dock nicht sichtbar
if !isDockVisible() {
    hidePanel()
    return
}
```

- [ ] **Step 4: Build, run, and test**

Test with dock auto-hide enabled:
1. Hover over dock → preview appears
2. Move mouse away → dock hides → preview should also hide
3. Move mouse back to dock → dock shows → hover works again

- [ ] **Step 5: Commit**

```bash
git add DockPeek/Views/DockPreviewPanel.swift
git commit -m "fix: hide preview when dock auto-hides"
```

---

## Task 7: Fix Bug 7 — Fullscreen-Farbe falsch

**Files:**
- Modify: `DockPeek/Services/DesktopStore.swift`
- Modify: `DockPeek/Views/DockPreviewPanel.swift`

- [ ] **Step 1: Understand current fullscreen color logic**

```bash
grep -n "fullscreen\|Fullscreen\|fullScreen\|isFullscreen\|colorFor" DockPeek/Services/DesktopStore.swift DockPeek/Views/DockPreviewPanel.swift DockPeek/Services/SpaceDetector.swift
```

Currently, fullscreen spaces inherit the color of the "current desktop" which is wrong. They should inherit from the desktop they were launched from.

- [ ] **Step 2: Add fullscreen-origin tracking to DesktopStore**

Add a mapping from fullscreen space IDs to their origin desktop index:

```swift
/// Maps fullscreen space ID → origin desktop index (1-based)
private var fullscreenOriginMap: [Int: Int] = [:]
```

In `onSpaceChanged()`, when a new fullscreen space appears that wasn't there before, record the current desktop as its origin:

```swift
// Wenn ein neuer Fullscreen-Space auftaucht, war der aktuelle Desktop der Ursprung
let currentSpaces = spaceDetector.detectMainDisplaySpaces()
let fullscreenSpaces = currentSpaces.filter { $0.isFullscreen }
for fs in fullscreenSpaces {
    if fullscreenOriginMap[fs.spaceID] == nil {
        // Neuer Fullscreen-Space — Ursprung ist der vorherige Desktop
        fullscreenOriginMap[fs.spaceID] = previousDesktopIndex
    }
}
// Alte Einträge aufräumen
let activeFullscreenIDs = Set(fullscreenSpaces.map { $0.spaceID })
fullscreenOriginMap = fullscreenOriginMap.filter { activeFullscreenIDs.contains($0.key) }
```

Add a `previousDesktopIndex` property that is updated before space changes.

- [ ] **Step 3: Add public method to get color for a fullscreen space**

```swift
/// Farbe für einen Space (regulär oder Fullscreen mit Ursprungs-Desktop)
func colorForSpace(_ spaceID: Int) -> NSColor {
    if let originIndex = fullscreenOriginMap[spaceID] {
        return colorForDesktopIndex(originIndex)
    }
    // Regulärer Desktop — Index aus desktops-Array
    if let idx = desktops.firstIndex(where: { $0.id == spaceID }) {
        return colorForDesktopIndex(idx + 1)
    }
    return colorForDesktopIndex(1) // Fallback
}
```

- [ ] **Step 4: Update DockPreviewPanel to use colorForSpace()**

In the panel layout where desktop group headers get their color, replace the current logic with a call to `store.colorForSpace(group.spaceID)`.

- [ ] **Step 5: Build, run, and test**

Test: Open app on Desktop 1 (blue). Enter fullscreen. Check preview — fullscreen header should be blue, not whatever random color it was before.

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Services/DesktopStore.swift DockPeek/Views/DockPreviewPanel.swift
git commit -m "fix: fullscreen windows use origin desktop color in preview"
```

---

## Task 8: Final Build, Test, and Documentation Update

**Files:**
- Modify: `DockPeek/.claude/CLAUDE.md`
- Modify: `DockPeek/.claude/BUGS_AND_FIXES.md`

- [ ] **Step 1: Full clean build**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "DockPeek.xcodeproj" -scheme "DockPeek" \
  -configuration Debug -derivedDataPath /tmp/vds-build clean build 2>&1 | tail -5
```

Verify: **BUILD SUCCEEDED**, 0 errors, 0 warnings.

- [ ] **Step 2: Launch and manual smoke test**

```bash
pkill -f "DockPeek" 2>/dev/null; sleep 0.5; open /tmp/vds-build/Build/Products/Debug/DockPeek.app
```

Test checklist:
1. [ ] Hover over dock icon → preview appears with thumbnails
2. [ ] No close buttons visible on thumbnails
3. [ ] No context menu on right-click
4. [ ] Click thumbnail → switches to that window/desktop
5. [ ] Escape closes preview
6. [ ] Floating badge shows correct name + color on each desktop
7. [ ] Settings → System tab shows mru-spaces warning (if not configured)
8. [ ] Dock auto-hide mode: preview hides when dock hides
9. [ ] Fullscreen app shows correct origin desktop color

- [ ] **Step 3: Update BUGS_AND_FIXES.md**

Add new section:

```markdown
## Session: Preview-Only Redesign (2026-03-30)

### Architektur-Entscheidung: Preview-Only Mode
App reduziert auf Kern-Features: Dock-Hover-Preview + Desktop-Benennung.
Alle Fenster-Management-Features deaktiviert (Code bleibt, wird nicht ausgeführt):
- CGEventTap / Dock-Click-Interception
- Close-Buttons, Kontextmenüs, "Neues Fenster"
- Single-Instance, Activation Observer, openNewWindow()
- workspaces=false, AppleSpacesSwitchOnActivate=false

### Bug #34: Floating Badge falscher Desktop
**Fix:** [details from Task 5]
**Status:** ✅ Fixed

### Bug #35: Dock Auto-Hide vs Preview
**Fix:** isDockVisible() Check in tick() — Preview schließt wenn Dock auto-hides
**Status:** ✅ Fixed

### Bug #36: Fullscreen-Farbe falsch
**Fix:** fullscreenOriginMap trackt von welchem Desktop die App in Fullscreen ging
**Status:** ✅ Fixed
```

- [ ] **Step 4: Update CLAUDE.md**

Update the file structure table (add NotchBadge, NotchSlide, PreviewComponents).
Update Section 4.3 (Dock Click Interception) to note it's deactivated.
Update Section 4.6 (Preview Panel) to note close/context/overflow features are deactivated.
Add new Section noting the Preview-Only redesign and which features are deactivated.

- [ ] **Step 5: Final commit**

```bash
git add DockPeek/.claude/CLAUDE.md DockPeek/.claude/BUGS_AND_FIXES.md
git commit -m "docs: update CLAUDE.md and BUGS_AND_FIXES.md for preview-only redesign"
```
