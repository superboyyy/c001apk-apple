// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoolapkKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoolapkKit", targets: ["CoolapkKit"]),
    ],
    targets: [
        .target(name: "CoolapkKit"),
        .executableTarget(name: "coolapk-probe", dependencies: ["CoolapkKit"]),
        .testTarget(
            name: "CoolapkKitTests",
            dependencies: ["CoolapkKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
