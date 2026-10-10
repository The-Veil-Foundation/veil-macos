import Foundation
import VeilHelperKit
import os

/// The privileged side of Veil. Runs as root under launchd and answers a fixed
/// set of typed requests — it never receives a command, a path or a script.
///
/// Every method validates its input, does the work synchronously and replies
/// before returning: XPC gives each call its own queue, so there is no thread
/// hop to get wrong and the lock below is the only shared-state discipline
/// needed.
final class HelperService: NSObject, VeilHelperProtocol, @unchecked Sendable {

    private let log = Logger(subsystem: "dev.local.veil.helper", category: "tunnel")
    private let lock = NSLock()

    private let device = "utun123"
    private let tunAddress = "198.18.0.1"
    private let tunPeer = "198.18.0.2"
    private let tunGateway = "198.18.0.1"
    private let mtu = 1500

    private var state: TunnelState?
    private var tun2socks: Process?
    private var core: Process?

    /// Largest a log may grow to before it is emptied in place.
    private static let logCap: UInt64 = 4 * 1024 * 1024
    /// Checks the log sizes while a tunnel runs. The cap used to be applied only
    /// when a process started, so a core left up for a week at debug level
    /// wrote until the disk said no.
    private var logTrimmer: DispatchSourceTimer?

    override init() {
        super.init()
        recoverOrphanedTunnel()
        startLogTrimmer()
    }

