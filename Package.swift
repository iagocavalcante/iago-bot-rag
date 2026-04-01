// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhatsAppAutoReply",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.16.0")
    ],
    targets: [
        .executableTarget(
            name: "WhatsAppAutoReply",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            exclude: [
                "Info.plist"
            ]
        ),
        .testTarget(
            name: "WhatsAppAutoReplyTests",
            dependencies: ["WhatsAppAutoReply"]
        )
    ]
)
