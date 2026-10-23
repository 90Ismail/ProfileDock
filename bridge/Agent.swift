import AppKit
import ApplicationServices
import ScreenCaptureKit

// ProfileDock Agent: a menu-bar-less background helper that
//  - shows an AltTab-style window switcher on Option+Tab (hold Option, press
//    Tab / Shift+Tab to move, release Option to switch, Esc to cancel), and
//  - makes the green traffic-light button fill the screen (like Option-click)
//    instead of entering full screen. Option-click the green button for real
//    full screen.
//  - shows a profile's Chrome windows when hovering its Dock icon, and
//  - makes a profile's Chrome windows minimize into that profile's Dock icon
//    (yellow button or Cmd+M) instead of Chrome's own.
// All need Accessibility permission, granted once to this app. Screen
// Recording is optional: with it, the minimize animation shows the window
// itself; without it, a card with the profile's icon.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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

func log(_ message: String) {
    let file = bridge.deletingLastPathComponent().appendingPathComponent("agent.log")
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
    var swallowMouseUp = false
    var restoreFrames: [CGWindowID: CGRect] = [:]
    var permissionTimer: Timer?
    // Minimize-into-profile state. `parked` survives restarts (on disk) so a
    // window never gets stranded in the screen corner.
    var parked: [CGWindowID: ParkedWindow] = [:]
    var snapshots: [CGWindowID: CGImage] = [:]
    var chromeObserver: AXObserver?
    var observedChromePid: pid_t = 0
    // Dock hover window list.
    var hoverPanel: HoverPanel?
    var hoverKey: String?          // profile whose list is showing
    var hoverTileKey: String?      // profile icon under the mouse right now
    var hoverTile = CGRect.null    // that icon, Accessibility coordinates
    var hoverShow: DispatchWorkItem?
    var hoverHide: DispatchWorkItem?
    var hoverHeartbeat: Timer?
    var lastHoverCheck = Date.distantPast
    var dockFrame = CGRect.null
    var dockFrameChecked = Date.distantPast
    var focusTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("started, accessibility \(trusted ? "granted" : "not granted yet")")
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let optionOnly = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
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
        guard let origin = point(window, kAXPositionAttribute), let extent = size(window, kAXSizeAttribute) else { return false }
        let current = CGRect(origin: origin, size: extent)
        log("green button in \(NSRunningApplication(processIdentifier: { var pid: pid_t = 0; AXUIElementGetPid(window, &pid); return pid }())?.localizedName ?? "?")")
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

    struct ChromeProfile { let label: String; let icon: NSImage?; let titles: Set<String>; let app: String? }

    /// Every ProfileDock profile with its Dock icon and current window titles.
    func chromeProfiles() -> [ChromeProfile] {
        guard let data = try? Data(contentsOf: bridge.appendingPathComponent("profiles.json")),
              let profiles = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return profiles.compactMap { key, profile in
            guard let label = profile["label"] as? String else { return nil }
            var titles = Set<String>()
            if let data = try? Data(contentsOf: bridge.appendingPathComponent("state/\(key).json")),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let windows = state["windows"] as? [[String: Any]] {
                titles = Set(windows.compactMap { $0["title"] as? String })
            }
            let icon = (profile["app"] as? String).map { NSWorkspace.shared.icon(forFile: $0) }
            return ChromeProfile(label: label, icon: icon, titles: titles, app: profile["app"] as? String)
        }
    }

    /// Which profile a Chrome window belongs to. With several profiles open,
    /// Chrome titles windows "Page - Google Chrome - Ismail (STU)", so the
    /// profile name after the last " - Google Chrome - " decides; the
    /// bridge's window titles are the fallback.
    func profile(forChromeTitle title: String, in profiles: [ChromeProfile]) -> ChromeProfile? {
        if let range = title.range(of: " - Google Chrome - ", options: .backwards) {
            let name = title[range.upperBound...].lowercased()
            if let exact = profiles.first(where: { name == $0.label.lowercased() || name.hasSuffix("(\($0.label.lowercased()))") }) { return exact }
            if let loose = profiles.first(where: { name.contains($0.label.lowercased()) }) { return loose }
        }
        let page = pageTitle(title)
        return profiles.first { $0.titles.contains(page) }
    }

    func pageTitle(_ title: String) -> String {
        guard let range = title.range(of: " - Google Chrome") else { return title }
        return String(title[..<range.lowerBound])
    }

    func openSwitcher() {
        items = collectWindows()
        guard !items.isEmpty else { active = false; return }
        selected = items.count > 1 ? 1 : 0
        let profiles = chromeProfiles()

        let columns = min(items.count, 6)
        let rows = (items.count + columns - 1) / columns
        let cell = CGSize(width: 150, height: 150), padding: CGFloat = 16
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
            let view = NSView(frame: frame.insetBy(dx: 4, dy: 4))
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
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
            title.font = .systemFont(ofSize: 11)
            title.alignment = .center
            title.maximumNumberOfLines = 2
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: 6, y: 2, width: view.frame.width - 12, height: 32)
            view.addSubview(title)
            background.addSubview(view)
            cells.append(view)
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
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
        item.app.activate(options: [])
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

    func observeChrome() {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first,
              chrome.processIdentifier != observedChromePid else { return }
        if let old = chromeObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode) }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            Unmanaged<Agent>.fromOpaque(refcon!).takeUnretainedValue().chromeWindowRestored(element)
        }
        guard AXObserverCreate(chrome.processIdentifier, callback, &observer) == .success, let observer else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        chromeObserver = observer
        observedChromePid = chrome.processIdentifier
    }

    /// Watch one window for being un-minimized (by the profile's Dock icon,
    /// Chrome's Window menu, or anything else).
    func watchForRestore(_ window: AXUIElement) {
        observeChrome()
        guard let chromeObserver else { return }
        AXObserverAddNotification(chromeObserver, window, kAXWindowDeminiaturizedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
    }

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
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.google.Chrome",
              let title: String = attribute(window, kAXTitleAttribute),
              profile(forChromeTitle: title, in: chromeProfiles())?.app != nil else { return false }
        DispatchQueue.main.async { self.minimizeIntoProfile(window) }
        return true
    }

    /// Cmd+M in Chrome (already swallowed by the event tap).
    func minimizeFocusedChromeWindow(_ chrome: NSRunningApplication) {
        let element = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window: AXUIElement = attribute(element, kAXFocusedWindowAttribute) else { return }
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
            self.snapshots[id] = image
            self.saveParked()
            // Tuck the real window into the corner (macOS clamps the huge
            // value), then minimize it from there.
            var corner = CGPoint(x: 100_000, y: 100_000)
            if let value = AXValueCreate(.cgPoint, &corner) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            self.watchForRestore(window)
            let tile = self.dockTile(forApp: app, near: frame)
            self.fly(ghost, to: tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.2), duration: 0.32, alpha: 0.4,
                     timing: CAMediaTimingFunction(name: .easeIn)) { ghost.orderOut(nil) }
        }
    }

    func chromeWindowRestored(_ window: AXUIElement) {
        let id = windowID(window)
        if let chromeObserver { AXObserverRemoveNotification(chromeObserver, window, kAXWindowDeminiaturizedNotification as CFString) }
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
        let wanted = URL(fileURLWithPath: app).standardizedFileURL.path.lowercased()
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let element = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            for list in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    guard let url: URL = attribute(item, kAXURLAttribute),
                          url.standardizedFileURL.path.lowercased() == wanted,
                          let origin = point(item, kAXPositionAttribute), let extent = size(item, kAXSizeAttribute) else { continue }
                    return cocoaRect(CGRect(origin: origin, size: extent))
                }
            }
        }
        let screen = cocoaRect(visibleFrame(containing: frame) ?? frame)
        return NSRect(x: screen.midX - 30, y: screen.minY - 60, width: 60, height: 60)
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

