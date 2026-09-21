// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AndroidMirroring",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AndroidMirroring",
            path: "Sources/AndroidMirroring",
            resources: [
                .copy("Resources/scrcpy-server")
            ]
        ),
        .testTarget(
            name: "AndroidMirroringTests",
            dependencies: ["AndroidMirroring"],
            path: "Tests/AndroidMirroringTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
