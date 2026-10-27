// Counts chrome.action.onClicked (popup-less clicks) and opens the popup on
// request (chrome.action.openPopup), for tools/e2e/engine_e2e.py --only actions.
chrome.action.onClicked.addListener(async (tab) => {
  const { clicks = 0 } = await chrome.storage.session.get("clicks");
  await chrome.storage.session.set({ clicks: clicks + 1, lastClickTab: tab.id });
});

function openPopup() {
  chrome.action.openPopup().then(
    () => chrome.storage.session.set({ openPopup: "ok" }),
    (e) => chrome.storage.session.set({ openPopup: String(e && e.message || e) }));
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message === "open-popup") {
    // After the popup that asked has closed.
    setTimeout(openPopup, 300);
    reply(true);
  } else if (message === "open-popup-now") {
    // While the popup that asked is still open: Chrome refuses.
    openPopup();
    reply(true);
  }
});
