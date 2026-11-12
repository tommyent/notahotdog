import AppKit
import Darwin
import NAHDTrap

/// macOS 27 replaced per-item status windows with a composite menubar.
/// Expanding an NSStatusItem no longer pushes siblings off-screen.
/// MenuBarClientCore's assessment assertion is the same allowlist hide
/// Bartender / BTT use: extras whose bundle is not allowed disappear.
enum AssessmentHide {
    private static var assertion: AnyObject?
    private static var pendingAssertion: AnyObject?
    private static var launching: Set<String> = []
    private static var loaded = false

    static var available: Bool {
        load()
        return NSClassFromString("MBAssessmentModeAssertion") != nil
    }

    @discardableResult
    private static func load() -> Bool {
        if loaded { return true }
        loaded = true
        dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
        return NSClassFromString("MBAssessmentModeAssertion") != nil
    }

    /// `temporary`: a reveal on top of the normal hide; `base` keeps the normal allowlist to restore.
    static func allow(bundles: Set<String>, retries: Int = 0, temporary: Bool = false) {
        load()
        let targetBase = temporary ? activeBase : bundles
        supersede()
        _ = pendingAssertion?.perform(NSSelectorFromString("invalidate"))
        pendingAssertion = nil
        let effectiveBundles = bundles.union(launching)
        let generation = generation
        guard let made = activation(effectiveBundles) else { return }
        let inst = made.assertion
        let completion: @convention(block) (NSError?) -> Void = { err in
            DispatchQueue.main.async {
                guard generation == self.generation, pendingAssertion === inst else { return }
                finishActivation(inst, succeeded: err == nil)
                if let err {
                    debugLog("nahd: assessment activate failed: \(err)")
                    if retries > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            guard generation == self.generation else { return }
                            debugLog("nahd: Clock bridge restore retry; \(retries) remaining")
                            allow(bundles: bundles, retries: retries - 1)
                        }
                    }
                } else {
                    lastBundles = bundles
                    base = targetBase
                    debugLog("nahd: assessment hide %@", allowlistChange(from: appliedBundles, to: effectiveBundles))
                    appliedBundles = effectiveBundles
                }
            }
        }
        pendingAssertion = inst
        // Launch admissions stay in `launching` only; folded in here they outlived their app and kept `isRevealing` true.
        requestedBundles = bundles
        requestedBase = targetBase
        if let ex = NAHDTrap({ made.activate(completion) }) {
            debugLog("nahd: assessment threw \(ex.name.rawValue): \(ex.reason ?? "")")
            finishActivation(inst, succeeded: false)
            return
        }
        lastApplied = Date()
        if observer == nil {
            // Focus/DND changes can silently tear the assertion down (same subsystem).
            // Our own activation posts this too, hence the 1.5s self-change window (Thaw's value).
            observer = DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.donotdisturb.stateChanged"), object: nil, queue: .main
            ) { _ in
                guard clockBridge == nil, assertion != nil, let b = lastBundles, Date().timeIntervalSince(lastApplied) > 1.5 else { return }
                debugLog("nahd: DND state changed; re-applying assessment hide")
                allow(bundles: b, temporary: true)
            }
        }
        if clockMonitor == nil {
            clockMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { event in
                guard assertion != nil, clockBridge == nil,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      let point = event.cgEvent?.location,
                      point.y <= NSStatusBar.system.thickness + 8,
                      extraItems().contains(where: { $0.isClock && $0.bundleID == "com.apple.MenuBarAgent" && $0.frame.contains(point) }),
                      let bundles = base else { return }
                bridgeClock(at: point, bundles: bundles)
            }
        }
    }

    typealias Completion = @convention(block) (NSError?) -> Void
    /// Builds the assertion for `bundles` and its activate call. `--check` swaps in a stand-in
    /// so self-tests run the real bookkeeping without ever reaching MenuBarAgent.
    static var activation: (Set<String>) -> (assertion: AnyObject, activate: (@escaping Completion) -> Void)? = menuBarActivation

    private static func menuBarActivation(_ bundles: Set<String>) -> (assertion: AnyObject, activate: (@escaping Completion) -> Void)? {
        guard let Config = NSClassFromString("MBAssessmentModeConfiguration"),
              let Assertion = NSClassFromString("MBAssessmentModeAssertion")
        else {
            debugLog("nahd: MenuBarClientCore assessment API missing")
            return nil
        }

        // MenuBarClientCore treats this as a Swift Array and calls objectAtIndex:.
        let systemItems = (0...8).map { NSNumber(value: $0) } as NSArray
        let bundleList = Array(bundles) as NSArray
        let allocCfg = (Config as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as AnyObject
        let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard let config = allocCfg.perform(initSel, with: systemItems, with: bundleList)?.takeUnretainedValue()
        else {
            debugLog("nahd: assessment config init failed")
            return nil
        }

        let allocAs = (Assertion as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as AnyObject
        guard let inst = allocAs.perform(NSSelectorFromString("init"))?.takeUnretainedValue() else {
            debugLog("nahd: assessment assertion init failed")
            return nil
        }

        let sel = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        typealias Activate = @convention(c) (AnyObject, Selector, AnyObject, Completion) -> Void
        let imp = class_getMethodImplementation(object_getClass(inst), sel)
        guard let imp else {
            debugLog("nahd: assessment activate IMP missing")
            return nil
        }
        let fn = unsafeBitCast(imp, to: Activate.self)
        return (inst, { completion in fn(inst, sel, config, completion) })
    }

    private static var lastBundles: Set<String>?
    private static var requestedBundles: Set<String>?
    private static var requestedBase: Set<String>?
    private static var base: Set<String>?
    private static var lastApplied = Date.distantPast
    private static var observer: Any?
    private static var clockMonitor: Any?
    private static var clockBridge: Timer?
    /// Clock bridge holds the assertion released and will restore `base` itself.
    static var bridging: Bool { clockBridge != nil }
    /// The normal allowlist while hiding is in force; nil while everything is shown.
    static var activeBase: Set<String>? { pendingAssertion != nil ? requestedBase : (assertion == nil ? nil : base) }
    static var isRevealing: Bool {
        guard let current = pendingAssertion != nil ? requestedBundles : lastBundles, let base = activeBase else { return false }
        return !current.subtracting(base).subtracting(launching).isEmpty
    }
    /// Bumped on every assertion change; async callers compare it to detect being superseded.
    private(set) static var generation = 0

    private static func bridgeClock(at point: CGPoint, bundles: Set<String>) {
        invalidate()
        debugLog("nahd: Clock bridge released assessment")
        var ticks = 0
        var opened = false
        // Notification Center is below status-window level, unlike item menus.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            ticks += 1
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let visible = pid != nil && windows.contains {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 21
            }
            if visible {
                if !opened { debugLog("nahd: Clock bridge Notification Center opened") }
                opened = true
            } else if shouldRestoreClock(visible: visible, opened: opened, ticks: ticks) {
                debugLog("nahd: Clock bridge restoring assessment (\(opened ? "closed" : "open timed out"))")
                // Direct activation bypasses the DND observer's anti-flap window.
                allow(bundles: bundles, retries: 2)
            } else if ticks == 4 {
                // Global monitors cannot consume the original click; replay once only if it was lost.
                debugLog("nahd: Clock bridge replaying click")
                ClickForwarder.click(at: point)
            }
        }
        clockBridge = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static func shouldRestoreClock(visible: Bool, opened: Bool, ticks: Int) -> Bool {
        !visible && (opened || ticks >= 12)
    }

    /// Un-hide just these apps on top of what's already visible. Un-hiding everything
    /// overflows a narrow bar and macOS collapses the target behind its « chevron.
    static func reveal(_ bundles: Set<String>) {
        guard let current = pendingAssertion != nil ? requestedBundles : lastBundles,
              assertion != nil || pendingAssertion != nil, !bundles.isEmpty else { return }
        allow(bundles: current.union(bundles), temporary: true)
    }

    /// Allowed (via `launching`) before its item registers, or macOS drops the item; not a reveal.
    static func admitLaunchingBundle(_ bundle: String) {
        launching.insert(bundle)
        guard activeBase != nil, !bridging,
              let current = pendingAssertion != nil ? requestedBundles : lastBundles else { return }
        allow(bundles: current, temporary: true)
    }

    static func finishLaunchingBundles(_ bundles: Set<String>) {
        launching.subtract(bundles)
    }

    static func pruneLaunchingBundles(_ bundles: Set<String>) {
        launching.formIntersection(bundles)
    }

    static func shutdown() {
        invalidate()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        if let clockMonitor { NSEvent.removeMonitor(clockMonitor) }
        observer = nil
        clockMonitor = nil
    }

    /// End a `reveal`: back to the normal allowlist in one re-layout.
    static func restoreBase() {
        guard !bridging, let base else { return }
        allow(bundles: base)
    }

    static func invalidate() {
        supersede()
        _ = pendingAssertion?.perform(NSSelectorFromString("invalidate"))
        pendingAssertion = nil
        _ = assertion?.perform(NSSelectorFromString("invalidate"))
        assertion = nil
        launching.removeAll()
        appliedBundles = nil
    }

    /// The allowlist in force, for logging only what each change adds or removes.
    private static var appliedBundles: Set<String>?

    /// "allowing 26 (+[a] -[b])"; the full list only when hiding starts from nothing.
    static func allowlistChange(from old: Set<String>?, to new: Set<String>) -> String {
        guard let old else { return "allowing \(new.count): \(new.sorted())" }
        let added = new.subtracting(old).sorted(), removed = old.subtracting(new).sorted()
        if added.isEmpty && removed.isEmpty { return "allowing \(new.count) (unchanged)" }
        return "allowing \(new.count) (" + [added.isEmpty ? nil : "+\(added)", removed.isEmpty ? nil : "-\(removed)"]
            .compactMap { $0 }.joined(separator: " ") + ")"
    }

    private static func supersede() {
        generation += 1
        clockBridge?.invalidate()
        clockBridge = nil
    }

    private static func finishActivation(_ instance: AnyObject, succeeded: Bool) {
        guard pendingAssertion === instance else { return }
        pendingAssertion = nil
        if succeeded {
            let previous = assertion
            assertion = instance
            _ = previous?.perform(NSSelectorFromString("invalidate"))
        } else {
            _ = instance.perform(NSSelectorFromString("invalidate"))
        }
    }

    /// Hand-off bookkeeping with stand-ins; never reaches MenuBarAgent.
    static func checkHandOff() {
        let a = FakeAssertion(), b = FakeAssertion(), c = FakeAssertion()
        assertion = a
        pendingAssertion = b
        finishActivation(b, succeeded: false)
        check(assertion === a && a.released == 0 && b.released == 1, "failure keeps active hide")
        pendingAssertion = c
        finishActivation(b, succeeded: true)
        check(assertion === a && pendingAssertion === c, "stale completion cannot replace state")
        finishActivation(c, succeeded: true)
        check(assertion === c && a.released == 1 && c.released == 0, "success replaces active hide")
        let d = FakeAssertion(); pendingAssertion = d
        let g = generation
        invalidate()
        check(c.released == 1 && d.released == 1 && assertion == nil && pendingAssertion == nil && generation == g + 1,
                     "invalidate releases everything")
        finishActivation(d, succeeded: true)
        check(c.released == 1, "answer after invalidate is a no-op")
    }

    /// Relaunch path (Air log 2026-11-05: Rex stayed visible 07:13 to 09:06) with a stand-in activation.
    @MainActor static func checkLaunchAdmissions() async {
        let real = activation
        var applied: [Set<String>] = []
        activation = { bundles in
            applied.append(bundles)
            return (FakeAssertion(), { completion in completion(nil) })
        }
        func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }  // completions hop through the main queue
        allow(bundles: ["base"]); await settle()
        check(activeBase == ["base"] && !isRevealing, "plain hide")
        admitLaunchingBundle("quits.early"); await settle()
        check(applied.last == ["base", "quits.early"], "a launching app is allowed before its item registers")
        check(!isRevealing, "an admission is not a reveal")
        pruneLaunchingBundles([])  // it quit before its item was filed
        check(!isRevealing, "a quit admission must not block re-hiding later launches")
        admitLaunchingBundle("relaunched"); await settle()
        check(applied.last == ["base", "relaunched"], "the quit admission is dropped at the next change")
        reveal(["clicked"]); await settle()
        check(isRevealing && applied.last == ["base", "relaunched", "clicked"], "a click-through reveal still counts")
        finishLaunchingBundles(["relaunched"]); restoreBase(); await settle()
        check(!isRevealing && applied.last == ["base"], "re-hide returns to the base allowlist")
        shutdown()
        activation = real
        check(allowlistChange(from: nil, to: ["b", "a"]) == "allowing 2: [\"a\", \"b\"]", "first hide lists everything")
        check(allowlistChange(from: ["a", "b"], to: ["a", "c"]) == "allowing 2 (+[\"c\"] -[\"b\"])", "later changes list only the difference")
        check(allowlistChange(from: ["a"], to: ["a"]) == "allowing 1 (unchanged)", "re-apply")
        print("launch admission self-check OK: admit, quit, relaunch, reveal, re-hide, log diff")
    }
}

private final class FakeAssertion: NSObject {
    var released = 0
    @objc func invalidate() { released += 1 }
}
