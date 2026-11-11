let port;
let config;
let retry;
// Doubles after each failed connection (a broken install would otherwise
// start the helper every 1.5 seconds forever); reset once connected.
const FIRST_RETRY = 1500, LAST_RETRY = 60000;
let retryDelay = FIRST_RETRY;
let revision = 0;
let lastStatus = "Connecting…";
// Favicons as data URLs, keyed by page origin + favicon URL, so each one is
// read from Chrome's own favicon cache once rather than on every snapshot.
const icons = new Map();

function hostOf(url) {
  try {
    const parsed = new URL(url);
    return /^https?:$/.test(parsed.protocol) ? parsed.hostname : undefined;
  } catch { return undefined; }
}

async function favicon(tab) {
  if (!tab?.url || !hostOf(tab.url)) return undefined;
  const key = new URL(tab.url).origin + "|" + (tab.favIconUrl || "");
  if (icons.has(key)) return icons.get(key);
  let data;
  try {
    const url = chrome.runtime.getURL(`/_favicon/?pageUrl=${encodeURIComponent(tab.url)}&size=32`);
    const response = await fetch(url);
    if (response.ok) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      let text = "";
      for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      const type = (response.headers.get("content-type") || "image/png").split(";")[0];
      if (bytes.length && bytes.length < 40000) data = `data:${type};base64,${btoa(text)}`;
    }
  } catch { /* no favicon: the Dock list shows a generic icon */ }
  if (icons.size > 300) icons.clear();
  icons.set(key, data);
  return data;
}

async function snapshot() {
  const current = ++revision;
  const all = await chrome.windows.getAll({populate: true, windowTypes: ["normal"]});
  const windows = await Promise.all(all.filter(w => !w.incognito).map(async w => {
    const active = (w.tabs || []).find(t => t.active);
    return {id: w.id, title: active?.title || "New Tab", tabCount: (w.tabs || []).length,
      focused: w.focused, state: w.state, host: hostOf(active?.url), icon: await favicon(active)};
  }));
  if (current !== revision || !port || !config) return;
  port.postMessage({type: "snapshot", profile: config.profileKey, windows});
}

// Events arrive in bursts at startup; without this, each could open its own
// connection (and start its own helper) before the first one exists.
let connecting;
function connect() {
  connecting ||= open().finally(() => { connecting = undefined; });
  return connecting;
}

async function open() {
  if (port) return;
  config ||= await (await fetch(chrome.runtime.getURL("config.json"))).json();
  const connection = chrome.runtime.connectNative("local.profiledock.bridge");
  port = connection;
  connection.onDisconnect.addListener(() => {
    lastStatus = chrome.runtime.lastError?.message || "Disconnected";
    if (port === connection) port = null;
    clearTimeout(retry);
    retry = setTimeout(() => connect().catch(() => {}), retryDelay);
    retryDelay = Math.min(retryDelay * 2, LAST_RETRY);
  });
  connection.onMessage.addListener(async message => {
    if (message.type === "ready") { lastStatus = "Connected"; retryDelay = FIRST_RETRY; await snapshot(); }
    // setup.py copied newer extension files; pick them up.
    if (message.type === "reload") { chrome.runtime.reload(); return; }
    if ((message.type === "focus" || message.type === "close") && Number.isInteger(message.windowId)) {
      try {
        const w = await chrome.windows.get(message.windowId);
        if (w.incognito || w.type !== "normal") throw new Error("Unsupported window");
        if (message.type === "close") {
          await chrome.windows.remove(w.id);
        } else {
          if (w.state === "minimized") await chrome.windows.update(w.id, {state: "normal"});
          await chrome.windows.update(w.id, {focused: true});
        }
        connection.postMessage({type: "result", requestId: message.requestId, ok: true});
      } catch (error) {
        connection.postMessage({type: "result", requestId: message.requestId, ok: false, error: String(error)});
      }
      await snapshot();
    }
  });
  connection.postMessage({type: "hello", profile: config.profileKey,
    version: chrome.runtime.getManifest().version, features: ["close", "favicon", "reload"]});
}

// Events come in bursts (a resize, a page load); one snapshot per burst.
let pending;
function refresh() {
  if (!port) { connect().catch(() => {}); return; }
  clearTimeout(pending);
  pending = setTimeout(() => snapshot().catch(() => {}), 40);
}
chrome.windows.onCreated.addListener(refresh);
chrome.windows.onRemoved.addListener(refresh);
chrome.windows.onFocusChanged.addListener(refresh);
// Minimize and restore change a window's bounds.
chrome.windows.onBoundsChanged?.addListener(refresh);
chrome.tabs.onCreated.addListener(refresh);
chrome.tabs.onRemoved.addListener(refresh);
chrome.tabs.onActivated.addListener(refresh);
chrome.tabs.onAttached.addListener(refresh);
chrome.tabs.onDetached.addListener(refresh);
chrome.tabs.onUpdated.addListener((_id, change) => {
  if (change.title || change.favIconUrl || change.status === "complete") refresh();
});
chrome.runtime.onStartup.addListener(refresh);
chrome.runtime.onInstalled.addListener(refresh);
chrome.alarms.create("reconnect", {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(refresh);
chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.type !== "status") return;
  chrome.windows.getAll({windowTypes: ["normal"]}).then(all => {
    respond({status: lastStatus, label: config?.label || "ProfileDock",
      windows: all.filter(w => !w.incognito).length, version: chrome.runtime.getManifest().version});
  }, () => respond({status: lastStatus, label: config?.label || "ProfileDock"}));
  return true;  // answered asynchronously
});
refresh();
