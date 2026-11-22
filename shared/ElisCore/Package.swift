// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElisCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElisCore", targets: ["ElisCore"]),
        .library(name: "elisctlKit", targets: ["elisctlKit"]),
        .executable(name: "elisctl", targets: ["elisctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "ElisCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .testTarget(name: "ElisCoreTests", dependencies: ["ElisCore"]),
        .target(
            name: "elisctlKit",
            dependencies: [
                "ElisCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // the platform-neutral CLI elis-server ships; the Mac's and Linux's register their relay transports
        .executableTarget(name: "elisctl", dependencies: ["elisctlKit"]),
        // debug-only fixture: it imports elisctlKit @testable, and release builds name their products.
        .executableTarget(name: "session-wait-watchdog-probe", dependencies: ["elisctlKit"]),
        .testTarget(
            name: "elisctlKitTests",
            dependencies: ["elisctlKit", "elisctl", "session-wait-watchdog-probe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
// Foundation's attributed Markdown parser is Darwin only; elis-server parses with swift-markdown instead
package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"))
package.targets[0].dependencies.append(.product(name: "Markdown", package: "swift-markdown"))
// the phone relay: swift-crypto for CryptoKit, qrcodegen for CoreImage's QR filter (the TLS listener and Bluetooth radio live in linux/bridge)
package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto", exact: "5.1.2"))
// zlib for Compression's raw DEFLATE
package.targets += [.target(name: "CQRCode"), .systemLibrary(name: "CZlib")]
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
for target in package.targets where target.name == "elisctlKit" {
    target.dependencies += [crypto, "CQRCode", "CZlib"]
}
for target in package.targets where target.name == "elisctlKitTests" { target.dependencies += [crypto] }
#endif
