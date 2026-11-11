import AppKit
import ApplicationServices
import ScreenCaptureKit

// ProfileDock Agent: a menu-bar-less background helper that
//  - shows an AltTab-style window switcher on Option+Tab (hold Option, press
//    Tab / Shift+Tab to move, release Option to switch, Esc to cancel), and
//  - makes the green traffic-light button fill the screen (like Option-click)
//    instead of entering full screen. Option-click the green button for real
//    full screen.
//  - shows a profile's Chrome windows when hovering its Dock icon,
//  - makes a profile's Chrome windows minimize into that profile's Dock icon
//    (yellow button or Cmd+M) instead of Chrome's own,
//  - picks a profile in Chrome's Profiles menu for launchers that can't tell
//    whether the profile has windows, and
//  - un-freezes profile launchers that macOS left suspended at launch.
// All need Accessibility permission, granted once to this app. Screen
// Recording is optional: with it, the minimize animation shows the window
// itself; without it, a card with the profile's icon.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// Bringing another app forward from a background app: macOS refuses plain
// activate() unless the caller is the active app, so this uses the window
// server call that window switchers such as AltTab rely on. Looked up at
// runtime; when missing, the public calls below are still tried.
typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
let setFrontProcess = dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), "_SLPSSetFrontProcessWithOptions")
    .map { unsafeBitCast($0, to: SetFrontProcess.self) }
let getProcessForPID = dlsym(dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY), "GetProcessForPID")
    .map { unsafeBitCast($0, to: GetProcessForPID.self) }

/// Make `app` the active app, with `window` (or its own key window) in front.
func bringForward(_ app: NSRunningApplication, window: CGWindowID = 0) {
    var psn = ProcessSerialNumber()
    if let getProcessForPID, let setFrontProcess, getProcessForPID(app.processIdentifier, &psn) == noErr {
        _ = setFrontProcess(&psn, window, 0x200)  // "user generated"
    }
    if !app.isActive {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
    }
}

let bridge = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProfileDock/bridge")

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value: AXValue = attribute(element, name) else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &result) ? result : nil
}

func size(_ element: AXUIElement, _ name: String) -> CGSize? {
    guard let value: AXValue = attribute(element, name) else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value, .cgSize, &result) ? result : nil
}

func setFrame(_ window: AXUIElement, _ frame: CGRect) {
    var origin = frame.origin, extent = frame.size
    // Position, size, then position again: some apps clamp the size against
    // the old position, so a single pass can leave the window short.
    if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
    if let s = AXValueCreate(.cgSize, &extent) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
}

/// The usable area (below the menu bar, beside the Dock) of the screen a
/// window is mostly on, in Accessibility's top-left-origin coordinates.
func visibleFrame(containing rect: CGRect) -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    let flip = { (r: CGRect) in CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height) }
    let screen = NSScreen.screens.max { a, b in
        flip(a.frame).intersection(rect).width * flip(a.frame).intersection(rect).height <
        flip(b.frame).intersection(rect).width * flip(b.frame).intersection(rect).height
    }
    return screen.map { flip($0.visibleFrame) }
}

let logFile = bridge.deletingLastPathComponent().appendingPathComponent("agent.log")

/// Keep only the end of a log that has grown large.
func trimLog() {
    guard let data = try? Data(contentsOf: logFile), data.count > 512 * 1024 else { return }
    try? data.suffix(128 * 1024).write(to: logFile, options: .atomic)
}

func log(_ message: String) {
    let file = logFile
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }
}

