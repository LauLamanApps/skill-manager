// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SkillManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SkillManager",
            path: "Sources/SkillManager"
        )
    ]
)
