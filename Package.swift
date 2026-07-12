// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ButterClassifier",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ButterClassifier",
            dependencies: ["Yams"],
            path: "Sources/ButterClassifier",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/default-tagzone-preset.json"),
                .copy("Resources/tag-token-rules.json"),
                .copy("Resources/proc-routines.json"),
                .copy("Resources/default-proc-presets.json"),
            ]
        )
    ]
)
