// Local-build shim (source of truth: local/shims/AtollAssets.swift).
//
// Without actool there is no Assets.car, and SwiftUI's `Image("name")` only
// looks inside compiled catalogs (verified: loose files render nothing).
// AppKit's `NSImage(named:)`, however, does find loose PNG/JPEG/SVG/ICNS
// files in Contents/Resources (verified), which is where local/tools/
// make_resources.py puts the converted imagesets.
//
// This module-level overload is preferred over SwiftUI's
// `init(_ name: String, bundle: Bundle? = nil)` (no defaulted argument) and
// routes name lookups through NSImage first. Unknown names fall through to the
// original initialiser, i.e. the same "empty image" Xcode builds show.
import SwiftUI
import AppKit

extension Image {
    init(_ name: String) {
        if let image = NSImage(named: NSImage.Name(name)) {
            self.init(nsImage: image)
        } else {
            self.init(name, bundle: nil)
        }
    }
}
