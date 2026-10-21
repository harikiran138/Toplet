// Checks that local/shims/AtollAssets.swift (copied in at build time by run.sh) makes Image("name")
// find loose resources converted by make_resources.py, that the plain AppKit lookup works, and that a
// missing name stays empty. Runs inside a throw-away bundle; see run.sh.
import SwiftUI
import AppKit

@MainActor func nonTransparentPixels<V: View>(_ v: V) -> Int {
    let r = ImageRenderer(content: v.frame(width: 40, height: 40))
    r.scale = 1
    guard let cg = r.cgImage else { return -1 }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0; var i = 3
    while i < buf.count { if buf[i] > 0 { n += 1 }; i += 4 }
    return n
}

var failures = 0
func expect(_ c: Bool, _ s: String) { print(c ? "PASS" : "FAIL", s); if !c { failures += 1 } }

@MainActor func run() {
    for name in ["bolt", "spotlight", "desktop", "logo", "Github"] {
        expect(NSImage(named: NSImage.Name(name)) != nil, "NSImage(named: \"\(name)\")")
        expect(nonTransparentPixels(Image(name).resizable()) > 0, "Image(\"\(name)\") renders pixels")
    }
    expect(NSImage(named: NSImage.Name("missing_xyz")) == nil, "NSImage(named: missing) is nil")
    expect(nonTransparentPixels(Image("missing_xyz").resizable()) == 0, "Image(\"missing_xyz\") renders nothing")
}
MainActor.assumeIsolated { run() }
exit(failures == 0 ? 0 : 1)
