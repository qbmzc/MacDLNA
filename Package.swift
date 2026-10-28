// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDLNA",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacDLNA",
            targets: ["MacDLNA"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacDLNA",
            dependencies: [],
            path: "Sources/MacDLNA"
        ),
        .testTarget(name: "MacDLNATests", dependencies: ["MacDLNA"])
    ]
)
