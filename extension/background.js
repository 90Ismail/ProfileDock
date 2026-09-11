let port;
let config;
let retry;
let revision = 0;
let lastStatus = "Connecting…";
async function snapshot() {
  const current = ++revision;
  const windows = await chrome.windows.getAll({populate: true, windowTypes: ["normal"]});
  if (current !== revision || !port || !config) return;
  console.log("[ProfileDock] sending snapshot,", windows.length, "windows");
  port.postMessage({type: "snapshot", profile: config.profileKey, windows: windows
    .filter(w => !w.incognito)
    .map(w => ({id: w.id, title: (w.tabs || []).find(t => t.active)?.title || "Chrome window",
      tabCount: (w.tabs || []).length, focused: w.focused, state: w.state}))});
}
async function connect() {
  if (port) return;
  config ||= await (await fetch(chrome.runtime.getURL("config.json"))).json();
  console.log("[ProfileDock] connecting native host for profile", config.profileKey);
  const connection = chrome.runtime.connectNative("local.profiledock.bridge");
  port = connection;
  connection.onDisconnect.addListener(() => {
    lastStatus = chrome.runtime.lastError?.message || "Disconnected";
    console.warn("[ProfileDock] native host disconnected:", lastStatus, "lastError:", chrome.runtime.lastError);
    if (port === connection) port = null;
    clearTimeout(retry);
    retry = setTimeout(connect, 1500);
  });
  connection.onMessage.addListener(async message => {
    console.log("[ProfileDock] message from host:", message);
    if (message.type === "ready") { lastStatus = "Connected"; await snapshot(); }
    if (message.type === "focus" && Number.isInteger(message.windowId)) {
      try {
        const w = await chrome.windows.get(message.windowId);
        if (w.incognito || w.type !== "normal") throw new Error("Unsupported window");
        if (w.state === "minimized") await chrome.windows.update(w.id, {state: "normal"});
        await chrome.windows.update(w.id, {focused: true});
        connection.postMessage({type: "result", requestId: message.requestId, ok: true});
      } catch (error) {
        connection.postMessage({type: "result", requestId: message.requestId, ok: false, error: String(error)});
      }
      await snapshot();
    }
  });
  connection.postMessage({type: "hello", profile: config.profileKey});
}
function refresh() { if (port) snapshot().catch(() => {}); else connect().catch(() => {}); }
chrome.windows.onCreated.addListener(refresh);
chrome.windows.onRemoved.addListener(refresh);
chrome.windows.onFocusChanged.addListener(refresh);
chrome.tabs.onCreated.addListener(refresh);
chrome.tabs.onRemoved.addListener(refresh);
chrome.tabs.onActivated.addListener(refresh);
chrome.tabs.onAttached.addListener(refresh);
chrome.tabs.onDetached.addListener(refresh);
chrome.tabs.onUpdated.addListener((_id, change) => { if (change.title || change.status === "complete") refresh(); });
chrome.runtime.onStartup.addListener(refresh);
chrome.runtime.onInstalled.addListener(refresh);
chrome.alarms.create("reconnect", {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(refresh);
chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.type === "status") { respond({status: lastStatus, label: config?.label || "ProfileDock"}); }
});
refresh();
