import Foundation

/// `Veil mcp` serves the Model Context Protocol on stdio; anything else is the
/// app. Decided before AppKit starts, so the bridge never shows a Dock icon or
/// trips the single-window start-up of the real app.
@main
enum Entry {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "mcp" {
            MCPBridge.run()
        }
        XrayClientApp.main()
    }
}
