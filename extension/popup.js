chrome.runtime.sendMessage({type: "status"}).then(result => {
  document.getElementById("title").textContent = `ProfileDock · ${result.label}`;
  const connected = result.status === "Connected";
  document.getElementById("dot").classList.toggle("ok", connected);
  let text = connected ? "Connected to the Dock" : result.status;
  if (connected && Number.isInteger(result.windows)) text += ` · ${result.windows} window${result.windows === 1 ? "" : "s"}`;
  document.getElementById("status").textContent = text;
}, () => { document.getElementById("status").textContent = "Starting…"; });
