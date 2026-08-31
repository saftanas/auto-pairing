// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "StudioSwitch",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "StudioSwitch", targets: ["StudioSwitch"])
  ],
  targets: [
    .executableTarget(
      name: "StudioSwitch",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOBluetooth"),
        .linkedFramework("ServiceManagement"),
      ]
    )
  ],
  swiftLanguageModes: [.v5]
)
