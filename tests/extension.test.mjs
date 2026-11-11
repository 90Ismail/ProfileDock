// Runs extension/background.js against a fake Chrome API.
// node --test tests/extension.test.mjs  (also run by tests/test_extension.py)
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../extension/background.js", import.meta.url), "utf8");
// Objects made inside the sandbox have its own prototypes; compare plain copies.
const plain = x => JSON.parse(JSON.stringify(x));
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise(r => setImmediate(r)); };
const event = () => { const fns = []; return {addListener: f => fns.push(f), fire: (...a) => fns.forEach(f => f(...a)), fns}; };

function load({windows = [], favicon = true} = {}) {
  const t = {ports: [], fetches: [], updates: [], removed: [], reloads: 0, now: 0, timers: []};
  t.windows = windows;
  const runtime = {
    getURL: p => "chrome-extension://abc" + p,
    getManifest: () => ({version: "0.2.0"}),
    reload: () => { t.reloads++; },
    connectNative: () => {
      const port = {sent: [], onDisconnect: event(), onMessage: event(), postMessage: m => port.sent.push(m)};
      t.ports.push(port);
      return port;
    },
    onStartup: event(), onInstalled: event(), onMessage: event(), lastError: undefined,
  };
  const chrome = {
    runtime,
    windows: {
      getAll: async () => structuredClone(t.windows),
      get: async id => { const w = t.windows.find(w => w.id === id); if (!w) throw new Error("No window with id"); return structuredClone(w); },
      update: async (id, change) => { t.updates.push([id, change]); },
      remove: async id => { t.removed.push(id); t.windows = t.windows.filter(w => w.id !== id); },
      onCreated: event(), onRemoved: event(), onFocusChanged: event(), onBoundsChanged: event(),
    },
    tabs: Object.fromEntries(["onCreated", "onRemoved", "onActivated", "onAttached", "onDetached", "onUpdated"].map(n => [n, event()])),
    alarms: {create: () => {}, onAlarm: event()},
  };
  const fetch = async url => {
    t.fetches.push(url);
    if (url.endsWith("config.json")) return {json: async () => ({profileKey: "pro", label: "Pro"})};
    if (!favicon) return {ok: false};
    return {ok: true, headers: {get: () => "image/png"}, arrayBuffer: async () => new Uint8Array([137, 80, 78, 71]).buffer};
  };
  const setTimeout = (fn, ms) => { const timer = {at: t.now + ms, fn, ms}; t.timers.push(timer); return timer; };
  const clearTimeout = timer => { t.timers = t.timers.filter(x => x !== timer); };
  t.advance = async ms => {
    const end = t.now + ms;
    for (;;) {
      const next = t.timers.filter(x => x.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!next) break;
      t.timers = t.timers.filter(x => x !== next);
      t.now = next.at;
      next.fn();
      await settle();
    }
    t.now = end;
  };
  t.port = () => t.ports.at(-1);
  t.chrome = chrome;
  vm.runInNewContext(source, {chrome, fetch, setTimeout, clearTimeout, URL, btoa, Promise, structuredClone, Uint8Array, String});
  return t;
}

const tab = (url, title, extra = {}) => ({active: true, url, title, ...extra});

test("one connection for a burst of startup events, announcing version and features", async () => {
  const t = load();
  t.chrome.runtime.onStartup.fire();
  t.chrome.windows.onCreated.fire();
  t.chrome.tabs.onActivated.fire();
  await settle();
  assert.equal(t.ports.length, 1);
  assert.deepEqual(plain(t.port().sent[0]), {type: "hello", profile: "pro", version: "0.2.0", features: ["close", "favicon", "reload"]});
});

test("snapshot: only normal, non-incognito windows; host only for web pages; favicon as data URL", async () => {
  const t = load({windows: [
    {id: 1, focused: true, state: "normal", tabs: [tab("https://www.github.com/x?secret=1", "PR"), {active: false, url: "https://a.com"}]},
    {id: 2, focused: false, state: "minimized", tabs: [tab("chrome://newtab/", "")]},
    {id: 3, incognito: true, tabs: [tab("https://private.example", "Private")]},
  ]});
  await settle();
  t.port().onMessage.fire({type: "ready"});
  await settle();
  const snap = t.port().sent.find(m => m.type === "snapshot");
  assert.equal(snap.windows.length, 2);
  assert.deepEqual(plain(snap.windows[0]), {id: 1, title: "PR", tabCount: 2, focused: true, state: "normal",
    host: "www.github.com", icon: "data:image/png;base64,iVBORw=="});
  assert.equal(snap.windows[1].title, "New Tab");
  assert.equal(snap.windows[1].host, undefined);
  assert.equal(snap.windows[1].icon, undefined);
  assert.ok(!JSON.stringify(snap).includes("secret"), "never sends URLs");
});

