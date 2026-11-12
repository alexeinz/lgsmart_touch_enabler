// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "touchd",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TouchCore", targets: ["TouchCore"]),
        .executable(name: "touchd", targets: ["touchd"]),
        .executable(name: "TouchdApp", targets: ["TouchdApp"]),
    ],
    targets: [
        // Pure logic + HID/CoreGraphics glue, shared by the CLI and the app.
        .target(
            name: "TouchCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ApplicationServices")]
        ),
        // Headless command-line daemon (debugging, LaunchAgent use).
        .executableTarget(name: "touchd", dependencies: ["TouchCore"]),
        // Menu-bar app with the settings UI. Bundled into Touchd.app by scripts/build-app.sh.
        .executableTarget(name: "TouchdApp", dependencies: ["TouchCore"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore"]),
    ]
)
