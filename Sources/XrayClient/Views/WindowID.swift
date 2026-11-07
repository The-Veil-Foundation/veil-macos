import SwiftUI

/// Identifiers for the app's auxiliary windows, in one place so a scene and the
/// `openWindow` call that shows it can never drift apart.
enum WindowID {
    static let main = "main"
    static let about = "about"
    static let update = "update"
    static let routing = "routing"
    static let settings = "settings"
}

/// Opening the main scene by ID raises its single window.
struct VeilMainWindow<Content: View>: Scene {
    @ViewBuilder var content: () -> Content

    var body: some Scene {
        Window("Veil", id: WindowID.main, content: content)
    }
}

/// The two halves of the main window.
enum MainMode: String, CaseIterable, Identifiable {
    /// The server list, and the button that connects.
    case connection
    /// Where those servers came from, and what they are made of.
    case sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "Connection"
        case .sources:    return "Sources"
        }
    }
}
