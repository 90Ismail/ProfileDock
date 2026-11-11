// Built with bridge/WindowChoice.swift and run by tests/test_swift.py.

var failures = 0
func check(_ got: Window?, _ want: Int?, _ name: String) {
    if got?.id != want {
        failures += 1
        print("FAIL \(name): expected \(want.map(String.init) ?? "nil"), got \(got.map { String($0.id) } ?? "nil")")
    } else {
        print("ok   \(name)")
    }
}

let now = 1_000_000.0
func w(_ id: Int, ago: Double? = nil, focused: Bool = false, minimized: Bool = false) -> Window {
    Window(id: id, focused: focused, lastFocused: ago.map { now - $0 }, state: minimized ? "minimized" : "normal")
}

@main
enum ChoiceTests {
    static func main() {
        check(clickTarget([], chromeWasFront: false, now: now), nil, "no windows: nothing to focus (launcher opens one)")
        check(clickTarget([w(5, ago: 100)], chromeWasFront: false, now: now), 5, "one window")
        check(clickTarget([w(5, ago: 0.2)], chromeWasFront: true, now: now), 5, "one window already in front: same window again")

        // From another app: the most recently used window.
        let three = [w(1, ago: 50), w(2, ago: 10), w(3, ago: 30)]
        check(clickTarget(three, chromeWasFront: false, now: now), 2, "from another app: most recent")
        check(clickTarget(three, chromeWasFront: true, now: now), 2, "from another Chrome profile: most recent")

        // Already in front: walk through windows by id, wrapping around.
        let front = [w(1, ago: 50), w(2, ago: 0.3), w(3, ago: 30)]
        check(clickTarget(front, chromeWasFront: true, now: now), 3, "in front: next by id")
        let last = [w(1, ago: 50), w(2, ago: 30), w(3, ago: 0.3)]
        check(clickTarget(last, chromeWasFront: true, now: now), 1, "in front on the last window: wraps to first")
        let stillFocused = [w(1, ago: 50), w(2, focused: true), w(3, ago: 30)]
        check(clickTarget(stillFocused, chromeWasFront: true, now: now), 3, "blur not reported yet (still focused): next")
        check(clickTarget(front, chromeWasFront: false, now: now), 2, "recent focus but another app was in front: no cycling")
        let stale = [w(1, ago: 50), w(2, ago: 1.5), w(3, ago: 30)]
        check(clickTarget(stale, chromeWasFront: true, now: now), 2, "left this profile over a second ago: most recent")

        // Minimized windows.
        let hidden = [w(1, ago: 5, minimized: true), w(2, ago: 40)]
        check(clickTarget(hidden, chromeWasFront: false, now: now), 2, "prefers a visible window over a newer minimized one")
        let allMin = [w(1, ago: 5, minimized: true), w(2, ago: 40, minimized: true)]
        check(clickTarget(allMin, chromeWasFront: false, now: now), 1, "all minimized: restores the most recent")
        check(clickTarget(allMin, chromeWasFront: true, now: now), 1, "all minimized, just minimized one: brings it back")
        let skip = [w(1, ago: 0.2), w(2, ago: 20, minimized: true), w(3, ago: 30)]
        check(clickTarget(skip, chromeWasFront: true, now: now), 3, "cycling skips minimized windows")
        let lone = [w(1, ago: 0.2), w(2, ago: 20, minimized: true), w(3, ago: 9, minimized: true)]
        check(clickTarget(lone, chromeWasFront: true, now: now), 3, "only visible window in front: restores the latest minimized")

        // Data the bridge may leave out.
        let unknown = [w(7), w(4)]
        check(clickTarget(unknown, chromeWasFront: true, now: now), 7, "no focus history: first in list, no crash")
        let neverFocused = [w(9), w(3, ago: 0.1)]
        check(clickTarget(neverFocused, chromeWasFront: true, now: now), 9, "in front with a never-focused window: goes to it")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        if failures > 0 { fatalError() }
    }
}
