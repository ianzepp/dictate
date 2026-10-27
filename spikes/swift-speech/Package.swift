// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DictateSpeechSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
                 revision: "efcedcd4cd245eb03b65050a6bd2c103d7252d42"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git",
                 revision: "fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6"),
    ],
    targets: [
        .executableTarget(
            name: "DictateSpeechSpike",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        ),
        .executableTarget(
            name: "DictateCleanupSpike",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
