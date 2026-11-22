// swift-tools-version: 6.0
import PackageDescription

// elis-server, the Linux host a Mac's remote window attaches to, on shared ElisCore.
let package = Package(
    name: "ElisServer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "elis-server", targets: ["elis-server"])],
    dependencies: [
        .package(path: "../shared/ElisCore"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "ElisServerKit", dependencies: [.product(name: "ElisCore", package: "ElisCore")]),
        .executableTarget(
            name: "elis-server",
            dependencies: ["ElisServerKit", .product(name: "ElisCore", package: "ElisCore"),
                           .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "ElisServerTests", dependencies: ["ElisServerKit", "elis-server"]),
    ],
    swiftLanguageModes: [.v6]
)
