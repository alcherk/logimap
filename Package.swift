// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "logimap",
    targets: [
        .executableTarget(
            name: "logimap",
            path: "Sources/logimap"
        ),
        .testTarget(
            name: "logimapTests",
            dependencies: ["logimap"],
            path: "Tests/logimapTests"
        ),
    ]
)
