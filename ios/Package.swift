// swift-tools-version: 5.9

import PackageDescription

let package = Package(
   name: "tauri-plugin-audio",
   platforms: [.iOS(.v16)],
   products: [
      .library(
         name: "tauri-plugin-audio",
         type: .static,
         targets: ["tauri-plugin-audio"]
      ),
   ],
   dependencies: [
      .package(name: "AudioPlayerKit", path: "AudioPlayerKit"),
      .package(name: "Tauri", path: "../.tauri/tauri-api"),
   ],
   targets: [
      .target(
         name: "tauri-plugin-audio",
         dependencies: [
            .byName(name: "AudioPlayerKit"),
            .byName(name: "Tauri"),
         ],
         path: "Sources"
      ),
   ]
)
