/// SpaceNameOverlay.swift — Center-screen HUD overlay shown on desktop switch.
///
/// Displays the desktop name in a large, bold, rounded-rect pill centered on screen.
/// Appears for 1 second then fades out over 0.3s. Enabled via `LabelSettings.showCenterOverlay`.
///
/// The window is borderless, click-through (`ignoresMouseEvents`), and lives on
/// `.screenSaver` level so it floats above everything including fullscreen apps.
/// `canJoinAllSpaces + stationary` ensures it's visible on every desktop without
/// being listed in Mission Control.
///
/// **Gotcha:** Uses a plain NSView with `layer.backgroundColor` for the colored
/// background — NOT NSVisualEffectView. CALayer sublayers on NSVisualEffectView are
/// invisible because the VFX rendering covers them.
import AppKit

/// Controls the center-screen HUD that briefly shows the desktop name on space switch.
/// Debounces rapid space switches (50ms) to avoid flickering during fast Ctrl+Arrow navigation.
@MainActor
class SpaceNameOverlayController {
    private var window: NSWindow?
    private var textField: NSTextField?
    private var bgBox: NSView?
    private var hideTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Shows the overlay with the given desktop name and color.
    /// Cancels any pending hide animation and debounces at 50ms for rapid switches.
    func show(name: String, fontSize: Double = 38, color: NSColor? = nil) {
        debounceTask?.cancel()
        hideTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.doShow(name: name, fontSize: fontSize, color: color)
        }
    }

    /// Performs the actual show — called after debounce delay. Creates the window lazily,
    /// sizes it to fit the text, centers it on the main screen, and schedules a 1s auto-hide.
    private func doShow(name: String, fontSize: Double, color: NSColor? = nil) {
        hideTask?.cancel()

        if window == nil { createWindow() }

        textField?.stringValue = name
        textField?.font = NSFont.systemFont(ofSize: CGFloat(fontSize), weight: .bold)
        textField?.sizeToFit()

        // Set background to desktop color (directly visible, no hidden layers)
        let bgColor = color ?? NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 1.0)
        bgBox?.layer?.backgroundColor = bgColor.withAlphaComponent(0.7).cgColor

        if let textField, let window {
            let textSize = textField.frame.size
            let padding = NSSize(width: 80, height: 48)
            let windowSize = NSSize(
                width: textSize.width + padding.width,
                height: textSize.height + padding.height
            )
            window.setContentSize(windowSize)
            bgBox?.frame = NSRect(origin: .zero, size: windowSize)
            textField.frame = NSRect(
                x: padding.width / 2,
                y: padding.height / 2,
                width: textSize.width,
                height: textSize.height
            )
        }

        if let screen = NSScreen.main, let window {
            let frame = screen.frame
            let x = frame.midX - window.frame.width / 2
            let y = frame.midY + 50
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.alphaValue = 1
        window?.orderFront(nil)

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.window?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.window?.orderOut(nil)
            }
        }
    }

    /// Lazily creates the borderless, click-through overlay window.
    /// Window level is `.screenSaver` to appear above fullscreen apps.
    private func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.ignoresMouseEvents = true

        // Direct colored background (no NSVisualEffectView — color must be visible)
        let bg = NSView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        bg.layer?.backgroundColor = NSColor(red: 0.35, green: 0.60, blue: 0.95, alpha: 0.7).cgColor
        w.contentView?.addSubview(bg)
        bgBox = bg

        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.systemFont(ofSize: 38, weight: .bold)
        tf.textColor = .white
        tf.alignment = .center
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        w.contentView?.addSubview(tf)

        self.textField = tf
        self.window = w
    }
}
