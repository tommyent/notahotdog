import AppKit
import ApplicationServices

/// Off by default. `defaults write com.tommyent.notahotdog debugLog -bool YES`, then relaunch,
/// logs to ~/Library/Logs/NotAHotDog.log (main.swift) and the system log.
let debugLogging = UserDefaults.standard.bool(forKey: "debugLog")
func debugLog(_ format: String, _ args: CVarArg...) {
    if debugLogging { withVaList(args) { NSLogv(format, $0) } }
}

/// Items sitting to the left of our control while everything is visible.
/// Used on the composite menu bar, where off-screen window frames no longer exist.
func hiddenWindowsLeftOfSeparator(from all: [StatusWindow], excludingPID pid: pid_t, separatorMinX: CGFloat) -> [StatusWindow] {
    // MenuBarAgent's own extras (native overflow chevron, mic/camera indicator) can't be hidden.
    all.filter { $0.pid != pid && $0.bundleID != "com.apple.MenuBarAgent" && $0.frame.minX < separatorMinX }
        .sorted { $0.frame.minX < $1.frame.minX }
}

func bundleID(forPID pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

func appName(forPID pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Extra"
}

/// The Shelf's name for an item: its owning app, plus the item's own label when that reads as words
/// (Malwarebytes' AX label is `statusBar.icon.alert`, Sukusho's `MenuBarIcon`).
func itemLabel(owner: String?, detail: String) -> String {
    let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = !detail.contains(" ")
    let identifier = detail.contains(".") || (token && detail.range(of: "[a-z][A-Z]", options: .regularExpression) != nil)
    let human = !detail.isEmpty && !identifier
    guard let owner, !owner.isEmpty else { return human ? detail : "Menu bar item" }
    guard human, detail.caseInsensitiveCompare(owner) != .orderedSame else { return owner }
    // "Rex server running" from "Rex Beta" already names its app.
    let firstWord = { (s: String) in s.split(separator: " ").first.map { $0.lowercased() } }
    if firstWord(detail) == firstWord(owner) { return detail }
    return owner + " — " + detail
}

/// The name people know an item's owner by: the outermost app around a nested helper
/// (ArqMonitor inside Arq.app → "Arq"), else the owner's name without a trailing " Agent" or " Helper"
/// (Malwarebytes' agent lives in a plug-in bundle, not inside Malwarebytes.app).
func ownerName(localizedName: String?, bundlePath: String?) -> String? {
    let parts = bundlePath.map { ($0 as NSString).pathComponents } ?? []
    if let outer = parts.firstIndex(where: { $0.hasSuffix(".app") }), outer < parts.count - 1 {
        return (parts[outer] as NSString).deletingPathExtension
    }
    guard let name = localizedName else { return nil }
    for suffix in [" Agent", " Helper"] where name.hasSuffix(suffix) && name.count > suffix.count {
        return String(name.dropLast(suffix.count))
    }
    return name
}

private func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return v
}

private func axString(_ el: AXUIElement, _ name: String) -> String {
    axAttr(el, name) as? String ?? ""
}

