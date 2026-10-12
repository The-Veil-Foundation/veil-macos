import SwiftUI

/// Whether a long-press menu is up, so the whole app behind it can be blurred.
///
/// iOS 26 lays only a faint frost behind a context menu. The row menus report
/// here when they open and close, and the root blurs the app while one is up.
@Observable @MainActor
final class MenuBackdrop {
    /// A count rather than a flag: one preview can appear before the last one
    /// has finished disappearing.
    private var depth = 0

    var isOpen: Bool { depth > 0 }

    func open() { depth += 1 }
    func close() { depth = max(0, depth - 1) }
    func reset() { depth = 0 }
}
