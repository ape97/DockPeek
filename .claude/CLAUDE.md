# macOS Virtual Desktop Suite (VDS) — Complete Project Reference

This document is the single source of truth for understanding, building, and modifying the macOS Virtual Desktop Suite. It is written to be self-contained: any developer or AI agent should be able to understand the entire project architecture, every critical implementation detail, and every known gotcha without reading the source code.

---

## 1. Project Overview

**What it is:** A SwiftUI menu bar app for macOS that intercepts dock clicks to prevent space switching, shows hover previews of application windows grouped by desktop, and provides window management (close, minimize, focus) directly from the preview panel.

**Core value proposition:** On stock macOS, clicking a dock icon for an app on another desktop teleports you to that desktop. VDS prevents this: it opens a new window on the current desktop instead, or unminimizes an existing one. The preview panel shows all of an app's windows across all desktops so the user can choose which to focus.

**Target platform:** macOS 14+ (Sonoma/Tahoe). Built with SwiftUI for the menu bar shell, but the preview panel and overlays are pure AppKit (NSWindow/NSView) for precise control over positioning, animations, and event handling.

**Language:** Swift, with German-language UI strings (menu items, labels, button text).

---

## 2. Build and Run

```bash
# Build (clean + build)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "MacOs Virtual Desktop Suite.xcodeproj" \
  -scheme "MacOs Virtual Desktop Suite" \
  -configuration Debug \
  -derivedDataPath /tmp/vds-build clean build

# Run
open /tmp/vds-build/Build/Products/Debug/MacOs\ Virtual\ Desktop\ Suite.app
```

**Signing:** Uses a self-signed certificate named "VDS Dev Signing" stored in the login keychain. This certificate is critical because TCC (Transparency, Consent, and Control) permissions for Accessibility and Screen Recording persist across builds when signed with the same certificate. Without it, permissions must be re-granted after every build.

**Required permissions:**
- **Accessibility** (TCC): For AXUIElement APIs (window enumeration, close buttons, dock item detection) and CGEventTap (dock click interception).
- **Screen Recording** (TCC): For SCShareableContent/SCScreenshotManager (window thumbnail capture).
- Terminal also needs Screen Recording permission for `screencapture` during testing.

---

## 3. File Structure

| File | Lines | Role |
|------|-------|------|
| `MacOs_Virtual_Desktop_SuiteApp.swift` | 40 | SwiftUI `@main` entry point. Creates `MenuBarExtra` with desktop list, auto-new-window toggle, settings link, and quit button. Instantiates `DesktopStore` as `@StateObject`. |
| `Models/DesktopModels.swift` | 60 | Data models: `DesktopConfig` (id + customName), `LabelSettings` (mode, position, color, opacity, font size, fade delay, center overlay), `PreviewSettings` (thumbnail size, hover/hide delays, space switch speed, max windows per group), `DesktopState` (top-level persistence container). Enums for `LabelPosition`, `LabelColorScheme`, `LabelMode`. |
| `Services/SpaceDetector.swift` | 85 | Wraps three private CGS APIs to detect macOS Spaces. Singleton (`SpaceDetector.shared`). Returns `[DetectedSpace]` with spaceID, isCurrentSpace, isFullscreen, index, displayID. |
| `Services/DockManager.swift` | 420 | CGEventTap for dock click interception, AX-based window operations (minimize, unminimize, focus), dock orientation detection, `ensureSpaceSwitchDisabled()` for macOS settings, `openNewWindow()` via AppleScript per-app recipes. |
| `Services/DesktopStore.swift` | 379 | Central `@MainActor ObservableObject`. Owns `DockManager`, `SpaceDetector`, overlay controllers, and `DockPreviewController`. Manages desktop configs, activation observer, space change handler, persistence to JSON, single-instance app list, and desktop color palette. |
| `Views/DockPreviewPanel.swift` | 1824 | The largest and most complex file. Contains: `DockPreviewController` (dock item polling, thumbnail capture, panel layout, close animation, keyboard navigation, context menus), `KeyablePanel` (NSPanel subclass), `CloseButton` (custom-drawn Mission Control style), `ClickableView` (hover/click/right-click card with tracking areas). |
| `Views/PreferencesView.swift` | 489 | Settings window with 5 custom tabs (Desktops, Appearance, Behavior, System, Debug) plus a `MockPreviewScene` live preview at the bottom. Uses `@EnvironmentObject` to bind to `DesktopStore`. |
| `Views/DesktopNameLabel.swift` | 149 | Floating `NSWindow` at the top of the screen showing the current desktop name with the desktop's palette color. Supports permanent, fade-out, and hidden modes. |
| `Views/SpaceNameOverlay.swift` | 112 | Center-screen HUD that briefly shows the desktop name on space switch. Uses debounced show + auto-fade-out. |
| `Views/DebugView.swift` | 131 | SwiftUI view embedded in the Debug tab of Preferences. Shows live state (desktop count, current space, AX status), action buttons (test preview, test close, refresh dock items), dock app list, and a scrolling log. |