struct SwitcherItem {
    let window: AXUIElement
    let app: NSRunningApplication
    let title: String
    let minimized: Bool
}

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class Agent: NSObject, NSApplicationDelegate {
    var tap: CFMachPort?
    var panel: SwitcherPanel?
    // Set synchronously in the event tap; the panel itself is built on the
    // next main-loop turn so slow apps can't stall the tap into a timeout.
    var active = false
    var items: [SwitcherItem] = []
    var selected = 0
    var cells: [NSView] = []
    var switcherOpenedAt: NSPoint?  // pointer position when the switcher opened
    var swallowMouseUp = false
    var restoreFrames: [CGWindowID: CGRect] = [:]
    var permissionTimer: Timer?
    // Minimize-into-profile state. `parked` survives restarts (on disk) so a
    // window never gets stranded in the screen corner.
    var parked: [CGWindowID: ParkedWindow] = [:]
    var snapshots: [CGWindowID: CGImage] = [:]
    var parkedAt: [CGWindowID: Date] = [:]  // when each was minimized, this run
    var chromeObserver: AXObserver?
    var observedChromePid: pid_t = 0
    // Dock hover window list.
    var hoverPanel: HoverPanel?
    var hoverKey: String?          // profile whose list is showing
    var hoverTileKey: String?      // profile icon under the mouse right now
    var hoverTile = CGRect.null    // that icon, Accessibility coordinates
    var hoverListTile = CGRect.null // the icon the open list belongs to
    var hoverShow: DispatchWorkItem?
    var hoverHide: DispatchWorkItem?
    var hoverRecheck: DispatchWorkItem?
    var hoverSuppressed: String?   // icon just clicked: no list until the pointer leaves it
    var hoverExcluded = Set<Int>() // windows closed from the list, until the bridge catches up
    var hoverAnchor: CGPoint?      // last pointer position on the shown profile's icon
    var hoverPoll: Timer?          // keeps the open list current
    var hoverShown: HoverShown?    // what the open list shows
    var lastHoverCheck = Date.distantPast
    var dockFrame = CGRect.null
    var dockFrameChecked = Date.distantPast
    // Caches of files read on every Dock hover.
    var profilesCache: (stamp: Date, checked: Date, value: [InstalledProfile]) = (.distantPast, .distantPast, [])
    var chromeNamesCache: (stamp: Date, checked: Date, value: [String: String]) = (.distantPast, .distantPast, [:])
    var appIcons: [String: NSImage] = [:]
    var favicons: [String: NSImage] = [:]
    // Requests from launchers, and the frozen-launcher watchdog.
    var requestSource: DispatchSourceFileSystemObject?
    var watchdog: Timer?
    var stoppedSince: [pid_t: Date] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("started, accessibility \(trusted ? "granted" : "not granted yet")")
        if !trusted {
            // Without asking, macOS never lists this app under Accessibility,
            // so there is nothing for the user to switch on. Asking shows the
            // system prompt and adds the (switched-off) entry.
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
        }
        try? FileManager.default.removeItem(at: bridge.appendingPathComponent("hover-picker.json"))  // no longer used
        trimLog()
        // The Dock list belongs to the Space and screen layout it opened on.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            self.hideHoverList()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            self.hideHoverList()
            self.dockFrameChecked = .distantPast
        }
        watchRequests()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.resumeFrozenLaunchers()
            self.returnRestoredWindows()
        }
        installTap()
        // Keep retrying until the tap exists, so it starts working as soon as
        // the switch is flipped in System Settings, without a relaunch.
        // (AXIsProcessTrusted can stay stale within a process; creating the
        // tap is the real test.)
        if tap == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                self.installTap()
                if self.tap != nil { timer.invalidate() }
            }
        }
    }

    func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) |
                   (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue) |
                   (1 << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let agent = Unmanaged<Agent>.fromOpaque(refcon!).takeUnretainedValue()
            return agent.handle(type, event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        log("event tap installed")
        startMinimizeSupport()
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // A key the Agent swallowed and then handed back (see passOn).
        if event.getIntegerValueField(.eventSourceUserData) == passedOn { return Unmanaged.passUnretained(event) }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let optionOnly = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            if key == 53 && !active && hoverPanel != nil {  // Esc closes the Dock list (and still reaches the app)
                DispatchQueue.main.async { self.hideHoverList() }
            }
            if key == 48 && optionOnly { // Tab
                if !active {
                    active = true
                    DispatchQueue.main.async { self.openSwitcher() }
                } else {
                    let delta = flags.contains(.maskShift) ? -1 : 1
                    DispatchQueue.main.async { self.move(delta) }
                }
                return nil
            }
            let commandOnly = flags.contains(.maskCommand) && !flags.contains(.maskAlternate) &&
                              !flags.contains(.maskControl) && !flags.contains(.maskShift)
            if key == 46 && commandOnly && !active, // Cmd+M
               let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.google.Chrome" {
                DispatchQueue.main.async { self.minimizeFocusedChromeWindow(front) }
                return nil
            }
            if active {
                DispatchQueue.main.async {
                    switch key {
                    case 53: self.closeSwitcher(activate: false) // Esc
                    case 123, 126: self.move(-1)                  // ← ↑
                    case 124, 125: self.move(1)                   // → ↓
                    case 36, 76: self.closeSwitcher(activate: true)
                    default: break
                    }
                }
                return nil
            }
        case .flagsChanged:
            if active && !event.flags.contains(.maskAlternate) {
                active = false
                DispatchQueue.main.async { self.closeSwitcher(activate: true) }
            }
        case .mouseMoved:
            let location = event.location
            DispatchQueue.main.async { self.dockHover(at: location) }
        case .leftMouseDown:
            let location = event.location
            DispatchQueue.main.async { self.hoverClick(at: location) }
            if takeChromeIconClick(at: location, flags: event.flags) {
                swallowMouseUp = true
                return nil
            }
            if !event.flags.contains(.maskAlternate), let (subrole, window) = trafficLight(at: event.location) {
                let handled: Bool
                switch subrole {
                case "AXMinimizeButton": handled = minimizeIntoProfileIfChrome(window)
                case "AXFullScreenButton", "AXZoomButton": handled = maximize(window)
                default: handled = false
                }
                if handled {
                    swallowMouseUp = true
                    return nil
                }
            }
        case .leftMouseUp:
            if swallowMouseUp { swallowMouseUp = false; return nil }
        case .rightMouseDown, .otherMouseDown:
            let location = event.location
            DispatchQueue.main.async { self.hoverClick(at: location) }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Green button

    /// The window-title-bar button under the mouse, if any, and its window.
    func trafficLight(at location: CGPoint) -> (String, AXUIElement)? {
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element) == .success,
              let button = element, let subrole: String = attribute(button, kAXSubroleAttribute),
              ["AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(subrole),
              let window: AXUIElement = attribute(button, kAXWindowAttribute) else { return nil }
        return (subrole, window)
    }

    func maximize(_ window: AXUIElement) -> Bool {
        // In full screen the green button takes the window out of it.
        guard !isFullScreen(window) else { return false }
        guard let origin = point(window, kAXPositionAttribute), let extent = size(window, kAXSizeAttribute) else { return false }
        let current = CGRect(origin: origin, size: extent)
        guard let target = visibleFrame(containing: current) else { return false }
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(window, &id)
        let isMaximized = abs(current.minX - target.minX) < 8 && abs(current.minY - target.minY) < 8 &&
                          abs(current.width - target.width) < 16 && abs(current.height - target.height) < 16
        if isMaximized, let previous = restoreFrames.removeValue(forKey: id) {
            setFrame(window, previous)
        } else if !isMaximized {
            restoreFrames[id] = current
            setFrame(window, target)
        }
        return true
    }

    // MARK: - Window switcher

    func collectWindows() -> [SwitcherItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // Front-to-back order of on-screen windows, so the list is ordered by
        // how recently each window was used, like ⌘Tab is for apps.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        var found: [(rank: Int, item: SwitcherItem)] = []
        for app in apps where app.bundleIdentifier?.hasPrefix("local.profiledock") != true {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) else { continue }
            for window in windows {
                guard (attribute(window, kAXSubroleAttribute) as String?) == "AXStandardWindow" else { continue }
                var id: CGWindowID = 0
                _ = _AXUIElementGetWindow(window, &id)
                let minimized = (attribute(window, kAXMinimizedAttribute) as Bool?) ?? false
                let title = (attribute(window, kAXTitleAttribute) as String?) ?? ""
                let rank = order.firstIndex(of: id) ?? (app.isHidden || minimized ? 100_000 : 50_000)
                found.append((rank, SwitcherItem(window: window, app: app, title: title.isEmpty ? (app.localizedName ?? "") : title, minimized: minimized)))
            }
        }
        return found.sorted { $0.rank < $1.rank }.map(\.item)
    }

    struct ChromeProfile {
        let label: String; let icon: NSImage?; let titles: Set<String>; let app: String?
        let names: [String]  // lowercased: the Dock label and Chrome's own name for the profile
    }

    /// Every ProfileDock profile with its Dock icon and current window titles.
    func chromeProfiles() -> [ChromeProfile] {
        installedProfiles().map { profile in
            var titles = Set<String>()
            if let data = try? Data(contentsOf: bridge.appendingPathComponent("state/\(profile.key).json")),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let windows = state["windows"] as? [[String: Any]] {
                titles = Set(windows.compactMap { $0["title"] as? String })
            }
            let names = [profile.label, chromeProfileName(profile.directory)].compactMap { $0?.lowercased() }
            return ChromeProfile(label: profile.label, icon: appIcon(profile), titles: titles, app: profile.app, names: names)
        }
    }

    /// Which profile a Chrome window belongs to. With several profiles open,
    /// Chrome titles windows "Page - Google Chrome - Alex (Work)", so the
    /// profile name after the last " - Google Chrome - " decides; the
    /// bridge's window titles are the fallback.
    func profile(forChromeTitle title: String, in profiles: [ChromeProfile]) -> ChromeProfile? {
        if let range = title.range(of: " - Google Chrome - ", options: .backwards) {
            let name = title[range.upperBound...].lowercased()
            if let exact = profiles.first(where: { $0.names.contains { name == $0 || name.hasSuffix("(\($0))") } }) { return exact }
            if let loose = profiles.first(where: { $0.names.contains { name.contains($0) } }) { return loose }
        }
        let page = pageTitle(title)
        return profiles.first { $0.titles.contains(page) }
    }

    func pageTitle(_ title: String) -> String {
        guard let range = title.range(of: " - Google Chrome") else { return title }
        return String(title[..<range.lowerBound])
    }

    func openSwitcher() {
        hideHoverList()
        items = collectWindows()
        guard !items.isEmpty else { active = false; return }
        selected = items.count > 1 ? 1 : 0
        let profiles = chromeProfiles()

        // Six columns, widened (then trimmed to the most recent windows) so
        // the panel never runs off the screen.
        let cell = CGSize(width: 150, height: 150), padding: CGFloat = 16
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let maxColumns = max(1, Int((screen.visibleFrame.width - 64 - padding * 2) / cell.width))
        let maxRows = max(1, Int((screen.visibleFrame.height - 64 - padding * 2) / cell.height))
        if items.count > maxColumns * maxRows { items = Array(items.prefix(maxColumns * maxRows)) }
        let columns = min(items.count, max(6, (items.count + maxRows - 1) / maxRows), maxColumns)
        let rows = (items.count + columns - 1) / columns
        switcherOpenedAt = mouse
        let width = CGFloat(columns) * cell.width + padding * 2
        let height = CGFloat(rows) * cell.height + padding * 2
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        panel.contentView = background

        cells = []
        for (index, item) in items.enumerated() {
            let column = index % columns, row = index / columns
            let frame = NSRect(x: padding + CGFloat(column) * cell.width, y: height - padding - CGFloat(row + 1) * cell.height,
                               width: cell.width, height: cell.height)
            let view = HoverControl(frame: frame.insetBy(dx: 4, dy: 4))
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            // The mouse works too: point at a window, click to switch. Only
            // once it has moved, so the panel opening under a resting
            // pointer doesn't change the selection.
            view.onHover = { [weak self] inside in
                guard let self, inside else { return }
                if let opened = self.switcherOpenedAt {
                    let now = NSEvent.mouseLocation
                    guard hypot(now.x - opened.x, now.y - opened.y) > 4 else { return }
                    self.switcherOpenedAt = nil  // moved: follow the pointer from now on
                }
                self.selected = index
                self.highlight()
            }
            view.onClick = { [weak self] in
                self?.selected = index
                self?.closeSwitcher(activate: true)
            }
            let chromeProfile = item.app.bundleIdentifier == "com.google.Chrome" ? profile(forChromeTitle: item.title, in: profiles) : nil
            let icon = NSImageView(frame: NSRect(x: (view.frame.width - 72) / 2, y: 56, width: 72, height: 72))
            icon.image = chromeProfile?.icon ?? item.app.icon
            icon.alphaValue = item.minimized || item.app.isHidden ? 0.5 : 1
            view.addSubview(icon)
            var subtitle = item.app.localizedName ?? ""
            if let chromeProfile { subtitle = "Chrome · " + chromeProfile.label }
            let appLabel = NSTextField(labelWithString: subtitle)
            appLabel.font = .boldSystemFont(ofSize: 11)
            appLabel.textColor = .secondaryLabelColor
            appLabel.alignment = .center
            appLabel.lineBreakMode = .byTruncatingTail
            appLabel.frame = NSRect(x: 6, y: 36, width: view.frame.width - 12, height: 16)
            view.addSubview(appLabel)
            let title = NSTextField(wrappingLabelWithString: item.app.bundleIdentifier == "com.google.Chrome" ? pageTitle(item.title) : item.title)
            title.isSelectable = false
            title.font = .systemFont(ofSize: 11)
            title.alignment = .center
            title.maximumNumberOfLines = 2
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 6, y: 2, width: view.frame.width - 12, height: 32)
            view.addSubview(title)
            background.addSubview(view)
            cells.append(view)
        }

        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2))
        self.panel = panel
        highlight()
        panel.orderFrontRegardless()
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        highlight()
    }

    func highlight() {
        for (index, view) in cells.enumerated() {
            view.layer?.backgroundColor = index == selected ? NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
        }
    }

    func closeSwitcher(activate: Bool) {
        active = false
        panel?.orderOut(nil)
        panel = nil
        cells = []
        guard activate, items.indices.contains(selected) else { return }
        let item = items[selected]
        if item.app.isHidden { item.app.unhide() }
        if item.minimized { AXUIElementSetAttributeValue(item.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(item.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(item.window, kAXRaiseAction as CFString)
        bringForward(item.app, window: windowID(item.window))
        // activate() brings the app's own front window along; raise the
        // chosen one again once the app is frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { AXUIElementPerformAction(item.window, kAXRaiseAction as CFString) }
    }
}

// MARK: - Minimize into the profile's Dock icon
//
// macOS always animates a minimizing window into the app that owns it, and
// every profile's windows belong to Chrome. The profile icons are separate
// launcher apps with no windows, so the system animation can't target them.
// Instead: cover the window with a picture of itself, tuck the real window
// into the screen corner (macOS won't move it fully off screen) so its own
// minimize animation is a short hop near the Dock, then fly the picture into
// the profile's icon. Restoring plays the same in reverse and puts the
// window back exactly where it was.

struct ParkedWindow: Codable {
    let frame: CGRect   // Accessibility (top-left origin) coordinates
    let app: String     // the profile launcher whose Dock icon it went into
}

let parkedFile = bridge.deletingLastPathComponent().appendingPathComponent("minimized-windows.json")

final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Marks events the Agent posts itself, so its event tap lets them through.
let passedOn: Int64 = 0x50_44_6F_63  // "PDoc"

/// Send Cmd+M on to the front app after all (the Agent couldn't take it over).
func passOnCommandM() {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 46, keyDown: down) else { continue }
        event.flags = .maskCommand
        event.setIntegerValueField(.eventSourceUserData, value: passedOn)
        event.post(tap: .cgSessionEventTap)
    }
}

