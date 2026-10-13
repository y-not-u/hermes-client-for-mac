// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HermesMac", platforms: [.macOS(.v14)], products: [.executable(name: "HermesMac", targets: ["HermesMac"])], targets: [.executableTarget(name: "HermesMac", path: "HermesMac", exclude: ["Info.plist", "Assets.xcassets"], resources: [.copy("Resources/BotScreen")]), .testTarget(name: "HermesMacTests", dependencies: ["HermesMac"], path: "Tests/HermesMacTests")])
