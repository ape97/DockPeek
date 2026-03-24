// PreviewComponents.swift
// Shared UI components for the dock preview panel.
// Extracted from DockPreviewPanel.swift for reusability.

import AppKit

// MARK: - Keyable Panel

/// NSPanel subclass that forwards key events to the preview controller
/// and allows key status without requiring full activation.
class KeyablePanel: NSPanel {
    weak var previewController: DockPreviewController?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        previewController?.handleKeyDown(event)
    }
    // Ensure mouse events are delivered without activation delay
    override var becomesKeyOnlyIfNeeded: Bool {
        get { true }
        set {}
    }
}


// MARK: - Panel Content View (forces arrow cursor)

/// Covers the entire panel and overrides the cursor to arrow.
/// Without this, the cursor shows whatever the app behind the panel uses
/// (e.g., I-beam over a text editor) because the panel is non-activating.
class PanelContentView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

// MARK: - Close Button (Mission Control style)

/// A circular close button drawn in either white (Mission Control style) or red (quit variant).
/// Hidden by default (alphaValue = 0); shown on parent hover via ClickableView association.
class CloseButton: NSView {
    var onClose: (() -> Void)?
    var isRedStyle = false // red quit button variant

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0 // hidden by default, shown on parent hover
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let r = bounds.insetBy(dx: 1, dy: 1)

        if isRedStyle {
            // Red filled circle
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1, color: NSColor(white: 0, alpha: 0.3).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0)
            // White X
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        } else {
            // White filled circle (Mission Control style)
            ctx.setFillColor(NSColor(white: 0.95, alpha: 0.9).cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1, color: NSColor(white: 0, alpha: 0.3).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0)
            // Gray X
            ctx.setStrokeColor(NSColor(white: 0.35, alpha: 0.9).cgColor)
        }

        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        let inset: CGFloat = 5.5
        ctx.move(to: CGPoint(x: r.minX + inset, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY - inset))
        ctx.move(to: CGPoint(x: r.maxX - inset, y: r.minY + inset))
        ctx.addLine(to: CGPoint(x: r.minX + inset, y: r.maxY - inset))
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) { layer?.opacity = 0.5 }
    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1.0
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A clickable card view with hover highlight, right-click support, and close button association.
/// Hidden overflow cards (alphaValue == 0) are excluded from hit testing.
class ClickableView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var savedBorderColor: CGColor?
    weak var associatedCloseButton: CloseButton?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hidden overflow cards (alpha=0) must not receive clicks
        if alphaValue == 0 { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { layer?.opacity = 0.7 }
    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1.0
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        savedBorderColor = layer?.borderColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        associatedCloseButton?.animator().alphaValue = 1
    }
    override func mouseExited(with event: NSEvent) {
        layer?.borderColor = savedBorderColor ?? NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        associatedCloseButton?.animator().alphaValue = 0
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
}
