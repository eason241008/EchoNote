// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoNote",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "EchoNote", targets: ["LectureAssistant"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LectureAssistant",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
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
