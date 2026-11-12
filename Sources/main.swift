import AppKit

if CommandLine.arguments.contains("--check") {
    Task { @MainActor in
        runSelfCheck()
        await checkOwnershipSweep()
        await AssessmentHide.checkLaunchAdmissions()
        exit(0)
    }
    dispatchMain()
}

if let i = CommandLine.arguments.firstIndex(of: "--dump-app"), i + 1 < CommandLine.arguments.count {
    print("accessibility=\(AXIsProcessTrusted())")
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]) {
        print("pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue) finishedLaunching=\(app.isFinishedLaunching)")
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var extras: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &extras)
        print("AXExtrasMenuBar result=\(result.rawValue) value=\(String(describing: extras)) owns=\(ownsMenuBarExtras(app.processIdentifier))")
        dumpAXTree(pid: app.processIdentifier)
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    print("mode=assessment assessment=\(AssessmentHide.available)")
    print("accessibility=\(AXIsProcessTrusted())")
    for screen in NSScreen.screens {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        print("display=\(id) AppKit=\(screen.frame) CG=\(CGDisplayBounds(id))")
    }
    for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent") {
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        print("MenuBarAgent pid=\(agent.processIdentifier) childrenResult=\(result.rawValue) children=\(String(describing: children))")
    }
    print("ax extras:")
    dumpExtraTree()
    for w in extraItems() {
        print("  \(w.label ?? "-") [\(w.appName)] pid=\(w.pid) bid=\(w.bundleID ?? "-") \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height))")
    }
    exit(0)
}

// `--snap <dir>`: write the composite crops the drop-down would show, as PNGs.
if let i = CommandLine.arguments.firstIndex(of: "--snap"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    let extras = extraItems()
    let sem = DispatchSemaphore(value: 0)
    Task {
        for (id, img) in await captureExtrasFromMenuBar(extras, trigger: "snap") {
            let name = extras.first { $0.id == id }?.appName ?? "\(id)"
            let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name.prefix(20)).png"))
            print(name, img.size, rep.pixelsWide, rep.pixelsHigh)
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// With debug logging on, NSLog lands here; keeps debugging possible without terminal-launching,
// which would misattribute TCC permissions to the terminal.
if debugLogging {
    freopen(("\(NSHomeDirectory())/Library/Logs/NotAHotDog.log" as NSString).utf8String, "a", stderr)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