// MARK: - Dock hover window list
//
// Hovering a profile's Dock icon shows that profile's windows just above it;
// clicking a row switches to that window. The Dock has no API for this, so
// on mouse moves near the Dock the Agent asks Accessibility which Dock icon
// is under the pointer (which also copes with Dock magnification).

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class HoverRow: NSView {
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?
    var highlighted = false {
        didSet { layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : NSColor.clear.cgColor }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }
    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

let hoverFile = bridge.appendingPathComponent("hover-picker.json")

extension Agent {
    /// key -> launcher app path (lowercased), from the installed profiles.
    func profileApps() -> [String: String] {
        guard let data = try? Data(contentsOf: bridge.appendingPathComponent("profiles.json")),
              let profiles = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return profiles.compactMapValues { ($0["app"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() } }
    }

    func dockHover(at location: CGPoint) {
        let panelFrame = hoverPanel.map { $0.frame } ?? .null
        let cocoaPoint = cocoaRect(CGRect(origin: location, size: .zero)).origin
        if panelFrame.insetBy(dx: -6, dy: -6).contains(cocoaPoint) {  // reaching for / inside the list
            hoverHide?.cancel()
            return
        }
        guard Date().timeIntervalSince(lastHoverCheck) > 0.04 else { return }
        lastHoverCheck = Date()
        let key = profileKey(underMouse: location)
        if key != hoverTileKey {
            hoverTileKey = key
            hoverShow?.cancel()
            if let key, key != hoverKey {
                // A short pause, so sweeping across the Dock doesn't flash lists.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoverTileKey == key else { return }
                    self.showHoverList(key)
                }
                hoverShow = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (hoverPanel == nil ? 0.25 : 0.05), execute: work)
            }
        }
        if key == nil {
            scheduleHoverHide()
        } else if key == hoverKey {
            hoverHide?.cancel()
        }
    }

    func scheduleHoverHide() {
        guard hoverPanel != nil, hoverHide == nil || hoverHide!.isCancelled else { return }
        // Grace time to move the pointer from the icon up into the list.
        let work = DispatchWorkItem { [weak self] in self?.hideHoverList() }
        hoverHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The profile whose Dock icon is under the pointer, if any.
    func profileKey(underMouse location: CGPoint) -> String? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        // Only ask the Dock when the pointer is near it.
        if Date().timeIntervalSince(dockFrameChecked) > 3 {
            dockFrameChecked = Date()
            dockFrame = .null
            if let list = (attribute(element, kAXChildrenAttribute) as [AXUIElement]?)?.first,
               let origin = point(list, kAXPositionAttribute), let extent = size(list, kAXSizeAttribute) {
                dockFrame = CGRect(origin: origin, size: extent)
            }
        }
        guard !dockFrame.isNull, dockFrame.insetBy(dx: -10, dy: -90).contains(location) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element, Float(location.x), Float(location.y), &hit) == .success, var item = hit else { return nil }
        var url: URL? = attribute(item, kAXURLAttribute)
        if url == nil, let parent: AXUIElement = attribute(item, kAXParentAttribute) { item = parent; url = attribute(item, kAXURLAttribute) }
        guard let path = url?.standardizedFileURL.path.lowercased(),
              let key = profileApps().first(where: { $0.value == path })?.key else { return nil }
        if let origin = point(item, kAXPositionAttribute), let extent = size(item, kAXSizeAttribute) {
            hoverTile = CGRect(origin: origin, size: extent)
        }
        return key
    }

    struct HoverWindow { let id: Int; let title: String; let tabCount: Int; let recency: Double }

    func liveWindows(_ key: String) -> (session: String, windows: [HoverWindow])? {
        guard let data = try? Data(contentsOf: bridge.appendingPathComponent("state/\(key).json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["connected"] as? Bool == true, let session = state["session"] as? String,
              let updated = state["updated"] as? Double, Date().timeIntervalSince1970 - updated < 5,
              let raw = state["windows"] as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSince1970
        let windows = raw.compactMap { w -> HoverWindow? in
            guard let id = w["id"] as? Int else { return nil }
            let recency = (w["focused"] as? Bool == true) ? now : ((w["lastFocused"] as? Double) ?? 0)
            return HoverWindow(id: id, title: (w["title"] as? String) ?? "Chrome window", tabCount: (w["tabCount"] as? Int) ?? 0, recency: recency)
        }
        return (session, windows.sorted { $0.recency > $1.recency })
    }

    func showHoverList(_ key: String) {
        hideHoverList()
        guard let (session, windows) = liveWindows(key), !windows.isEmpty else { return }
        let label = (try? JSONSerialization.jsonObject(with: Data(contentsOf: bridge.appendingPathComponent("profiles.json"))) as? [String: [String: Any]])?[key]?["label"] as? String ?? key
        let width: CGFloat = 340, rowHeight: CGFloat = 44, header: CGFloat = 30
        let rows = min(windows.count, 10)
        let height = header + CGFloat(rows) * rowHeight + 6
        let tile = cocoaRect(hoverTile)
        let screen = NSScreen.screens.first { $0.frame.intersects(tile) } ?? NSScreen.main!
        var x = tile.midX - width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        let y = max(tile.maxY + 10, screen.visibleFrame.minY + 4)
        let panel = HoverPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        let title = NSTextField(labelWithString: "\(label) · \(windows.count) window\(windows.count == 1 ? "" : "s")")
        title.font = .boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 14, y: height - header + 6, width: width - 28, height: 18)
        background.addSubview(title)

        for (index, window) in windows.prefix(rows).enumerated() {
            let row = HoverRow(frame: NSRect(x: 4, y: height - header - CGFloat(index + 1) * rowHeight, width: width - 8, height: rowHeight))
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            let icon = NSImageView(frame: NSRect(x: 10, y: (rowHeight - 18) / 2, width: 18, height: 18))
            icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            row.addSubview(icon)
            let name = NSTextField(labelWithString: window.title)
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 38, y: rowHeight / 2, width: width - 60, height: 17)
            row.addSubview(name)
            let detail = NSTextField(labelWithString: "\(window.tabCount) tab\(window.tabCount == 1 ? "" : "s")" + (index == 0 ? " · last used" : ""))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 38, y: rowHeight / 2 - 15, width: width - 60, height: 14)
            row.addSubview(detail)
            row.onClick = { [weak self] in
                self?.hideHoverList()
                self?.focusWindow(key: key, session: session, windowId: window.id)
            }
            background.addSubview(row)
        }
        hoverPanel = panel
        hoverKey = key
        panel.orderFrontRegardless()
        // Tells the launcher a list is already showing, so clicking the icon
        // doesn't open a second one.
        let beat = { try? JSONSerialization.data(withJSONObject: ["key": key, "updated": Date().timeIntervalSince1970]).write(to: hoverFile, options: .atomic) }
        beat()
        hoverHeartbeat = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in beat() }
    }

    func hideHoverList() {
        hoverHide?.cancel()
        hoverHide = nil
        hoverHeartbeat?.invalidate()
        hoverHeartbeat = nil
        hoverPanel?.orderOut(nil)
        hoverPanel = nil
        hoverKey = nil
        try? FileManager.default.removeItem(at: hoverFile)
    }

    /// A click anywhere but the list or its Dock icon closes the list.
    func hoverClick(at location: CGPoint) {
        guard let panel = hoverPanel else { return }
        let cocoaPoint = cocoaRect(CGRect(origin: location, size: .zero)).origin
        if panel.frame.contains(cocoaPoint) || hoverTile.insetBy(dx: -4, dy: -4).contains(location) { return }
        hideHoverList()
    }

    /// Same path as the launcher: ask the profile's extension to focus the
    /// window, then bring Chrome forward once it confirms.
    func focusWindow(key: String, session: String, windowId: Int) {
        let request = UUID().uuidString
        let folder = bridge.appendingPathComponent("commands/\(key)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "focus", "session": session, "windowId": windowId]) {
            try? data.write(to: folder.appendingPathComponent(request + ".json"), options: .atomic)
        }
        let result = bridge.appendingPathComponent("results/\(request).json")
        let deadline = Date().addingTimeInterval(1.0)
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            guard FileManager.default.fileExists(atPath: result.path) || Date() > deadline else { return }
            timer.invalidate()
            try? FileManager.default.removeItem(at: result)
            guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return }
            // Setting "frontmost" through Accessibility works from a
            // background app, where a plain activate() can be refused.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(chrome.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            chrome.activate(options: [])
        }
    }
}

let app = NSApplication.shared
let agent = Agent()
app.delegate = agent
app.setActivationPolicy(.accessory)
app.run()
