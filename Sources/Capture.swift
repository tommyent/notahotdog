import AppKit
import ScreenCaptureKit

private typealias WindowImageFn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
private let legacyFn: WindowImageFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: WindowImageFn.self)
}()

private func legacyWindowImage(_ id: CGWindowID) -> CGImage? {
    legacyFn?(.null, [.optionIncludingWindow], id, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
}

private func menuBarComposite() -> (id: CGWindowID, frame: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let mainMenu = Int(CGWindowLevelForKey(.mainMenuWindow))
    for info in list {
        let name = info[kCGWindowName as String] as? String ?? ""
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        guard name == "Menubar" || (layer == mainMenu && owner.contains("Window Server")),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { continue }
        let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        guard frame.height <= 60, frame.width > 100 else { continue }
        return (id, frame)
    }
    return nil
}

/// Crop each extra out of the single composite menubar window (macOS 27). One log line per capture,
/// so a stale Shelf glyph can be traced to when it was last photographed.
func captureExtrasFromMenuBar(_ extras: [StatusWindow], trigger: String) async -> [CGWindowID: NSImage] {
    guard !extras.isEmpty else { return [:] }
    let out = await cropExtrasFromMenuBar(extras)
    debugLog("nahd: captured %d of %d glyphs (%@)", out.count, extras.count, trigger)
    return out
}

private func cropExtrasFromMenuBar(_ extras: [StatusWindow]) async -> [CGWindowID: NSImage] {
    guard CGPreflightScreenCaptureAccess() else { return [:] }
    guard let bar = menuBarComposite() else {
        debugLog("nahd: no composite menubar window")
        return [:]
    }
    // Restore the window capture used by the last Air build with visible glyphs.
    var barImage: CGImage?
    let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    if let scw = content?.windows.first(where: { $0.windowID == bar.id }) {
        let cfg = SCStreamConfiguration()
        cfg.width = max(Int(bar.frame.width) * 2, 2)
        cfg.height = max(Int(bar.frame.height) * 2, 2)
        cfg.showsCursor = false
        barImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg)
    }
    if barImage == nil { barImage = legacyWindowImage(bar.id) }
    guard let full = barImage else {
        debugLog("nahd: composite menubar capture failed")
        return [:]
    }
    let scaleX = CGFloat(full.width) / max(bar.frame.width, 1)
    let scaleY = CGFloat(full.height) / max(bar.frame.height, 1)
    var out: [CGWindowID: NSImage] = [:]
    for extra in extras { autoreleasepool {
        let r = extra.frame.offsetBy(dx: -bar.frame.minX, dy: -bar.frame.minY)
        let crop = CGRect(
            x: r.minX * scaleX,
            y: r.minY * scaleY,
            width: max(r.width * scaleX, 1),
            height: max(r.height * scaleY, 1)
        ).integral
        guard let piece = full.cropping(to: crop), let glyph = removingBackdrop(piece) else { return }
        out[extra.id] = NSImage(cgImage: glyph, size: extra.frame.size)
    } }
    return out
}

/// Composite crops include the wallpaper behind the bar, which boxed each icon in the drop-down.
/// "Color to alpha": make the backdrop color transparent,
/// keeping anti-aliased edges and colored glyphs.
/// shortcut: one backdrop color per crop; revisit if interior texture exceeds measured border noise.
func removingBackdrop(_ image: CGImage) -> CGImage? {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = ctx.data
    else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    // Backdrop = per-channel median of the crop's border (item padding). A single corner pixel
    // can sit on an edge highlight and leave the whole tile tinted.
    var border: [Int] = []  // byte offsets
    for x in 0..<w { border += [x * 4, ((h - 1) * w + x) * 4] }
    for y in 0..<h { border += [y * w * 4, (y * w + w - 1) * 4] }
    let bg: [Float] = (0..<3).map { c in
        let values = border.map { px[$0 + c] }.sorted()
        return Float(values[values.count / 2]) / 255
    }
    // Smallest alpha that explains the pixel as some color over the backdrop.
    func alpha(_ i: Int) -> Float {
        var a: Float = 0
        for c in 0..<3 {
            let p = Float(px[i + c]) / 255
            // Floored denominators: on a near-black bar, a pixel one shade darker is noise, not an opaque glyph.
            if p > bg[c] { a = max(a, (p - bg[c]) / max(1 - bg[c], 0.25)) } else if p < bg[c] { a = max(a, (bg[c] - p) / max(bg[c], 0.25)) }
        }
        return a
    }
    let noise = border.map(alpha).sorted()
    let cutoff = max(Float(2) / 255, noise[min(noise.count - 1, noise.count * 95 / 100)] + Float(2) / 255)
    var hasGlyph = false
    for i in stride(from: 0, to: w * h * 4, by: 4) {
        let a = alpha(i)
        // Preserve faint glyph alpha once it clears the crop's measured noise floor.
        let keep = min(1, max(0, (a - cutoff) / max(cutoff, 0.01)))
        for c in 0..<3 {
            let p = Float(px[i + c]) / 255
            px[i + c] = UInt8((min(max(p - bg[c] + a * bg[c], 0), a) * keep * 255).rounded())  // premultiplied
        }
        px[i + 3] = UInt8((a * keep * 255).rounded())
        hasGlyph = hasGlyph || px[i + 3] > 0
    }
    // An empty crop must use the panel's app-icon fallback, not an invisible tile.
    guard hasGlyph else { return nil }
    return ctx.makeImage() ?? image
}
