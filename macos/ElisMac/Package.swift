// swift-tools-version: 6.0
import PackageDescription

// The Mac elisctl: the shared CLI with the phone relay's Network framework listener and Core Bluetooth radio.
let package = Package(
    name: "ElisMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "elisctl-mac", targets: ["elisctl-mac"])],
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
    ],
    swiftLanguageModes: [.v6]
)
