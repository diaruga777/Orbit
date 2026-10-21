// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LunaDeviceGateway", platforms: [.iOS(.v26), .macOS(.v15)],
 products: [.library(name: "IdeviceGateway", targets: ["IdeviceGateway"])],
 dependencies: [.package(path: "Common")], targets: [
 .binaryTarget(name: "IDevice", path: "IDevice.xcframework"),
 .target(name: "DeviceGatewayAPI", dependencies: [.product(name: "MinimuxerCommon", package: "Common")], path: ".", exclude: ["idevice", "Common", "LICENSE", "UPSTREAM.md", "IDevice.xcframework"], sources: ["BaseDeviceGateway.swift", "DeviceGatewayAPI.swift", "DeviceGatewayError.swift", "DeviceGatewayLogging.swift"]),
 .target(name: "IdeviceGateway", dependencies: ["DeviceGatewayAPI", "IDevice", .product(name: "MinimuxerCommon", package: "Common")], path: "idevice")
 ], swiftLanguageModes: [.v5])