    private func startLogTrimmer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Generous leeway: nothing depends on when exactly this runs, and it
        // should never be the reason the machine wakes up.
        timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(60))
        timer.setEventHandler {
            HelperService.trimLog(VeilHelperInfo.coreLogPath)
            HelperService.trimLog(VeilHelperInfo.logPath)
        }
        timer.resume()
        logTrimmer = timer
    }

    /// Empties `path` once it passes the cap. Safe while a process is writing
    /// to it: logs are opened with `O_APPEND`, so the writer's next line lands
    /// at the new end instead of leaving a hole the size of the old file.
    private static func trimLog(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, UInt64(info.st_size) > logCap else { return }
        truncate(path, 0)
    }

    // MARK: - VeilHelperProtocol

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(VeilHelperInfo.protocolVersion)
    }

    func startTunnel(socksHost: String,
                     socksPort: Int,
                     serverIPs: [String],
                     dnsServers: [String],
                     reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }

        guard HelperValidation.isLoopback(socksHost) else {
            return reply("SOCKS host must be the loopback address")
        }
        guard HelperValidation.isPort(socksPort) else {
            return reply("SOCKS port out of range")
        }
        let servers = HelperValidation.sanitizeAddresses(serverIPs)
        let resolvers = HelperValidation.sanitizeResolvers(dnsServers)

        // Already up: this is a server switch, so only re-pin.
        if isTunnelRunning() {
            repin(servers)
            return reply(nil)
        }

        guard let original = NetworkOps.defaultRoute() else {
            return reply("Could not determine the current default gateway")
        }
        log.info("bringing tunnel up on \(self.device, privacy: .public)")

        var newState = TunnelState(device: device,
                                   originalGateway: original.gateway,
                                   originalInterface: original.interface)

        guard let process = launchTun2socks(socksHost: socksHost,
                                            socksPort: socksPort,
                                            interface: original.interface) else {
            return reply("tun2socks is not installed alongside the helper")
        }
        tun2socks = process
        newState.tun2socksPID = process.processIdentifier

        guard waitForInterface(process) else {
            let detail = lastLogLine().map { ": \($0)" } ?? ""
            process.terminate()
            tun2socks = nil
            return reply("\(device) did not come up\(detail)")
        }

        guard NetworkOps.configureInterface(device, address: tunAddress,
                                            peer: tunPeer, mtu: mtu) else {
            process.terminate()
            tun2socks = nil
            return reply("Could not configure \(device)")
        }

        for ip in servers {
            NetworkOps.deleteHostRoute(ip)
            NetworkOps.addHostRoute(ip, gateway: original.gateway)
        }
        newState.pinnedIPs = servers
        NetworkOps.addSplitDefaults(gateway: tunGateway)

        if !resolvers.isEmpty {
            for service in NetworkOps.networkServices() {
                newState.savedDNS[service] = NetworkOps.dnsServers(for: service)
                NetworkOps.setDNSServers(resolvers, for: service)
            }
        }

        state = newState
        newState.save()
        log.info("tunnel up, pinned \(servers.count, privacy: .public) server address(es)")
        reply(nil)
    }

    func stopTunnel(reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        teardown()
        reply(nil)
    }

    func pinServerIPs(_ ips: [String], reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard state != nil else { return reply("The tunnel is not up") }
        repin(HelperValidation.sanitizeAddresses(ips))
        reply(nil)
    }

    func addProbeRoutes(_ ips: [String], reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var current = state else { return reply("The tunnel is not up") }
        let wanted = HelperValidation.sanitizeAddresses(ips)
        for ip in wanted where !current.pinnedIPs.contains(ip) {
            NetworkOps.addHostRoute(ip, gateway: current.originalGateway)
            if !current.probeIPs.contains(ip) { current.probeIPs.append(ip) }
        }
        state = current
        current.save()
        reply(nil)
    }

    func removeProbeRoutes(reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var current = state else { return reply(nil) }
        for ip in current.probeIPs { NetworkOps.deleteHostRoute(ip) }
        current.probeIPs = []
        state = current
        current.save()
        reply(nil)
    }

    func tunnelStatus(reply: @escaping (Bool, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        reply(isTunnelRunning(), state?.device)
    }

    // MARK: - Native core (sing-box owns the TUN)

    func startCore(config: Data, reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if isCoreRunning() {
            return reply(restartCore(with: config))
        }
        // A tun2socks tunnel and a native core cannot both own the routes.
        if isTunnelRunning() { teardown() }
        reply(launchCore(with: config))
    }

    func reloadCore(config: Data, reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard isCoreRunning() else { return reply(launchCore(with: config)) }
        reply(restartCore(with: config))
    }

    func stopCore(reply: @escaping (String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        stopCoreProcess()
        reply(nil)
    }

    func coreStatus(reply: @escaping (Bool, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        reply(isCoreRunning(), lastLogLines(VeilHelperInfo.coreLogPath, count: 20))
    }

    // MARK: - Core internals

    /// Validates, writes and starts the core. Returns nil on success.
    ///
    /// The configuration arrives as bytes and is written by the helper, into a
    /// filename the helper chose: root never opens a path the app named.
    private func launchCore(with config: Data) -> String? {
        let binary = VeilHelperInfo.singBoxPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return "The routing core is not installed alongside the helper. Reinstall it in Settings."
        }

        let sanitized: Data
        do {
            sanitized = try CoreConfigGuard.sanitize(
                config,
                cachePath: VeilHelperInfo.coreCachePath,
                workingDirectory: VeilHelperInfo.coreWorkingDirectory)
        } catch {
            log.error("refused core config: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }

        guard writeRootOwned(sanitized, to: VeilHelperInfo.coreConfigPath) else {
            return "Could not write the core configuration"
        }
        guard ensureWorkingDirectory() else {
            return "Could not create the core working directory"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "run",
            "-c", VeilHelperInfo.coreConfigPath,
            "-D", VeilHelperInfo.coreWorkingDirectory
        ]
        attachLog(VeilHelperInfo.coreLogPath, to: process)
        let devicesBefore = NetworkOps.tunnelDevices()
        do {
            try process.run()
        } catch {
            log.error("core failed to start: \(error.localizedDescription, privacy: .public)")
            return "The routing core could not be started: \(error.localizedDescription)"
        }

        // A configuration the core rejects is fatal within milliseconds, so a
        // short wait turns "it is not working" into the core's own message.
        if !survivesStartup(process, newDeviceSince: devicesBefore) {
            let detail = lastLogLines(VeilHelperInfo.coreLogPath, count: 3).map { ": \($0)" } ?? ""
            return "The routing core exited on startup\(detail)"
        }

        core = process
        var newState = state ?? TunnelState(device: "",
                                            originalGateway: "",
                                            originalInterface: "")
        newState.corePID = process.processIdentifier
        state = newState
        newState.save()
        log.info("routing core up (pid \(process.processIdentifier, privacy: .public))")
        return nil
    }

    /// Swaps the configuration by restarting the core.
    ///
    /// sing-box has no in-place reload, and doing it as stop-then-start means a
    /// bad config takes the tunnel down with it — so the new configuration is
    /// validated before anything is stopped.
    private func restartCore(with config: Data) -> String? {
        do {
            _ = try CoreConfigGuard.sanitize(
                config,
                cachePath: VeilHelperInfo.coreCachePath,
                workingDirectory: VeilHelperInfo.coreWorkingDirectory)
        } catch {
            return error.localizedDescription
        }
        stopCoreProcess()
        return launchCore(with: config)
    }

    private func stopCoreProcess() {
        if let process = core, process.isRunning {
            process.terminate()
            _ = waitForExit(process, timeout: 5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        } else if let pid = state?.corePID, pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
        core = nil
        if var current = state {
            current.corePID = nil
            state = current
            if current.corePID == nil && current.tun2socksPID == nil
                && current.pinnedIPs.isEmpty && current.probeIPs.isEmpty
                && current.savedDNS.isEmpty {
                state = nil
                TunnelState.clear()
            } else {
                current.save()
            }
        }
        log.info("routing core down")
    }

    private func isCoreRunning() -> Bool {
        if let process = core, process.isRunning { return true }
        if let pid = state?.corePID, pid > 0, kill(pid, 0) == 0 { return true }
        return false
    }

    /// True when the core is up.
    ///
    /// The tunnel device the core creates is the first signal: it appears
    /// within a few hundred milliseconds of a good start, so watching for it
    /// beats sitting out a fixed delay. It is not the last signal, though —
    /// the interface is created *before* the routes that make it useful are
    /// installed, and a core that fails on `auto_route` is still alive and
    /// still holding a `utunN` at that instant. Returning there is how "the
    /// tunnel is up" ends up on screen over a tunnel that carries nothing, so
    /// the device only starts a short grace period, and the answer is whether
    /// the core is still running at the end of it.
    private func survivesStartup(_ process: Process, newDeviceSince before: Set<String>) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        var confirmBy: Date?
        while Date() < deadline {
            if !process.isRunning { return false }
            if confirmBy == nil,
               !NetworkOps.tunnelDevices().subtracting(before).isEmpty {
                confirmBy = min(Date().addingTimeInterval(1), deadline)
            }
            if let confirmBy, Date() >= confirmBy { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if confirmBy == nil {
            // Still running but no device of its own: unusual, and not worth
            // calling a failure — the core is alive and says why in its log.
            log.info("core is up but no new tunnel device appeared")
        }
        return process.isRunning
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !process.isRunning
    }

    private func ensureWorkingDirectory() -> Bool {
        let fm = FileManager.default
        let path = VeilHelperInfo.coreWorkingDirectory
        if !fm.fileExists(atPath: path) {
            guard (try? fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else {
                return false
            }
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return true
    }

    /// Writes root-owned, 0600, replacing whatever was there.
    private func writeRootOwned(_ data: Data, to path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            guard (try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])) != nil else {
                return false
            }
        } else {
            guard fm.createFile(atPath: path, contents: data,
                                attributes: [.posixPermissions: 0o600]) else { return false }
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    /// Sends a process's output to a root-owned 0600 log beside the helper.
    private func attachLog(_ path: String, to process: Process) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        // A log that grows without bound is its own outage. Start fresh when it
        // gets large rather than rotating: nothing here is worth keeping.
        HelperService.trimLog(path)
        // Append mode, so the log can be emptied in place while the process
        // keeps writing to it.
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CLOEXEC)
        if descriptor >= 0 {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            process.standardOutput = handle
            process.standardError = handle
        }
    }

    /// Last `count` non-empty lines of a log, for reporting a failure the app
    /// cannot read itself.
    private func lastLogLines(_ path: String, count: Int) -> String? {
        guard let text = HelperService.logTail(path) else { return nil }
        let lines = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(count)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// The last 32 KB of a log, decoded leniently.
    ///
    /// The app asks for the core's tail every couple of seconds while its log
    /// pane is open. Reading the whole file for that — up to the cap, megabytes
    /// at debug level — and splitting all of it into lines was the single most
    /// expensive thing the helper did.
    private static func logTail(_ path: String, bytes: UInt64 = 32 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > bytes ? size - bytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A cut into the middle of the file starts on half a line.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    // MARK: - Internals

    private func isTunnelRunning() -> Bool {
        guard state != nil else { return false }
        if let process = tun2socks, process.isRunning { return true }
        if let pid = state?.tun2socksPID, pid > 0, kill(pid, 0) == 0 { return true }
        return false
    }

    private func repin(_ ips: [String]) {
        guard var current = state else { return }
        for ip in ips where !current.pinnedIPs.contains(ip) {
            NetworkOps.addHostRoute(ip, gateway: current.originalGateway)
            current.pinnedIPs.append(ip)
        }
        // A switch can leave the split defaults behind if the route table was
        // reshuffled (sleep/wake, Wi-Fi change), so reassert them.
        NetworkOps.addSplitDefaults(gateway: tunGateway)
        state = current
        current.save()
    }

    private func launchTun2socks(socksHost: String, socksPort: Int,
                                 interface: String) -> Process? {
        let binary = VeilHelperInfo.tun2socksPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Tun2socksArguments.build(device: device,
                                                     socksHost: socksHost,
                                                     socksPort: socksPort,
                                                     interface: interface)
        // The log lives next to the helper (root-owned, 0600) rather than in
        // /tmp, where anything could read or pre-create it.
        let logPath = VeilHelperInfo.logPath
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            return process
        } catch {
            log.error("tun2socks failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func waitForInterface(_ process: Process) -> Bool {
        for _ in 0..<25 {
            if NetworkOps.interfaceExists(device) { return true }
            // A tun2socks that rejected its arguments is already gone; waiting
            // out the full five seconds only delays the error.
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Last non-empty line tun2socks wrote, so a failure to start says why
    /// instead of only saying that the interface never appeared.
    private func lastLogLine() -> String? {
        guard let text = HelperService.logTail(VeilHelperInfo.logPath) else { return nil }
        let line = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        return String(line.prefix(300))
    }

    /// Undoes everything recorded in the state, in the reverse order it was
    /// applied. Safe to call when nothing is up.
    private func teardown() {
        let current = state ?? TunnelState.load()

        stopCoreProcess()
        NetworkOps.removeSplitDefaults()

        if let current {
            for ip in current.pinnedIPs + current.probeIPs {
                NetworkOps.deleteHostRoute(ip)
            }
            for (service, servers) in current.savedDNS {
                NetworkOps.setDNSServers(servers, for: service)
            }
        }

        if let process = tun2socks, process.isRunning {
            process.terminate()
        } else if let pid = current?.tun2socksPID, pid > 0 {
            kill(pid, SIGTERM)
        }
        tun2socks = nil
        state = nil
        TunnelState.clear()
        log.info("tunnel down")
    }

    /// A helper that was killed while a tunnel was up leaves the machine with
    /// no route to the internet. On startup, put it back.
    private func recoverOrphanedTunnel() {
        guard let orphan = TunnelState.load() else { return }
        log.info("recovering orphaned tunnel from a previous run")
        state = orphan
        lock.lock()
        teardown()
        lock.unlock()
    }
}