private func axKids(_ el: AXUIElement) -> [AXUIElement] {
    axAttr(el, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

private func axFrame(_ el: AXUIElement) -> CGRect {
    var pt = CGPoint.zero
    var sz = CGSize.zero
    if let p = axAttr(el, kAXPositionAttribute as String) {
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    }
    if let s = axAttr(el, kAXSizeAttribute as String) {
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
    }
    return CGRect(origin: pt, size: sz)
}

private func axPID(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

private func inMenuBarBand(_ frame: CGRect) -> Bool {
    frame.minY >= 0 && frame.minY < 50 && frame.height > 8 && frame.height <= 50 && frame.width > 8 && frame.width < 400
}

private func syntheticID(pid: pid_t, x: CGFloat) -> CGWindowID {
    CGWindowID(truncatingIfNeeded: (Int(pid) &* 10007) &+ Int(x.rounded()))
}

private func extraFrom(_ el: AXUIElement) -> StatusWindow? {
    let frame = axFrame(el)
    guard inMenuBarBand(frame) else { return nil }
    let pid = axPID(el)
    let desc = axString(el, kAXDescriptionAttribute as String)
    let title = axString(el, kAXTitleAttribute as String)
    let ident = axString(el, kAXIdentifierAttribute as String)
    let name = [desc, title, ident, appName(forPID: pid)].first { !$0.isEmpty } ?? "Extra"
    let bid = bundleID(forPID: pid) ?? (ident.hasPrefix("com.") ? ident : nil)
    let raw = [desc, title, ident].first { !$0.isEmpty } ?? ""
    // Apple's own extras (Clock, Control Center) already carry readable names.
    let system = bid?.hasPrefix("com.apple.") != false
    let running = NSRunningApplication(processIdentifier: pid)
    return StatusWindow(
        id: syntheticID(pid: pid, x: frame.minX),
        pid: pid,
        appName: name,
        frame: frame,
        bundleID: bid,
        // macOS 27.2 exposes a stable identifier for the overflow control.
        isOverflowChevron: bid == "com.apple.MenuBarAgent" && ident == "menu-bar-overflow-indicator",
        isClock: ident == "com.apple.menuextra.clock",
        label: system ? name : itemLabel(owner: ownerName(localizedName: running?.localizedName, bundlePath: running?.bundleURL?.path), detail: raw)
    )
}

/// Raw geometry helps distinguish discovery failures from an empty menu bar.
func dumpExtraTree() {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
    dumpAXTree(pid: agent.processIdentifier)
}

func dumpAXTree(pid: pid_t) {
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth <= 7 else { return }
        print("\(String(repeating: " ", count: depth))\(axString(element, kAXRoleAttribute as String)) sub=\(axString(element, kAXSubroleAttribute as String)) pid=\(axPID(element)) frame=\(axFrame(element)) name=\(axString(element, kAXDescriptionAttribute as String)) id=\(axString(element, kAXIdentifierAttribute as String))")
        for child in axKids(element) { walk(child, depth: depth + 1) }
    }
    walk(AXUIElementCreateApplication(pid), depth: 0)
}

/// Extras as reported by MenuBarAgent's accessibility tree (macOS 27).
func extraItems() -> [StatusWindow] {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
        return []
    }
    let app = AXUIElementCreateApplication(agent.processIdentifier)
    var found: [StatusWindow] = []
    var seen = Set<CGWindowID>()
    func consider(_ el: AXUIElement) {
        if let extra = extraFrom(el), seen.insert(extra.id).inserted {
            found.append(extra)
        }
    }
    func walk(_ el: AXUIElement, depth: Int) {
        if depth > 6 { return }
        let role = axString(el, kAXRoleAttribute as String)
        let sub = axString(el, kAXSubroleAttribute as String)
        if sub == "AXMenuExtra" || role == "AXButton" {
            consider(el)
            return
        }
        if role == "AXApplication" && depth > 0 {
            // Nested app (e.g. Eon's custom extra): take only its menu extra, not File/Edit.
            for kid in axKids(el) { walkMenuExtras(kid, depth: 0) }
            return
        }
        for kid in axKids(el) { walk(kid, depth: depth + 1) }
    }
    func walkMenuExtras(_ el: AXUIElement, depth: Int) {
        if depth > 5 { return }
        if axString(el, kAXSubroleAttribute as String) == "AXMenuExtra" {
            consider(el)
            return
        }
        for kid in axKids(el) { walkMenuExtras(kid, depth: depth + 1) }
    }
    walk(app, depth: 0)
    return numberingRepeatedLabels(found.sorted { $0.frame.minX < $1.frame.minX })
}

/// Two items of one app often both read as the app's name; number the later ones, left to right.
func numberingRepeatedLabels(_ items: [StatusWindow]) -> [StatusWindow] {
    var counts: [String: Int] = [:]
    return items.map { item in
        var item = item
        guard let label = item.label else { return item }
        let key = "\(item.bundleID ?? "")|\(label)"
        counts[key, default: 0] += 1
        if counts[key]! > 1 { item.label = "\(label) (\(counts[key]!))" }
        return item
    }
}

/// Finds `item` again after the bar re-laid out (positions shift, so synthetic IDs change):
/// same app, same AX name if possible (Stint's title ticks), else nearest x.
func liveMatch(for item: StatusWindow, in extras: [StatusWindow]) -> StatusWindow? {
    let same = extras.filter { $0.pid == item.pid }
    let named = same.filter { $0.appName == item.appName }
    return (named.isEmpty ? same : named).min { abs($0.frame.minX - item.frame.minX) < abs($1.frame.minX - item.frame.minX) }
}

/// What a click at `point` would reach, as the system hit-tests it: the element and two
/// ancestors (a custom status view can hit a child first), read like `extraItems()` reads them.
func extrasHit(at point: CGPoint) -> [StatusWindow] {
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &found) == .success,
          var el = found
    else { return [] }
    var hits: [StatusWindow] = []
    for _ in 0..<3 {
        if let extra = extraFrom(el) { hits.append(extra) }
        guard let parent = axAttr(el, kAXParentAttribute as String), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        el = parent as! AXUIElement
    }
    return hits
}

