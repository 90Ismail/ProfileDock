import AppKit

struct Window: Decodable { let id: Int; let title: String; let tabCount: Int }
struct State: Decodable { let session: String; let connected: Bool; let updated: Double; let windows: [Window] }

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HoverTableView: NSTableView {
    private var hoverTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredRow = row(at: point)
        if hoveredRow >= 0 && hoveredRow != selectedRow { selectRowIndexes(IndexSet(integer: hoveredRow), byExtendingSelection: false) }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProfileDock/bridge")
    var key = "", label = "", directory = ""
    var timer: Timer?
    var grace = Date().addingTimeInterval(15)

    // Picker panel state (shown in-process — no child process, no
    // cross-process activation race, no IPC round trip to lose).
    var panel: NSPanel?
    var tableView: HoverTableView?
    var pickerWindows: [Window] = []
    var pickerState: State?
    var keyMonitor: Any?

    func state() -> State? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state/\(key).json")),
              let s = try? JSONDecoder().decode(State.self, from: data), s.connected,
              Date().timeIntervalSince1970 - s.updated < 5 else { return nil }
        return s
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let info = Bundle.main.infoDictionary!
        key = info["ProfileDockKey"] as? String ?? ""
        label = info["ProfileDockLabel"] as? String ?? key
        directory = info["ProfileDockDirectory"] as? String ?? "Default"
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
        if !CommandLine.arguments.contains("--indicator-only") { choose() }
    }

    func tick() {
        let heartbeat = root.appendingPathComponent("launchers/\(key).json")
        try? FileManager.default.createDirectory(at: heartbeat.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "updated": Date().timeIntervalSince1970]) { try? data.write(to: heartbeat, options: .atomic) }
        if panel == nil && Date() > grace && (state()?.windows.isEmpty ?? true) { NSApp.terminate(nil) }
        if let s = state(), !s.windows.isEmpty { grace = Date() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        choose()
        return false
    }

    func choose() {
        if let panel {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let s = state(), !s.windows.isEmpty else {
            grace = Date().addingTimeInterval(15)
            let chromeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
            if !chromeRunning {
                // A genuine cold start — nothing to hand off to, so
                // --profile-directory is honored directly and reliably here
                // (unlike when Chrome is already running for another
                // profile, where this same invocation is silently ignored).
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", "Google Chrome", "--args", "--profile-directory=\(directory)"]
                try? p.run()
                return
            }
            // Chrome's already running (for some other profile). Command-line
            // invocation (`open -a`, `-na`, or the raw binary) cannot reliably
            // make an already-running Chrome open a specific *other* profile
            // — none of them actually produced a window in testing, and `-n`
            // additionally spawns a genuinely separate, Dock-visible process.
            // Clicking Chrome's own Profiles menu is the one mechanism proven
            // reliable — but System Events automation needs Accessibility
            // permission, and each of the 6 launcher apps is its own bundle
            // identity (which would mean granting it 6 separate times, and
            // losing the grant on every rebuild's re-signing). So this is
            // delegated to the one shared native_host.py process instead:
            // one grant to that stable interpreter covers every profile.
            //
            // This profile has no window (that's why we're here), which
            // usually means ITS OWN native_host.py isn't even running — a
            // profile Chrome wasn't launched with and that has no window
            // typically has no active background context at all, so nobody
            // would ever see a request left in commands/<this-profile>/.
            // Instead this drops the request in one shared folder that every
            // *other*, currently-alive instance polls regardless of which
            // profile it serves.
            let folder = root.appendingPathComponent("open-requests")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["label": label]) {
                try? data.write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
            }
            return
        }
        if s.windows.count == 1 { focus(s.windows[0], s); return }
        showPicker(s)
    }

    func activateChrome() {
        // NSRunningApplication.activate() is the fast path; osascript's
        // "activate" verb is a proven fallback that reliably raises Chrome
        // even from a helper process with no foreground presence of its own.
        if let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
            chrome.activate(options: [])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Google Chrome\" to activate"]
        try? p.run()
    }

    func focus(_ window: Window, _ state: State) {
        let folder = root.appendingPathComponent("commands/\(key)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "focus", "session": state.session, "windowId": window.id]) {
            try? data.write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        }
        // chrome.windows.update({focused:true}) only reorders Chrome's own
        // internal window stack; it does not raise Chrome above other
        // applications at the OS level. Do that explicitly, after a short
        // delay so the extension has already processed the focus command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.activateChrome() }
    }

    // MARK: - Picker panel (in-process, no subprocess)

    func showPicker(_ s: State) {
        pickerWindows = s.windows
        pickerState = s

        let width: CGFloat = 390
        let rowHeight: CGFloat = 52
        let headerHeight: CGFloat = 36
        let footerHeight: CGFloat = 28
        let maxVisibleRows = 8
        let visibleRows = min(pickerWindows.count, maxVisibleRows)
        let tableHeight = CGFloat(visibleRows) * rowHeight
        // A couple of extra points of breathing room below the last row so
        // nothing ever reads as clipped against the footer hairline.
        let totalHeight = headerHeight + 1 + tableHeight + 4 + 1 + footerHeight

        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: totalHeight),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        self.panel = panel

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        let header = NSTextField(labelWithString: "\(label) · \(pickerWindows.count) windows")
        header.font = .boldSystemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 14, y: totalHeight - headerHeight, width: width - 28, height: headerHeight)
        header.lineBreakMode = .byTruncatingTail
        background.addSubview(header)
        background.addSubview(hairline(x: 0, y: totalHeight - headerHeight, width: width))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: footerHeight + 1, width: width, height: tableHeight + 4))
        scrollView.hasVerticalScroller = pickerWindows.count > maxVisibleRows
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tableView = HoverTableView(frame: NSRect(x: 0, y: 0, width: width, height: tableHeight))
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(confirmSelection)
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("window"))
        column.width = width
        tableView.addTableColumn(column)
        self.tableView = tableView

        scrollView.documentView = tableView
        background.addSubview(scrollView)
        background.addSubview(hairline(x: 0, y: footerHeight, width: width))

        let footer = NSTextField(labelWithString: "1–9 or ↑↓ + ⏎ to switch · Esc to cancel")
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.frame = NSRect(x: 0, y: 0, width: width, height: footerHeight)
        background.addSubview(footer)

        positionPanel(panel)
        installKeyMonitor()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func hairline(x: CGFloat, y: CGFloat, width: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: x, y: y, width: width, height: 1))
        box.boxType = .separator
        return box
    }

    private func positionPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: mouseLocation.x, y: mouseLocation.y)
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 36, 76: // Return, keypad Enter
                self.confirmSelection()
                return nil
            case 53: // Escape
                self.closePicker(choiceIndex: 0)
                return nil
            default:
                if let chars = event.charactersIgnoringModifiers, let n = Int(chars),
                   n >= 1, n <= self.pickerWindows.count {
                    self.tableView?.selectRowIndexes(IndexSet(integer: n - 1), byExtendingSelection: false)
                    self.closePicker(choiceIndex: n)
                    return nil
                }
                return event
            }
        }
    }

    @objc private func confirmSelection() {
        closePicker(choiceIndex: (tableView?.selectedRow ?? -1) + 1)
    }

    private func closePicker(choiceIndex: Int) {
        guard let panel else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let windows = pickerWindows
        let s = pickerState
        self.panel = nil
        self.tableView = nil
        panel.orderOut(nil)
        if choiceIndex > 0, choiceIndex <= windows.count, let s {
            focus(windows[choiceIndex - 1], s)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        closePicker(choiceIndex: 0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pickerWindows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = pickerWindows[row]
        let rowHeight: CGFloat = 52
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 0, height: rowHeight))

        let badge = NSTextField(labelWithString: row < 9 ? "\(row + 1)" : "")
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .center
        badge.frame = NSRect(x: 12, y: (rowHeight - 18) / 2, width: 18, height: 18)
        cell.addSubview(badge)

        let icon = NSImageView(frame: NSRect(x: 34, y: (rowHeight - 20) / 2, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Browser window")
        icon.contentTintColor = .secondaryLabelColor
        cell.addSubview(icon)

        let titleWidth = (tableColumn?.width ?? 390) - 62 - 16
        let title = NSTextField(labelWithString: choice.title)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 62, y: rowHeight / 2 + 2, width: max(titleWidth, 40), height: 18)
        title.toolTip = choice.title
        cell.addSubview(title)

        let subtitle = NSTextField(labelWithString: "\(choice.tabCount) tab\(choice.tabCount == 1 ? "" : "s")")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 62, y: rowHeight / 2 - 16, width: max(titleWidth, 40), height: 14)
        cell.addSubview(subtitle)

        return cell
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
