import AppKit

// A transient native window picker: no Dock icon, screen recording, or
// Accessibility needed. Runs its own NSApplication event loop (rather than a
// bare NSMenu popUp) so hover, click, and keyboard input are all delivered
// reliably regardless of what app was frontmost before launch.

struct WindowChoice {
    let title: String
    let tabCount: String
}

func parseArgs() -> (profileName: String, windows: [WindowChoice])? {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { return nil }
    let windows = args.dropFirst().map { arg -> WindowChoice in
        let parts = arg.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return WindowChoice(title: String(parts[0]), tabCount: String(parts[1]))
        }
        return WindowChoice(title: arg, tabCount: "")
    }
    return (args[0], windows)
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HoverTableView: NSTableView {
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredRow = row(at: point)
        if hoveredRow >= 0 && hoveredRow != selectedRow {
            selectRowIndexes(IndexSet(integer: hoveredRow), byExtendingSelection: false)
        }
    }
}

final class PickerController: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {

    private let profileName: String
    private let windows: [WindowChoice]
    private var panel: NSPanel!
    private var tableView: HoverTableView!
    private var didRespond = false
    private var keyMonitor: Any?

    init(profileName: String, windows: [WindowChoice]) {
        self.profileName = profileName
        self.windows = windows
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        installKeyMonitor()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func buildPanel() {
        let width: CGFloat = 440
        let rowHeight: CGFloat = 48
        let headerHeight: CGFloat = 34
        let footerHeight: CGFloat = 26
        let maxVisibleRows = 8
        let visibleRows = min(windows.count, maxVisibleRows)
        let tableHeight = CGFloat(visibleRows) * rowHeight
        let totalHeight = headerHeight + 1 + tableHeight + 1 + footerHeight

        panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: totalHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        let header = NSTextField(labelWithString: "\(profileName) · \(windows.count) window\(windows.count == 1 ? "" : "s")")
        header.font = .boldSystemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 14, y: totalHeight - headerHeight, width: width - 28, height: headerHeight)
        header.lineBreakMode = .byTruncatingTail
        background.addSubview(header)

        background.addSubview(hairline(x: 0, y: totalHeight - headerHeight, width: width))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: footerHeight + 1, width: width, height: tableHeight))
        scrollView.hasVerticalScroller = windows.count > maxVisibleRows
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        tableView = HoverTableView(frame: scrollView.bounds)
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

        scrollView.documentView = tableView
        background.addSubview(scrollView)

        background.addSubview(hairline(x: 0, y: footerHeight, width: width))

        let footer = NSTextField(labelWithString: "1–9 or ↑↓ + ⏎ to switch · ⌘W to close · Esc to cancel")
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.frame = NSRect(x: 0, y: 0, width: width, height: footerHeight)
        background.addSubview(footer)

        position(panel)
    }

    private func hairline(x: CGFloat, y: CGFloat, width: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: x, y: y, width: width, height: 1))
        box.boxType = .separator
        return box
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: mouseLocation.x, y: mouseLocation.y - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 20), max(visible.minY + 20, visible.maxY - size.height - 8))
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
                self.respond(0)
                return nil
            default:
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "w" {
                    let row = self.tableView.selectedRow
                    if row >= 0 { self.respond(-(row + 1)) }
                    return nil
                }
                if let chars = event.charactersIgnoringModifiers, let n = Int(chars),
                   n >= 1, n <= self.windows.count {
                    self.tableView.selectRowIndexes(IndexSet(integer: n - 1), byExtendingSelection: false)
                    self.respond(n)
                    return nil
                }
                return event
            }
        }
    }

    @objc private func confirmSelection() {
        respond(tableView.selectedRow + 1)
    }

    private func respond(_ index: Int) {
        guard !didRespond else { return }
        didRespond = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        print(index)
        NSApp.terminate(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        respond(0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { windows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let choice = windows[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 0, height: 48))

        let badge = NSTextField(labelWithString: row < 9 ? "\(row + 1)" : "")
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .center
        badge.frame = NSRect(x: 12, y: 15, width: 18, height: 18)
        cell.addSubview(badge)

        let icon = NSImageView(frame: NSRect(x: 34, y: 14, width: 20, height: 20))
        icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Browser window")
        icon.contentTintColor = .secondaryLabelColor
        cell.addSubview(icon)

        let titleWidth = (tableColumn?.width ?? 390) - 62 - 56
        let title = NSTextField(labelWithString: choice.title)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 62, y: 26, width: max(titleWidth, 40), height: 18)
        title.toolTip = choice.title
        cell.addSubview(title)

        let subtitle = NSTextField(labelWithString: choice.tabCount.isEmpty ? "" : "\(choice.tabCount) tabs")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 62, y: 7, width: max(titleWidth, 40), height: 14)
        cell.addSubview(subtitle)

        let closeButton = NSButton(frame: NSRect(x: (tableColumn?.width ?? 440) - 34, y: 15, width: 18, height: 18))
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close window")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.imageScaling = .scaleProportionallyUpOrDown
        closeButton.toolTip = "Close this window"
        closeButton.tag = row
        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped(_:))
        cell.addSubview(closeButton)

        return cell
    }

    @objc private func closeButtonTapped(_ sender: NSButton) {
        respond(-(sender.tag + 1))
    }
}

guard let (profileName, windows) = parseArgs() else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PickerController(profileName: profileName, windows: windows)
app.delegate = controller
app.run()
