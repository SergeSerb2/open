// The page under the popup: what Bitwarden-style popups ask for first.
chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  const tab = tabs[0];
  document.getElementById("out").textContent =
    tab ? `Current tab ${tab.id}: ${tab.url}` : "No current tab";
  window.currentTab = tab || null;
});
