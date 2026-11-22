// swift-tools-version: 6.0
import PackageDescription

// The Qt app's C ABI onto ElisCore, so Linux and the Mac share one implementation of host-free logic,
// and the Linux elisctl with the phone relay's TLS listener and BlueZ radio.
let package = Package(
    name: "ElisBridge",
    products: [
        .library(name: "ElisBridge", type: .dynamic, targets: ["ElisBridge"]),
        .executable(name: "elisctl-linux", targets: ["elisctl-linux"]),
    ],
    dependencies: [
        .package(path: "../../shared/ElisCore"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "5.1.2"),
    ],
    targets: [
        .target(name: "ElisBridge", dependencies: [.product(name: "ElisCore", package: "ElisCore")]),
        .target(name: "CElisTLS"),
        .target(name: "CElisBlueZ"),
        .target(
            name: "ElisLinuxRelay",
            dependencies: [.product(name: "elisctlKit", package: "ElisCore"), "CElisTLS", "CElisBlueZ"]
        ),
        .executableTarget(
            name: "elisctl-linux",
            dependencies: ["ElisLinuxRelay", .product(name: "elisctlKit", package: "ElisCore")]
        ),
        .testTarget(
            name: "ElisLinuxRelayTests",
            dependencies: [
                "ElisLinuxRelay",
                "elisctl-linux",
                "CElisTLS",
                .product(name: "elisctlKit", package: "ElisCore"),
                .product(name: "ElisCore", package: "ElisCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.define("ELIS_PLATFORM_ADAPTERS")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