/// A click at `live`'s centre reaches `live` itself. The name matters too: A1 and A2 of one app share a pid.
func routes(_ hits: [StatusWindow], to live: StatusWindow) -> Bool {
    hits.contains { $0.pid == live.pid && $0.appName == live.appName }
}

/// Whether `pid`'s app owns menu-bar icons. Its own AX tree lists them even while the
/// allowlist hides them (macOS 27 VM probe, 2026-10-12); apps without any report no value.
func ownsMenuBarExtras(_ pid: pid_t) -> Bool {
    menuBarOwnership(pid) == true
}

/// nil means no answer: keep it eligible, but never treat a timeout as ownership.
func menuBarOwnership(_ pid: pid_t) -> Bool? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.15)
    var bar: AnyObject?
    let result = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar)
    if CommandLine.arguments.contains("--trace-ownership") {
        debugLog("nahd: ownership pid=%d result=%d", pid, result.rawValue)
    }
    if result == .cannotComplete { return nil }
    // A restricted item can retain its extras bar while its rendered children disappear.
    return result == .success && bar.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
}

/// Files the icons of newly launched `bundles`, revealed on their own: a bundle with any icon right of
/// the control stays shown, like a full recapture. Their stale entries go (a relaunched app has a new pid).
func fileNewIcons(_ extras: [StatusWindow], bundles: Set<String>, separatorMinX: CGFloat,
                  cached: [StatusWindow]) -> (shown: Set<String>, hidden: [StatusWindow]) {
    let theirs = extras.filter { bundles.contains($0.bundleID ?? "") }
    let shown = Set(theirs.filter { $0.frame.minX >= separatorMinX }.compactMap(\.bundleID))
    let fresh = theirs.filter { !shown.contains($0.bundleID ?? "") }
    return (shown, cached.filter { !bundles.contains($0.bundleID ?? "") } + fresh)
}

func ourSeparatorMinX(from extras: [StatusWindow], pid: pid_t) -> CGFloat? {
    if let x = extras.filter({ $0.pid == pid }).map(\.frame.minX).min() { return x }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let bar = axAttr(app, "AXExtrasMenuBar"),
          CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
    return axKids(bar as! AXUIElement).compactMap(extraFrom).map(\.frame.minX).min()
}

/// Extras left of this x sit behind a collapsed native « and aren't drawn.
/// Unknown overflow state stays conservative: do not capture potentially collapsed pixels.
func collapsedBeforeX(_ extras: [StatusWindow]) -> CGFloat {
    extras.first { $0.isOverflowChevron && $0.overflowExpanded != true }?.frame.minX ?? -.infinity
}

