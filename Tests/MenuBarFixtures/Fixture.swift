import AppKit

// Menu-only status items for testing menu bar managers.
// The bundle ID picks the items: *.beta owns B1, anything else owns A1 and A2.
// Each menu open and each action appends one line to /tmp/menubar-fixture-events.log:
// "<local ISO 8601 time> <bundle ID> <item> opened|activated".
final class Fixture: NSObject, NSMenuDelegate {
    let bundleID = Bundle.main.bundleIdentifier ?? "?"
    let log = URL(fileURLWithPath: "/tmp/menubar-fixture-events.log")
    let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current  // matches NotAHotDog.log's local timestamps
        return f
    }()
    var items: [NSStatusItem] = []

    func record(_ item: String, _ event: String) {
        let line = Data("\(stamp.string(from: Date())) \(bundleID) \(item) \(event)\n".utf8)
        if let file = try? FileHandle(forWritingTo: log) {
            file.seekToEndOfFile()
            file.write(line)
            file.closeFile()
        } else {
            FileManager.default.createFile(atPath: log.path, contents: line)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { record(menu.title, "opened") }

    @objc func activate(_ sender: NSMenuItem) { record(sender.menu?.title ?? "?", "activated") }

    func setup() {
        for name in bundleID.hasSuffix(".beta") ? ["B1"] : ["A1", "A2"] {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "audit.\(name)"  // same keys as the 2026-10-11 audit fixtures, so arrangements carry over
            item.button?.title = name
            item.button?.setAccessibilityLabel("Audit \(name)")
            let menu = NSMenu(title: name)
            menu.delegate = self
            menu.addItem(withTitle: "Audit \(name) menu", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Record \(name) activation", action: #selector(activate(_:)), keyEquivalent: "").target = self
            item.menu = menu
            items.append(item)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let fixture = Fixture()
if let flag = CommandLine.arguments.firstIndex(of: "--delay"),
   CommandLine.arguments.indices.contains(flag + 1),
   let delay = Double(CommandLine.arguments[flag + 1]), delay > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { fixture.setup() }
} else {
    fixture.setup()
}
app.run()
