// swift-tools-version: 6.2
import PackageDescription

// The modules live here; Down.xcodeproj adds a thin app target (App/) that links DownUI and DownCore
// and produces Down.app. `swift build` / `swift test` keep working on the package alone.
let package = Package(
    name: "Down",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DownUI", targets: ["DownUI"]),
        .library(name: "DownCore", targets: ["DownCore"]),
    ],
    targets: [
        // Thin C shim over getattrlistbulk(2)/getattrlist(2) buffer parsing.
        .target(name: "CDirent"),
        // Model layer: no AppKit / SwiftUI imports allowed here.
        .target(name: "DownCore", dependencies: ["CDirent"]),
        // ViewModels + AppKit/SwiftUI views.
        .target(name: "DownUI", dependencies: ["DownCore"]),
        // Fakes and fixtures shared by the test targets.
        .target(name: "DownTestSupport", dependencies: ["DownCore"]),
        .testTarget(name: "DownCoreTests", dependencies: ["DownCore", "DownTestSupport"]),
        .testTarget(name: "DownUITests", dependencies: ["DownUI", "DownCore", "DownTestSupport"]),
    ]
)
