import AppKit

/// Reveal only the target bundle, hit-test its live position, and restore hiding after dismissal.
enum ClickForwarder {
    /// Bumped whenever a forward starts or is cancelled.
    private(set) static var generation = 0
    private static var closeTimer: Timer?
    private static var expandedOverflow = false

    /// Composite menubar: reveal the item, expanding the native overflow first
    /// when MenuBarAgent still reports it to the left of a collapsed chevron.
    static func forwardExtra(_ item: StatusWindow, reveal: @escaping () -> Void, rehide: @escaping () -> Void) {
        let token = begin()
        debugLog("nahd: click reveal requested for %@", item.appName)
        reveal()
        // Same settle time as the capture path: the assertion swap re-lays out the whole bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard token == generation else { return }
            let extras = extraItems()
            guard let live = liveMatch(for: item, in: extras) else { rehide(); return }
            guard let chevron = extras.first(where: \.isOverflowChevron),
                  live.frame.minX < chevron.frame.minX
            else {
                clickExtra(live, token: token, rehide: rehide)
                return
            }

            guard let expanded = expandNativeOverflow(in: extras) else {
                rehide()
                return
            }
            guard expanded else {
                clickExtra(live, token: token, rehide: rehide)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard token == generation else { return }
                let currentExtras = extraItems()
                guard let currentChevron = currentExtras.first(where: \.isOverflowChevron),
                      currentChevron.overflowExpanded == true,
                      let current = liveMatch(for: item, in: currentExtras)
                else {
                    collapseNativeOverflow()
                    rehide()
                    return
                }
                clickExtra(current, token: token, rehide: rehide)
            }
        }
    }

    /// Returns true when this call expanded the chevron, false when it was
    /// already expanded (or absent), and nil when its state is unrecognized.
    /// MenuBarAgent exposes no AX actions for this AXButton, so activation uses
    /// the current AX frame; runtime inspection reports AXPress unsupported.
    /// Unknown localized state fails closed; labels come from MenuBarAgent's own catalog.
    static func expandNativeOverflow(in extras: [StatusWindow]) -> Bool? {
        guard let chevron = extras.first(where: \.isOverflowChevron) else { return false }
        if chevron.overflowExpanded == true { return false }
        guard chevron.overflowExpanded == false else { return nil }
        click(at: CGPoint(x: chevron.frame.midX, y: chevron.frame.midY))
        expandedOverflow = true
        return true
    }

    static func collapseNativeOverflow() {
        guard expandedOverflow else { return }
        defer { expandedOverflow = false }
        guard let chevron = extraItems().first(where: \.isOverflowChevron),
              chevron.overflowExpanded == true
        else { return }
        click(at: CGPoint(x: chevron.frame.midX, y: chevron.frame.midY))
    }

    /// Clicks only after the live frame stays hit-testable and unchanged for 100 ms.
    /// Observed (VM, 2026-10-11): after a reveal, B1's new centre hit-tested as hidden A1 for ~200 ms.
    /// Whether that caused the unguarded B1 failures is unconfirmed.
    private static func clickExtra(_ target: StatusWindow, token: Int, rehide: @escaping () -> Void,
                                   since start: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                   settling: ExtraFrameSettling = ExtraFrameSettling()) {
        guard token == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let waited = Int((now - start) * 1000)
        let live = liveMatch(for: target, in: extraItems())
        let hit = live.map { routes(extrasHit(at: CGPoint(x: $0.frame.midX, y: $0.frame.midY)), to: $0) } ?? false
        var settling = settling
        let settled = settling.observe(frame: hit ? live?.frame : nil, at: now)
        if settled, let live {
            let host = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier
            let owners = Set([live.pid, host].compactMap { $0 })
            let baseline = overlayWindowIDs(owners: owners)
            // Not AXPress: it stalls ~1.5s on some extras, then fires late and the fallback click toggles the menu shut.
            debugLog("nahd: forwarding \(live.appName) at x=\(Int(live.frame.minX)) after \(waited) ms")
            click(at: CGPoint(x: live.frame.midX, y: live.frame.midY))
            waitForNewWindowsToClose(baseline: baseline, owners: owners, token: token, then: rehide)
        } else if waited >= 1000 {
            debugLog("nahd: \(target.appName) not clickable after \(waited) ms; re-hiding")
            collapseNativeOverflow()
            rehide()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                clickExtra(target, token: token, rehide: rehide, since: start, settling: settling)
            }
        }
    }

    /// The target or composite host can own the menu; unrelated overlays cannot hold a reveal.
    private static func overlayWindowIDs(owners: Set<pid_t>) -> Set<CGWindowID> {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(list.compactMap {
            guard let owner = $0[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = $0[kCGWindowLayer as String] as? Int,
                  let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  isMenuOverlay(owner: owner, owners: owners, layer: layer, frame: frame,
                                alpha: $0[kCGWindowAlpha as String] as? Double ?? 1),
                  let id = $0[kCGWindowNumber as String] as? CGWindowID
            else { return nil }
            return id
        })
    }

    /// Level 0 counts only when it hangs from the bar, like PIA's Dashboard; other app windows don't hold a reveal.
    static func isMenuOverlay(owner: pid_t, owners: Set<pid_t>, layer: Int, frame: CGRect, alpha: Double) -> Bool {
        owners.contains(owner) && (layer > 0 || frame.minY <= 50) && alpha > 0 && !frame.isEmpty && frame.maxY > 50
    }

    static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Supersede any delayed click or menu-close watcher. The caller owns the
    /// resulting bar state, so cancellation deliberately does not re-hide.
    static func cancel() {
        generation &+= 1
        closeTimer?.invalidate()
        closeTimer = nil
        collapseNativeOverflow()
    }

    private static func begin() -> Int {
        cancel()
        return generation
    }

    /// shortcut: interaction-only polling; use AX observers if window ownership proves insufficient.
    private static func waitForNewWindowsToClose(baseline: Set<CGWindowID>, owners: Set<pid_t>, token: Int, then rehide: @escaping () -> Void) {
        var state = ExtraMenuTracking()
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.25, repeats: true) { t in
            guard token == generation else {
                t.invalidate()
                return
            }
            let now = overlayWindowIDs(owners: owners).subtracting(baseline)
            let wasOpened = state.opened
            let restore = state.observe(windows: now, elapsed: ProcessInfo.processInfo.systemUptime - start)
            if !wasOpened && state.opened { debugLog("nahd: forwarded menu observed windows=%@", now.sorted().description) }
            if restore {
                debugLog("nahd: forwarded menu %@; re-hiding", state.opened ? "closed" : "open timed out")
                finish(t, token: token, then: rehide)
            }
        }
        closeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func finish(_ timer: Timer, token: Int, then rehide: () -> Void) {
        timer.invalidate()
        if closeTimer === timer { closeTimer = nil }
        guard token == generation else { return }
        collapseNativeOverflow()
        rehide()
    }
}

struct ExtraFrameSettling {
    private var frame: CGRect?
    private var since: TimeInterval = 0

    mutating func observe(frame next: CGRect?, at time: TimeInterval) -> Bool {
        guard let next else { frame = nil; return false }
        if frame != next { frame = next; since = time; return false }
        return time - since >= 0.1
    }
}

struct ExtraMenuTracking {
    private(set) var opened = false

    mutating func observe(windows: Set<CGWindowID>, elapsed: TimeInterval) -> Bool {
        if !windows.isEmpty { opened = true; return false }
        return opened || elapsed >= 2
    }
}