---

## 4. Architecture Deep Dive

### 4.1 Application Lifecycle

1. `MacOs_Virtual_Desktop_SuiteApp` creates `DesktopStore` as a `@StateObject`.
2. `DesktopStore.init()` loads saved config from `~/Library/Application Support/MacOs Virtual Desktop Suite/desktop-config.json`, syncs with the system's current spaces, installs NSWorkspace observers, installs the CGEventTap via `DockManager`, and updates the desktop name label.
3. After a 2-second delay (to let the app settle), `DesktopStore` creates `DockPreviewController`, which starts a 50ms polling timer to track mouse position over the dock.

### 4.2 Space Detection (SpaceDetector)

Uses three undocumented CoreGraphics SPI functions imported via `@_silgen_name`:

- **`CGSMainConnectionID()`** -- Returns the connection ID for the current GUI session.
- **`CGSCopyManagedDisplaySpaces(_ cid)`** -- Returns a CFArray of dictionaries, one per display. Each contains `"Display Identifier"`, `"Current Space"` (dict with `"ManagedSpaceID"`), and `"Spaces"` (array of dicts with `"ManagedSpaceID"` and `"type"`).
- **`CGSCopySpacesForWindows(_ cid, _ mask, _ wids)`** -- Given window IDs, returns which space(s) each window belongs to. Mask `0x7` means "all space types."

Space type `4` = fullscreen space. Regular desktops get sequential `userIndex` values; fullscreen spaces get index `0`.

The detector filters to the current display's spaces via `detectMainDisplaySpaces()` (matches on `displayID` of the current space).

### 4.3 Dock Click Interception (DockManager)

#### CGEventTap Setup

A session-level event tap (`cgSessionEventTap`, `headInsertEventTap`, `defaultTap`) intercepts `leftMouseDown` events. The callback is a top-level `nonisolated` C-compatible function (`vdsDockClickCallback`) that bridges to `DockManager.preHandleDockClick(at:)` via `MainActor.assumeIsolated`.

**CRITICAL:** `event.location` must be extracted BEFORE entering `MainActor.assumeIsolated` because `CGEvent` is not `Sendable`.

The tap auto-re-enables on `tapDisabledByTimeout` or `tapDisabledByUserInput`.

#### Decision Logic (preHandleDockClick)

This is the hybrid event-tap logic. DO NOT CHANGE without full regression testing.

```
1. Is click in dock area? (90px zone, supports bottom/left/right orientation)
   NO  -> return false (pass through)

2. Identify app at click point via AX (AXURL on dock icon element, fallback to title match)
   Not found / is Dock itself / is VDS itself -> return false

3. Check window state for that app:

   CASE 1: App has non-minimized windows AND windows on current space
     - Is app frontmost?
       YES -> SUPPRESS click + minimize all windows (toggle behavior)
       NO  -> PASS THROUGH (let dock focus it with natural bounce animation)

   CASE 2: App has minimized windows (but no visible ones on current space)
     -> SUPPRESS click + unminimize window (prefer same-space window)
     -> app.activate() for dock icon highlight as visual feedback
     -> If no same-space minimized window found, trigger onNeedNewWindow

   CASE 3: App has no windows at all
     -> PASS THROUGH (let dock launch the app naturally)
```

**Why suppress is necessary for minimized windows:** macOS ignores the `workspaces=false` dock preference for minimized windows. If the click is not suppressed, macOS will switch to the desktop where the minimized window lives, defeating the purpose of VDS.

**Why Case 1 (not frontmost) passes through:** Preserving the dock bounce animation provides natural visual feedback. The `workspaces=false` setting prevents space switching for non-minimized windows, so passing through is safe.

#### Activation Observer (DesktopStore)

A secondary handler via `NSWorkspace.didActivateApplicationNotification` catches dock clicks that were passed through (Case 1 not-frontmost and Case 3). When activation happens while the mouse is in the dock area:

- Skip if the app was just launched (< 2 seconds ago, it opens its own window).
- Skip if within the `ignoreActivationsUntil` cooldown window.
- If the app has no visible window on the current space:
  - Try to unminimize a same-space window.
  - If none, open a new window via `openNewWindow()`.
- Single-instance apps: switch to existing window instead of opening a new one.

#### Space Change Handler

