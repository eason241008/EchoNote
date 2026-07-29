// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoNote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EchoNote", targets: ["LectureAssistant"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LectureAssistant",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/LectureAssistant",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "LectureAssistantTests",
            dependencies: ["LectureAssistant"],
            path: "Tests/LectureAssistantTests"
        ),
    ]
)
