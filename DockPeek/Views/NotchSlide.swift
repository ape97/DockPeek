/// NotchSlide.swift — Desktop indicator that slides left out of the notch.
///
/// Each show() creates a fresh NSWindow. Previous window removed immediately.
import AppKit

@MainActor
class NotchSlideController {
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    private let noNotchWidth: CGFloat = 180
    private let pillHeight: CGFloat = 28
    private let cornerRadius: CGFloat = 14
    private let contentPadding: CGFloat = 24 // horizontal padding around dot+text

    private func notchGeometry(for screen: NSScreen) -> (width: CGFloat, centerX: CGFloat, leftEdge: CGFloat)? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let w = right.minX - left.maxX
        let cx = left.maxX + w / 2 + 0.5
        return (w, cx, left.maxX)
    }

    func show(name: String, color: NSColor, holdDuration: Double = 1.8, animationSpeed: Double = 0.3) {
        hideTask?.cancel()

        // Let old window retract on its own space
        if let oldWindow = window {
            retract(window: oldWindow, animationSpeed: 0.2)
        }
        window = nil

        guard let screen = NSScreen.main else { return }
        let notch = notchGeometry(for: screen)
        let hasNotch = notch != nil
        let notchW = notch?.width ?? noNotchWidth
        let notchLeftEdge = notch?.leftEdge ?? (screen.frame.midX - noNotchWidth / 2)
        let topEdge = screen.frame.maxY
        let notchH: CGFloat = hasNotch ? screen.safeAreaInsets.top : 0
        let windowH = hasNotch ? notchH : pillHeight
        let windowY = topEdge - windowH

        // Create fresh window
        let w = makeWindow(hasNotch: hasNotch, height: windowH)
        let bg = w.contentView!.subviews[0]
        let dotView = bg.subviews[0]
        let label = bg.subviews[1] as! NSTextField

        label.stringValue = name
        label.sizeToFit()
        dotView.layer?.backgroundColor = color.cgColor

        // Dynamic content width based on actual text
        let dotSize: CGFloat = 8
        let gap: CGFloat = 8
        let labelW = label.frame.width
        let contentWidth = dotSize + gap + labelW + contentPadding
        let expandedW = notchW + contentWidth
        let expandedX = notchLeftEdge - contentWidth
        let startX = contentPadding / 2
        let cy = windowH / 2
        dotView.frame = NSRect(x: startX, y: cy - dotSize / 2, width: dotSize, height: dotSize)
        label.frame = NSRect(x: startX + dotSize + gap, y: cy - 9, width: labelW + 4, height: 18)
        // Background only covers content + small overlap behind notch (not full notch width)
        let notchOverlap: CGFloat = 10
        let bgWidth = contentWidth + notchOverlap
        bg.frame = NSRect(x: 0, y: 0, width: bgWidth, height: windowH)

        // Phase 1: Instant — place so the bg overlaps behind the notch left edge
        let hiddenX = notchLeftEdge - notchOverlap
        w.setFrame(NSRect(x: hiddenX, y: windowY, width: bgWidth, height: windowH), display: false)
        w.orderFront(nil)
        self.window = w

        // Phase 2: Smooth — slide left to reveal content
        let visibleX = notchLeftEdge - contentWidth
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationSpeed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(
                NSRect(x: visibleX, y: windowY, width: bgWidth, height: windowH),
                display: false
            )
        }

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
        let notchW = notch?.width ?? noNotchWidth
        let notchLeftEdge = notch?.leftEdge ?? (screen.frame.midX - noNotchWidth / 2)
        let topEdge = screen.frame.maxY
        let notchH: CGFloat = hasNotch ? screen.safeAreaInsets.top : 0
        let windowH = hasNotch ? notchH : pillHeight
        let windowY = topEdge - windowH

        // Smooth — slide right back behind notch
        let notchOverlap: CGFloat = 10
        let hiddenX = notchLeftEdge - notchOverlap
        let bgWidth = w.frame.width
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationSpeed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(
                NSRect(x: hiddenX, y: windowY, width: bgWidth, height: windowH),
                display: false
            )
        }, completionHandler: {
            Task { @MainActor in
                w.orderOut(nil)
            }
        })
    }

    private func makeWindow(hasNotch: Bool, height: CGFloat) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        w.level = .screenSaver
        w.collectionBehavior = [.stationary, .ignoresCycle]
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = !hasNotch
        w.ignoresMouseEvents = true

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = cornerRadius
        bg.layer?.masksToBounds = true
        if hasNotch { bg.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner] }
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
