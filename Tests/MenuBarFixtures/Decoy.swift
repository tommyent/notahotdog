import AppKit

// A status-level window outside the menu bar must never influence hiding mode.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
final class OffBarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
let panel = OffBarPanel(contentRect: NSRect(x: 0, y: -44, width: 82, height: 44),
                    styleMask: .borderless, backing: .buffered, defer: false)
panel.level = .statusBar
panel.backgroundColor = .systemRed
panel.orderFrontRegardless()
panel.setFrameOrigin(NSPoint(x: 0, y: -44))
precondition(panel.frame == NSRect(x: 0, y: -44, width: 82, height: 44))
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let ours = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
    let evidence = "AppKit=\(panel.frame)\nWindowServer=\(ours)\n"
    try? evidence.write(toFile: "/tmp/nahd-decoy-frame.txt", atomically: true, encoding: .utf8)
}
app.run()
