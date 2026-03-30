/// DesktopNameLabel.swift — Persistent (or fade-out) desktop name label at top of screen.
///
/// Displays a small rounded-rect pill with the current desktop name near the menu bar.
/// Supports three modes: always visible, fade-out after delay, or hidden (see `LabelMode`).
/// Position is configurable (top-left, top-center, top-right).
///
/// The label color is always the per-desktop palette color from `DesktopStore.desktopPalette`,
/// regardless of the `LabelColorScheme` setting (the `resolveColor()` method exists for
/// potential future use but `applyStyle()` currently uses `currentDesktopColor` directly).
///
/// Window is borderless, click-through, `.statusBar` level, and joins all spaces.
/// Positioned 28px below the top of the screen to sit just under the menu bar.
import AppKit

/// Controls the persistent desktop name label shown near the top of the screen.
/// Updated by `DesktopStore` on every space change and settings change.
@MainActor
class DesktopNameLabelController {
    private var window: NSWindow?
    private var textField: NSTextField?
    private var backgroundView: NSView?
    private var gradientLayer: CAGradientLayer?
    private var settings: LabelSettings = LabelSettings()
    private var currentDesktopColor: NSColor?
    private var fadeTask: Task<Void, Never>?

    /// Main entry point — called by `DesktopStore.updateLabel()` on every space change.
    /// Hides the window if mode is `.hidden`, otherwise creates/updates the label and
    /// schedules a fade-out if mode is `.fadeOut`.
    func update(name: String, settings: LabelSettings, desktopColor: NSColor? = nil) {
        self.settings = settings
        self.currentDesktopColor = desktopColor

        if settings.mode == .hidden {
            window?.orderOut(nil)
            return
        }

        if window == nil { createWindow() }

        textField?.stringValue = name
        textField?.font = .systemFont(ofSize: CGFloat(settings.fontSize), weight: .medium)
        textField?.sizeToFit()

        applyStyle()
        positionOnScreen()

        window?.alphaValue = CGFloat(settings.opacity)
        window?.orderFront(nil)

        if settings.mode == .fadeOut {
            scheduleFadeOut()
        }
    }

    func hide() {
        fadeTask?.cancel()
        window?.orderOut(nil)
    }

    /// Schedules a fade-out animation after `settings.fadeOutDelay` seconds.
    /// Cancels any previously scheduled fade. Only used in `.fadeOut` mode.
    private func scheduleFadeOut() {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.settings.fadeOutDelay))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.settings.fadeOutDuration
                self.window?.animator().alphaValue = 0
            }
        }
    }

    /// Lazily creates the borderless, click-through label window.
    /// `.statusBar` level keeps it above normal windows but below the center HUD overlay.
    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.ignoresMouseEvents = true

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.masksToBounds = true
        w.contentView?.addSubview(bg)
        backgroundView = bg

        let tf = NSTextField(labelWithString: "")
        tf.textColor = .white
        tf.alignment = .center
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        w.contentView?.addSubview(tf)
        textField = tf

        self.window = w
    }

    /// Applies the desktop-specific palette color to the background.
    /// Removes any existing gradient layer first (leftover from a previous color scheme).
    /// **Note:** `resolveColor()` is defined below but NOT used here — `currentDesktopColor`
    /// (from `DesktopStore.colorForCurrentDesktop()`) always takes priority.
    private func applyStyle() {
        guard let bg = backgroundView else { return }

        gradientLayer?.removeFromSuperlayer()
        gradientLayer?.removeAllAnimations()
        gradientLayer = nil

        let cornerRadius = CGFloat(settings.fontSize * 0.85)
        bg.layer?.cornerRadius = cornerRadius

        // Always use the desktop-specific palette color
        if let color = currentDesktopColor {
            bg.layer?.backgroundColor = color.withAlphaComponent(0.8).cgColor
        } else {
            bg.layer?.backgroundColor = NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 0.8).cgColor
        }
    }

    /// Sizes the window to fit the text, then positions it near the top of the main screen.
    /// Sits 28px below screen top (just under the menu bar) with horizontal padding of 80px
    /// for left/right positions.
    private func positionOnScreen() {
        guard let tf = textField, let window, let screen = NSScreen.main else { return }

        tf.sizeToFit()
        let textSize = tf.frame.size
        let hPad: CGFloat = 16
        let vPad: CGFloat = 6
        let winSize = NSSize(width: textSize.width + hPad * 2, height: textSize.height + vPad * 2)

        window.setContentSize(winSize)
        tf.frame = NSRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)
        backgroundView?.frame = NSRect(origin: .zero, size: winSize)
        gradientLayer?.frame = NSRect(origin: .zero, size: winSize)

        let sf = screen.frame
        let y = sf.maxY - 28 - winSize.height - 4

        let x: CGFloat
        switch settings.position {
        case .topLeft:   x = sf.minX + 80
        case .topCenter: x = sf.midX - winSize.width / 2
        case .topRight:  x = sf.maxX - winSize.width - 80
        }

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

}
