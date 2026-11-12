import AppKit
import ScreenCaptureKit
import ServiceManagement
import Sparkle

let ownBundleID = Bundle.main.bundleIdentifier ?? "com.tommyent.notahotdog"

/// The menu-bar glyph: a hot dog, drawn as a template so it follows the bar's light or dark look.
private let hotDogIcon: NSImage? = {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18" fill="none">
    <path d="M6.1 3.25 C4.65 3.4 3.75 4.6 3.75 6.15 V11.85 C3.75 13.4 4.65 14.6 6.1 14.75" stroke="black" stroke-width="1.35" stroke-linecap="round"/>
    <path d="M11.9 3.25 C13.35 3.4 14.25 4.6 14.25 6.15 V11.85 C14.25 13.4 13.35 14.6 11.9 14.75" stroke="black" stroke-width="1.35" stroke-linecap="round"/>
    <rect x="6.25" y="2" width="5.5" height="14" rx="2.75" stroke="black" stroke-width="1.35"/>
    <path d="M9 4.3 C7.9 5.05 10.1 5.75 9 6.55 C7.9 7.35 10.1 8.05 9 8.85 C7.9 9.65 10.1 10.35 9 11.15 C7.9 11.95 10.1 12.65 9 13.45" stroke="black" stroke-width="1.15" stroke-linecap="round"/>
    </svg>
    """
    // An OS that can't read SVG gets the chevron instead of an empty button.
    let image = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "chevron.down.2", accessibilityDescription: nil)
    image?.isTemplate = true
    return image
}()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one menu-bar control: it opens the drop-down, and icons left of it are hidden.
    private let control = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: BarPanel?
    private var panelStyle: PanelStyle {
        PanelStyle(rawValue: UserDefaults.standard.string(forKey: "panelStyle") ?? "") ?? .shelf
    }
    private var cachedImages: [CGWindowID: NSImage] = [:]
    private var cachedHidden: [StatusWindow] = []
    /// Arranging: everything visible, so icons can be ⌘-dragged across the control.
    private var showAll = false { didSet { updateControl() } }
    private var refreshTask: Task<Void, Never>?
    private var requestedScreenCapture = false
    private var requestedAccessibility = false
    /// Accessibility finds and clicks items; without it hidden items would be unreachable.
    /// Screen Recording is optional: without it the drop-down shows app icons.
    private var permissionsReady: Bool { AXIsProcessTrusted() }
    /// The allowlist hides extras of apps launched after the last capture, so they must be recaptured.
    private var pendingApps: Set<pid_t> = []
    private var capturedApps: Set<pid_t> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var launchSettling: Task<Void, Never>?
    private var runningObservation: NSKeyValueObservation?
    private var observedApps: Set<pid_t> = []
    private var shelfRequestAt: TimeInterval?
    private var ownershipTask: Task<Void, Never>?
    private var ownershipAnswers: [pid_t: Bool] = [:]
    /// Sparkle: asks before its first automatic check, then checks the feed in Info.plist.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The old "/" separator's slot, so upgrading keeps every icon on its side of the boundary.
        control.autosaveName = "nahd.separator"
        control.button?.target = self
        control.button?.action = #selector(controlClicked)
        control.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateControl()
        pendingApps = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)).subtracting([getpid()])
        let notifications = NSWorkspace.shared.notificationCenter
        observedApps = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] workspace, _ in
            let apps = workspace.runningApplications
            DispatchQueue.main.async {
                guard let self else { return }
                let current = Set(apps.map(\.processIdentifier))
                for app in apps where !self.observedApps.contains(app.processIdentifier) { self.applicationLaunched(app) }
                self.pendingApps.formIntersection(current)
                self.capturedApps.formIntersection(current)
                self.ownershipAnswers = self.ownershipAnswers.filter { current.contains($0.key) }
                self.cachedHidden.removeAll { !current.contains($0.pid) }
                self.trimImages()
                AssessmentHide.pruneLaunchingBundles(Set(apps.compactMap(\.bundleIdentifier)))
                self.observedApps = current
                self.observeMenuBar()  // no-op unless MenuBarAgent restarted
            }
        }
        workspaceObservers.append(notifications.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.applicationLaunched(app) }
        })
        workspaceObservers.append(notifications.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self.pendingApps.remove(app.processIdentifier)
                self.capturedApps.remove(app.processIdentifier)
                self.ownershipAnswers.removeValue(forKey: app.processIdentifier)
                if let bundle = app.bundleIdentifier { AssessmentHide.finishLaunchingBundles([bundle]) }
                guard self.cachedHidden.contains(where: { $0.pid == app.processIdentifier }) else { return }
                self.cachedHidden.removeAll { $0.pid == app.processIdentifier }
                self.trimImages()
                self.panel?.dismiss()
            }
        })
        debugLog("nahd: mode=assessment macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) available=\(AssessmentHide.available)")
        observeMenuBar()
        recaptureThenHide()
    }

    private func applicationLaunched(_ app: NSRunningApplication) {
        // Background-only processes (XPC services, WebKit helpers) can't own a menu-bar item, so admitting
        // them only churned the allowlist. Apps that may add an item later stay admitted while they run:
        // an item registered while hidden is dropped (WhatCable, 2026-11-03), so "owns none yet" is not "never".
        guard app.processIdentifier != getpid(), app.bundleIdentifier != ownBundleID,
              app.activationPolicy != .prohibited,
              pendingApps.insert(app.processIdentifier).inserted else { return }
        if let bundle = app.bundleIdentifier {
            debugLog("nahd: admitting launch pid=%d bundle=%@", app.processIdentifier, bundle)
            AssessmentHide.admitLaunchingBundle(bundle)
        }
        launchSettling?.cancel()
        launchSettling = Task { @MainActor [weak self] in
            // Bounded launch polling (about 50 s), the fallback for the menu-bar observer below.
            for delay: UInt64 in [400_000_000, 800_000_000, 1_600_000_000, 3_200_000_000, 6_400_000_000, 12_800_000_000, 25_600_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                guard await self.fileReadyApps() else { return }
            }
            self?.launchSettling = nil
        }
    }

    /// Files launched apps whose items are now on the bar. False when filing can't run at all right now.
    private func fileReadyApps() async -> Bool {
        guard permissionsReady, !showAll, !AssessmentHide.bridging else { return false }
        if refreshTask != nil || AssessmentHide.isRevealing { return true }
        let ready = pendingApps.intersection(extraItems().map(\.pid))
        if !ready.isEmpty { await revealNewApps(ready) }
        return true
    }

    // MenuBarAgent posts AXCreated for new elements (Air, 2026-11-05: 55 in 10.7 min, all other apps'
    // tooltips and windows); all its notifications together ran at about 17 a second, so only AXCreated is observed.
    private var barObserver: (pid: pid_t, observer: AXObserver)?
    private var barChangeTask: Task<Void, Never>?

    private func observeMenuBar() {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              barObserver?.pid != agent.processIdentifier else { return }
        if let old = barObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old.observer), .defaultMode) }
        barObserver = nil
        var made: AXObserver?
        guard AXObserverCreate(agent.processIdentifier, { _, _, _, refcon in
            guard let refcon else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { delegate.menuBarElementCreated() }
        }, &made) == .success, let made,
              AXObserverAddNotification(made, AXUIElementCreateApplication(agent.processIdentifier),
                                        kAXCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success
        else { return debugLog("nahd: menu-bar observer unavailable; launch polling only") }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        barObserver = (agent.processIdentifier, made)
    }

    /// Coalesces a burst of creations, then files any launched app whose item just appeared.
    private func menuBarElementCreated() {
        guard !pendingApps.isEmpty, barChangeTask == nil else { return }
        barChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            defer { self.barChangeTask = nil }
            let before = self.pendingApps
            _ = await self.fileReadyApps()
            if self.pendingApps != before { debugLog("nahd: menu-bar observer filed %@", before.subtracting(self.pendingApps).sorted().description) }
        }
    }

    /// Arranging, the control reads "Done": the marker to drag icons across, and the way out.
    private func updateControl() {
        guard let button = control.button else { return }
        if showAll {
            control.length = NSStatusItem.variableLength
            button.image = nil
            button.title = "Done"
            button.setAccessibilityLabel("Done arranging")
            button.toolTip = "⌘-drag icons left of Done to hide them, then click Done"
        } else {
            control.length = NSStatusItem.squareLength
            button.title = ""
            button.image = hotDogIcon
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Not A Hot Dog")
            button.toolTip = "Click for hidden icons, right-click for settings"
        }
    }

    /// Launching the already-running app (Raycast, Spotlight, Finder) opens the drop-down,
    /// or ends arranging: a crowded bar can push the Done control behind macOS's overflow.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if showAll {
            toggleShowAll()
        } else if panel == nil {
            showBar()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchSettling?.cancel()
        runningObservation?.invalidate()
        runningObservation = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        restoreItems()
        AssessmentHide.shutdown()
    }

    private func restoreItems() {
        ownershipTask?.cancel()
        ownershipTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        ClickForwarder.cancel()
        panel?.dismiss()
        AssessmentHide.invalidate()
        cachedImages.removeAll()
        cachedHidden.removeAll()
    }

    /// Capture at launch and after Arrange; later refreshes reveal only new apps.
    private func recaptureThenHide(openAfter: Bool = false) {
        guard permissionsReady else {
            restoreItems()
            return
        }
        if AssessmentHide.bridging { return }
        refreshTask?.cancel()
        ClickForwarder.cancel()
        refreshTask = Task { @MainActor in
            await recaptureCompositeThenHide()
            guard !Task.isCancelled else { return }
            guard permissionsReady else {
                restoreItems()
                return
            }
            refreshTask = nil
            if openAfter || panel != nil { presentBar() }
        }
    }

    private func recaptureCompositeThenHide() async {
        // e.g. a forwarded menu closed because the user clicked the Clock: don't cancel that bridge.
        if AssessmentHide.bridging { return }
        AssessmentHide.invalidate()
        let token = AssessmentHide.generation
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, permissionsReady, token == AssessmentHide.generation else { return }
        let extras = extraItems()
        // Items collapsed behind the native « aren't drawn, so their crops are blank/wrong; captureCollapsed gets them.
        let chevronX = collapsedBeforeX(extras)
        guard let sepX = ourSeparatorMinX(from: extras, pid: getpid()) else {
            cachedHidden.removeAll()
            cachedImages.removeAll()
            return
        }
        var allowed: Set<String> = [ownBundleID, "com.apple.controlcenter", "com.apple.MenuBarAgent"]
        for extra in extras where extra.frame.minX >= sepX {
            if let bid = extra.bundleID { allowed.insert(bid) }
        }
        cachedHidden = hiddenWindowsLeftOfSeparator(from: extras, excludingPID: getpid(), separatorMinX: sepX)
            .filter { !allowed.contains($0.bundleID ?? "") }
        pendingApps.subtract(extras.map(\.pid))
        capturedApps.formUnion(extras.map(\.pid))
        let fresh = await captureExtrasFromMenuBar(cachedHidden.filter { $0.frame.minX >= chevronX }, trigger: "full recapture")
        guard !Task.isCancelled, permissionsReady, token == AssessmentHide.generation else { return }
        cachedImages = fresh
        let collapsed = cachedHidden.filter { $0.frame.minX < chevronX }
        debugLog("nahd: composite extras: \(extras.map { "\($0.appName)@\(Int($0.frame.minX))" }.joined(separator: ", "))")
        debugLog("nahd: composite hidden: \(cachedHidden.map { "\($0.appName)@\(Int($0.frame.minX))" }.joined(separator: ", "))")
        // A Clock bridge or click forward may have taken over the assertion while we slept.
        if showAll || cachedHidden.isEmpty || token != AssessmentHide.generation { return }
        AssessmentHide.allow(bundles: allowed)
        await captureCollapsed(collapsed, base: allowed)
    }

    /// A full recapture shows every hidden icon for 0.4 s, so after new menu-bar apps
    /// launch, reveal only them and file their icons; everything else stays put.
    private func revealNewApps(_ launched: Set<pid_t>) async {
        guard let base = AssessmentHide.activeBase else { return await recaptureCompositeThenHide() }
        let bundles = Set(launched.compactMap(bundleID(forPID:))).subtracting(base)
        pendingApps.subtract(launched.filter { base.contains(bundleID(forPID: $0) ?? "") })
        guard !bundles.isEmpty else { return }
        AssessmentHide.reveal(bundles)
        let token = AssessmentHide.generation
        defer {
            if Task.isCancelled && token == AssessmentHide.generation { AssessmentHide.restoreBase() }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled, permissionsReady, token == AssessmentHide.generation else { return }
        let extras = extraItems()
        guard let sepX = ourSeparatorMinX(from: extras, pid: getpid()) else { return AssessmentHide.restoreBase() }
        let found = Set(extras.compactMap(\.bundleID)).intersection(bundles)
        guard !found.isEmpty else {
            if CommandLine.arguments.contains("--trace-ownership") {
                dumpExtraTree()
                for pid in launched { dumpAXTree(pid: pid) }
                fflush(stdout)
            }
            debugLog("nahd: new apps \(bundles.subtracting(found).sorted()) didn't appear; restoring hide without full reveal")
            AssessmentHide.restoreBase()
            return
        }
        let filed = fileNewIcons(extras, bundles: found, separatorMinX: sepX, cached: cachedHidden)
        let chevronX = collapsedBeforeX(extras)
        let added = filed.hidden.filter { found.contains($0.bundleID ?? "") }
        let shots = await captureExtrasFromMenuBar(added.filter { $0.frame.minX >= chevronX }, trigger: "new apps")
        guard !Task.isCancelled, token == AssessmentHide.generation else { return }
        cachedImages.merge(shots) { _, new in new }
        cachedHidden = filed.hidden
        trimImages()
        let filedPIDs = launched.filter { found.contains(bundleID(forPID: $0) ?? "") }
        pendingApps.subtract(filedPIDs)
        capturedApps.formUnion(filedPIDs)
        AssessmentHide.finishLaunchingBundles(found)
        debugLog("nahd: new apps \(found.sorted()): hiding \(added.map(\.appName)), showing \(filed.shown.sorted())")
        AssessmentHide.allow(bundles: base.union(filed.shown))
        if panel != nil { presentBar() }
    }

    /// A hidden item is drawn nowhere (macOS 27 keeps no per-item window), so its Shelf glyph can only be
    /// refreshed while it's on the bar anyway: after a click-through, just before it hides again.
    /// No extra reveal; the re-hide waits for one capture.
    private func refreshImage(of item: StatusWindow, then rehide: @escaping () -> Void) {
        let forward = ClickForwarder.generation, layout = AssessmentHide.generation
        Task { @MainActor in
            // Only a newer click-through or recapture owns the bar now; a launch admission must not keep the item shown.
            defer { if forward == ClickForwarder.generation { rehide() } }
            let extras = extraItems()
            // Items behind the native « are mid-collapse here (finish() just closed the overflow): keep their old glyph.
            let chevronX = extras.first(where: \.isOverflowChevron)?.frame.minX ?? -.infinity
            guard let live = liveMatch(for: item, in: extras), live.frame.minX >= chevronX,
                  let image = await captureExtrasFromMenuBar([live], trigger: "click-through")[live.id],
                  layout == AssessmentHide.generation, cachedHidden.contains(where: { $0.id == item.id })
            else { return }
            cachedImages[item.id] = image
        }
    }

    private func trimImages() {
        let ids = Set(cachedHidden.map(\.id))
        cachedImages = cachedImages.filter { ids.contains($0.key) }
    }

    /// Second pass for items macOS collapsed behind « during the full reveal: show only
    /// them (plus what's normally visible) so they fit on the bar, photograph, re-hide.
    private func captureCollapsed(_ collapsed: [StatusWindow], base: Set<String>) async {
        let bundles = Set(collapsed.compactMap(\.bundleID)).subtracting(base)
        guard !bundles.isEmpty else { return }
        AssessmentHide.reveal(bundles)
        let token = AssessmentHide.generation
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard token == AssessmentHide.generation else { return }
        let live = extraItems()
        let chevronX = collapsedBeforeX(live)
        var pairs: [(old: CGWindowID, new: StatusWindow)] = []
        for item in collapsed {
            if let m = liveMatch(for: item, in: live), m.frame.minX >= chevronX { pairs.append((item.id, m)) }
        }
        let shots = await captureExtrasFromMenuBar(pairs.map(\.new), trigger: "collapsed pass")
        for p in pairs { cachedImages[p.old] = shots[p.new.id] }
        debugLog("nahd: collapsed pass captured \(pairs.count)/\(collapsed.count)")
        if !showAll && token == AssessmentHide.generation { AssessmentHide.allow(bundles: base) }
    }

    @objc private func controlClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel?.dismiss()
            showMenu()
        } else if showAll {
            toggleShowAll()
        } else if panel != nil {
            panel?.dismiss()
        } else {
            showBar()
        }
    }

    private func showBar() {
        shelfRequestAt = ProcessInfo.processInfo.systemUptime
        debugLog("nahd: shelf requested")
        guard permissionsReady else {
            restoreItems()
            showMenu()
            return
        }
        if showAll {
            showMenu()
        } else if cachedHidden.isEmpty {
            recaptureThenHide(openAfter: true)
        } else {
            ownershipTask?.cancel()
            ownershipTask = showThenReconcile(show: {
                presentBar()
            }, candidates: {
                let apps = NSWorkspace.shared.runningApplications
                pendingApps.formUnion(Set(apps.map(\.processIdentifier)).subtracting(capturedApps).subtracting([getpid()]))
                return Array(apps.filter {
                    $0.activationPolicy != .prohibited && $0.bundleIdentifier != nil &&
                    $0.bundleIdentifier != ownBundleID && pendingApps.contains($0.processIdentifier) &&
                    ownershipAnswers[$0.processIdentifier] == nil
                }.map(\.processIdentifier).sorted().prefix(32))
            }, sweep: { candidates in
                var answers: [OwnershipAnswer] = []
                for pid in candidates {
                    guard !Task.isCancelled else { break }
                    answers.append(OwnershipAnswer(pid: pid, owns: menuBarOwnership(pid)))
                }
                return answers
            }, update: { [weak self] answers in
                guard let self, self.permissionsReady, !self.showAll else { return }
                let live = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                for answer in answers where live.contains(answer.pid) {
                    if let owns = answer.owns { self.ownershipAnswers[answer.pid] = owns }
                }
                let owners = self.pendingApps.intersection(live).filter { self.ownershipAnswers[$0] == true }
                debugLog("nahd: ownership sweep checked=%d owners=%@", answers.count, owners.sorted().description)
                if self.refreshTask == nil && !AssessmentHide.bridging && !AssessmentHide.isRevealing && !owners.isEmpty {
                    await self.revealNewApps(owners)
                }
                guard !Task.isCancelled else { return }
                self.ownershipTask = nil
            })
        }
    }

    private func presentBar() {
        guard permissionsReady else {
            restoreItems()
            return
        }
        guard let button = control.button, let window = button.window, let screen = window.screen else { return }
        let hidden = cachedHidden
        debugLog("nahd: hidden items: \(hidden.map { "\($0.appName)@\(Int($0.frame.minX))" }.joined(separator: ", "))")
        guard !hidden.isEmpty else {
            showMenu()
            return
        }
        let p = panel ?? BarPanel()
        p.onItemClick = { [weak self] w in
            guard let self else { return }
            guard self.permissionsReady else {
                self.restoreItems()
                self.showMenu()
                return
            }
            let reveal = {
                AssessmentHide.reveal(Set([w.bundleID].compactMap { $0 }))
            }
            ClickForwarder.forwardExtra(w, reveal: reveal, rehide: { [weak self] in
                guard let self else { return AssessmentHide.restoreBase() }
                self.refreshImage(of: w) { AssessmentHide.restoreBase() }
            })
        }
        p.onSettings = { [weak self] in self?.showMenu() }
        p.onDismiss = { [weak self] in self?.panel = nil }
        panel = p
        p.show(windows: hidden, images: cachedImages, anchor: window.frame, on: screen,
               appearance: button.effectiveAppearance, style: panelStyle)
        if let start = shelfRequestAt {
            debugLog("nahd: shelf visible=%d request_ms=%.3f", p.isVisible ? 1 : 0,
                  (ProcessInfo.processInfo.systemUptime - start) * 1000)
            shelfRequestAt = nil
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        // Named by what it does: macOS 27 titles the Accessibility prompt "Device Control and Data Access".
        if !AXIsProcessTrusted() {
            let item = NSMenuItem(title: "Allow Control of This Mac (required)…", action: #selector(enableAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !CGPreflightScreenCaptureAccess() {
            let item = NSMenuItem(title: "Allow Screen Recording (optional, shows real icons)…", action: #selector(enableScreenCapture), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let hint: String? = if !permissionsReady {
            "Icons stay visible until control is allowed"
        } else if showAll {
            "⌘-drag icons left of Done to hide them"
        } else if cachedHidden.isEmpty {
            "Nothing hidden: choose Arrange Icons, then ⌘-drag icons left of Done"
        } else {
            nil
        }
        if let hint {
            menu.addItem(NSMenuItem(title: hint, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        let arrangeItem = NSMenuItem(title: showAll ? "Done Arranging" : "Arrange Icons", action: #selector(toggleShowAll), keyEquivalent: "")
        arrangeItem.target = self
        menu.addItem(arrangeItem)

        let styles = NSMenu(title: "Panel Style")
        for style in PanelStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectPanelStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == panelStyle ? .on : .off
            styles.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Panel Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styles
        menu.addItem(styleItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About Not A Hot Dog", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updater
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Quit Not A Hot Dog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        control.menu = menu
        control.button?.performClick(nil)
        control.menu = nil
    }

    @objc private func showAbout() {
        NSApp.activate()  // an accessory app's panel would open behind the frontmost app
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func selectPanelStyle(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let style = PanelStyle(rawValue: value) else { return }
        UserDefaults.standard.set(style.rawValue, forKey: "panelStyle")
    }

    @objc private func enableScreenCapture() {
        if !requestedScreenCapture {
            requestedScreenCapture = true
            CGRequestScreenCaptureAccess()
        }
        // A real capture request as well: on macOS 27.0.1 CGRequestScreenCaptureAccess alone never put the
        // app in the Screen Recording list; with this request it is listed (both observed, 2026-11-11).
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func enableAccessibility() {
        if !requestedAccessibility {
            requestedAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Arrange: reveals everything so icons can be ⌘-dragged across the control.
    @objc private func toggleShowAll() {
        showAll.toggle()
        if showAll {
            restoreItems()
        } else {
            recaptureThenHide()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
