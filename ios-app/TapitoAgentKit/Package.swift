// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TapitoAgentKit",
    platforms: [.macOS(.v13), .iOS("27.0")],
    products: [
        .library(name: "TapitoAgentCore", targets: ["TapitoAgentCore"]),
        .library(name: "TapitoAgentSwiftAgentKit", targets: ["TapitoAgentSwiftAgentKit"])
    ],
    dependencies: [.package(path: "../Vendor/SwiftAgentKit"), .package(path: "../ProviderKit")],
    targets: [
        .target(name: "TapitoAgentCore"),
        .target(name: "TapitoAgentSwiftAgentKit", dependencies: ["TapitoAgentCore",
            .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
            .product(name: "ProviderCore", package: "ProviderKit")]),
        .testTarget(name: "TapitoAgentCoreTests", dependencies: ["TapitoAgentCore", "TapitoAgentSwiftAgentKit", .product(name: "SwiftAgentKit", package: "SwiftAgentKit"), .product(name: "ProviderCore", package: "ProviderKit")])
    ], swiftLanguageModes: [.v5]
)
