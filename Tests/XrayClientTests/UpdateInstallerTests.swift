#if os(macOS)
import XCTest
@testable import XrayClient

/// The update installer replaces the running bundle from a detached script, so
/// nothing it does can be reported back through the process that started it.
/// That makes two things worth proving here: that the app refuses to quit for
/// an install that cannot work, and that the script leaves a readable verdict
/// behind when it does run.
final class UpdateInstallerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-installer-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A directory made read-only by a test cannot be removed while it is.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: scratch.path)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - What the app checks before it quits

    func testTranslocatedBundleIsRefused() {
        let translocated = URL(fileURLWithPath:
            "/private/var/folders/ab/xy/T/AppTranslocation/ABC-123/d/Veil.app")
        XCTAssertEqual(UpdateInstaller.blocker(for: translocated), .translocated)
    }

    func testBundleInAReadOnlyDirectoryIsRefused() throws {
        let parent = scratch.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bundle = try makeBundle(at: parent.appendingPathComponent("Veil.app"),
                                    version: "1.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: parent.path)
        }
        XCTAssertEqual(UpdateInstaller.blocker(for: bundle), .notWritable)
    }

    func testWritableBundleIsAllowed() throws {
        let bundle = try makeBundle(at: scratch.appendingPathComponent("Veil.app"),
                                    version: "1.0.0")
        XCTAssertNil(UpdateInstaller.blocker(for: bundle))
    }

    // MARK: - What the script actually does

    func testScriptSwapsTheBundleAndRecordsSuccess() throws {
        let target = try makeBundle(at: scratch.appendingPathComponent("Veil.app"),
                                    version: "1.0.0")
        let staging = scratch.appendingPathComponent("staging", isDirectory: true)
        let payload = try makeBundle(at: staging.appendingPathComponent("Veil.app"),
                                     version: "2.0.0")

        try runScript(newBundle: payload, target: target, expectedVersion: "2.0.0")

        XCTAssertEqual(try version(of: target), "2.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath(for: target)))
        XCTAssertEqual(UpdateInstaller.lastOutcome(logPath: logPath), .installed("2.0.0"))
    }

    func testScriptRestoresTheOldBundleWhenThePayloadIsGone() throws {
        let target = try makeBundle(at: scratch.appendingPathComponent("Veil.app"),
                                    version: "1.0.0")
        let missing = scratch.appendingPathComponent("nowhere/Veil.app")

        try runScript(newBundle: missing, target: target, expectedVersion: "2.0.0")

        XCTAssertEqual(try version(of: target), "1.0.0",
                       "a failed copy must leave the working app in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupPath(for: target)))
        guard case .failed = UpdateInstaller.lastOutcome(logPath: logPath) else {
            return XCTFail("expected a recorded failure, got \(UpdateInstaller.lastOutcome(logPath: logPath))")
        }
    }

    func testScriptRollsBackWhenTheCopiedBundleIsTheWrongVersion() throws {
        let target = try makeBundle(at: scratch.appendingPathComponent("Veil.app"),
                                    version: "1.0.0")
        let staging = scratch.appendingPathComponent("staging", isDirectory: true)
        // A payload that unpacked to something other than what was offered:
        // the swap must not be reported as an install.
        let payload = try makeBundle(at: staging.appendingPathComponent("Veil.app"),
                                     version: "1.0.0")

        try runScript(newBundle: payload, target: target, expectedVersion: "2.0.0")

        XCTAssertEqual(try version(of: target), "1.0.0")
        guard case .failed = UpdateInstaller.lastOutcome(logPath: logPath) else {
            return XCTFail("a version mismatch must be recorded as a failure")
        }
    }

    func testNoLogMeansNothingToReport() {
        let absent = scratch.appendingPathComponent("never-written.log").path
        XCTAssertEqual(UpdateInstaller.lastOutcome(logPath: absent), .none)
    }

    // MARK: - Helpers

    private var logPath: String {
        scratch.appendingPathComponent("update.log").path
    }

    private func backupPath(for target: URL) -> String {
        target.deletingLastPathComponent()
            .appendingPathComponent("Veil.old.app").path
    }

    /// Runs the generated script to completion, standing in for the app that
    /// would normally have quit by now.
    private func runScript(newBundle: URL, target: URL,
                           expectedVersion: String) throws {
        let text = UpdateInstaller.script(pid: try deadPID(),
                                          newBundle: newBundle,
                                          target: target,
                                          logPath: logPath,
                                          expectedVersion: expectedVersion,
                                          openTool: "/usr/bin/true")
        let url = scratch.appendingPathComponent("install.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = [url.path]
        try bash.run()
        bash.waitUntilExit()
    }

    /// A process id that has already exited, so the script's wait loop falls
    /// straight through instead of waiting on the test runner.
    private func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// The smallest thing `PlistBuddy` and `ditto` will both treat as an app.
    @discardableResult
    private func makeBundle(at url: URL, version: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents,
                                                withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "org.veil.app",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }

    private func version(of bundle: URL) throws -> String? {
        let data = try Data(contentsOf: bundle
            .appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }
}
#endif
