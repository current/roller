// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Roller",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RollerApp", targets: ["RollerApp"]),
        .executable(name: "roller", targets: ["roller"]),
        .library(name: "RollerCore", targets: ["RollerCore"]),
    ],
    targets: [
        // Pure, platform-independent logic: the strip model, layout geometry,
        // springs, configuration and the TOML codec. Fully unit tested.
        .target(name: "RollerCore"),
        // The menu bar app: Accessibility, hotkeys, gestures, overlays, settings UI.
        .executableTarget(
            name: "RollerApp",
            dependencies: ["RollerCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Command line client that talks to the running app over a Unix socket.
        .executableTarget(name: "roller", dependencies: ["RollerCore"]),
        .testTarget(name: "RollerCoreTests", dependencies: ["RollerCore"]),
    ]
)
