// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Metrickle",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Metrickle", targets: ["Metrickle"]),
    ],
    targets: [
        .target(
            name: "Metrickle",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "MetrickleTests", dependencies: ["Metrickle"]),
    ],
    swiftLanguageModes: [.v6]
)
