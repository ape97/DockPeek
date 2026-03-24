import SwiftUI

@main
struct DockPeekApp: App {
    @StateObject private var store = DesktopStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Section(NSLocalizedString("menu.desktops", comment: "")) {
                ForEach(store.desktops) { desktop in
                    Label(
                        desktop.customName,
                        systemImage: desktop.id == store.currentSpaceID
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
            }

            Divider()

            Button(NSLocalizedString("menu.settings", comment: "")) {
                SettingsWindowController.shared.show()
            }

            Button(NSLocalizedString("menu.quit", comment: "")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if store.labelSettings.showMenuBarBadge {
                Image(nsImage: menuBarBadge(name: store.currentDesktopName, color: store.colorForCurrentDesktop()))
            } else {
                Image("MenuBarIcon")
            }
        }
    }

    /// Renders the full menu bar badge as a single NSImage: colored dot + text.
    /// Gives full pixel control since MenuBarExtra labels ignore SwiftUI padding.
    private func menuBarBadge(name: String, color: NSColor) -> NSImage {
        let dotSize: CGFloat = 8
        let gap: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (name as NSString).size(withAttributes: attrs)
        let totalW = dotSize + gap + textSize.width
        let h: CGFloat = 18

        let img = NSImage(size: NSSize(width: totalW, height: h))
        img.lockFocus()

        // Dot
        color.setFill()
        let dotY = (h - dotSize) / 2
        NSBezierPath(ovalIn: NSRect(x: 0, y: dotY, width: dotSize, height: dotSize)).fill()

        // Text
        let textY = (h - textSize.height) / 2
        (name as NSString).draw(at: NSPoint(x: dotSize + gap, y: textY), withAttributes: attrs)

        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

@MainActor
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = PreferencesView()
            .environmentObject(DesktopStore.shared)

        let hostingController = NSHostingController(rootView: settingsView)
        let w = NSWindow(contentViewController: hostingController)
        w.title = "DockPeek Einstellungen"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 700, height: 460))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
