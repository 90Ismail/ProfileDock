import AppKit

// One profile's Dock icon. A click always does something visible:
//  - the profile has no windows: open one;
//  - another app or profile is in front: go to this profile's most recently
//    used window;
//  - this profile is already in front: move on to its next window, so
//    repeated clicks visit every window.
// Hovering the icon (ProfileDock Agent) lists the windows to pick from, and
// right-clicking it shows the same list as a Dock menu. Which window a click
// picks is decided in WindowChoice.swift.

struct State: Decodable { let session: String; let connected: Bool; let updated: Double; let windows: [Window] }

let chromeID = "com.google.Chrome"

final class Delegate: NSObject, NSApplicationDelegate {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProfileDock/bridge")
    var key = "", label = "", directory = ""
    var timer: Timer?
    var grace = Date().addingTimeInterval(15)
    // Without this, App Nap can throttle the 1s heartbeat timer, since this
    // process has no windows and is rarely in front; native_host.py would
    // then think it died.
    var activity: NSObjectProtocol?
    // The app that was frontmost before this launcher. By the time a Dock
    // click reaches choose(), the Dock has already made *this* process
    // frontmost, so it can't ask "is Chrome in front?" directly.
    var previousFrontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    // When choose() last ran, so a Cmd+Tab to this launcher (activation with
    // no Dock click) can be told apart from a Dock click (activation + reopen).
    var lastChoose = Date.distantPast
    var resultTimer: Timer?

