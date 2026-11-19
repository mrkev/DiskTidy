// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "disktidy-scan", targets: ["disktidy-scan"]),
    ],
    targets: [
        .target(name: "ScanKit"),
        .executableTarget(name: "disktidy-scan", dependencies: ["ScanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
    ]
)
