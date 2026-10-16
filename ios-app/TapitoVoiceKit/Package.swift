// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapitoVoiceKit",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [
        .library(name: "TapitoVoiceCore", targets: ["TapitoVoiceCore"]),
        .library(name: "TapitoVoiceAudio", targets: ["TapitoVoiceAudio"])
    ],
    targets: [
        .target(name: "TapitoVoiceCore"),
        .target(name: "TapitoVoiceAudio", dependencies: ["TapitoVoiceCore"]),
        .testTarget(name: "TapitoVoiceCoreTests", dependencies: ["TapitoVoiceCore"])
    ],
    swiftLanguageModes: [.v5]
)
