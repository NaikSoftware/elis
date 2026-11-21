// swift-tools-version: 6.0
import PackageDescription

// The Qt app's C ABI onto ElisCore, so Linux and the Mac share one implementation of host-free logic.
let package = Package(
    name: "ElisBridge",
    products: [.library(name: "ElisBridge", type: .dynamic, targets: ["ElisBridge"])],
    dependencies: [.package(path: "../../macos/ElisCore")],
    targets: [.target(name: "ElisBridge", dependencies: [.product(name: "ElisCore", package: "ElisCore")])],
    swiftLanguageModes: [.v6]
)