test("favicons are fetched once per site", async () => {
  const t = load({windows: [{id: 1, focused: true, tabs: [tab("https://a.com/1", "A")]}]});
  await settle();
  t.port().onMessage.fire({type: "ready"});
  await settle();
  t.chrome.tabs.onActivated.fire();
  await t.advance(100);
  t.windows[0].tabs[0].url = "https://a.com/2";
  t.chrome.tabs.onUpdated.fire(1, {title: "A2"});
  await t.advance(100);
  assert.equal(t.fetches.filter(u => u.includes("_favicon")).length, 1);
});

test("a burst of tab events sends one snapshot", async () => {
  const t = load({windows: [{id: 1, tabs: [tab("https://a.com", "A")]}]});
  await settle();
  t.port().onMessage.fire({type: "ready"});
  await settle();
  const before = t.port().sent.length;
  for (let i = 0; i < 10; i++) t.chrome.tabs.onUpdated.fire(1, {title: "x" + i});
  t.chrome.tabs.onUpdated.fire(1, {audible: true});  // ignored: nothing the Dock shows
  await t.advance(100);
  assert.equal(t.port().sent.length - before, 1);
});

test("focus restores a minimized window, then focuses it, and reports success", async () => {
  const t = load({windows: [{id: 7, type: "normal", state: "minimized", tabs: [tab("https://a.com", "A")]}]});
  await settle();
  t.port().onMessage.fire({type: "focus", windowId: 7, requestId: "r1"});
  await settle();
  assert.deepEqual(plain(t.updates), [[7, {state: "normal"}], [7, {focused: true}]]);
  assert.deepEqual(plain(t.port().sent.find(m => m.type === "result")), {type: "result", requestId: "r1", ok: true});
});

test("focus or close of a missing or incognito window fails cleanly", async () => {
  const t = load({windows: [{id: 8, type: "normal", incognito: true, tabs: []}]});
  await settle();
  t.port().onMessage.fire({type: "focus", windowId: 99, requestId: "a"});
  t.port().onMessage.fire({type: "close", windowId: 8, requestId: "b"});
  t.port().onMessage.fire({type: "focus", windowId: "8", requestId: "c"});  // not a number: ignored
  await settle();
  const results = t.port().sent.filter(m => m.type === "result");
  assert.deepEqual(results.map(r => [r.requestId, r.ok]), [["a", false], ["b", false]]);
  assert.deepEqual(t.removed, []);
});

test("close removes the window", async () => {
  const t = load({windows: [{id: 4, type: "normal", tabs: [tab("https://a.com", "A")]}]});
  await settle();
  t.port().onMessage.fire({type: "close", windowId: 4, requestId: "z"});
  await settle();
  assert.deepEqual(t.removed, [4]);
});

test("reload message reloads the extension", async () => {
  const t = load();
  await settle();
  t.port().onMessage.fire({type: "reload"});
  await settle();
  assert.equal(t.reloads, 1);
});

test("reconnects with growing delays, and resets them once connected", async () => {
  const t = load();
  await settle();
  const delays = [];
  for (let i = 0; i < 7; i++) {
    t.port().onDisconnect.fire();
    const timer = t.timers.find(x => x.ms >= 1500);
    delays.push(timer.ms);
    await t.advance(timer.ms);
  }
  assert.deepEqual(delays, [1500, 3000, 6000, 12000, 24000, 48000, 60000]);
  t.port().onMessage.fire({type: "ready"});
  await settle();
  t.port().onDisconnect.fire();
  assert.equal(t.timers.find(x => x.ms >= 1500).ms, 1500);
});

test("popup status answers with the window count", async () => {
  const t = load({windows: [{id: 1, tabs: []}, {id: 2, incognito: true, tabs: []}]});
  await settle();
  t.port().onMessage.fire({type: "ready"});
  await settle();
  const answer = await new Promise(resolve => {
    const keepOpen = t.chrome.runtime.onMessage.fns[0]({type: "status"}, {}, resolve);
    assert.equal(keepOpen, true);
  });
  assert.equal(answer.status, "Connected");
  assert.equal(answer.windows, 1);
});
