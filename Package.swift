// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    // Core Audio process taps shipped in macOS 14.2. Keeping the deployment
    // target at the actual API floor lets quill run on this Mac (14.7) while
    // still rejecting older systems that cannot capture system audio.
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
    ],
    targets: [
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            linkerSettings: [
                // Embed the app bundle's Info.plist into the binary too, so
                // TCC attributes capture permissions to quill even when it
                // runs outside Quill.app. One plist, one identity.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "quillTests",
            dependencies: ["quill"]
        ),
    ]
)
