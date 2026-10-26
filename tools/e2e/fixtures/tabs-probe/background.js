// Records tab and window events in chrome.storage.session so the e2e
// harness can read them from the popup page. Sets a badge for the toolbar.
let events = [];
const loaded = chrome.storage.session.get({ events: [] }).then((stored) => {
  events = stored.events.concat(events);
});

function record(type, data) {
  events.push({ type, time: Date.now(), ...data });
  loaded.then(() => chrome.storage.session.set({ events }));
}

chrome.tabs.onActivated.addListener((info) =>
  record("activated", { tabId: info.tabId, windowId: info.windowId }));
chrome.tabs.onCreated.addListener((tab) =>
  record("created", { tabId: tab.id, windowId: tab.windowId,
                      url: tab.pendingUrl || tab.url, active: tab.active }));
chrome.tabs.onRemoved.addListener((tabId, info) =>
  record("removed", { tabId, windowId: info.windowId }));
chrome.tabs.onMoved.addListener((tabId, info) =>
  record("moved", { tabId, windowId: info.windowId,
                    fromIndex: info.fromIndex, toIndex: info.toIndex }));
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.status === "complete") record("updated", { tabId, url: tab.url });
  if (change.pinned !== undefined) record("pinned", { tabId, pinned: change.pinned });
});
chrome.windows.onFocusChanged.addListener((windowId) => record("focus", { windowId }));

chrome.action.setBadgeText({ text: "P1" });
chrome.action.setBadgeBackgroundColor({ color: "#3366ff" });

// Calls that switch tabs run here, not in the popup: a tab switch closes the
// action popup (as in Chrome), which would end a popup-side call before its
// result arrives. The result goes to chrome.storage.session.lastOp.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  const done = (result) => chrome.storage.session.set({ lastOp: { seq: message.seq, ...result } });
  if (message && message.op === "create") {
    chrome.tabs.create(message.props).then(
      (t) => done({ id: t.id, windowId: t.windowId }), (e) => done({ error: String(e.message || e) }));
    reply(true);
  } else if (message && message.op === "activate") {
    chrome.tabs.update(message.tabId, { active: true }).then(
      (t) => done({ id: t.id }), (e) => done({ error: String(e.message || e) }));
    reply(true);
  }
});
