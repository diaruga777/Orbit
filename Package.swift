// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Orbit", platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "OrbitWidgets", targets: ["OrbitWidgets"]),
        .library(name: "OrbitWidgetUI", targets: ["OrbitWidgetUI"]),
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .library(name: "OrbitMac", targets: ["OrbitMac"]),
        .library(name: "OrbitRefresh", targets: ["OrbitRefresh"]),
        .library(name: "OrbitUI", targets: ["OrbitUI"]),
        .library(name: "OrbitTransport", targets: ["OrbitTransport"]),
        .library(name: "OrbitHost", targets: ["OrbitHost"]),
        .executable(name: "OrbitMacApp", targets: ["OrbitMacApp"])
    ],
    dependencies: [
        .package(path: "Vendor/DeviceGateway"),
        .package(url: "https://github.com/SideStore/SideSign.git", revision: "752d1ef602aa792a432ffa1e71646dc1ecf7363c"),
        .package(url: "https://github.com/n0-computer/iroh-ffi.git", exact: "1.1.0"),
        .package(url: "https://github.com/simonbs/Runestone.git", exact: "0.5.2"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages.git", exact: "0.1.9"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0")
    ],
    targets: [
        .binaryTarget(name: "COrbitNet", path: "Vendor/OrbitNet.xcframework"),
        .target(name: "OrbitWire"),
        .target(name: "OrbitTransport", dependencies: ["OrbitWire", "OrbitCore", "COrbitNet", .product(name: "IrohLib", package: "iroh-ffi")], linkerSettings: [.linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "OrbitHost", dependencies: ["OrbitWidgets", "OrbitCore", "OrbitMac", "OrbitTransport", "OrbitWire"]),
        .executableTarget(name: "OrbitMacApp", dependencies: ["OrbitHost", "OrbitCore"]),
        .target(name: "OrbitWidgets"),
        .target(name: "OrbitWidgetUI", dependencies: ["OrbitWidgets"]),
        .testTarget(name: "OrbitWidgetTests", dependencies: ["OrbitWidgets"]),
        .target(name: "OrbitCore"),
        .target(name: "OrbitRefresh", dependencies: ["OrbitCore", .product(name: "SideSign", package: "SideSign"), .product(name: "IdeviceGateway", package: "DeviceGateway")]),
        .testTarget(name: "OrbitRefreshTests", dependencies: ["OrbitRefresh", .product(name: "SideSign", package: "SideSign"), .product(name: "IdeviceGateway", package: "DeviceGateway")]),
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
