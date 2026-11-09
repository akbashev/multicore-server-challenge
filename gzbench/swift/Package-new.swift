// swift-tools-version:6.2
// Not for upstream: million's new Gzip with its CRCExtensions and Syscalls (copied in by the workflow), with the
// submission's own flags, and the timing loop.
import PackageDescription

#if arch(x86_64)
let crcFlags = ["-enable-builtin-module", "-Xcc", "-mpclmul", "-Xcc", "-msse4.1"]
#else
let crcFlags: [String] = []
#endif

let package = Package(
    name: "sbench",
    targets: [
        .target(name: "Syscalls", path: "Sources/Syscalls", swiftSettings: [.enableExperimentalFeature("Extern")]),
        .target(name: "CRCExtensions", path: "Sources/CRCExtensions",
                swiftSettings: [.unsafeFlags(crcFlags), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .target(name: "Gzip", dependencies: ["Syscalls", "CRCExtensions"], path: "Sources/Gzip",
                swiftSettings: [.unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release))]),
        .executableTarget(name: "sbench", dependencies: ["Gzip"], path: "Sources/sbench"),
    ]
)
