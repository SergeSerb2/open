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

// P3 commands; E12's next child consumes the omnibox events below.
chrome.commands.onCommand.addListener(async (command, tab) => {
  const { commands = [] } = await chrome.storage.session.get("commands");
  await chrome.storage.session.set({ commands: [...commands, command], lastCommandTab: tab?.id });
});
chrome.omnibox.setDefaultSuggestion({ description: "Probe: %s" });
chrome.omnibox.onInputStarted.addListener(() => {
  chrome.storage.session.set({ omniboxStarted: true });
});
const omniboxInputs = [];
chrome.omnibox.onInputChanged.addListener((text, suggest) => {
  omniboxInputs.push(text);
  if (omniboxInputs.length > 32) omniboxInputs.shift();
  chrome.storage.session.set({ omniboxInputs });
  const suggestions = [
    { content: "alpha", description: "<match>alpha</match>" },
    { content: "beta", description: "<match>beta</match>", deletable: true }
  ].filter(row => row.content.startsWith(text));
  // A deliberately late response proves that E12 drops stale suggestions.
  if (text === "a") setTimeout(() => suggest([{content: "a-stale", description: "Late a response"}]), 300);
  else suggest(suggestions);
});
chrome.omnibox.onInputEntered.addListener(async (text, disposition) => {
  const url = "https://example.com/?q=" + encodeURIComponent(text);
  await chrome.storage.session.set({ omniboxEntered: { text, disposition } });
  if (disposition === "currentTab") {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab) await chrome.tabs.update(tab.id, { url });
  } else await chrome.tabs.create({ url, active: disposition !== "newBackgroundTab" });
});
chrome.omnibox.onInputCancelled.addListener(async () => {
  const { onInputCancelled = 0 } = await chrome.storage.session.get("onInputCancelled");
  await chrome.storage.session.set({ onInputCancelled: onInputCancelled + 1 });
});
chrome.omnibox.onDeleteSuggestion.addListener(text => chrome.storage.session.set({ omniboxDeleted: text }));
