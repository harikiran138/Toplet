// swift-tools-version:5.9
// LOCAL REPLACEMENT MANIFEST for migueldeicaza/SwiftTerm 1.13.0 (8e7a1e15...).
// Upstream declares Shaders.metal as `.process(...)`, which needs the Xcode-only `metal`
// compiler. Here it is shipped verbatim with `.copy`; SwiftTerm's own
// MetalTerminalRenderer.makeLibrary() falls back to compiling Shaders.metal from source
// at runtime (device.makeLibrary(source:)) if no default.metallib exists.
// Executables/benchmarks/tests (argument-parser, docc-plugin, package-benchmark) are omitted.
import PackageDescription

let package = Package(
	name: "SwiftTerm",
	platforms: [.macOS(.v13)],
	products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
	targets: [
		.target(
			name: "SwiftTerm",
			path: "Sources/SwiftTerm",
			exclude: ["Mac/README.md", "Documentation.docc"],
			resources: [.copy("Apple/Metal/Shaders.metal")]
		)
	],
	swiftLanguageVersions: [.v5]
)
