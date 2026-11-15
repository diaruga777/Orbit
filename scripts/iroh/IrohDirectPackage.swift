// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IrohDirect",
    platforms: [.iOS("17.5"), .macOS("15.0")],
    products: [.library(name: "IrohLib", targets: ["IrohLib", "Iroh"])],
    targets: [
        .target(name: "IrohLib", dependencies: ["Iroh"], linkerSettings: [
            .linkedFramework("SystemConfiguration"),
            .linkedFramework("Network"),
            .linkedFramework("CoreWLAN", .when(platforms: [.macOS]))
        ]),
        .binaryTarget(name: "Iroh", path: "Iroh.xcframework")
    ]
)