    func state() -> State? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state/\(key).json")),
              let s = try? JSONDecoder().decode(State.self, from: data), s.connected,
              Date().timeIntervalSince1970 - s.updated < 5 else { return nil }
        return s
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Keep heartbeat timer accurate")
        let info = Bundle.main.infoDictionary!
        key = info["ProfileDockKey"] as? String ?? ""
        label = info["ProfileDockLabel"] as? String ?? key
        directory = info["ProfileDockDirectory"] as? String ?? "Default"
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier, app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.previousFrontApp = id }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Reached with Cmd+Tab rather than a Dock click: there's no
            // reopen event, so without this the user lands on an app with
            // no windows and nothing happens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if NSApp.isActive && Date().timeIntervalSince(self.lastChoose) > 0.6 { self.choose() }
            }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
        if !CommandLine.arguments.contains("--indicator-only") { choose() }
    }

    func tick() {
        let heartbeat = root.appendingPathComponent("launchers/\(key).json")
        try? FileManager.default.createDirectory(at: heartbeat.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "updated": Date().timeIntervalSince1970]) { try? data.write(to: heartbeat, options: .atomic) }
        if let s = state(), !s.windows.isEmpty { grace = Date() + 15 }
        // Quit once the profile has had no windows for a while, so the Dock's
        // "running" dot means "has windows". Never right after a click: a
        // Reopen sent to a quitting app is lost.
        if Date() > grace && Date().timeIntervalSince(lastChoose) > 10 { NSApp.terminate(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A double-click on the icon is one click: the second would
        // otherwise move on from the window the first one just brought.
        if Date().timeIntervalSince(lastChoose) > 0.35 { choose() }
        return false
    }

    // MARK: - Click

    func choose() {
        lastChoose = Date()
        grace = max(grace, Date() + 15)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).isEmpty else {
            // Cold start. `-n` as everywhere: should Chrome be starting up
            // or not quite gone, a plain `open -a` would reach it as a click
            // on its icon and show the "Who's using Chrome?" picker.
            run("/usr/bin/open", ["-n", "-a", "Google Chrome", "--args", "--profile-directory=\(directory)"])
            return
        }
        guard let s = state() else {
            // The bridge isn't connected (extension asleep or not installed),
            // so whether this profile has windows is unknown: let Chrome's
            // own Profiles menu bring one forward or open one.
            selectProfile()
            return
        }
        guard let window = clickTarget(s.windows, chromeWasFront: previousFrontApp == chromeID,
                                       now: Date().timeIntervalSince1970) else { openNewWindow(); return }
        focus(window, s)
    }

    func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
    }

    func yieldToChrome() {
        // macOS only lets an app come forward if the frontmost app (this
        // launcher, after the Dock click) hands over.
        if #available(macOS 14.0, *) { NSApp.yieldActivation(toApplicationWithBundleIdentifier: chromeID) }
    }

    /// A new window in this profile. With Chrome already running, a second
    /// `open -n` hands its command line to the running Chrome and exits, and
    /// Chrome opens the window in the requested profile. (Never a plain
    /// `open -a`: Chrome ignores its arguments and may show its picker.)
    func openNewWindow() {
        yieldToChrome()
        run("/usr/bin/open", ["-n", "-a", "Google Chrome", "--args", "--profile-directory=\(directory)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.activateChrome(onlyIfNeeded: true) }
        // A picker left from an earlier click on Chrome's own icon has no
        // use now; the Agent closes it.
        askAgent(["type": "opened"]) { _ in }
    }

    /// Hand a request to the ProfileDock Agent (it has the Accessibility
    /// permission launchers lack). `claimed` says whether it picked it up.
    func askAgent(_ request: [String: Any], claimed: @escaping (Bool) -> Void) {
        let folder = root.appendingPathComponent("agent-requests")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              (try? data.write(to: file, options: .atomic)) != nil else { claimed(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Removing it only succeeds if the Agent never claimed it.
            claimed((try? FileManager.default.removeItem(at: file)) == nil)
        }
    }

    /// Ask the Agent to pick this profile in Chrome's Profiles menu, which
    /// focuses the profile's last window or opens one. Without a running
    /// Agent, open a new window instead.
    func selectProfile() {
        yieldToChrome()
        askAgent(["type": "select", "key": key]) { claimed in
            if claimed {
                // Still the active app after the Dock click, this launcher
                // can bring Chrome forward even if the Agent couldn't.
                self.activateChrome(onlyIfNeeded: true)
            } else {
                self.openNewWindow()
            }
        }
    }

    func activateChrome(onlyIfNeeded: Bool = false) {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).first else { return }
        if onlyIfNeeded && chrome.isActive { return }
        // Without .allWindows only Chrome's key window comes forward — the
        // one the extension just focused — not every other profile's window.
        chrome.activate(options: [])
        // macOS refuses that unless this launcher is the active app (it
        // isn't after a Dock-menu choice); the Agent can do it from the
        // background, and osascript is the last resort.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !chrome.isActive else { return }
            self.askAgent(["type": "front"]) { claimed in
                guard !claimed, !chrome.isActive else { return }
                self.run("/usr/bin/osascript", ["-e", "tell application \"Google Chrome\" to activate"])
            }
        }
    }

    func send(_ type: String, _ window: Window, _ state: State, done: ((Bool?) -> Void)? = nil) {
        let request = UUID().uuidString
        let folder = root.appendingPathComponent("commands/\(key)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["type": type, "session": state.session, "windowId": window.id]) {
            try? data.write(to: folder.appendingPathComponent(request + ".json"), options: .atomic)
        }
        guard let done else { return }
        // Wait for the extension's answer rather than a fixed delay:
        // activating Chrome too early briefly shows whichever window Chrome
        // had in front (often another profile's).
        let result = root.appendingPathComponent("results/\(request).json")
        let deadline = Date().addingTimeInterval(1.2)
        resultTimer?.invalidate()
        resultTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if let data = try? Data(contentsOf: result) {
                timer.invalidate()
                try? FileManager.default.removeItem(at: result)
                let ok = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool
                done(ok ?? false)
            } else if Date() > deadline {
                timer.invalidate()
                done(nil)
            }
        }
    }

    func focus(_ window: Window, _ state: State, retried: Bool = false) {
        // Lets Chrome's own activation (from chrome.windows.update) succeed,
        // bringing exactly the requested window.
        yieldToChrome()
        send("focus", window, state) { ok in
            if ok == true { self.activateChrome(); return }
            // Refused or slow: the bridge may have reconnected (a new
            // session) since the state was read. Try once more with the
            // current state while the window still exists.
            if !retried, let fresh = self.state(), fresh.windows.contains(where: { $0.id == window.id }) {
                self.focus(window, fresh, retried: true)
            } else if ok == nil {
                self.activateChrome()  // it may have worked; don't jump to another window
            } else {
                // The window just closed: still land on this profile rather
                // than whichever window was in front.
                self.selectProfile()
            }
        }
    }

    // MARK: - Right-click Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let s = state() {
            // The order clicks on the icon walk through.
            for w in s.windows.sorted(by: { $0.id < $1.id }) {
                var title = w.title.isEmpty ? "New Tab" : w.title
                if title.count > 60 { title = String(title.prefix(57)) + "…" }
                if w.minimized { title += " (minimized)" }
                let item = NSMenuItem(title: title, action: #selector(menuFocus(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = w.id
                item.image = favicon(w.icon)
                if w.focused == true { item.state = .on }
                menu.addItem(item)
            }
            if !s.windows.isEmpty { menu.addItem(.separator()) }
        }
        let new = NSMenuItem(title: "New Window", action: #selector(menuNewWindow), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    func favicon(_ dataURL: String?) -> NSImage? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc func menuFocus(_ item: NSMenuItem) {
        lastChoose = Date()
        guard let id = item.representedObject as? Int, let s = state(),
              let w = s.windows.first(where: { $0.id == id }) else { selectProfile(); return }
        focus(w, s)
    }

    @objc func menuNewWindow() {
        lastChoose = Date()
        openNewWindow()
    }
}

@main
enum Launcher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