Observes `NSWorkspace.activeSpaceDidChangeNotification`. If a space switch was caused by a dock click (detected via `lastActivationWasDockClick` flag within 0.5s), opens a new window on the destination space. Otherwise, treats it as a normal space switch (Ctrl+Arrow, Mission Control) and updates the label/overlay.

### 4.4 macOS Settings (ensureSpaceSwitchDisabled)

On every launch, DockManager writes these settings and restarts the Dock if any changed:

| Setting | Domain | Key | Value | Purpose |
|---------|--------|-----|-------|---------|
| Don't switch spaces on dock click | `com.apple.dock` | `workspaces` | `false` | Primary space-switch prevention for non-minimized windows |
| Don't switch spaces on app activate | `NSGlobalDomain` | `AppleSpacesSwitchOnActivate` | `false` | Prevents activate() from switching spaces |
| Don't auto-reorder spaces | `com.apple.dock` | `mru-spaces` | `false` | Keeps desktop order stable (not reordered by most-recently-used) |
| Disable dock tooltips | `com.apple.dock` | `show-tooltip` | `false` | Dock tooltips conflict with VDS preview panel positioning |

The dock settings are written directly to `~/Library/Preferences/com.apple.dock.plist`. The `AppleSpacesSwitchOnActivate` setting is written via `/usr/bin/defaults write NSGlobalDomain`. After changes, the Dock process is killed after a 1.5s delay to allow the plist write to flush.

### 4.5 New Window Creation (openNewWindow)

Uses `NSAppleScript` with per-app recipes:

