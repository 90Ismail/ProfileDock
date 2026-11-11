// Which window a click on a profile's Dock icon brings forward. Kept apart
// from the launcher so tests can check it without Chrome (tests/swift).

struct Window: Decodable, Equatable {
    let id: Int
    let title: String
    let tabCount: Int
    let focused: Bool?
    let lastFocused: Double?
    let state: String?
    let host: String?   // the active tab's site, never its URL
    let icon: String?   // the active tab's favicon, as a data: URL

    init(id: Int, title: String = "", tabCount: Int = 1, focused: Bool? = nil, lastFocused: Double? = nil,
         state: String? = nil, host: String? = nil, icon: String? = nil) {
        self.id = id; self.title = title; self.tabCount = tabCount
        self.focused = focused; self.lastFocused = lastFocused; self.state = state; self.host = host; self.icon = icon
    }

    var minimized: Bool { state == "minimized" }

    /// When it was last in front. A focused window counts as "now"; the
    /// bridge also stamps the moment a window loses focus.
    func recency(now: Double) -> Double { (focused ?? false) ? now : (lastFocused ?? 0) }
}

/// How recently (seconds) a window must have been in front for a click to
/// count as "this profile is already in front". A Dock click always takes
/// focus from Chrome before the launcher looks, so "lost focus a moment ago"
/// is the only sign left.
let inFrontWindow = 1.0

/// - Another app or profile in front: the most recently used window that
///   isn't minimized (like the Dock does for any app), or the most recently
///   used one when all are minimized.
/// - This profile in front: the next window, in a fixed order (by when it
///   was opened), so repeated clicks visit every window. Minimized windows
///   are skipped unless nothing else is left to show.
func clickTarget(_ windows: [Window], chromeWasFront: Bool, now: Double) -> Window? {
    guard let latest = windows.max(by: { $0.recency(now: now) < $1.recency(now: now) }) else { return nil }
    let visible = windows.filter { !$0.minimized }
    let inFront = chromeWasFront && !latest.minimized && now - latest.recency(now: now) < inFrontWindow
    guard inFront else {
        return visible.max { $0.recency(now: now) < $1.recency(now: now) } ?? latest
    }
    if visible.count < 2 {
        // Only the window already in front is showing: bring back the most
        // recently minimized one, so the click still does something.
        return windows.filter(\.minimized).max { $0.recency(now: now) < $1.recency(now: now) } ?? latest
    }
    let ordered = visible.sorted { $0.id < $1.id }
    let index = ordered.firstIndex { $0.id == latest.id } ?? -1
    return ordered[(index + 1) % ordered.count]
}
