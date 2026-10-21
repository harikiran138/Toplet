// swift-tools-version:5.9
// LOCAL REPLACEMENT MANIFEST for sindresorhus/Defaults 9.0.3 (00c82eff...).
// Upstream's manifest also declares the DefaultsMacros products which pull in
// swift-syntax; Atoll links only the `Defaults` library, so those targets are omitted.
// All upstream sources are used as-is except the `@State` rename done by local/prepare.py.
import PackageDescription

let package = Package(
	name: "Defaults",
	platforms: [.macOS(.v11)],
	products: [.library(name: "Defaults", targets: ["Defaults"])],
	targets: [
		.target(name: "Defaults", resources: [.copy("PrivacyInfo.xcprivacy")])
	]
)