/// Self-check assertion. A failure prints and exits 1: check() would crash and leave a
/// crash report that looks like the installed app's.
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
           file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { fail(message(), file: file, line: line) }
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("self-check FAILED at \(file):\(line): \(message)\n".utf8))
    exit(1)
}

/// `notahotdog --check` — the one runnable check for the non-trivial logic.
func runSelfCheck() {
    var settling = ExtraFrameSettling()
    let first = CGRect(x: 900, y: 0, width: 24, height: 24)
    let movedFrame = first.offsetBy(dx: 30, dy: 0)
    check(!settling.observe(frame: first, at: 0), "reveal cannot immediately press")
    check(!settling.observe(frame: movedFrame, at: 0.1), "moving target resets settle interval")
    check(!settling.observe(frame: nil, at: 0.2), "wrong hit target resets settling")
    check(!settling.observe(frame: movedFrame, at: 0.3), "hit target must settle again")
    check(settling.observe(frame: movedFrame, at: 0.5), "settled hit target permits one press")
    var tracking = ExtraMenuTracking()
    check(!tracking.observe(windows: [], elapsed: 0.1), "press waits for delayed menu")
    check(!tracking.observe(windows: [1], elapsed: 1), "opening holds reveal")
    check(!tracking.observe(windows: [2], elapsed: 10), "replacement submenu holds reveal beyond timeout")
    check(tracking.observe(windows: [], elapsed: 11), "closed menu re-hides")
    var unopened = ExtraMenuTracking()
    check(unopened.observe(windows: [], elapsed: 2), "failed open re-hides without a second press")
    let menu = CGRect(x: 900, y: 30, width: 200, height: 300)
    check(ClickForwarder.isMenuOverlay(owner: 1, owners: [1, 2], layer: 8, frame: menu, alpha: 1), "target popover below status level counts")
    check(ClickForwarder.isMenuOverlay(owner: 2, owners: [1, 2], layer: 101, frame: menu, alpha: 1), "host menu counts")
    check(!ClickForwarder.isMenuOverlay(owner: 3, owners: [1, 2], layer: 101, frame: menu, alpha: 1), "unrelated overlay cannot hold reveal")
    check(!ClickForwarder.isMenuOverlay(owner: 1, owners: [1, 2], layer: 25, frame: first, alpha: 1), "revealed status item is not an open menu")
    check(!ClickForwarder.isMenuOverlay(owner: 1, owners: [1, 2], layer: 101, frame: menu, alpha: 0), "invisible window is not an open menu")
    // PIA's item opens "PIA Dashboard", an ordinary-level window hanging from the bar (Air, 2026-11-05).
    check(ClickForwarder.isMenuOverlay(owner: 1, owners: [1, 2], layer: 0, frame: CGRect(x: 988, y: 34, width: 320, height: 480), alpha: 1),
                 "a level-0 window hanging from the bar counts")
    check(!ClickForwarder.isMenuOverlay(owner: 1, owners: [1, 2], layer: 0, frame: CGRect(x: 300, y: 200, width: 800, height: 600), alpha: 1),
                 "an ordinary app window does not")
    print("click-through ordering self-check OK: settle, press, delayed open, hold, close, re-hide")
    var overflow = StatusWindow(id: 1, pid: 1, appName: "Menüleistenobjekte ausblenden", frame: .zero, isOverflowChevron: true)
    check(overflow.overflowExpanded == true, "German expanded overflow from the OS catalog")
    overflow = StatusWindow(id: 1, pid: 1, appName: "Ausgeblendete Menüleistenobjekte einblenden", frame: .zero, isOverflowChevron: true)
    check(overflow.overflowExpanded == false, "German collapsed overflow from the OS catalog")
    overflow = StatusWindow(id: 1, pid: 1, appName: "unknown", frame: .zero, isOverflowChevron: true)
    check(overflow.overflowExpanded == nil, "unknown overflow state fails closed")
    check(!AssessmentHide.shouldRestoreClock(visible: true, opened: true, ticks: 100), "open Clock survives timeout")
    check(AssessmentHide.shouldRestoreClock(visible: false, opened: true, ticks: 1), "closed Clock restores")
    check(AssessmentHide.shouldRestoreClock(visible: false, opened: false, ticks: 12), "failed Clock open restores")
    let screen = NSRect(x: -1200, y: 0, width: 1200, height: 800)
    let anchor = NSRect(x: -1190, y: 800, width: 24, height: 24)
    let oversized = BarPanel.frame(for: NSSize(width: 2000, height: 1000), anchor: anchor, visibleFrame: screen)
    check(screen.contains(oversized), "oversized panels stay on their display")
    check(oversized.maxY <= anchor.minY - 6, "panel remains below menu bar")
    let compact = BarPanel.frame(for: NSSize(width: 200, height: 40),
                                 anchor: NSRect(x: -300, y: 800, width: 24, height: 24), visibleFrame: screen)
    check(compact.size == NSSize(width: 200, height: 40) && compact.maxX == -276,
                 "compact panel preserves size and control alignment")
    // Tray, as on the Air at 09:05 on 2026-11-05: twelve icons, Vitals (about 83 pt) seventh.
    // Three per row left rows 1, 2 and 4 one cell short of Vitals' row.
    let airWidths: [CGFloat] = [30, 30, 30, 30, 30, 30, 83, 34, 30, 30, 30, 30]
    let (airCell, airTray) = BarPanel.trayGrid(widths: airWidths)
    func rowWidths(_ slots: [TraySlot], cell: CGFloat) -> [Int: CGFloat] {
        Dictionary(grouping: slots, by: \.row).mapValues { row in
            row.reduce(0) { $0 + BarPanel.trayCellWidth(span: $1.span, cell: cell) } + CGFloat(row.count - 1) * BarPanel.traySpacing
        }
    }
    let airRows = rowWidths(airTray, cell: airCell)
    check(airTray[6].span == 2 && airRows.count == 5 && Set((0..<4).map { airRows[$0]! }).count == 1,
                 "full tray rows are equally wide: \(airRows)")
    check(zip(airWidths, airTray).allSatisfy { BarPanel.trayCellWidth(span: $1.span, cell: airCell) >= $0 },
                 "every item fits its cells, Vitals included: cell \(airCell)")
    check(BarPanel.trayGrid(widths: [36, 38, 44]).slots.allSatisfy { $0.span == 1 }, "icon-sized items take one cell")
    check((36...44).contains(BarPanel.trayGrid(widths: [44, 30, 88, 120]).cell), "cell widens at most one spacing")
    let backfilled = BarPanel.trayGrid(widths: [30, 30, 83, 30]).slots
    check(backfilled == [TraySlot(row: 0, column: 0, span: 1), TraySlot(row: 0, column: 1, span: 1),
                                TraySlot(row: 1, column: 0, span: 2), TraySlot(row: 0, column: 2, span: 1)],
                 "a wide item that doesn't fit moves down and the next icon fills the gap: \(backfilled)")
    let (wideCell, wide) = BarPanel.trayGrid(widths: [30, 200, 30, 30, 30, 30, 30])
    check(wide[1].span == 5 && rowWidths(wide, cell: wideCell).values.allSatisfy { $0 <= rowWidths(wide, cell: wideCell)[1]! },
                 "rows widen to the widest item instead of overflowing")
    check(BarPanel.trayNeighbor(of: 4, in: airTray, down: true) == 6, "down from column 1 lands on Vitals, which covers it")
    check(BarPanel.trayNeighbor(of: 6, in: airTray, down: true) == 8, "down from Vitals keeps its first column")
    check(BarPanel.trayNeighbor(of: 8, in: airTray, down: false) == 6, "up into a wide item")
    check(BarPanel.trayNeighbor(of: 10, in: airTray, down: true) == 11, "short last row: its last item")
    check(BarPanel.trayNeighbor(of: 11, in: airTray, down: true) == nil, "below the last row: Settings")
    check(BarPanel.trayNeighbor(of: 1, in: airTray, down: false) == nil, "above the first row: stay")
    print("tray grid self-check OK: equal full rows, wide items, backfill, arrow keys")
    func w(_ id: CGWindowID, _ pid: pid_t, x: CGFloat, width: CGFloat = 30) -> StatusWindow {
        StatusWindow(id: id, pid: pid, appName: "t", frame: CGRect(x: x, y: 0, width: width, height: 24))
    }
    // Shelf names, from the Air's AX labels on 2026-11-05.
    check(itemLabel(owner: "Malwarebytes", detail: "statusBar.icon.alert") == "Malwarebytes", "dotted identifier → app")
    check(itemLabel(owner: "Sukusho", detail: "MenuBarIcon") == "Sukusho", "camel-case identifier → app")
    check(itemLabel(owner: "Tailscale", detail: "Tailscale") == "Tailscale", "same name once")
    check(itemLabel(owner: "Rex Beta", detail: "Rex server running") == "Rex server running", "label repeats the app's first word")
    check(itemLabel(owner: "Google Drive", detail: "Google Drive") == "Google Drive", "same name, two words")
    // Owners' real bundle paths on the Air, 2026-11-05.
    check(ownerName(localizedName: "Malwarebytes Agent", bundlePath:
        "/Library/Application Support/Malwarebytes/MBAM/Engine.bundle/Contents/PlugIns/FrontendAgent.app") == "Malwarebytes",
          "agent outside its app drops the suffix")
    check(ownerName(localizedName: "ArqMonitor", bundlePath: "/Applications/Arq.app/Contents/Resources/ArqMonitor.app") == "Arq",
          "helper inside an app takes the app's name")
    check(ownerName(localizedName: "BlockBlock Helper", bundlePath: "/Applications/BlockBlock Helper.app") == "BlockBlock", "helper suffix")
    check(ownerName(localizedName: "Rex Beta", bundlePath: "/Applications/Rex Beta.app") == "Rex Beta", "plain app keeps its name")
    check(ownerName(localizedName: nil, bundlePath: nil) == nil, "unknown owner")
    check(itemLabel(owner: "Stint", detail: "Timer paused") == "Stint — Timer paused", "readable label keeps its app")
    check(itemLabel(owner: nil, detail: "com.example.item") == "Menu bar item", "no owner, no words")
    let twins = numberingRepeatedLabels([
        StatusWindow(id: 1, pid: 7, appName: "statusBar.icon.alert", frame: .zero, bundleID: "a", label: "Malwarebytes"),
        StatusWindow(id: 2, pid: 7, appName: "statusBar.icon.main", frame: .zero, bundleID: "a", label: "Malwarebytes"),
        StatusWindow(id: 3, pid: 8, appName: "Clock", frame: .zero, bundleID: "b", label: "Clock"),
    ])
    check(twins.map(\.label) == ["Malwarebytes", "Malwarebytes (2)", "Clock"] && twins[1].appName == "statusBar.icon.main",
                 "repeats are numbered and the raw AX name used for clicks is kept")
    check(!inMenuBarBand(CGRect(x: 0, y: 1107, width: 82, height: 44)), "bottom-edge decoy is not an extra")
    check(inMenuBarBand(CGRect(x: 900, y: 5, width: 24, height: 24)), "ordinary extra")
    // Composite menu bar: hide by position relative to our control, not the screen edge.
    let extras = [
        w(10, 100, x: 900),
        w(11, 100, x: 1100),
        w(17, 500, x: 1190, width: 40), // starts left of the control even though its AX frame overlaps
        w(12, 200, x: 1400),
        w(13, 999, x: 1200), // our control
        w(15, 300, x: 1500),
        StatusWindow(id: 16, pid: 400, appName: "overflow", frame: CGRect(x: 1000, y: 0, width: 18, height: 24),
                     bundleID: "com.apple.MenuBarAgent"),
    ]
    let bySep = hiddenWindowsLeftOfSeparator(from: extras, excludingPID: 999, separatorMinX: 1200)
    check(bySep.map(\.id) == [10, 11, 17], "expected [10,11,17], got \(bySep.map(\.id))")

    // Apps launched since the last capture, revealed alone: only they are filed; old entries stay.
    func app(_ id: CGWindowID, _ pid: pid_t, _ bid: String, x: CGFloat) -> StatusWindow {
        StatusWindow(id: id, pid: pid, appName: bid, frame: CGRect(x: x, y: 0, width: 30, height: 24), bundleID: bid)
    }
    let cached = [app(40, 100, "old.hidden", x: 900), app(41, 101, "relaunched", x: 950)]
    let revealed = [app(50, 200, "new.left", x: 1100), app(51, 201, "relaunched", x: 1150),
                    app(52, 202, "new.right", x: 1300), app(53, 203, "new.both", x: 1120), app(54, 203, "new.both", x: 1320),
                    app(55, 999, "ours", x: 1200), app(56, 100, "old.hidden", x: 1180)]
    let filed = fileNewIcons(revealed, bundles: ["new.left", "relaunched", "new.right", "new.both"], separatorMinX: 1200, cached: cached)
    check(filed.shown == ["new.right", "new.both"], "right of the control stays shown, per bundle: \(filed.shown)")
    check(filed.hidden.map(\.id) == [40, 50, 51], "old kept, stale relaunch replaced: \(filed.hidden.map(\.id))")

    // After a partial reveal the item moved; match by name, else nearest same-PID.
    let moved = [w(20, 100, x: 300), w(21, 100, x: 600), w(22, 200, x: 610)]
    check(liveMatch(for: w(10, 100, x: 900), in: moved)?.id == 21, "nearest same-pid")
    let named = StatusWindow(id: 11, pid: 100, appName: "a", frame: CGRect(x: 1100, y: 0, width: 30, height: 24))
    let renamed = [StatusWindow(id: 30, pid: 100, appName: "a", frame: CGRect(x: 100, y: 0, width: 30, height: 24)), w(31, 100, x: 1000)]
    check(liveMatch(for: named, in: renamed)?.id == 30, "name beats distance")
    check(liveMatch(for: w(1, 555, x: 0), in: moved) == nil, "other apps never match")

    // Click routing: after a reveal, B1's new centre still hit hidden A1 for ~200 ms (VM, 2026-10-11).
    func item(_ pid: pid_t, _ name: String) -> StatusWindow {
        StatusWindow(id: 0, pid: pid, appName: name, frame: CGRect(x: 1380, y: 0, width: 37, height: 24))
    }
    let a1 = item(100, "Audit A1"), a2 = item(100, "Audit A2"), b1 = item(200, "Audit B1")
    check(routes([b1, item(200, "Audit Beta")], to: b1), "the item itself")
    check(!routes([a1, item(100, "Audit Alpha")], to: b1), "another app's stale item")
    check(!routes([a1, item(100, "Audit Alpha")], to: a2), "same app, other item")
    check(routes([item(200, "badge"), b1], to: b1), "a custom view's child, then the item")
    check(!routes([], to: b1), "nothing hit")

    // Backdrop keying: wallpaper-colored padding and its texture → transparent; white glyph stays opaque white.
    func rgba(_ bytes: [UInt8], width: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: width * 4)
        for (i, b) in bytes.enumerated() { p[i] = b }
        return ctx
    }
    func keyed(_ bytes: [UInt8]) -> [UInt8] {
        let n = bytes.count / 4
        let out = rgba([], width: n)
        if let glyph = removingBackdrop(rgba(bytes, width: n).makeImage()!) {
            out.draw(glyph, in: CGRect(x: 0, y: 0, width: n, height: 1))
        }
        return Array(UnsafeBufferPointer(start: out.data!.bindMemory(to: UInt8.self, capacity: n * 4), count: n * 4))
    }
    // Backdrop keying on a tinted, textured wallpaper is checked below on realistic 20×20 crops:
    // a tiny crop is all border, so its noise floor would be the glyph itself.
    // Near-black bar: a pixel one shade darker than the backdrop is noise.
    check(keyed([1, 1, 1, 255, 0, 0, 0, 255]) == [0, 0, 0, 0, 0, 0, 0, 0], "near-black backdrop")
    check(removingBackdrop(rgba([60, 60, 60, 255, 60, 60, 60, 255], width: 2).makeImage()!) == nil,
                 "blank capture must fall back to the app icon")

    // Faint glyphs: Tailscale's dimmed dots measure alpha 0.257–0.295 over the bar (Air, 2026-11-03).
    for background: UInt8 in [40, 215] {
        for texture in [{ (i: Int) in i % 3 }, { (i: Int) in (i * 7919) % 9 }] {  // regular, and spread like a real wallpaper
            for opacity: Float in [0.26, 0.35, 0.5, 1] {
                let width = 20, height = 20
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
                let tint = { (c: Int) in background - UInt8(c * 8) }  // reddish wallpaper behind the bar
                for i in 0..<(width * height) {
                    for c in 0..<3 { pixels[i * 4 + c] = tint(c) + UInt8(texture(i)) }
                    pixels[i * 4 + 3] = 255
                }
                check(removingBackdrop(context.makeImage()!) == nil, "textured wallpaper-only crop is empty")
                for y in 7..<13 { for x in 7..<13 {
                    let fg: Float = background < 128 ? 255 : 0
                    for c in 0..<3 { pixels[(y * width + x) * 4 + c] = UInt8((Float(tint(c)) * (1 - opacity) + fg * opacity).rounded()) }
                } }
                guard let glyph = removingBackdrop(context.makeImage()!) else { fail("faint glyph removed at \(opacity)") }
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(glyph, in: CGRect(x: 0, y: 0, width: width, height: height))
                check(Float(pixels[(10 * width + 10) * 4 + 3]) / 255 > opacity - 0.04, "faint dot alpha preserved at \(opacity)")
                check(pixels[3] == 0, "backdrop keyed out next to a faint glyph")
                if opacity == 1 {
                    check(abs(Int(pixels[(10 * width + 10) * 4]) - (background < 128 ? 255 : 0)) <= 5, "opaque glyph keeps its color")
                }
            }
        }
    }
    print("faint glyph self-check OK: 26–100 percent, light/dark, regular and spread texture")

    // Shelf glyphs lose their side padding, measured at 2x, and keep their height.
    let shelfCanvas = CGContext(data: nil, width: 60, height: 44, bitsPerComponent: 8, bytesPerRow: 240,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let shelfSize = NSSize(width: 30, height: 22)
    let blankGlyph = NSImage(cgImage: shelfCanvas.makeImage()!, size: shelfSize)
    check(BarPanel.trimmingSides(blankGlyph).size == shelfSize, "a blank glyph keeps its size")
    shelfCanvas.setFillColor(gray: 1, alpha: 0.26)
    shelfCanvas.fill(CGRect(x: 20, y: 10, width: 8, height: 20))
    let paddedGlyph = NSImage(cgImage: shelfCanvas.makeImage()!, size: shelfSize)
    check(BarPanel.trimmingSides(paddedGlyph).size == NSSize(width: 5, height: 22), "8 px glyph plus 1 px each side at 2x")
    shelfCanvas.fill(CGRect(x: 0, y: 10, width: 60, height: 20))
    let fullGlyph = NSImage(cgImage: shelfCanvas.makeImage()!, size: shelfSize)
    check(BarPanel.trimmingSides(fullGlyph).size == shelfSize, "an edge-to-edge glyph keeps its size")
    print("shelf glyph self-check OK: side padding trimmed, height kept")

    // build.sh runs this on the signed app: hardened runtime must still load the private framework.
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
        check(AssessmentHide.available, "MenuBarClientCore assessment API did not load")
    }
    AssessmentHide.checkHandOff()
    print("self-check OK")
}
