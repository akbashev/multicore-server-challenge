// swift-tools-version:6.2
// Not for upstream: both carry-less CRC folds against a table CRC at every length, and their time on a feed's length.
import PackageDescription
let package = Package(name: "crccheck", targets: [
    .target(name: "CRCExtensions", path: "Sources/CRCExtensions",
            swiftSettings: [.unsafeFlags(["-enable-builtin-module", "-Xcc", "-mpclmul", "-Xcc", "-msse4.1", "-Ounchecked"])]),
    .target(name: "CRCExtensions512", path: "Sources/CRCExtensions512",
            swiftSettings: [.unsafeFlags(["-enable-builtin-module", "-Xcc", "-mavx512f", "-Xcc", "-mvpclmulqdq", "-Xcc", "-mpclmul", "-Ounchecked"])]),
    .executableTarget(name: "crccheck", dependencies: ["CRCExtensions", "CRCExtensions512"], path: "Sources/crccheck"),
])
