// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "LangStream",
    platforms: [
        .macOS(.v14) // 设置支持的系统版本
    ],
    targets: [
        .executableTarget(
            name: "LangStream",
            dependencies: [],
            path: "Sources/langstream",
            resources: [
                .copy("Resources/tech_terms.json"),
                .copy("Resources/filler_words.json")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]) // 允许使用 @main
            ]
        ),
    ]
)
