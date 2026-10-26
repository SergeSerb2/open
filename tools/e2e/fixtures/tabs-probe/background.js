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

// One page context-menu item: Open's context-menu allowlist keeps
// extension items (engine_e2e.py context_menu_allowlist).
chrome.runtime.onInstalled.addListener(() =>
  chrome.contextMenus.create({ id: "probe", title: "Tabs probe item", contexts: ["all"] }));
chrome.contextMenus.onClicked.addListener((info) => record("menu", { id: info.menuItemId }));
