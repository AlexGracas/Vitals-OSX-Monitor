// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vitals",
            path: "Sources/Vitals",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
