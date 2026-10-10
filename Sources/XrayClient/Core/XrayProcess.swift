// macOS-only: this file drives the system proxy / tun2socks / a bundled
// core subprocess, none of which exist on iOS. The iOS build runs Xray
// in-process inside the NetworkExtension instead (see ios/Tunnel).
#if os(macOS)
import Foundation

/// Safe replacement for the SPM-synthesized `Bundle.module`.
///
/// `Bundle.module` is a `static let` whose initializer calls `fatalError(…)`
/// when the `XrayClient_XrayClient.bundle` resource bundle can't be located —
/// so *merely accessing it* hard-crashes the app (e.g. when the .app is run
/// from a copy/volume where the resource bundle didn't come along). This finder
/// performs the same candidate search but returns `nil` instead of trapping.
enum ResourceBundle {
    private final class BundleFinder {}

    static let module: Bundle? = {
        let bundleName = "XrayClient_XrayClient"

        var candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ]

        // Bundle next to the running executable (handy for `swift run`).
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        candidates.append(exeDir)
        candidates.append(exeDir.deletingLastPathComponent())

        for candidate in candidates {
            let url = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let url, let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()
}

/// Locates a bundled (or system) core executable by name.
enum CoreBinary {
    /// Finds an executable named `name` (e.g. "xray" or "sing-box").
    static func locate(_ name: String) -> URL? {
        // 1. SPM resource bundle — where `.copy("Resources/…")` lands.
        if let resourceURL = ResourceBundle.module?.url(forResource: name, withExtension: nil) {
            return resourceURL
        }
        // 2. Main bundle (in case resources are flattened into the app bundle).
        if let resourceURL = Bundle.main.url(forResource: name, withExtension: nil) {
            return resourceURL
        }
        // 3. Next to the running binary (handy for `swift run`).
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let sibling = exeDir.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        // 4. A few common install locations / PATH fallbacks.
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Resolves the executable for a given core engine.
    static func locate(for engine: CoreEngine) -> URL? {
        switch engine {
        case .xray:    return locate("xray")
        case .singbox: return locate("sing-box")
        }
    }
}

/// Locates the bundled (or system) `xray` executable.
enum XrayBinary {
    static func locate() -> URL? { CoreBinary.locate("xray") }
}

/// Manages the lifecycle of the `xray` core subprocess and streams its logs.
final class XrayProcess {
    private var process: Process?
    /// The config the running process was started from. It holds the node's
    /// credentials, so it goes when the process does — `stop()` clears the
    /// termination handler, and that handler used to be the only thing that
    /// removed it, so every server switch left one behind in the temp folder.
    private var configURL: URL?
    private let queue = DispatchQueue(label: "xray.process")

    /// Called on the main queue with each new log line.
    var onLog: (@Sendable (String) -> Void)?
    /// Called on the main queue when the process exits unexpectedly.
    var onExit: (@Sendable (Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    /// Writes the config to a temp file and launches xray with `run -c`.
    /// `assetDir` is exported as `XRAY_LOCATION_ASSET` so geosite:/geoip: rules
    /// can find geoip.dat / geosite.dat.
    func start(configData: Data, binary: URL, assetDir: URL? = nil) throws {
        stop()

        let tmpDir = FileManager.default.temporaryDirectory
        let configURL = tmpDir.appendingPathComponent("xray-config-\(UUID().uuidString).json")
        // Owner-only: it carries the node's UUID or password.
        guard FileManager.default.createFile(atPath: configURL.path, contents: configData,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["run", "-c", configURL.path]
        if let assetDir {
            var env = ProcessInfo.processInfo.environment
            env["XRAY_LOCATION_ASSET"] = assetDir.path
            proc.environment = env
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let logCallback = onLog
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Decoded leniently: a read can end inside a multi-byte character,
            // and the strict initialiser threw the whole chunk away for it.
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { logCallback?(text) }
        }

        let exitCallback = onExit
        proc.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: configURL)
            let status = p.terminationStatus
            DispatchQueue.main.async { exitCallback?(status) }
        }

        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: configURL)
            throw error
        }
        self.process = proc
        self.configURL = configURL
    }

    /// Stops the process. `wait` holds the caller until it is gone, which only
    /// matters when the next core is about to bind the same port.
    func stop(wait: Bool = true) {
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
            self.configURL = nil
        }
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        proc.terminationHandler = nil
        proc.terminate()
        process = nil
        guard wait else { return }
        // Wait briefly for the process to actually go away. A core that is
        // still alive still holds the SOCKS port, and the replacement started
        // right after would fail to bind — which is what made switching
        // servers look slow: the first attempt died and the watchdog retried.
        let deadline = Date().addingTimeInterval(0.5)
        while proc.isRunning, Date() < deadline {
            usleep(10_000) // 10ms
        }
    }
}
#endif