func isFullScreen(_ window: AXUIElement) -> Bool { (attribute(window, "AXFullScreen") as Bool?) == true }

/// Accessibility coordinates (origin top-left of the primary screen) to
/// AppKit's (origin bottom-left).
func cocoaRect(_ r: CGRect) -> NSRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
}

func windowID(_ window: AXUIElement) -> CGWindowID {
    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(window, &id)
    return id
}

extension Agent {
    func startMinimizeSupport() {
        if let data = try? Data(contentsOf: parkedFile),
           let saved = try? JSONDecoder().decode([String: ParkedWindow].self, from: data) {
            parked = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UInt32(key).map { ($0, value) } })
        }
        observeChrome()
        recoverChromeWindows()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.google.Chrome" else { return }
            // Window IDs don't survive a Chrome restart.
            self.parked = [:]
            self.snapshots = [:]
            self.saveParked()
            // A window Chrome restores from its session may come back in the
            // corner it was tucked into; give it time to open its windows.
            for delay in [3.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.observeChrome(); self.recoverChromeWindows() }
            }
        }
    }

    func saveParked() {
        let saved = Dictionary(uniqueKeysWithValues: parked.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: parkedFile, options: .atomic) }
    }

    /// Watch every Chrome window for being un-minimized (by the profile's
    /// Dock icon, Chrome's Window menu, or anything else). One app-wide
    /// registration, so a window minimized before this Agent started, or
    /// whose own registration was lost, still comes back out of the corner.
    func observeChrome() {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first,
              chrome.processIdentifier != observedChromePid else { return }
        if let old = chromeObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes) }
        chromeObserver = nil
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            Unmanaged<Agent>.fromOpaque(refcon!).takeUnretainedValue().chromeWindowRestored(element)
        }
        guard AXObserverCreate(chrome.processIdentifier, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(chrome.processIdentifier)
        guard AXObserverAddNotification(observer, element, kAXWindowDeminiaturizedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        chromeObserver = observer
        observedChromePid = chrome.processIdentifier
    }

    func watchForRestore(_ window: AXUIElement) { observeChrome() }

    /// After an Agent or Chrome restart: re-watch windows still minimized,
    /// and bring back any window left tucked in the corner.
    func recoverChromeWindows() {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return }
        let element = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) else { return }
        for window in windows where (attribute(window, kAXSubroleAttribute) as String?) == "AXStandardWindow" {
            let id = windowID(window)
            let minimized = (attribute(window, kAXMinimizedAttribute) as Bool?) ?? false
            if minimized {
                if parked[id] != nil { watchForRestore(window) }
            } else if let entry = parked.removeValue(forKey: id) {
                setFrame(window, entry.frame)
            } else {
                rescueIfOffscreen(window)
            }
        }
        saveParked()
    }

    /// Safety net for the restore notification: a parked window that is no
    /// longer minimized goes back where it was. Cheap when nothing is parked.
    func returnRestoredWindows() {
        guard !parked.isEmpty, let chrome = runningChrome() else { return }
        let element = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) else { return }
        var changed = false
        for window in windows {
            let id = windowID(window)
            // Not while it's still on its way down.
            guard parked[id] != nil, Date().timeIntervalSince(parkedAt[id] ?? .distantPast) > 2,
                  (attribute(window, kAXMinimizedAttribute) as Bool?) == false,
                  let entry = parked.removeValue(forKey: id) else { continue }
            snapshots[id] = nil
            setFrame(window, entry.frame)
            changed = true
            log("returned a restored Chrome window to its place")
        }
        if changed { saveParked() }
    }

    /// Move a window that is almost entirely off screen back into view.
    func rescueIfOffscreen(_ window: AXUIElement) {
        guard let origin = point(window, kAXPositionAttribute), let extent = size(window, kAXSizeAttribute),
              extent.width > 0, extent.height > 0, let primary = NSScreen.screens.first else { return }
        let frame = CGRect(origin: origin, size: extent)
        let visible = NSScreen.screens.reduce(CGFloat(0)) { total, screen in
            let r = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            let overlap = r.intersection(frame)
            return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard visible < frame.width * frame.height * 0.2, let area = visibleFrame(containing: frame) else { return }
        let width = min(extent.width, area.width - 80), height = min(extent.height, area.height - 80)
        setFrame(window, CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height))
        log("moved a stranded Chrome window back on screen")
    }

    /// Yellow button: true when it was a profile's Chrome window and the
    /// click has been taken over.
    func minimizeIntoProfileIfChrome(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.google.Chrome", !isFullScreen(window),
              let title: String = attribute(window, kAXTitleAttribute),
              profile(forChromeTitle: title, in: chromeProfiles())?.app != nil else { return false }
        DispatchQueue.main.async { self.minimizeIntoProfile(window) }
        return true
    }

    /// Cmd+M in Chrome (already swallowed by the event tap).
    func minimizeFocusedChromeWindow(_ chrome: NSRunningApplication) {
        let element = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        // Chrome didn't answer, or a full-screen window (which can't be
        // minimized): let Chrome have the keystroke after all.
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute), !isFullScreen(window) else {
            passOnCommandM()
            return
        }
        minimizeIntoProfile(window)
    }

    func minimizeIntoProfile(_ window: AXUIElement) {
        let title: String = attribute(window, kAXTitleAttribute) ?? ""
        guard (attribute(window, kAXSubroleAttribute) as String?) == "AXStandardWindow",
              let profile = profile(forChromeTitle: title, in: chromeProfiles()), let app = profile.app,
              let origin = point(window, kAXPositionAttribute), let extent = size(window, kAXSizeAttribute) else {
            // Not a profile window (a dialog, an unknown profile): minimize
            // it the ordinary way.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }
        let frame = CGRect(origin: origin, size: extent)
        let id = windowID(window)
        captureWindow(id) { image in
            let ghost = self.makeGhost(frame: cocoaRect(frame), image: image, icon: profile.icon)
            ghost.orderFrontRegardless()
            self.parked[id] = ParkedWindow(frame: frame, app: app)
            self.parkedAt[id] = Date()
            self.snapshots[id] = image
            self.saveParked()
            // Tuck the real window into the corner (macOS clamps the huge
            // value), then minimize it from there.
            var corner = CGPoint(x: 100_000, y: 100_000)
            if let value = AXValueCreate(.cgPoint, &corner) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            self.watchForRestore(window)
            // If the window refused to minimize, put it straight back rather
            // than leave it in the corner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard (attribute(window, kAXMinimizedAttribute) as Bool?) == false, self.parked.removeValue(forKey: id) != nil else { return }
                self.saveParked()
                self.snapshots[id] = nil
                setFrame(window, frame)
                log("a Chrome window didn't minimize; put it back")
            }
            let tile = self.dockTile(forApp: app, near: frame)
            self.fly(ghost, to: tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.2), duration: 0.32, alpha: 0.4,
                     timing: CAMediaTimingFunction(name: .easeIn)) { ghost.orderOut(nil) }
        }
    }

    func chromeWindowRestored(_ window: AXUIElement) {
        let id = windowID(window)
        guard let entry = parked.removeValue(forKey: id) else { return }
        saveParked()
        let image = snapshots.removeValue(forKey: id) ?? nil
        let tile = dockTile(forApp: entry.app, near: entry.frame)
        let ghost = makeGhost(frame: tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.2), image: image,
                              icon: NSWorkspace.shared.icon(forFile: entry.app))
        ghost.alphaValue = 0.4
        ghost.orderFrontRegardless()
        fly(ghost, to: cocoaRect(entry.frame), duration: 0.25, alpha: 1, timing: CAMediaTimingFunction(name: .easeOut)) {
            setFrame(window, entry.frame)
            // A beat for the window to draw in place before the picture goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { ghost.orderOut(nil) }
        }
    }

    /// The profile launcher's Dock icon, in AppKit coordinates. Falls back
    /// to the bottom middle of the window's screen.
    func dockTile(forApp app: String, near frame: CGRect) -> NSRect {
        if let tile = dockItemFrame(forApp: app) { return cocoaRect(tile) }
        let screen = cocoaRect(visibleFrame(containing: frame) ?? frame)
        return NSRect(x: screen.midX - 30, y: screen.minY - 60, width: 60, height: 60)
    }

    /// An app's Dock icon right now (Accessibility coordinates), if it's in the Dock.
    func dockItemFrame(forApp app: String) -> CGRect? {
        let wanted = URL(fileURLWithPath: app).standardizedFileURL.path.lowercased()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        for list in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (attribute(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let url: URL = attribute(item, kAXURLAttribute),
                      url.standardizedFileURL.path.lowercased() == wanted,
                      let origin = point(item, kAXPositionAttribute), let extent = size(item, kAXSizeAttribute) else { continue }
                return CGRect(origin: origin, size: extent)
            }
        }
        return nil
    }

    /// A screenshot of one window, if Screen Recording is allowed. Never
    /// holds up the minimize by more than a moment.
    func captureWindow(_ id: CGWindowID, _ done: @escaping (CGImage?) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            let asked = bridge.deletingLastPathComponent().appendingPathComponent(".asked-screen-recording")
            if !FileManager.default.fileExists(atPath: asked.path) {
                FileManager.default.createFile(atPath: asked.path, contents: nil)
                CGRequestScreenCaptureAccess()
            }
            done(nil)
            return
        }
        var finished = false
        let finish = { (image: CGImage?) in
            guard !finished else { return }
            finished = true
            done(image)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(nil) }
        Task {
            var image: CGImage?
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let window = content.windows.first(where: { $0.windowID == id }) {
                let config = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            }
            let result = image
            DispatchQueue.main.async { finish(result) }
        }
    }

    func makeGhost(frame: NSRect, image: CGImage?, icon: NSImage?) -> GhostPanel {
        let ghost = GhostPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.level = .popUpMenu  // above the Dock, so it lands "in" the icon
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let content: NSView
        if let image {
            content = NSView(frame: NSRect(origin: .zero, size: frame.size))
            content.wantsLayer = true
            content.layer?.contents = image
            content.layer?.contentsGravity = .resize
        } else {
            // No Screen Recording permission: a card with the profile icon.
            let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            card.material = .windowBackground
            card.state = .active
            card.wantsLayer = true
            let side = min(frame.width, frame.height) * 0.4
            let iconView = NSImageView(frame: NSRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side))
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.autoresizingMask = [.width, .height, .minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            card.addSubview(iconView)
            content = card
        }
        content.autoresizingMask = [.width, .height]
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        ghost.contentView = content
        return ghost
    }

    func fly(_ ghost: NSWindow, to target: NSRect, duration: TimeInterval, alpha: CGFloat,
             timing: CAMediaTimingFunction, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            ghost.animator().setFrame(target, display: true)
            ghost.animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}


