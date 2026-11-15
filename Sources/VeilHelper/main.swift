import Foundation
import Security
import VeilHelperKit
import os

/// Entry point of the privileged helper.
///
/// launchd starts this as root on demand and it stays up for as long as a
/// tunnel is running, because it owns the state needed to put the machine's
/// routes and DNS back.

private let bootLog = Logger(subsystem: "org.veil.app.helper", category: "boot")

/// Reads the code-signing requirement the connecting app has to satisfy.
///
/// The file is written by the installer and lives in a root-owned directory.
/// It is only trusted when root owns it and nobody else can write it — if the
/// user could edit it, it would authorise nothing.
private func loadClientRequirement() -> String? {
    let path = VeilHelperInfo.clientRequirementPath
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        bootLog.error("no client requirement at \(path, privacy: .public)")
        return nil
    }
    guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0 else {
        bootLog.error("client requirement is not owned by root")
        return nil
    }
    guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.int32Value,
          permissions & 0o022 == 0 else {
        bootLog.error("client requirement is group- or world-writable")
        return nil
    }
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let requirement = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requirement.isEmpty else { return nil }

    // `setCodeSigningRequirement` raises rather than returning an error when the
    // string does not parse, so it is checked here first.
    var parsed: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
        bootLog.error("client requirement does not parse")
        return nil
    }
    return requirement
}

/// Accepts connections only from the app the installer pinned.
private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    private let service = HelperService()
    private let requirement: String?
    private let log = Logger(subsystem: "org.veil.app.helper", category: "xpc")

    init(requirement: String?) {
        self.requirement = requirement
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Fail closed: no pinned requirement, no clients.
        guard let requirement else {
            log.error("refusing connection: no client requirement installed")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VeilHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate(requirement: loadClientRequirement())
private let listener = NSXPCListener(machServiceName: VeilHelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
bootLog.info("helper \(VeilHelperInfo.protocolVersion, privacy: .public) listening")
RunLoop.main.run()
