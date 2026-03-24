import SwiftUI
import AppKit

struct DebugView: View {
    @EnvironmentObject var store: DesktopStore
    @State private var log: [String] = []
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug Panel").font(.headline)

            GroupBox("State") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Desktops: \(store.desktops.count)")
                    Text("Current: \(store.currentDesktopName) (ID \(store.currentSpaceID))")
                    Text("AXTrusted: \(AXIsProcessTrusted() ? "✅" : "❌")")
                    Text("Preview: \(store.dockPreviewController != nil ? "ready" : "loading...")")
                    Text("SingleInstance: \(store.singleInstanceApps.joined(separator: ", "))")
                }
                .font(.system(size: 11, design: .monospaced))
            }

            GroupBox("Actions") {
                HStack(spacing: 8) {
                    Button("Open Preview for frontmost") {
                        testPreviewForFrontmost()
                    }
                    Button("Test Close (TextEdit)") {
                        testClose("com.apple.TextEdit")
                    }
                    Button("Refresh Dock Items") {
                        addLog("Dock items refreshed")
                    }
                }
                .font(.system(size: 11))
            }

            GroupBox("Dock Items") {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(getDockApps(), id: \.self) { name in
                            Text(name)
                                .font(.system(size: 9))
                                .padding(2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.1)))
                        }
                    }
                }
            }

            GroupBox("Log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.suffix(20).enumerated()), id: \.offset) { _, entry in
                            Text(entry).font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
                .frame(height: 100)
            }
        }
        .padding()
        .frame(width: 450, height: 400)
        .onAppear { startMonitoring() }
        .onDisappear { timer?.invalidate() }
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let space = SpaceDetector.shared.currentSpaceID()
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                addLog("space=\(space) front=\(front)")
            }
        }
    }

    private func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(ts)] \(msg)")
        if log.count > 100 { log.removeFirst(50) }
    }

    private func testPreviewForFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier else {
            addLog("No frontmost app")
            return
        }
        addLog("Testing preview for \(front.localizedName ?? bid)")

        // Programmatically trigger preview
        guard let ctrl = store.dockPreviewController else {
            addLog("Preview controller not ready")
            return
        }
        addLog("Preview controller ready, loading...")
        Task {
            // Use center of screen as mock position
            let pos = NSPoint(x: NSScreen.main!.frame.midX, y: 80)
            await ctrl.showPreviewForDebug(bundleID: bid, appName: front.localizedName ?? bid, at: pos)
            addLog("Preview loaded")
        }
    }

    private func testClose(_ bundleID: String) {
        let pids = store.dockManager.pidsForApp(bundleID)
        guard let pid = pids.first else { addLog("App not running"); return }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], let first = windows.first else {
            addLog("No AX windows"); return
        }
        var closeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(first, "AXCloseButton" as CFString, &closeRef) == .success {
            let result = AXUIElementPerformAction(closeRef as! AXUIElement, kAXPressAction as CFString)
            addLog("Close: \(result == .success ? "✅" : "❌ \(result.rawValue)")")
        } else {
            addLog("No AXCloseButton found")
        }
    }

    private func getDockApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
    }
}
