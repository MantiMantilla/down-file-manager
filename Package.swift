// swift-tools-version: 6.2
import PackageDescription
import Foundation

// With only the Command Line Tools installed (no Xcode), SwiftPM doesn't search the folder that
// holds swift-testing's macro plugin and framework. Point the test targets at them when present.
let clt = "/Library/Developer/CommandLineTools"
let testingPlugins = "\(clt)/usr/lib/swift/host/plugins/testing"
let testingFrameworks = "\(clt)/Library/Developer/Frameworks"
let isCLTOnly = FileManager.default.fileExists(atPath: testingPlugins)
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

let testSwiftSettings: [SwiftSetting] = isCLTOnly
    ? [.unsafeFlags(["-plugin-path", testingPlugins, "-F", testingFrameworks])]
    : []
let testLinkerSettings: [LinkerSetting] = isCLTOnly
    ? [.unsafeFlags(["-F", testingFrameworks, "-Xlinker", "-rpath", "-Xlinker", testingFrameworks])]
    : []

let package = Package(
    name: "Down",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Down", targets: ["Down"]),
    ],
    targets: [
        // Thin C shim over getattrlistbulk(2)/getattrlist(2) buffer parsing.
        .target(name: "CDirent"),
        // Model layer: no AppKit / SwiftUI imports allowed here.
        .target(name: "DownCore", dependencies: ["CDirent"]),
        // ViewModels + AppKit/SwiftUI views.
        .target(name: "DownUI", dependencies: ["DownCore"]),
        .executableTarget(name: "Down", dependencies: ["DownUI", "DownCore"]),
        // Fakes and fixtures shared by the test targets.
        .target(name: "DownTestSupport", dependencies: ["DownCore"]),
        .testTarget(name: "DownCoreTests", dependencies: ["DownCore", "DownTestSupport"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
        .testTarget(name: "DownUITests", dependencies: ["DownUI", "DownCore", "DownTestSupport"],
                    swiftSettings: testSwiftSettings, linkerSettings: testLinkerSettings),
    ]
)
