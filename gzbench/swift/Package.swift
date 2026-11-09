// swift-tools-version:6.2
// Not for upstream: million's Gzip module (copied in by the workflow), with its own flags, and a timing loop.
import PackageDescription

let package = Package(
    name: "sbench",
    targets: [
        .target(name: "Gzip", path: "Sources/Gzip",
                swiftSettings: [.unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release))]),
        .executableTarget(name: "sbench", dependencies: ["Gzip"], path: "Sources/sbench"),
    ]
)
