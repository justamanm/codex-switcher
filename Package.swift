// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexSwitcherCore", targets: ["CodexSwitcherCore"]),
        .executable(name: "CodexSwitcher", targets: ["CodexSwitcher"]),
    ],
    targets: [
        .target(name: "CodexSwitcherCore"),
        .executableTarget(
            name: "CodexSwitcher",
            dependencies: ["CodexSwitcherCore"]
        ),
        .executableTarget(
            name: "CodexSwitcherCoreChecks",
            dependencies: ["CodexSwitcherCore"]
        ),
    ]
)
