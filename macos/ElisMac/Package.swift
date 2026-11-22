// swift-tools-version: 6.0
import PackageDescription

// What only the Mac builds, on shared ElisCore: the Mac elisctl with the phone relay's Network framework listener and
// Core Bluetooth radio, the session host and the responsibility SPI (linux/bridge's role for Qt).
let package = Package(
    name: "ElisMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "elisctl-mac", targets: ["elisctl-mac"]),
        .library(name: "ElisResponsibility", targets: ["ElisResponsibility"]),
        .executable(name: "elis-session-host", targets: ["elis-session-host"]),
    ],
    dependencies: [.package(path: "../../shared/ElisCore")],
    targets: [
        .target(name: "ElisMacRelay", dependencies: [.product(name: "elisctlKit", package: "ElisCore")]),
        // Info.plist is linked in by the app's Bundle helper executables phase (project.yml), not here:
        // unsafeFlags would make SwiftPM refuse this package as a dependency
        .executableTarget(
            name: "elisctl-mac",
            dependencies: ["ElisMacRelay", .product(name: "elisctlKit", package: "ElisCore")],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ElisMacRelayTests",
            dependencies: [
                "ElisMacRelay",
                "elisctl-mac",
                .product(name: "elisctlKit", package: "ElisCore"),
                .product(name: "ElisCore", package: "ElisCore"),
            ],
            swiftSettings: [.define("ELIS_PLATFORM_ADAPTERS")]
        ),
        .target(name: "ElisResponsibility"),
        .target(name: "SessionHostTrampoline"),
        .target(
            name: "SessionHostRuntime",
            dependencies: ["SessionHostTrampoline", "ElisResponsibility", .product(name: "ElisCore", package: "ElisCore")]
        ),
        .executableTarget(name: "elis-session-host", dependencies: ["SessionHostRuntime"]),
        // The fixtures need a socket client they can copy into a test bundle, which /usr/bin/nc
        // cannot be (see the target's own comment).
        .executableTarget(name: "session-host-test-client"),
        .executableTarget(name: "session-host-pty-probe"),
        .testTarget(name: "SessionHostRuntimeTests",
                    dependencies: ["SessionHostRuntime", "elis-session-host", "session-host-test-client",
                                   "session-host-pty-probe"]),
    ],
    swiftLanguageModes: [.v6]
)
