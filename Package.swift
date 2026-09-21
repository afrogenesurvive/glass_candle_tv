// swift-tools-version: 6.0
import PackageDescription

// black_glass_candle — menu bar client for the FreshRSS instance.
//
// Deliberately minimal, mirroring the DS-mon layout: one executable target, no
// Xcode project, no external dependencies.
//
// NOTE: there are no `resources:` entries on purpose. The menu bar icon is drawn
// with NSBezierPath at runtime (see StatusBar/CandleIcon.swift), which means no
// binary assets in git and nothing to keep in sync between Package.swift,
// scripts/build.sh and the source tree.
let package = Package(
    name: "black_glass_candle",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "black_glass_candle",
            path: "Sources/BlackGlassCandle"
        )
    ]
)
