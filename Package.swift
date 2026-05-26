// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GijirokuTaker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GijirokuTaker", targets: ["GijirokuTaker"]),
        .executable(name: "GijirokuCLI", targets: ["GijirokuCLI"]),
        .library(name: "GijirokuCore", targets: ["GijirokuCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "GijirokuTaker",
            dependencies: [
                "GijirokuCore",
                "GijirokuLLM",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/GijirokuTaker"
        ),
        .executableTarget(
            name: "GijirokuCLI",
            dependencies: [
                "GijirokuCore",
                "GijirokuLLM",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/GijirokuCLI"
        ),
        .target(
            name: "GijirokuCore",
            path: "Sources/GijirokuCore"
        ),
        .target(
            name: "GijirokuLLM",
            dependencies: [
                "GijirokuCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/GijirokuLLM"
        ),
        .testTarget(
            name: "GijirokuCoreTests",
            dependencies: ["GijirokuCore"],
            path: "Tests/GijirokuCoreTests"
        ),
    ]
)
