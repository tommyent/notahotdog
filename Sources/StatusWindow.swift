import AppKit

struct StatusWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let frame: CGRect  // global, top-left origin (CGWindowList / AX)
    var bundleID: String? = nil
    /// macOS 27's native « chevron. Items left of it are collapsed off the bar.
    var isOverflowChevron = false
    var isClock = false
    /// What the Shelf shows. `appName` stays the raw AX label: click routing and the overflow state match on it.
    var label: String? = nil

    var overflowExpanded: Bool? {
        guard isOverflowChevron else { return nil }
        if Self.overflowLabels["menuBar.hideOverflowItemsAccessibilityLabel"]?.contains(appName) == true { return true }
        if Self.overflowLabels["menuBar.showOverflowItemsAccessibilityLabel"]?.contains(appName) == true { return false }
        return nil
    }

    // Use the host's translations, including per-app language overrides.
    private static let overflowLabels: [String: Set<String>] = {
        var result = ["menuBar.hideOverflowItemsAccessibilityLabel": Set(["Hide Menu Bar Items"]),
                      "menuBar.showOverflowItemsAccessibilityLabel": Set(["Show Hidden Menu Bar Items"])]
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        if let data = try? Data(contentsOf: url),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for case let values as [String: String] in table.values {
                for key in Array(result.keys) { if let value = values[key] { result[key]?.insert(value) } }
            }
        }
        return result
    }()
}
