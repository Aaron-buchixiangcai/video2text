// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Video2Text",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Video2Text",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Video2Text"
        ),
    ]
)
