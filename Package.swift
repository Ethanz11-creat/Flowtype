// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "FlowType",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.15"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
    ],
    targets: [
        .executableTarget(
            name: "FlowType",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/flowtype",
            resources: [
                .copy("Resources/tech_terms.json"),
                .copy("Resources/filler_words.json"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/status_bar_icon.png"),
                .copy("Resources/status_bar_icon@2x.png"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]) // 允许使用 @main
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech")
            ]
        ),
        .testTarget(
            name: "FlowTypeTests",
            dependencies: ["FlowType"],
            path: "Tests/FlowTypeTests"
        ),
    ]
)
