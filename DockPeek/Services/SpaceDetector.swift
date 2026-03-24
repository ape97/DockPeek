/// SpaceDetector.swift — Private CGS API wrapper for macOS virtual desktop detection.
///
/// macOS has no public API for enumerating Mission Control spaces or determining the
/// active desktop. This file bridges that gap using three undocumented CoreGraphics
/// Server (CGS) functions accessed via `@_silgen_name`. The returned data is an array
/// of per-display dictionaries containing space IDs, types, and the current space.
///
/// **Gotcha:** CGS space IDs are ephemeral — they change every time spaces are
/// created/destroyed or the Mac reboots. They must be re-queried on every space change.
import Foundation
import AppKit

/// Returns the connection ID for the current login session's window server.
/// Required as the first argument to all other CGS calls.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// Returns a CFArray of per-display dictionaries. Each dictionary contains:
/// - `"Display Identifier"` (String): display UUID
/// - `"Current Space"` (Dict): has `"ManagedSpaceID"` (Int) for the active space
/// - `"Spaces"` (Array of Dict): each with `"ManagedSpaceID"` and `"type"` (0 = normal, 4 = fullscreen)
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

/// Given an array of window IDs, returns the space IDs those windows live on.
/// The `mask` parameter is a bitmask — 0x7 matches all space types (current, other, fullscreen).
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray?

/// Represents a single Mission Control space discovered via CGS APIs.
/// `index` is the 1-based user-facing desktop number (0 for fullscreen spaces).
struct DetectedSpace {
    var spaceID: Int
    var isCurrentSpace: Bool
    var isFullscreen: Bool
    var index: Int
    var displayID: String
}

/// Singleton that queries macOS private CGS APIs to enumerate Mission Control spaces.
/// Thread-safe (`Sendable`) — the underlying CGS calls are stateless C functions.
final class SpaceDetector: Sendable {
    static let shared = SpaceDetector()

    /// Queries all displays and returns every space (normal + fullscreen).
    /// Fullscreen spaces have `type == 4` and get `index = 0`.
    /// Normal spaces are numbered 1, 2, 3, ... per display.
    func detectSpaces() -> [DetectedSpace] {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }

        var result: [DetectedSpace] = []

        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "unknown"
            let currentSpace = display["Current Space"] as? [String: Any]
            let currentSpaceID = currentSpace?["ManagedSpaceID"] as? Int ?? 0
            let spaces = display["Spaces"] as? [[String: Any]] ?? []

            var userIndex = 0
            for space in spaces {
                let spaceID = space["ManagedSpaceID"] as? Int ?? 0
                let type = space["type"] as? Int ?? 0
                let isFullscreen = (type == 4)

                if !isFullscreen {
                    userIndex += 1
                }

                result.append(DetectedSpace(
                    spaceID: spaceID,
                    isCurrentSpace: spaceID == currentSpaceID,
                    isFullscreen: isFullscreen,
                    index: isFullscreen ? 0 : userIndex,
                    displayID: displayID
                ))
            }
        }

        return result
    }

    /// Returns spaces for the display that currently has the active space.
    /// In multi-monitor setups this filters to just the "main" display so callers
    /// don't accidentally count spaces from a secondary monitor.
    func detectMainDisplaySpaces() -> [DetectedSpace] {
        let all = detectSpaces()
        let currentDisplayID = all.first(where: \.isCurrentSpace)?.displayID
        guard let currentDisplayID else { return all }
        return all.filter { $0.displayID == currentDisplayID }
    }

    /// Convenience: returns just the active space's ID, or 0 if detection fails.
    func currentSpaceID() -> Int {
        detectSpaces().first(where: \.isCurrentSpace)?.spaceID ?? 0
    }

    /// Get the space ID for a given window
    func spaceForWindow(_ windowID: CGWindowID) -> Int? {
        let cid = CGSMainConnectionID()
        let wids = [NSNumber(value: windowID)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(cid, 0x7, wids) as? [Int] else { return nil }
        return spaces.first
    }

    /// Map space ID to desktop name using provided configs
    func desktopName(for spaceID: Int, desktops: [DesktopConfig]) -> String {
        desktops.first(where: { $0.id == spaceID })?.customName ?? "Desktop"
    }
}
