// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapitoConnectionKit",
    platforms: [.macOS(.v13), .iOS("27.0")],
    products: [.library(name: "TapitoConnectionKit", targets: ["TapitoConnectionKit"])],
    targets: [.target(name: "TapitoConnectionKit"), .testTarget(name: "TapitoConnectionKitTests", dependencies: ["TapitoConnectionKit"])],
    swiftLanguageModes: [.v5]
)
