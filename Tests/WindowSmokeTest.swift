import AppKit
import SwiftUI

@main
struct WindowSmokeTest: App {
    @NSApplicationDelegateAdaptor(KeepAlive.self) private var delegate

    init() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            Self.fail("Timed out waiting for the window test")
        }
    }

    var body: some Scene {
        VeilMainWindow { Probe() }
    }

    nonisolated static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

private final class KeepAlive: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct Probe: View {
    @Environment(\.openWindow) private var openWindow
    private static var started = false

    var body: some View {
        Text("Testing Veil window reuse")
            .padding(40)
            .onAppear {
                guard !Self.started else { return }
                Self.started = true
                Task { await checkWindowLifecycle() }
            }
    }

    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.title == "Veil" && ($0.isVisible || $0.isMiniaturized) }
    }

    private func checkWindowLifecycle() async {
        await settle()
        guard mainWindows.count == 1, let first = mainWindows.first else {
            WindowSmokeTest.fail("Expected one window on launch")
        }
        for _ in 0..<2 {
            openWindow(id: WindowID.main)
            await settle()
            guard mainWindows.count == 1, mainWindows.first === first else {
                WindowSmokeTest.fail("Opening the main window created a duplicate")
            }
        }

        first.miniaturize(nil)
        await settle()
        guard first.isMiniaturized else { WindowSmokeTest.fail("The window did not minimize") }
        openWindow(id: WindowID.main)
        await settle()
        guard mainWindows.count == 1, mainWindows.first === first, !first.isMiniaturized else {
            WindowSmokeTest.fail("Opening the main window did not restore it")
        }

        first.close()
        await settle()
        guard mainWindows.isEmpty else { WindowSmokeTest.fail("The window did not close") }
        openWindow(id: WindowID.main)
        await settle()
        guard mainWindows.count == 1 else {
            WindowSmokeTest.fail("Opening the closed window did not show one main window")
        }
        print("Main window smoke test passed")
        exit(0)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(500))
    }
}
