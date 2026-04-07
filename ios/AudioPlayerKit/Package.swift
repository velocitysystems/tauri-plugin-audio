// swift-tools-version: 5.9

import PackageDescription

let package = Package(
   name: "AudioPlayerKit",
   platforms: [.iOS(.v16)],
   products: [
      .library(
         name: "AudioPlayerKit",
         targets: ["AudioPlayerKit"]
      ),
   ],
   targets: [
      .target(
         name: "AudioPlayerKit"
      ),
      .testTarget(
         name: "AudioPlayerKitTests",
         dependencies: ["AudioPlayerKit"]
      ),
   ]
)
