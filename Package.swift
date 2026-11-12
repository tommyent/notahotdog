// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotAHotDog",
    // Info.plist asks for macOS 27.3; the SDK in Xcode 27.2 accepts deployment targets up to 27.2.
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(
            name: "NAHDTrap",
            path: "Sources/NAHDTrap",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "NotAHotDog",
            dependencies: ["NAHDTrap", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            exclude: ["NAHDTrap"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework sits in the app's Contents/Frameworks (build.sh)
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
