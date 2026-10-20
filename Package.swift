// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Orbit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .library(name: "OrbitMac", targets: ["OrbitMac"]),
        .library(name: "OrbitUI", targets: ["OrbitUI"]),
        .library(name: "OrbitTransport", targets: ["OrbitTransport"]),
        .library(name: "OrbitHost", targets: ["OrbitHost"]),
        .executable(name: "OrbitMacApp", targets: ["OrbitMacApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", exact: "1.1.0"),
        .package(url: "https://github.com/simonbs/Runestone.git", exact: "0.5.2"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages.git", exact: "0.1.9"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0")
    ],
    targets: [
        .binaryTarget(name: "COrbitNet", path: "Vendor/OrbitNet.xcframework"),
        .target(name: "OrbitWire"),
        .target(name: "OrbitTransport", dependencies: ["OrbitWire", "OrbitCore", "COrbitNet", .product(name: "IrohLib", package: "iroh-ffi")], linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "OrbitHost", dependencies: ["OrbitCore", "OrbitMac", "OrbitTransport", "OrbitWire"]),
        .executableTarget(name: "OrbitMacApp", dependencies: ["OrbitHost", "OrbitCore"]),
        .target(name: "OrbitCore"),
        .target(name: "OrbitMac", dependencies: ["OrbitCore"], resources: [.copy("Resources/BuildServer")]),
        .target(name: "OrbitUI", dependencies: ["OrbitCore",
            .product(name: "Runestone", package: "Runestone", condition: .when(platforms: [.iOS])),
            .product(name: "SwiftParser", package: "swift-syntax", condition: .when(platforms: [.iOS])),
            .product(name: "SwiftParserDiagnostics", package: "swift-syntax", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            .product(name: "TreeSitterCRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS]))
        ], resources: [.copy("Resources/Acknowledgements.txt")]),
        .testTarget(name: "OrbitTests", dependencies: ["OrbitCore", "OrbitMac", "OrbitHost", "OrbitTransport", "OrbitWire"])
    ], swiftLanguageModes: [.v5])
