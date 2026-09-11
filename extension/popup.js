chrome.runtime.sendMessage({type: "status"}).then(result => {
  document.getElementById("status").textContent = `${result.label}: ${result.status}`;
});