// MARK: - Profiles

struct InstalledProfile {
    let key: String
    let label: String
    let directory: String
    let app: String?
    let appPath: String?   // standardized, lowercased, for matching Dock items
}

func modified(_ url: URL) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
}

let chromeID = "com.google.Chrome"

func runningChrome() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).first
}

extension Agent {
    /// The installed profiles (bridge/profiles.json), re-read only when the
    /// file changes.
    func installedProfiles() -> [InstalledProfile] {
        if Date().timeIntervalSince(profilesCache.checked) < 2 { return profilesCache.value }
        profilesCache.checked = Date()
        let file = bridge.appendingPathComponent("profiles.json")
        let stamp = modified(file)
        guard stamp != profilesCache.stamp else { return profilesCache.value }
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return profilesCache.value }
        let profiles = raw.compactMap { key, value -> InstalledProfile? in
            guard let label = value["label"] as? String else { return nil }
            let app = value["app"] as? String
            return InstalledProfile(key: key, label: label, directory: value["chromeDirectory"] as? String ?? "Default", app: app,
                                    appPath: app.map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() })
        }.sorted { $0.key < $1.key }
        profilesCache = (stamp, Date(), profiles)
        appIcons = [:]
        return profiles
    }

    func appIcon(_ profile: InstalledProfile) -> NSImage? {
        guard let app = profile.app else { return nil }
        if let icon = appIcons[profile.key] { return icon }
        // The bundle's own icon file: NSWorkspace can hand back a blank
        // placeholder while it loads icons in the background, and this is
        // cached for good.
        let file = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/app.icns")
        let icon = NSImage(contentsOf: file) ?? NSWorkspace.shared.icon(forFile: app)
        appIcons[profile.key] = icon
        return icon
    }

    /// Chrome's own display name for a profile directory (from Local State).
    func chromeProfileName(_ directory: String) -> String? {
        if Date().timeIntervalSince(chromeNamesCache.checked) > 5 {
            chromeNamesCache.checked = Date()
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
            let stamp = modified(file)
            if stamp != chromeNamesCache.stamp, let data = try? Data(contentsOf: file),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
                chromeNamesCache = (stamp, Date(), cache.compactMapValues { $0["name"] as? String })
            }
        }
        return chromeNamesCache.value[directory]
    }

    // MARK: Opening a profile

    /// Open a window in a profile. Always `open -n`: with Chrome running, it
    /// starts a second copy that hands its command line to the running one
    /// and exits, and Chrome opens the window in that profile. A plain
    /// `open -a` on a running Chrome drops the arguments and acts like a
    /// click on Chrome's icon: with no windows open, that shows the
    /// "Who's using Chrome?" picker instead.
    func openChrome(_ directory: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", "Google Chrome", "--args", "--profile-directory=\(directory)"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.bringChromeForward(onlyIfNeeded: true) }
        closeProfilePicker(after: 1.5)
    }

    /// Chrome's "Who's using Chrome?" window, left over from an earlier click
    /// on Chrome's own icon, is pointless once a profile has been opened.
    /// Only called after ProfileDock opens a profile, so a picker the user
    /// opened on purpose (Profiles → Edit…) with windows around is left be.
    func closeProfilePicker(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let chrome = runningChrome() else { return }
            let app = AXUIElementCreateApplication(chrome.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.3)
            for window in (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []
            where (attribute(window, kAXTitleAttribute) as String?) == profilePickerTitle {
                if let close: AXUIElement = attribute(window, kAXCloseButtonAttribute) {
                    AXUIElementPerformAction(close, kAXPressAction as CFString)
                    log("closed Chrome's profile picker")
                }
            }
        }
    }

    // MARK: Chrome's own Dock icon

    /// A plain click on Chrome's own Dock icon while Chrome has no windows
    /// would show the "Who's using Chrome?" picker. Open the profile used
    /// last instead, as Chrome does with its picker switched off. Called
    /// from the event tap; true means the click was taken over.
    func takeChromeIconClick(at location: CGPoint, flags: CGEventFlags) -> Bool {
        guard flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty,
              !dockFrame.isNull, dockFrame.insetBy(dx: -10, dy: -90).contains(location),
              let chrome = runningChrome(), let chromePath = chrome.bundleURL?.standardizedFileURL.path.lowercased(),
              dockItem(at: location)?.path == chromePath, !chromeHasWindows(chrome) else { return false }
        let directory = lastUsedProfileDirectory()
        DispatchQueue.main.async {
            self.hideHoverList()
            log("Chrome's icon clicked with no windows open: opening \(directory) instead of the profile picker")
            self.openChrome(directory)  // also closes a picker already showing
        }
        return true
    }

    /// Whether Chrome has a window to show: one on this Space or minimized
    /// (Accessibility), or one any profile's bridge knows of, which covers
    /// other Spaces and full screen. Chrome's own picker doesn't count. (The
    /// system window list can't tell: Chrome keeps closed windows in it for
    /// a while.)
    func chromeHasWindows(_ chrome: NSRunningApplication) -> Bool {
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        if windows.contains(where: { (attribute($0, kAXTitleAttribute) as String?) != profilePickerTitle }) { return true }
        return installedProfiles().contains { liveWindows($0.key)?.windows.isEmpty == false }
    }

    /// The profile Chrome would open without its picker: the last one used.
    func lastUsedProfileDirectory() -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: file),
              let profile = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["profile"] as? [String: Any] else { return "Default" }
        let known = profile["info_cache"] as? [String: [String: Any]] ?? [:]
        if let last = profile["last_used"] as? String, known[last] != nil { return last }
        return known.max { ($0.value["active_time"] as? Double ?? 0) < ($1.value["active_time"] as? Double ?? 0) }?.key ?? "Default"
    }

    func bringChromeForward(onlyIfNeeded: Bool = false) {
        guard let chrome = runningChrome(), !(onlyIfNeeded && chrome.isActive) else { return }
        bringForward(chrome)
    }

    /// Chrome's Profiles menu brings the profile's last window forward, or
    /// opens one if it has none, which is right when nothing says which.
    /// Falls back to opening a window when the menu can't be used (no
    /// Accessibility yet, a non-English Chrome).
    func selectProfile(_ key: String) {
        guard let profile = installedProfiles().first(where: { $0.key == key }) else { return }
        guard let chrome = runningChrome() else { openChrome(profile.directory); return }
        let names = [chromeProfileName(profile.directory), profile.label].compactMap { $0 }
        if pressProfilesMenuItem(chrome, names: names) {
            log("selected \(profile.label) in Chrome's Profiles menu")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.bringChromeForward() }
            closeProfilePicker(after: 1.0)
        } else {
            log("Profiles menu unavailable for \(profile.label); opening a window")
            openChrome(profile.directory)
        }
    }

    func pressProfilesMenuItem(_ chrome: NSRunningApplication, names: [String]) -> Bool {
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let title = { (element: AXUIElement) in (attribute(element, kAXTitleAttribute) as String?) ?? "" }
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute),
              let barItems: [AXUIElement] = attribute(bar, kAXChildrenAttribute),
              let profilesItem = barItems.first(where: { title($0) == "Profiles" }),
              let menu = (attribute(profilesItem, kAXChildrenAttribute) as [AXUIElement]?)?.first,
              let items: [AXUIElement] = attribute(menu, kAXChildrenAttribute) else { return false }
        // Profiles come first, as "Name (Label)", then a separator, "Edit…".
        let entries = items.prefix { !title($0).isEmpty }.map { ($0, title($0).lowercased()) }
        for name in names.map({ $0.lowercased() }) {
            let match = entries.first { $0.1 == name || $0.1.hasSuffix("(\(name))") }
                ?? entries.first { $0.1.contains(name) }
            if let (item, _) = match {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    // MARK: Launcher requests

    /// Launchers drop a file in agent-requests/ when they need Chrome's
    /// Profiles menu, or Chrome brought forward while they aren't the active
    /// app (they have no Accessibility permission of their own).
    func watchRequests() {
        let folder = bridge.appendingPathComponent("agent-requests")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.handleRequests() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        requestSource = source
        handleRequests()
    }

    func handleRequests() {
        let folder = bridge.appendingPathComponent("agent-requests")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            // Claiming by rename tells the launcher not to fall back itself.
            let claimed = file.deletingPathExtension().appendingPathExtension("claimed")
            guard (try? FileManager.default.moveItem(at: file, to: claimed)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard Date().timeIntervalSince(modified(claimed)) < 5,  // never act on a stale click
                  let data = try? Data(contentsOf: claimed),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch request["type"] as? String {
            case "select": if let key = request["key"] as? String { selectProfile(key) }
            case "front": bringChromeForward()
            case "opened": closeProfilePicker(after: 1.0)  // a launcher opened a window itself
            default: break
            }
        }
    }

    // MARK: Frozen launchers

    /// Now and then macOS spawns a launcher stopped (SIGSTOP) and never
    /// resumes it: its Dock icon then ignores every click. Resume any
    /// launcher that stays stopped; the click it was launched for then runs.
    func resumeFrozenLaunchers() {
        var seen = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix("local.profiledock.profile.") == true {
            let pid = app.processIdentifier
            seen.insert(pid)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat == CChar(SSTOP) else {
                stoppedSince[pid] = nil
                continue
            }
            if let since = stoppedSince[pid] {
                if Date().timeIntervalSince(since) > 1.5 {
                    kill(pid, SIGCONT)
                    stoppedSince[pid] = nil
                    log("resumed frozen launcher \(app.bundleIdentifier ?? "?") [\(pid)]")
                }
            } else {
                stoppedSince[pid] = Date()
            }
        }
        stoppedSince = stoppedSince.filter { seen.contains($0.key) }
    }
}

// MARK: - Dock hover window list
//
// Hovering a profile's Dock icon shows that profile's windows next to it;
// clicking a row switches to that window, × closes it, and "New Window"
// opens another. The Dock has no API for this, so on mouse moves near the
// Dock the Agent asks Accessibility which Dock icon is under the pointer
// (which also copes with Dock magnification).

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Reacts to the mouse even though its panel never becomes key (the Agent
/// is never the active app, so ordinary buttons would ignore the click).
class HoverControl: NSView {
    var onClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private(set) var hovering = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole control takes the click, labels and icons included; only
    /// a control inside it (the × button) keeps its own. Otherwise a click
    /// on a title can start a text selection and never reach the row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is HoverControl ? hit : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }
    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        onHover?(value)
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let onMiddleClick { onMiddleClick() } else { superview?.otherMouseUp(with: event) }
    }
}

/// A rounded row that highlights under the pointer.
final class HoverRow: HoverControl {
    var accessory: NSView?   // shown only while hovered (the close button)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        onHover = { [weak self] _ in self?.updateLook() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        }
        accessory?.isHidden = !hovering
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.cell?.truncatesLastVisibleLine = true
    return field
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    view.contentTintColor = color
    view.imageScaling = .scaleProportionallyDown
    return view
}

let markedRow = NSUserInterfaceItemIdentifier("marked")
/// The title of Chrome's profile picker window (English Chrome).
let profilePickerTitle = "Who's using Chrome?"

/// One profile's windows as its bridge last reported them.
struct LiveState: Decodable {
    let session: String
    let connected: Bool
    let updated: Double
    let features: [String]?
    let windows: [Window]
    var canClose: Bool { features?.contains("close") == true }
}

/// What the open list is showing, to tell when it needs redrawing.
struct HoverShown: Equatable {
    let session: String
    let windows: [Window]
    let chromeActive: Bool
    let canClose: Bool
}

/// Whether `p` lies in the triangle a, b, c.
func inTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
    func side(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
    let d1 = side(p, a, b), d2 = side(p, b, c), d3 = side(p, c, a)
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}

extension Agent {
    func dockHover(at location: CGPoint, recheck: Bool = true) {
        guard !active else { return }  // the Option+Tab switcher is up
        let cocoaPoint = cocoaRect(CGRect(origin: location, size: .zero)).origin
        if let panel = hoverPanel, panel.frame.insetBy(dx: -6, dy: -6).contains(cocoaPoint) {
            // In the list: keep it, and forget any icon the pointer crossed
            // on its way up, so that profile's list doesn't replace this one.
            hoverHide?.cancel()
            hoverShow?.cancel()
            hoverTileKey = nil
            return
        }
        // Check again shortly after the pointer stops: if it came to rest
        // while the Dock was still magnifying, the first look can miss.
        hoverRecheck?.cancel()
        if recheck {
            let again = DispatchWorkItem { [weak self] in
                guard let self, let now = CGEvent(source: nil)?.location else { return }
                self.lastHoverCheck = .distantPast
                self.dockHover(at: now, recheck: false)
            }
            hoverRecheck = again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: again)
        }
        guard Date().timeIntervalSince(lastHoverCheck) > 0.04 else { return }
        lastHoverCheck = Date()
        let key = profileKey(underMouse: location)
        if key != nil && key == hoverKey { hoverAnchor = location }
        if key != hoverTileKey {
            hoverTileKey = key
            hoverShow?.cancel()
            if key != hoverSuppressed { hoverSuppressed = nil }
            if let key, key != hoverKey, key != hoverSuppressed {
                // A short pause, so sweeping across the Dock doesn't flash
                // lists, and a longer one for an icon crossed on the way up
                // to the open list.
                let delay = hoverPanel == nil ? 0.3 : (aimingAtList(location) ? 0.35 : 0.06)
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoverTileKey == key else { return }
                    self.showHoverList(key)
                }
                hoverShow = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        if key == nil {
            scheduleHoverHide()
        } else if key == hoverKey {
            hoverHide?.cancel()
        }
    }

    /// True while the pointer heads from the shown profile's icon towards its
    /// list: inside the triangle between where it last was on that icon and
    /// the list's near edge.
    func aimingAtList(_ location: CGPoint) -> Bool {
        guard let panel = hoverPanel, let apex = hoverAnchor else { return false }
        let list = cocoaRect(panel.frame).insetBy(dx: -24, dy: -24)  // cocoaRect flips both ways
        let dock = dockFrame.isNull ? hoverListTile : dockFrame
        let a: CGPoint, b: CGPoint
        if dock.width >= dock.height {
            (a, b) = (CGPoint(x: list.minX, y: list.maxY), CGPoint(x: list.maxX, y: list.maxY))
        } else if dock.midX < list.midX {
            (a, b) = (CGPoint(x: list.minX, y: list.minY), CGPoint(x: list.minX, y: list.maxY))
        } else {
            (a, b) = (CGPoint(x: list.maxX, y: list.minY), CGPoint(x: list.maxX, y: list.maxY))
        }
        return inTriangle(location, apex, a, b)
    }

    func scheduleHoverHide() {
        guard hoverPanel != nil, hoverHide == nil || hoverHide!.isCancelled else { return }
        // Grace time to move the pointer from the icon up into the list.
        let work = DispatchWorkItem { [weak self] in self?.hideHoverList(animated: true) }
        hoverHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Within reach of a screen edge, where an auto-hidden Dock appears.
    func nearScreenEdge(_ p: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let f = cocoaRect(screen.frame)  // Accessibility coordinates
            return f.contains(p) && (p.y > f.maxY - 160 || p.x < f.minX + 160 || p.x > f.maxX - 160)
        }
    }

    /// The profile whose Dock icon is under the pointer, if any.
    func profileKey(underMouse location: CGPoint) -> String? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        // Only ask the Dock about the pointer when it's near the Dock. The
        // Dock's frame is re-read every few seconds, and more often near a
        // screen edge, since an auto-hidden Dock moves when it appears.
        let near = { self.dockFrame.insetBy(dx: -10, dy: -90).contains(location) }
        let age = Date().timeIntervalSince(dockFrameChecked)
        if age > 3 || (age > 0.5 && nearScreenEdge(location)) {
            dockFrameChecked = Date()
            dockFrame = .null
            if let list = (attribute(element, kAXChildrenAttribute) as [AXUIElement]?)?.first,
               let origin = point(list, kAXPositionAttribute), let extent = size(list, kAXSizeAttribute) {
                dockFrame = CGRect(origin: origin, size: extent)
            }
        }
        guard !dockFrame.isNull, near(), let item = dockItem(at: location),
              let key = installedProfiles().first(where: { $0.appPath == item.path })?.key else { return nil }
        hoverTile = item.frame
        return key
    }

    /// The app (standardized, lowercased path) and frame of the Dock icon at
    /// a point, Accessibility coordinates.
    func dockItem(at location: CGPoint) -> (path: String, frame: CGRect)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element, Float(location.x), Float(location.y), &hit) == .success, var item = hit else { return nil }
        var url: URL? = attribute(item, kAXURLAttribute)
        if url == nil, let parent: AXUIElement = attribute(item, kAXParentAttribute) { item = parent; url = attribute(item, kAXURLAttribute) }
        guard let path = url?.standardizedFileURL.path.lowercased() else { return nil }
        var frame = CGRect.null
        if let origin = point(item, kAXPositionAttribute), let extent = size(item, kAXSizeAttribute) { frame = CGRect(origin: origin, size: extent) }
        return (path, frame)
    }

    /// The profile's windows, if its bridge is connected and current.
    func liveWindows(_ key: String) -> LiveState? {
        guard let data = try? Data(contentsOf: bridge.appendingPathComponent("state/\(key).json")),
              let state = try? JSONDecoder().decode(LiveState.self, from: data),
              state.connected, Date().timeIntervalSince1970 - state.updated < 5 else { return nil }
        return state
    }

    func shown(_ live: LiveState) -> HoverShown {
        HoverShown(session: live.session, windows: live.windows.filter { !hoverExcluded.contains($0.id) },
                   chromeActive: runningChrome()?.isActive == true, canClose: live.canClose)
    }

    func favicon(_ dataURL: String?) -> NSImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ",") else { return nil }
        if let cached = favicons[dataURL] { return cached }
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        if favicons.count > 200 { favicons = [:] }
        favicons[dataURL] = image
        return image
    }

    func showHoverList(_ key: String) {
        let previousTile = hoverListTile
        hoverListTile = hoverTile
        guard let live = liveWindows(key), let content = hoverContent(key, live) else {
            // Nothing to list for this profile (no windows, not connected):
            // treat it like leaving the Dock, so an open list gets the usual
            // grace time instead of vanishing as the pointer crosses here.
            hoverListTile = previousTile
            scheduleHoverHide()
            return
        }
        hideHoverList()
        let panel = HoverPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        hoverPanel = panel
        hoverKey = key
        hoverShown = shown(live)
        install(content, in: panel)
        // In a long list, start scrolled to the window a click would bring.
        if let scroll = scrollView(in: content),
           let row = scroll.documentView?.subviews.first(where: { $0.identifier == markedRow }) {
            row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -24))
        }
        // Fade in while rising a few points out of the Dock.
        let final = panel.frame
        let dock = dockFrame.isNull ? hoverListTile : dockFrame
        let offset: NSPoint = dock.width >= dock.height ? NSPoint(x: 0, y: -6) : (cocoaRect(dock).midX < final.midX ? NSPoint(x: -6, y: 0) : NSPoint(x: 6, y: 0))
        panel.setFrameOrigin(NSPoint(x: final.minX + offset.x, y: final.minY + offset.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        // Keep the list current while it's open: titles, new and closed windows.
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.pollHoverList() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.clearMagnifiedIcon() }
    }

    /// The Dock keeps magnifying after the list appears: move the list up if
    /// the icon has grown into it. Never down, so it doesn't drift away from
    /// a pointer on its way in while the icon shrinks back.
    func clearMagnifiedIcon() {
        guard let panel = hoverPanel, let key = hoverKey,
              let app = installedProfiles().first(where: { $0.key == key })?.app,
              let tile = dockItemFrame(forApp: app), tile != hoverListTile else { return }
        let previous = hoverListTile
        hoverListTile = tile
        let origin = hoverOrigin(for: panel.frame.size)
        let dock = dockFrame.isNull ? tile : dockFrame
        let away = dock.width >= dock.height ? origin.y > panel.frame.minY + 1
            : (cocoaRect(dock).midX < panel.frame.midX ? origin.x > panel.frame.minX + 1 : origin.x < panel.frame.minX - 1)
        // A shrinking icon must not pull the list back down later.
        guard away else { hoverListTile = previous; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
        }
    }

    func pollHoverList() {
        guard let key = hoverKey, let panel = hoverPanel else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }  // never swap rows mid-click
        guard let live = liveWindows(key) else {
            // Only once the pointer is out of the list: a bridge that is
            // reconnecting is back within a second or two.
            if !panel.frame.contains(NSEvent.mouseLocation) { hideHoverList(animated: true) }
            return
        }
        // While the pointer is in the list, rows stay exactly where they are
        // (a title changing in the background would shift the row about to
        // be clicked); the list catches up once the pointer leaves.
        if shown(live) != hoverShown && !panel.frame.contains(NSEvent.mouseLocation) { refreshHoverList() }
        clearMagnifiedIcon()
    }

    /// Rebuild the open list in place, keeping its scroll position.
    func refreshHoverList() {
        guard let panel = hoverPanel, let key = hoverKey else { return }
        guard let live = liveWindows(key), let content = hoverContent(key, live) else { hideHoverList(animated: true); return }
        let scrolled = scrollView(in: panel.contentView)?.contentView.bounds.origin
        install(content, in: panel, keepPlace: true)
        if let scrolled, let scroll = scrollView(in: content) {
            scroll.contentView.scroll(to: scrolled)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        hoverShown = shown(live)
    }

    func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    /// `keepPlace`: a list already on screen keeps its edge by the Dock
    /// (only growing or shrinking away from it), instead of being placed
    /// afresh against an icon that has since shrunk back.
    func install(_ content: NSView, in panel: NSPanel, keepPlace: Bool = false) {
        var origin = hoverOrigin(for: content.frame.size)
        if keepPlace {
            let dock = dockFrame.isNull ? hoverListTile : dockFrame
            let old = panel.frame
            if dock.width >= dock.height {
                origin = NSPoint(x: old.minX, y: old.minY)
            } else {
                origin = NSPoint(x: cocoaRect(dock).midX < old.midX ? old.minX : old.maxX - content.frame.width,
                                 y: old.maxY - content.frame.height)
            }
            if let screen = panel.screen ?? NSScreen.main {
                let bounds = screen.frame.insetBy(dx: 8, dy: 8)
                origin.x = min(max(origin.x, bounds.minX), bounds.maxX - content.frame.width)
                origin.y = min(max(origin.y, bounds.minY), bounds.maxY - content.frame.height)
            }
        }
        panel.setFrame(NSRect(origin: origin, size: content.frame.size), display: false)
        panel.contentView = content
        panel.invalidateShadow()
        // Highlight whatever row is already under the pointer.
        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        var stack: [NSView] = [content]
        while let view = stack.popLast() {
            if let row = view as? HoverControl, let superview = row.superview {
                row.setHovering(row.frame.contains(superview.convert(mouse, from: nil)))
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    /// How far magnified Dock icons reach past the Dock itself.
    /// Measured from the Dock itself, not its size setting: a crowded Dock
    /// draws icons smaller than the setting, so they grow further. A
    /// magnified tile is about 1.23 times the magnified icon size.
    func magnificationReach(dockThickness: CGFloat) -> CGFloat {
        guard let dock = UserDefaults(suiteName: "com.apple.dock"), dock.bool(forKey: "magnification") else { return 0 }
        let large = dock.object(forKey: "largesize") as? Double ?? 64
        return max(0, CGFloat(large) * 1.23 - dockThickness)
    }

    /// Where the list goes: just past a bottom or side Dock (and its
    /// magnified icons), lined up with the hovered icon and kept on screen.
    func hoverOrigin(for size: NSSize) -> NSPoint {
        let tile = cocoaRect(hoverListTile), dock = cocoaRect(dockFrame.isNull ? hoverListTile : dockFrame)
        let screen = NSScreen.screens.first { $0.frame.intersects(tile) } ?? NSScreen.main!
        let bounds = screen.frame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 10, reach = magnificationReach(dockThickness: min(dock.width, dock.height))
        var origin: NSPoint
        if dock.width >= dock.height {
            origin = NSPoint(x: tile.midX - size.width / 2, y: max(dock.maxY + reach, tile.maxY, screen.visibleFrame.minY) + gap)
        } else if dock.midX < screen.frame.midX {
            origin = NSPoint(x: max(dock.maxX + reach, tile.maxX) + gap, y: tile.midY - size.height / 2)
        } else {
            origin = NSPoint(x: min(dock.minX - reach, tile.minX) - gap - size.width, y: tile.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), min(bounds.maxY, screen.visibleFrame.maxY - 8) - size.height)
        return origin
    }

    func hoverContent(_ key: String, _ live: LiveState) -> NSView? {
        guard let profile = installedProfiles().first(where: { $0.key == key }) else { return nil }
        // A fixed order (when each was opened), the same one clicks on the
        // icon walk through, so rows don't jump around between visits.
        let windows = live.windows.filter { !hoverExcluded.contains($0.id) }.sorted { $0.id < $1.id }
        guard !windows.isEmpty else { return nil }
        // Mark where a click on the icon goes: the window in front, or else
        // the one a click would bring back.
        let now = Date().timeIntervalSince1970
        let chromeActive = runningChrome()?.isActive == true
        let current = chromeActive ? windows.first { $0.focused == true }?.id : nil
        let next = current == nil ? clickTarget(windows, chromeWasFront: false, now: now)?.id : nil

        let width: CGFloat = 300, inset: CGFloat = 6, rowWidth = width - inset * 2
        let headerHeight: CGFloat = 40, footerHeight: CGFloat = 32
        let rows = windows.map { window in
            makeRow(window, width: rowWidth, tag: window.id == current ? .current : (window.id == next ? .lastUsed : nil),
                    canClose: live.canClose, key: key, session: live.session)
        }
        let listHeight = rows.reduce(0) { $0 + $1.frame.height }
        let available = (NSScreen.screens.first { $0.frame.intersects(cocoaRect(hoverListTile)) } ?? NSScreen.main)
            .map { $0.visibleFrame.height - headerHeight - footerHeight - 60 } ?? 500
        // About ten rows at most, then it scrolls: a list taller than that is
        // slower to scan than to scroll.
        let shownHeight = min(listHeight, max(min(available, 540), 120))
        let height = headerHeight + 1 + 4 + shownHeight + 4 + 1 + 4 + footerHeight + inset

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.effectiveAppearance.performAsCurrentDrawingAppearance {
            background.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let content = FlippedView(frame: background.bounds)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)

        // Header: the profile's icon and name; how many windows and tabs.
        let icon = NSImageView(frame: NSRect(x: 12, y: 9, width: 22, height: 22))
        icon.image = appIcon(profile)
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)
        let tabs = windows.reduce(0) { $0 + $1.tabCount }
        let summary = "\(windows.count) window\(windows.count == 1 ? "" : "s") · \(tabs) tab\(tabs == 1 ? "" : "s")"
        let count = label(summary, size: 11, color: .secondaryLabelColor)
        count.alignment = .right
        count.frame = NSRect(x: width - 152, y: 13, width: 140, height: 14)
        content.addSubview(count)
        let name = label(profile.label, size: 13, weight: .semibold)
        name.frame = NSRect(x: 42, y: 11, width: width - 42 - 156, height: 17)
        content.addSubview(name)
        content.addSubview(separator(y: headerHeight, width: width))

        // Windows; scrolls if there are a lot.
        let listTop = headerHeight + 1 + 4
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: listHeight))
        var y: CGFloat = 0
        for row in rows {
            row.setFrameOrigin(NSPoint(x: inset, y: y))
            list.addSubview(row)
            y += row.frame.height
        }
        if listHeight > shownHeight {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: listTop, width: width, height: shownHeight))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.documentView = list
            content.addSubview(scroll)
        } else {
            list.setFrameOrigin(NSPoint(x: 0, y: listTop))
            content.addSubview(list)
        }

        // Footer: a new window in this profile.
        let footerTop = listTop + shownHeight + 4
        content.addSubview(separator(y: footerTop, width: width))
        let new = HoverRow(frame: NSRect(x: inset, y: footerTop + 1 + 4, width: rowWidth, height: footerHeight))
        let plus = symbol("plus", size: 13, weight: .medium)
        plus.frame = NSRect(x: 9, y: 7, width: 18, height: 18)
        new.addSubview(plus)
        let newLabel = label("New Window", size: 13)
        newLabel.frame = NSRect(x: 36, y: 7, width: rowWidth - 46, height: 17)
        new.addSubview(newLabel)
        new.setAccessibilityElement(true)
        new.setAccessibilityRole(.button)
        new.setAccessibilityLabel("New \(profile.label) window")
        new.onClick = { [weak self] in
            self?.hideHoverList()
            self?.openChrome(profile.directory)
        }
        content.addSubview(new)
        return background
    }

    func separator(y: CGFloat, width: CGFloat) -> NSView {
        let line = NSBox(frame: NSRect(x: 12, y: y, width: width - 24, height: 1))
        line.boxType = .separator
        return line
    }

    enum RowTag { case current, lastUsed }

    func makeRow(_ window: Window, width: CGFloat, tag: RowTag?, canClose: Bool, key: String, session: String) -> HoverRow {
        let textX: CGFloat = 36, textWidth = width - textX - (canClose ? 32 : 10)
        let text = window.title.isEmpty ? "New Tab" : window.title
        let title = NSTextField(wrappingLabelWithString: text)
        title.isSelectable = false  // wrapping labels are selectable by default
        title.font = .systemFont(ofSize: 13, weight: tag == .current ? .medium : .regular)
        title.textColor = window.minimized ? .secondaryLabelColor : .labelColor
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.preferredMaxLayoutWidth = textWidth
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: title.font!))
        let measured = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: 200),
                                                       options: [.usesLineFragmentOrigin], attributes: [.font: title.font!]).height
        let titleHeight = min(ceil(measured), lineHeight * 2)
        let height = 8 + titleHeight + 2 + 14 + 8
        let row = HoverRow(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if tag != nil { row.identifier = markedRow }
        title.frame = NSRect(x: textX, y: 8, width: textWidth, height: titleHeight)
        row.addSubview(title)

        // The tab's favicon (or a plain globe), dimmed when minimized.
        let iconFrame = NSRect(x: 10, y: 8 + (lineHeight - 16) / 2, width: 16, height: 16)
        let icon: NSImageView
        if let image = favicon(window.icon) {
            icon = NSImageView(frame: iconFrame)
            icon.image = image
            icon.imageScaling = .scaleProportionallyUpOrDown
        } else {
            icon = symbol("globe", size: 13)
            icon.frame = iconFrame
        }
        icon.alphaValue = window.minimized ? 0.5 : 1
        row.addSubview(icon)

        // "Current · github.com · 5 tabs"
        let detail = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: 11)
        func add(_ text: String, _ color: NSColor = .secondaryLabelColor, weight: NSFont.Weight = .regular) {
            if detail.length > 0 { detail.append(NSAttributedString(string: " · ", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor])) }
            detail.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight), .foregroundColor: color]))
        }
        switch tag {
        case .current: add("Current", .controlAccentColor, weight: .medium)
        case .lastUsed: add("Last used", .secondaryLabelColor, weight: .medium)
        case nil: break
        }
        if window.minimized { add("Minimized") }
        if let host = window.host { add(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) }
        add("\(window.tabCount) tab\(window.tabCount == 1 ? "" : "s")")
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        detail.addAttribute(.paragraphStyle, value: truncate, range: NSRange(location: 0, length: detail.length))
        let subtitle = NSTextField(labelWithAttributedString: detail)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: textX, y: 8 + titleHeight + 2, width: textWidth, height: 14)
        row.addSubview(subtitle)

        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.button)
        row.setAccessibilityLabel(text + (window.minimized ? ", minimized" : ""))
        row.onClick = { [weak self] in
            self?.hideHoverList()
            self?.focusWindow(key: key, windowId: window.id, title: text)
        }

        if canClose {
            let close = HoverControl(frame: NSRect(x: width - 28, y: (height - 20) / 2, width: 20, height: 20))
            close.wantsLayer = true
            close.layer?.cornerRadius = 10
            let mark = symbol("xmark", size: 9, weight: .bold)
            mark.frame = close.bounds.insetBy(dx: 4, dy: 4)
            close.addSubview(mark)
            close.onHover = { [weak close] hovering in
                close?.effectiveAppearance.performAsCurrentDrawingAppearance {
                    close?.layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
                }
            }
            let closeWindow = { [weak self] in
                guard let self else { return }
                self.hoverExcluded.insert(window.id)
                let current = self.liveWindows(key)?.session ?? session  // the bridge may have reconnected
                self.sendCommand("close", key: key, session: current, windowId: window.id) { [weak self] ok in
                    // Chrome refused (or the window was already gone): show
                    // whatever is really there.
                    guard let self, ok != true else { return }
                    self.hoverExcluded.remove(window.id)
                    self.refreshHoverList()
                }
                self.refreshHoverList()
            }
            close.onClick = closeWindow
            row.onMiddleClick = closeWindow  // like closing a tab
            close.setAccessibilityElement(true)
            close.setAccessibilityRole(.button)
            close.setAccessibilityLabel("Close \(text)")
            close.isHidden = true
            row.accessory = close
            row.addSubview(close)
        }
        return row
    }

    func hideHoverList(animated: Bool = false) {
        hoverHide?.cancel()
        hoverHide = nil
        hoverPoll?.invalidate()
        hoverPoll = nil
        if let panel = hoverPanel {
            if animated {
                panel.ignoresMouseEvents = true
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.1
                    panel.animator().alphaValue = 0
                }, completionHandler: { panel.orderOut(nil) })
            } else {
                panel.orderOut(nil)
            }
        }
        hoverPanel = nil
        hoverKey = nil
        hoverAnchor = nil
        hoverExcluded = []
    }

    /// A click on a profile's Dock icon goes to its launcher (a left click
    /// opens a window, a right click shows the Dock menu): the list steps
    /// aside until the pointer leaves that icon. A click anywhere else but
    /// the list closes it too.
    func hoverClick(at location: CGPoint) {
        if let key = hoverTileKey, hoverTile.insetBy(dx: -2, dy: -2).contains(location) {
            hoverSuppressed = key
            hoverShow?.cancel()
            hideHoverList()
            return
        }
        guard let panel = hoverPanel else { return }
        if panel.frame.contains(cocoaRect(CGRect(origin: location, size: .zero)).origin) { return }
        hideHoverList()
    }

    /// Same path as the launcher: hand the profile's extension a command,
    /// then act on its answer.
    func sendCommand(_ type: String, key: String, session: String, windowId: Int, done: @escaping (Bool?) -> Void) {
        let request = UUID().uuidString
        let folder = bridge.appendingPathComponent("commands/\(key)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["type": type, "session": session, "windowId": windowId]) {
            try? data.write(to: folder.appendingPathComponent(request + ".json"), options: .atomic)
        }
        let result = bridge.appendingPathComponent("results/\(request).json")
        let deadline = Date().addingTimeInterval(1.2)
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if let data = try? Data(contentsOf: result) {
                timer.invalidate()
                try? FileManager.default.removeItem(at: result)
                done((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool ?? false)
            } else if Date() > deadline {
                timer.invalidate()
                done(nil)
            }
        }
    }

    /// Switch to one window from the list. Always uses the bridge's current
    /// connection (it changes whenever Chrome restarts the extension, which
    /// a list opened earlier can't know), waits out a reconnect, retries a
    /// refusal, and only falls back to the profile's last window when the
    /// window itself is gone.
    func focusWindow(key: String, windowId: Int, title: String, attempt: Int = 0) {
        let retry = { (delay: Double) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.focusWindow(key: key, windowId: windowId, title: title, attempt: attempt + 1)
            }
        }
        if attempt == 0 { log("list click: \(key) window \(windowId)") }
        guard let live = liveWindows(key) else {
            if attempt < 8 { retry(0.25); return }
            log("list click: \(key) bridge not connected; showing the profile instead")
            selectProfile(key)
            return
        }
        guard live.windows.contains(where: { $0.id == windowId }) else {
            log("list click: that \(key) window is gone; showing the profile instead")
            selectProfile(key)
            return
        }
        sendCommand("focus", key: key, session: live.session, windowId: windowId) { ok in
            if ok == true {
                log("list click: \(key) window \(windowId) focused")
                self.bringChromeWindowForward(title: title, key: key)
            } else if attempt < 2 {
                log("list click: \(key) focus \(ok == nil ? "timed out" : "refused"), retrying")
                retry(0.15)
            } else if ok == nil {
                // Chrome may still have switched; don't jump to another window.
                log("list click: \(key) focus timed out; bringing Chrome forward")
                self.bringChromeWindowForward(title: title, key: key)
            } else {
                log("list click: \(key) focus refused; showing the profile instead")
                self.selectProfile(key)
            }
        }
    }

    /// Bring Chrome forward with the window just focused on top: the Chrome
    /// window with that page title in that profile (preferring Chrome's own
    /// key window among look-alikes), raised by itself rather than the app's
    /// whole stack.
    func bringChromeWindowForward(title: String, key: String) {
        guard let chrome = runningChrome() else { return }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        let label = installedProfiles().first { $0.key == key }?.label
        let profiles = chromeProfiles()
        let matches = windows.filter { window in
            let full: String = attribute(window, kAXTitleAttribute) ?? ""
            return full.hasPrefix(title + " - Google Chrome") && (label == nil || profile(forChromeTitle: full, in: profiles)?.label == label)
        }
        let focused: AXUIElement? = attribute(app, kAXFocusedWindowAttribute)
        let target = matches.first { window in focused.map { CFEqual($0, window) } ?? false } ?? matches.first ?? focused
        if let target {
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            bringForward(chrome, window: windowID(target))
        } else {
            bringForward(chrome)
        }
    }
}

@main
enum AgentMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let agent = Agent()
        app.delegate = agent
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
