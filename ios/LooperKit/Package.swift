// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LooperKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LooperKit", targets: ["LooperKit"]),
    ],
    targets: [
        .target(name: "LooperKit"),
        .testTarget(name: "LooperKitTests", dependencies: ["LooperKit"]),
    ]
)
