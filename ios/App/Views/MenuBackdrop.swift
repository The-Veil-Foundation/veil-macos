import SwiftUI

/// Whether a long-press menu is up, so the whole app behind it can be blurred.
///
/// iOS 26 lays only a faint frost behind a context menu, and SwiftUI offers no
/// way to change it or to hear that a menu opened. A preview view, though, is
/// on screen exactly as long as its menu is, so previews report through here.
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

extension View {
    /// For a context-menu preview: blurs the app behind it while it shows.
    /// The backdrop is passed in, since a preview inherits no environment.
    func liftsMenuBackdrop(_ backdrop: MenuBackdrop) -> some View {
        onAppear { backdrop.open() }
            .onDisappear { backdrop.close() }
    }
}
