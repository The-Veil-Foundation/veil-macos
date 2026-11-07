// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XrayClient",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Protocol and validation shared by the app and the privileged helper.
        // Kept tiny on purpose: it is the only code that exists on both sides
        // of the privilege boundary.
        .target(
            name: "VeilHelperKit",
            path: "Sources/VeilHelperKit"
        ),
        // The privileged helper itself — a launchd daemon that runs as root and
        // accepts a fixed set of typed commands from the app.
        .executableTarget(
            name: "VeilHelper",
            dependencies: ["VeilHelperKit"],
            path: "Sources/VeilHelper"
        ),
        .executableTarget(
            name: "XrayClient",
            dependencies: ["VeilHelperKit"],
            path: "Sources/XrayClient",
            // tun2socks runs inside the privileged helper, not the app, so the
            // packaging scripts copy it next to the helper instead.
            exclude: ["Resources/tun2socks"],
            resources: [
                .copy("Resources/xray"),
                .copy("Resources/sing-box")
            ]
        ),
        .testTarget(
            name: "XrayClientTests",
            dependencies: ["XrayClient", "VeilHelperKit"],
            path: "Tests/XrayClientTests"
        )
    ]
)
