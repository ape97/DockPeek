/// DesktopModels.swift — Core data models for desktop configuration and settings.
///
/// All models are `Codable` for JSON persistence to `~/Library/Application Support/`.
/// Raw values for enums are in German to match the localized UI strings.
///
/// ## Desktop Identity Model
///
/// Desktops are identified by **index** (position in Mission Control), not by CGS space ID.
/// Space IDs are ephemeral — they change on reboot or when spaces are added/removed.
///
/// - `DesktopPreset`: User-defined name + optional color, stored by index (1-based).
///   Survives reboots and space ID changes. Can define presets for desktops that
///   don't exist yet (e.g., preset 10 desktops when only 3 are active).
///
/// - `DesktopConfig`: Maps a live CGS space ID to a preset index. Rebuilt on every
///   space change by `DesktopStore.syncWithSystem()`.
import Foundation

/// User-defined preset for a desktop at a given index (1-based).
/// Stored persistently — survives reboots and space ID changes.
/// `colorR/G/B` are optional: `nil` means use the default palette color.
struct DesktopPreset: Codable, Hashable, Identifiable {
    var id: Int // 1-based desktop index
    var name: String
    var colorR: Double?
    var colorG: Double?
    var colorB: Double?

    /// Whether this preset has a user-defined custom color
    var hasCustomColor: Bool { colorR != nil && colorG != nil && colorB != nil }
}

/// Maps a live CGS space ID to a desktop index. Rebuilt on every space change.
/// The `index` links to the matching `DesktopPreset`.
struct DesktopConfig: Identifiable, Codable, Hashable {
    var id: Int          // CGS space ID (ephemeral)
    var index: Int       // 1-based desktop index (matches DesktopPreset.id)
    var customName: String
}

/// Screen position for the persistent desktop name label.
/// Raw values are German UI strings used directly in the preferences picker.
enum LabelPosition: String, Codable, CaseIterable {
    case topLeft = "Oben Links"
    case topCenter = "Oben Mitte"
    case topRight = "Oben Rechts"
}

/// Display style for the desktop indicator.
enum IndicatorStyle: String, Codable, CaseIterable {
    case notchDrop = "Notch Drop"
    case notchSlide = "Notch Slide"
    case floatingBadge = "Floating Badge"
}

/// Controls whether the Floating Badge label is always visible,
/// fades out after a delay, or is completely hidden.
enum LabelMode: String, Codable, CaseIterable {
    case permanent = "Immer sichtbar"
    case fadeOut = "Einblenden & Ausblenden"
    case hidden = "Ausgeblendet"
}

/// Settings for the desktop indicator (Notch Drop, Notch Slide, Floating Badge).
struct LabelSettings: Codable, Hashable {
    var indicatorStyle: IndicatorStyle = .notchDrop
    // Menu Bar Badge: shows desktop color dot + name in the menu bar (parallel to other styles)
    var showMenuBarBadge: Bool = false
    // Notch Drop / Notch Slide settings
    var notchDropHold: Double = 1.8     // seconds the badge stays visible
    var notchDropSpeed: Double = 0.3    // seconds for slide animation
    // Floating Badge settings
    var mode: LabelMode = .fadeOut
    var position: LabelPosition = .topCenter
    var opacity: Double = 0.85
    var fontSize: Double = 14
    var fadeOutDelay: Double = 3.0
    var fadeOutDuration: Double = 0.5
}

/// Settings for the dock hover preview panel (DockPreviewPanel).
/// `spaceSwitchSpeed` is milliseconds between simulated Ctrl+Arrow keypresses —
/// lower values switch desktops faster but may outrun the macOS animation.
struct PreviewSettings: Codable, Hashable {
    var thumbnailWidth: Double = 120
    var thumbnailHeight: Double = 72
    var hoverDelay: Double = 0.2      // seconds before preview appears (before dock tooltip)
    var hideDelay: Double = 0.1       // seconds before preview hides
    var spaceSwitchSpeed: Double = 80 // milliseconds between Ctrl+Arrow presses (lower = faster)
    var maxWindowsPerGroup: Double = 5 // max visible thumbnails per desktop group
}

/// Top-level serialization container for all persisted state.
/// Saved as JSON to `~/Library/Application Support/DockPeek/desktop-config.json`.
struct DesktopState: Codable {
    var desktops: [DesktopConfig]
    var presets: [DesktopPreset] = []
    var singleInstanceApps: [String] = []  // bundle IDs of apps that should never open a second window
    var labelSettings: LabelSettings = LabelSettings()
    var previewSettings: PreviewSettings = PreviewSettings()
}
