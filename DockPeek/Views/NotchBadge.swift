/// NotchBadge.swift — Desktop indicator that slides out from behind the notch.
///
/// Each show() creates a fresh NSWindow. The previous window (if visible) is
/// removed immediately — no animation conflicts, no lag on rapid switching.
import AppKit

@MainActor
class NotchBadgeController {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    private let noNotchWidth: CGFloat = 180
    private let contentHeight: CGFloat = 28
    private let cornerRadius: CGFloat = 14

    private func notchGeometry(for screen: NSScreen) -> (width: CGFloat, centerX: CGFloat)? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let w = right.minX - left.maxX
        let cx = left.maxX + w / 2 + 0.5
        return (w, cx)
    }

    func show(name: String, color: NSColor, holdDuration: Double = 1.8, animationSpeed: Double = 0.3) {
        hideTask?.cancel()

        // Let the old window retract on its own space (don't orderOut — it stays behind)
        if let oldWindow = window {
            retract(window: oldWindow, animationSpeed: 0.2)
        }
        window = nil

        guard let screen = NSScreen.main else { return }
        let notch = notchGeometry(for: screen)
        let hasNotch = notch != nil
        let pillW = notch?.width ?? noNotchWidth
        let centerX = notch?.centerX ?? screen.frame.midX
        let topEdge = screen.frame.maxY
        let notchH: CGFloat = hasNotch ? screen.safeAreaInsets.top : 0
        let windowH = notchH + contentHeight
        let windowX = centerX - pillW / 2
        let expandedY = topEdge - windowH

        // Create fresh window
        let w = makeWindow(hasNotch: hasNotch, width: pillW, height: windowH)
        let bg = w.contentView!.subviews[0]
        let dotView = bg.subviews[0]
        let label = bg.subviews[1] as! NSTextField

        // Set content
        label.stringValue = name
        label.sizeToFit()
        dotView.layer?.backgroundColor = color.cgColor

        // Layout content at bottom of window
        let dotSize: CGFloat = 8
        let gap: CGFloat = 8
        let labelW = label.frame.width
        let totalW = dotSize + gap + labelW
        let startX = (pillW - totalW) / 2
        let cy = contentHeight / 2
        dotView.frame = NSRect(x: startX, y: cy - dotSize / 2, width: dotSize, height: dotSize)
        label.frame = NSRect(x: startX + dotSize + gap, y: cy - 9, width: labelW + 4, height: 18)
        bg.frame = NSRect(x: 0, y: 0, width: pillW, height: windowH)

        // Phase 1: Instant — fill notch area (hidden behind hardware)
        let notchBottomY = topEdge - notchH
        w.setFrame(NSRect(x: windowX, y: notchBottomY, width: pillW, height: hasNotch ? notchH : 1), display: false)
        w.orderFront(nil)
        self.window = w

        // Phase 2: Smooth — slide visible part below notch
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationSpeed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(
                NSRect(x: windowX, y: expandedY, width: pillW, height: windowH),
                display: false
            )
        }

        // Auto-retract
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled else { return }
            self?.retract(window: w, animationSpeed: animationSpeed)
        }
    }

    private func retract(window w: NSWindow, animationSpeed: Double) {
        guard let screen = NSScreen.main else { w.orderOut(nil); return }

        let notch = notchGeometry(for: screen)
        let hasNotch = notch != nil
        let pillW = notch?.width ?? noNotchWidth
        let centerX = notch?.centerX ?? screen.frame.midX
        let topEdge = screen.frame.maxY
        let notchH: CGFloat = hasNotch ? screen.safeAreaInsets.top : 0
        let notchBottomY = topEdge - notchH
        let windowX = centerX - pillW / 2

        // Smooth — slide back up to notch bottom
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationSpeed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(
                NSRect(x: windowX, y: notchBottomY, width: pillW, height: hasNotch ? notchH : 1),
                display: false
            )
        }, completionHandler: {
            Task { @MainActor in
                w.orderOut(nil)
            }
        })
    }

    private func makeWindow(hasNotch: Bool, width: CGFloat, height: CGFloat) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        w.level = .screenSaver
        w.collectionBehavior = [.stationary, .ignoresCycle]
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = !hasNotch
        w.ignoresMouseEvents = true

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = cornerRadius
        bg.layer?.masksToBounds = true
        if hasNotch { bg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
        w.contentView?.addSubview(bg)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        bg.addSubview(dot)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        bg.addSubview(label)

        return w
    }
}