- **Finder:** `make new Finder window`
- **Safari:** Activate, then click "Neues Fenster"/"New Window" menu item via System Events (handles both German and English locales)
- **Chrome/Edge:** `make new window`
- **Terminal:** `do script ""`
- **TextEdit:** `make new document`
- **Mail:** Just activate (don't open compose window)
- **Spotify:** Just activate (single-window app)
- **Generic fallback:** Activate, then try clicking "Neues Fenster"/"New Window" via System Events

### 4.6 Preview Panel (DockPreviewController)

#### Polling and Hover Detection

A 50ms `Timer` (`tick()`) continuously checks:
1. Is accessibility granted? If not, skip.
2. Is mouse button pressed outside panel? Hide panel.
3. Is right-click cooldown or close cooldown active? Skip.
4. Is mouse over/near the panel (20px extended hit area, like Windows 11)? Keep panel, auto-refresh if empty.
5. Is a dock context menu visible? Hide panel.
6. Is mouse in dock area? If not, hide panel.
7. Identify dock item under mouse via AX (refreshed every 0.5s).
8. Same app as before? Wait for hover delay (configurable, default 0.2s), then load preview. Auto-refresh every 3s (0.5s if showing empty state).
9. Different app? Start new hover timer. If panel was already showing, use shorter delay (0.15s) for quick switching.

#### Dock Item Detection via AX

Reads the Dock process's AX tree: `AXApplication` -> `AXList` children -> items with `AXURL` (file URL to app bundle, resolved to bundle ID) or title (matched against running applications).

Each dock item's screen position and size are cached and used for hit testing (with 4px horizontal / 8px vertical padding for easier targeting).

#### Thumbnail Capture

Uses ScreenCaptureKit (`SCShareableContent` + `SCScreenshotManager`):
1. Fetch all shareable windows via `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)`.
2. Filter to the target app's bundle ID, non-empty title, minimum 200x100 size.
3. Cross-reference with AX window IDs to filter out phantom windows (Safari keeps off-screen windows that are not in AX).
4. Detect dialog windows (no `AXCloseButton` in AX) and show them with the app icon instead of a dark/broken thumbnail.
5. Detect minimized windows via AX `kAXMinimizedAttribute`.
6. Detect fullscreen windows by checking if their space ID is in the fullscreen space set.
7. Capture each window via `SCScreenshotManager.captureImage` at 2x resolution for Retina, scaled to configured thumbnail width.
8. Cache thumbnails for 5 seconds (`thumbnailCache`).

#### Window Filtering Rule

```
Include window if:
  - Bundle ID matches
  - Title is non-empty
  - Frame > 200x100
  - NOT a dialog (no AXCloseButton) -- dialogs handled separately
  - AND (window ID is in AX window list OR window is on-screen)
```

The `isOnScreen || inAX` rule is specifically for Safari, which keeps phantom off-screen windows that appear in SCShareableContent but are not real user-visible windows and are not in the AX tree.

#### Panel Layout

Windows are grouped by desktop (sorted by desktop config order). Each group has:
- **Header:** Colored background (from 6-color palette), color dot, desktop name, app icon, optional app name (if >= 2 windows and enough width), optional pin icon (single-instance apps).
- **Thumbnail cards:** Up to `maxWindowsPerGroup` visible cards (default 5), plus up to 5 hidden overflow cards (pre-rendered at `alphaValue=0`, `zPosition=-1`).
- **Window title:** Below each card, truncated with ellipsis.
- **State badge:** Bottom-right icon on each card -- blue window icon (normal), yellow down-arrow (minimized), purple arrows (fullscreen).
- **Overflow indicator:** "+N" button that opens a menu listing hidden windows.

If the total width exceeds screen width minus 40px, a horizontal `NSScrollView` with overlay scroller is used, with a gradient fade indicator on the right edge.

The panel is an `NSPanel` (`KeyablePanel`) at `.popUpMenu` level with `NSVisualEffectView` (.hudWindow material) background. Positioned directly above the dock at y=78, centered on the hovered dock icon. A small triangle marker points down at the icon.

**Empty state:** When an app is running but has no windows, shows the app icon, "AppName - Keine Fenster" text, and a "+ Neues Fenster" button.

#### Close Animation (WORKING - DO NOT CHANGE)

This is the most fragile part of the UI. The current solution uses pre-rendered hidden overflow cards.

**How it works:**
1. When laying out a group with more than `maxThumbsPerDesktop` windows, cards beyond the limit are rendered at `alphaValue=0` and `zPosition=-1`. They are fully laid out in the view hierarchy but invisible and non-interactive (`hitTest` returns nil for alpha=0 cards).
2. When the user closes a visible card:
   - The closed card fades out (alpha -> 0).
   - Cards in the same group to the right slide left by `thumbnailWidth + gap`.
   - If a hidden overflow card exists in the same group, it slides into the visible area and fades in (alpha -> 1, zPosition -> 0).
   - If NO overflow card exists, the group header shrinks, subsequent groups slide left, and the panel shrinks from the right.
   - Group headers with no remaining visible cards fade out.
3. After all cards are closed, shows the empty-state placeholder if the app is still running.
4. After 2 seconds, a full refresh rebuilds the panel from scratch (clears thumbnail cache).

**Why this approach:** Earlier attempts at rebuilding the panel from scratch after each close caused visible flicker. The pre-rendered overflow approach allows smooth single-animation-group transitions without any async thumbnail re-fetching during the animation.

#### Window Close Strategy (3 tiers per window)

```
Tier 1: AXCloseButton + kAXPressAction
  - Match by windowID (most reliable, uses _AXUIElementGetWindow to cross-reference)
  - Fallback: match by window title
  - Last resort: close first window that has an AXCloseButton

Tier 2: Try ALL PIDs for the bundle ID
  - Electron apps (VS Code, Slack, Discord) have multiple processes
  - Repeat Tier 1 matching for each PID

Tier 3: Send Escape key to dismiss dialogs
  - NSSavePanel/NSOpenPanel have no AXCloseButton
  - CGEvent(keyboardEventSource:virtualKey:53) posted to the target PID
  - Also tries finding Cancel/Abbrechen/Close button via AX tree traversal
```

**IMPORTANT:** Use `kAXPressAction`, NOT `kAXCloseAction`. The constant `kAXCloseAction` does not exist in the Accessibility API. The close button is an AXUIElement obtained via `AXCloseButton` attribute, and you perform `kAXPressAction` on it.

**Note:** Spotify's AXCloseButton hides/minimizes the window instead of closing it. This is Spotify's native behavior, not a VDS bug.

#### Keyboard Navigation

`KeyablePanel` overrides `keyDown` and forwards to the controller:
- **Escape:** Hide panel.
- **Tab / Shift+Tab:** Move focus forward/backward through cards.
- **Left/Right arrows:** Move focus.
- **Return / Space:** Activate focused card (same as click).

Focused cards get a 2px accent-color border.

#### Context Menus (Right-click)

Each card has a right-click menu with:
- "Fenster schliessen" (close window)
- "Alle Fenster schliessen" (close all windows)
- "App beenden" (quit app, disabled for Finder)
- "Einzelne Instanz" (toggle single-instance mode for this app)

The empty-state panel has:
- "Neues Fenster" (open new window)
- "App beenden" (quit app)

### 4.7 Desktop Name Label (DesktopNameLabelController)

A borderless `NSWindow` at `.statusBar` level with `canJoinAllSpaces` + `stationary` + `ignoresCycle` collection behavior. `ignoresMouseEvents = true` so it never intercepts clicks.

Uses a plain `NSView` with `layer.backgroundColor` for the colored background -- NOT `NSVisualEffectView` (see gotcha #3 below).

Supports three positions (topLeft, topCenter, topRight) and three modes:
- **permanent:** Always visible at configured opacity.
- **fadeOut:** Shows on space switch, fades out after configurable delay (default 3s).
- **hidden:** Never shown.

Color comes from the desktop palette (6 colors cycling: blue, green, purple, orange, pink, teal).

### 4.8 Space Name Overlay (SpaceNameOverlayController)

A center-screen HUD at `.screenSaver` level. Shows briefly (1s) on desktop switch with a 0.3s fade-out animation. Debounced by 50ms to avoid rapid flickering on fast space switches.

Same `canJoinAllSpaces` + `stationary` + `ignoresCycle` + `ignoresMouseEvents` pattern as the label.

### 4.9 Persistence

State is saved to `~/Library/Application Support/MacOs Virtual Desktop Suite/desktop-config.json` as pretty-printed sorted-key JSON. The `DesktopState` struct contains:
- `desktops: [DesktopConfig]` (id + customName)
- `autoNewWindowEnabled: Bool`
- `singleInstanceApps: [String]` (bundle IDs)
- `labelSettings: LabelSettings`
- `previewSettings: PreviewSettings`

Saved on every change (rename, setting toggle, etc.) via `JSONEncoder`.

### 4.10 Space Switching from Preview Panel

When the user clicks a window thumbnail that is on a different desktop, `switchToSpace()` uses AppleScript to simulate Ctrl+Arrow keypresses:

```swift
NSAppleScript(source: "tell application \"System Events\" to key code \(keyCode) using control down")
```

The number of keypresses equals the index difference between current and target space. A configurable delay (`spaceSwitchSpeed`, default 80ms) is inserted between presses via `usleep`.

This includes fullscreen spaces in the space list so the user can switch to fullscreen apps from the preview.

---

## 5. Critical Architecture Rules and Gotchas

These are hard-won lessons. Each one was discovered through debugging sessions that took significant time. Violating any of them will cause regressions.

### Rule 1: CGEventTap Hybrid Logic
The three-case decision in `preHandleDockClick` is the result of extensive testing. The "visible + not frontmost -> pass through" case is essential for preserving dock bounce animation. The "minimized -> suppress" case is essential because macOS ignores `workspaces=false` for minimized windows. Do not simplify or refactor this logic without running the full 54-test regression suite.

### Rule 2: AppleSpacesSwitchOnActivate Bool Default Trap
```swift
// WRONG: Returns false for MISSING keys too (nil coalesces to false)
UserDefaults.standard.bool(forKey: "AppleSpacesSwitchOnActivate")

// CORRECT: Distinguishes "set to false" from "not set at all"
UserDefaults(suiteName: "NSGlobalDomain")?.object(forKey: "AppleSpacesSwitchOnActivate") as? Bool != false
```
If you use the wrong pattern, `ensureSpaceSwitchDisabled()` will think the setting is already false when it was never set, and will not write it.

### Rule 3: NSVisualEffectView Sublayers Are INVISIBLE
`CALayer` sublayers added to an `NSVisualEffectView` are invisible because the vibrancy rendering covers them completely. This was tried 3 times before root-causing. All colored backgrounds in VDS use a plain `NSView` with `layer.backgroundColor` instead. The `NSVisualEffectView` is only used for the preview panel's blurred background, and the actual content is layered on top in a separate `NSView`.

### Rule 4: Close Buttons MUST Be Inside Card Views
In AppKit, views that extend outside their superview's bounds do not receive mouse events. Close buttons were originally positioned as siblings of the card views, offset to overlap the top-left corner. This broke hit testing. The fix: close buttons are subviews of the card (`ClickableView`) itself, with `layer.masksToBounds = false` on the card and `layer.zPosition = 10` on the close button to render above the card border.

### Rule 5: AXCloseButton + kAXPressAction (Not kAXCloseAction)
The Accessibility API has no `kAXCloseAction` constant. To close a window programmatically:
```swift
var closeRef: CFTypeRef?
AXUIElementCopyAttributeValue(window, "AXCloseButton" as CFString, &closeRef)
AXUIElementPerformAction(closeRef as! AXUIElement, kAXPressAction as CFString)
```

### Rule 6: CGEvent.post Does Not Work for Ctrl+Arrow on macOS Tahoe
System-level keyboard shortcuts (like Ctrl+Left/Right for space switching) cannot be triggered via `CGEvent.post` on modern macOS. The events are posted but the system ignores them for built-in shortcuts. The workaround is AppleScript via System Events:
```swift
NSAppleScript(source: "tell application \"System Events\" to key code \(keyCode) using control down")
```

### Rule 7: Close Animation Uses Pre-Rendered Hidden Overflow Cards (DO NOT CHANGE)
The close animation in `DockPreviewPanel.swift` relies on overflow cards being pre-rendered at `alphaValue=0` and `zPosition=-1`. When a visible card is closed, a hidden card slides into its place in a single `NSAnimationContext.runAnimationGroup` block. Rebuilding the panel from scratch during close causes flicker. This approach was arrived at after multiple failed alternatives and must not be changed.

### Rule 8: Dialog Windows (NSSavePanel/NSOpenPanel)
Dialog windows have no `AXCloseButton` attribute. VDS detects these by checking for the absence of `AXCloseButton` in the AX tree. They are shown in the preview panel with the app icon as the thumbnail (since SCScreenshotManager produces dark/broken captures for dialogs). Closing them uses Escape key injection (`CGEvent` with virtual key 53 posted to the target PID) or finding a Cancel/Abbrechen button via AX tree traversal.

### Rule 9: Safari Phantom Windows
Safari keeps phantom off-screen windows that appear in `SCShareableContent` but are not real user-visible windows. These windows are not present in the AX window list and are not on-screen. The filtering rule is: include a window only if it is in the AX window list (`_AXUIElementGetWindow` match) OR it is on-screen (`isOnScreen`). This prevents phantom windows from appearing in the preview.

### Rule 10: macOS Ignores workspaces=false for Minimized Windows
Even with `workspaces=false` set in the dock preferences, clicking a dock icon for an app that has ONLY minimized windows will cause macOS to switch to the desktop where that minimized window lives. The CGEventTap MUST suppress the click in this case and handle unminimize + activate manually. This is Case 2 in the hybrid logic.

---

## 6. Key Implementation Details

### Private API Import Pattern
```swift
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
```
These are undocumented Apple APIs. `@_silgen_name` links directly to the symbol without needing a bridging header or dynamic lookup.

### CGEventTap Callback Threading
The callback must be a top-level `nonisolated` function (not a method or closure) for C compatibility. It uses `Unmanaged<DockManager>` to pass the manager instance through the `userInfo` void pointer. Inside the callback, `MainActor.assumeIsolated` is used because CGEventTap callbacks run on the main thread.

### Dock Area Detection
The dock can be on the bottom, left, or right side of the screen. `dockOrientation()` reads `com.apple.dock`'s `orientation` preference. `isCGPointInDockArea()` uses CG coordinates (origin top-left), while `isMouseInDockArea()` uses NSEvent coordinates (origin bottom-left). The dock zone is 90px from the relevant screen edge.

### Dock Item Identification
Two strategies for identifying which app a dock click targets:
1. **AXURL:** Dock icon AX elements expose an `AXURL` attribute containing a `file://` URL to the app bundle. Resolved to bundle ID via `Bundle(url:)?.bundleIdentifier`.
2. **Title fallback:** Match the AX title against `NSWorkspace.shared.runningApplications` `localizedName`.

### Thumbnail Cache
`thumbnailCache` maps `CGWindowID` to `(image: NSImage, time: Date)`. Entries older than 5 seconds are considered stale and re-captured. The cache is cleared on full panel refresh (triggered 2s after close animation, or on app switch).

### Stable Window Sort Order
`stableWindowOrder` maintains a persistent ordering of window IDs across refreshes. New windows are appended; closed windows are removed. Within each desktop group, windows are sorted by their position in this stable array, preventing jarring reordering on refresh.

### Desktop Color Palette
Six colors that cycle for desktops:
1. Blue (0.35, 0.60, 0.95)
2. Green (0.40, 0.78, 0.55)
3. Purple (0.68, 0.50, 0.90)
4. Orange (0.95, 0.60, 0.35)
5. Pink (0.90, 0.45, 0.55)
6. Teal (0.50, 0.75, 0.75)

Used for desktop headers in preview, desktop name label, and space name overlay. Fullscreen spaces inherit the color of the preceding regular desktop.

### Single-Instance Apps
Some apps (like Spotify) should never open a second window. Users can mark apps as single-instance via right-click context menu in the preview. When a dock click occurs for a single-instance app with no window on the current space, VDS switches to the existing window's desktop instead of opening a new one. Persisted in `singleInstanceApps` array of bundle IDs.

### Panel Positioning and Extended Hit Area
The panel is positioned at `y=78` (directly above the dock). It uses a 20px horizontal / 15px vertical extended hit area around the panel frame to prevent accidental dismissal when the mouse slightly exits while reaching for edge thumbnails (similar to Windows 11 taskbar previews).

### Dock Context Menu Detection
VDS hides the preview panel when a dock context menu is visible. Detection: check `CGWindowListCopyWindowInfo` for windows owned by the Dock PID (`com.apple.dock`) with layer > 25 (the dock bar itself is layer ~20, context menus are higher).

---

## 7. Testing

### Automated Testing

```bash
# Full regression suite (54 tests: Safari, TextEdit, Finder x 6 scenarios)
/tmp/vds_masstest.sh

# Space detection diagnostic
/tmp/vds_test diag

# AX close test on specific app
/tmp/vds_axclose com.apple.Safari

# AX close debug
/tmp/vds_close_debug com.apple.TextEdit
```

### Visual Testing

```bash
# Screenshot (silent, no shutter sound)
screencapture -x /tmp/vds_screenshot.png

# Record video (5 seconds)
screencapture -V 5 /tmp/vds_video.mov

# Record via helper script
/tmp/vds_record.sh start test_name
/tmp/vds_record.sh stop

# Extract frames for analysis (10 fps)
ffmpeg -i /tmp/vds_test_name.mov -vf "fps=10" /tmp/frame_%03d.png -y

# Clean up
rm -f /tmp/vds_*.png /tmp/vds_*.mov
```

ffmpeg is installed via Homebrew. Screen Recording permission must be granted for Terminal.

### Critical Test Limitation

**Synthetic mouse events (`CGEvent.post`) do NOT trigger the CGEventTap or the preview panel's hover detection.** The CGEventTap only fires for real hardware mouse events. All automated dock-click tests rely on the `workspaces=false` setting + activation observer as the testable path. Preview/close button testing requires real mouse interaction.

### Debug Panel

The Debug tab in Preferences (`DebugView.swift`) provides:
- Live state display (desktop count, current space ID, AX trusted status, preview controller status, single-instance apps).
- "Open Preview for frontmost" button: programmatically triggers preview for the current frontmost app at screen center, useful for testing without mouse interaction.
- "Test Close (TextEdit)" button: tests AX close button on TextEdit windows.
- Live dock app list.
- Scrolling log with 1-second polling of current space and frontmost app.

---

## 8. Known Behaviors (Not Bugs)

- **Spotify AXCloseButton hides instead of closing:** Spotify's close button is wired to hide/minimize, not quit. This is Spotify's native behavior.
- **Dock icon highlights briefly on minimized-window unminimize:** This is the intended visual feedback for Case 2 (suppress + unminimize + activate).
- **No full dock bounce animation for minimized windows:** Impossible to achieve while preventing space switches. The suppress + activate approach is the best available compromise (3 alternatives were tested).
- **Safari menu item uses German+English fallback:** `openNewWindow` tries "Neues Fenster" first, then "New Window", to support both locales.
- **Fullscreen space color inherits from current desktop:** macOS puts fullscreen spaces at the END of the space list (not adjacent to the originating desktop), making it impossible to determine the true origin desktop. The current desktop's color is used as a best guess.

---

## 9. Dependencies

- **No third-party dependencies.** The project uses only Apple frameworks: SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics (including private CGS APIs), and ApplicationServices (Accessibility).
- **ffmpeg** (Homebrew) is used for test video frame extraction only, not at runtime.
- **System Events** AppleScript access is required for space switching (Ctrl+Arrow simulation) and new window creation (menu item clicking).

---

## 10. Agent Working Instructions

These are mandatory rules for any AI agent (Claude, etc.) working on this project. Follow them in every session without being reminded.

### 10.1 Documentation-After-Every-Change

After **every** completed task, update the following:

1. **`BUGS_AND_FIXES.md`** — Add entry for every bug fix with: symptom, root cause, fix, failed alternatives
2. **`CLAUDE.md`** — Update architecture rules if new gotchas were discovered
3. **Memory files** — Save feedback, project status, and TODO items for cross-session persistence

### 10.2 Failed Approach Tracking

When a solution **does not work** (user says "geht nicht", "funktioniert nicht", "gleicher Fehler"):

1. **Immediately document** in `BUGS_AND_FIXES.md`:
   - What was tried
   - Why it failed (root cause if known)
   - User's exact feedback
2. **Never retry the same approach** — check BUGS_AND_FIXES.md and memory files before attempting a fix
3. **Tag failed approaches** with `❌ FAILED` in documentation so future sessions skip them
4. Save to memory as `feedback` type if it reveals a reusable lesson

### 10.3 Build-Test-Verify Cycle

For every code change:

1. **Build** after every edit: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project "MacOs Virtual Desktop Suite.xcodeproj" -scheme "MacOs Virtual Desktop Suite" -configuration Debug -derivedDataPath /tmp/vds-build build`
2. **0 errors AND 0 warnings** required before presenting to user
3. **Restart the app** after build: `pkill -f "MacOs Virtual Desktop Suite"; sleep 0.5; open /tmp/vds-build/Build/Products/Debug/MacOs\ Virtual\ Desktop\ Suite.app`
4. **Visual changes** → record video with `/tmp/vds_record.sh start/stop` and analyze frames
5. **Never say "sollte funktionieren"** — verify it yourself or ask the user to test

### 10.4 Video-Based Debugging

When the user reports a visual bug:

1. Record with `/tmp/vds_record.sh start name` → user shows bug → `/tmp/vds_record.sh stop`
2. Extract frames: `ffmpeg -i /tmp/vds_name.mov -vf "fps=10" /tmp/vds_name_%03d.png -y`
3. Read key frames to understand the exact visual sequence
4. **Reproduce the same steps yourself** before attempting a fix
5. After fix, record again and verify the frames show correct behavior

### 10.5 Close Animation — DO NOT TOUCH

The close animation in `DockPreviewPanel.swift` uses pre-rendered hidden overflow cards. This solution was developed over 10+ iterations. See `feedback_close_animation.md` in memory. **Any modification requires manual testing: 10+ windows, close 5+ rapidly in sequence.**

### 10.6 Code Quality Standards

- **SOLID principles** — each class has one responsibility, extract when files exceed ~500 lines
- **Apple best practices** — no deprecated APIs, no unnecessary force-unwraps, 0 compiler warnings
- **German UI** — all user-facing strings in German (menu items, labels, buttons)
- **Inline documentation** — every class and non-obvious method gets a `///` doc comment
- **No over-engineering** — keep it simple, don't add abstractions for hypothetical future needs

### 10.7 Dialog Window Handling (TODO — Not Yet Solved)

NSSavePanel/NSOpenPanel dialogs are a known unsolved edge case. See `project_todo_dialog_preview.md` in memory. Current state:
- Dialogs detected via AX (no AXCloseButton)
- Shown with app icon instead of dark screenshot
- Closed via Escape key or Cancel button
- **Still has flicker/consistency issues** — needs more work

Failed approaches for dialog handling (DO NOT retry):
- ❌ Relying on SCShareableContent for dialog detection (inconsistent, flickers)
- ❌ Excluding all windows without AXCloseButton (breaks real windows behind dialog sheets)
- ❌ `disableScreenUpdatesUntilFlush()` (deprecated in macOS 15, no-op)

---

## 11. Preview-Only Redesign (2026-03-30)

### What Changed

DockPeek was redesigned from a window-management app to a **pure display app**. The app now only shows dock hover previews and desktop names — it no longer intercepts dock clicks, opens/closes windows, or manages single-instance apps.

### Active Features
- **Dock-Hover-Preview:** Read-only thumbnail preview of all windows, grouped by desktop
- **Thumbnail-Klick:** Click → switch to that desktop + focus the window
- **Desktop-Benennung:** Floating Badge, Notch Badge, Notch Slide indicators
- **Settings:** Appearance, Behavior, Desktops, System (mru-spaces only)
- **Escape:** Closes the preview panel

### Deactivated Features (code preserved, not executed)

All deactivated code is marked with:
```
// DEACTIVATED: Preview-Only Mode (2026-03-30)
```

| Feature | File | What's Disabled |
|---------|------|----------------|
| CGEventTap | DockManager.swift | `installClickInterceptor()` not called |
| macOS Settings | DockManager.swift | `ensureSpaceSwitchDisabled()` body commented out |
| Activation Observer | DesktopStore.swift | `didActivateApplicationNotification` observer not registered |
| onNeedNewWindow | DesktopStore.swift | Callback not set |
| Close-Buttons | DockPreviewPanel.swift | CloseButton not created on cards |
| Context Menus | DockPreviewPanel.swift | Right-click handlers removed |
| Empty-State Button | DockPreviewPanel.swift | "Neues Fenster" button removed |
| Overflow Cards | DockPreviewPanel.swift | All windows rendered, no hidden overflow |
| Close Animation | DockPreviewPanel.swift | No close = no animation needed |
| Keyboard Nav | DockPreviewPanel.swift | Only Escape remains |
| Debug Close Test | DebugView.swift | "Test Close" button removed |
| Old System Settings | PreferencesView.swift | workspaces/AppleSpacesSwitchOnActivate/show-tooltip display removed |

### macOS Settings Policy

The app now only cares about `mru-spaces=false` (stable desktop order). It is **never set automatically** — the user must click "Jetzt konfigurieren" in Settings → System. Methods:
- `DockManager.checkMruSpacesStatus() -> Bool` — read-only check
- `DockManager.configureMruSpaces()` — sets mru-spaces=false + dock restart (user action only)

### Files Not in Section 3 Table
| File | Lines | Role |
|------|-------|------|
| `Views/PreviewComponents.swift` | ~140 | KeyablePanel, CloseButton (deactivated), ClickableView |
| `Views/NotchBadge.swift` | ~150 | Notch drop animation indicator |
| `Views/NotchSlide.swift` | ~160 | Notch slide animation indicator |
