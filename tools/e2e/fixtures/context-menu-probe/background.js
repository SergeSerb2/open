chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.op !== 'configure') return;
  (async () => {
    await chrome.contextMenus.removeAll();
    const create = options => new Promise((resolve, reject) => {
      chrome.contextMenus.create(options, () => chrome.runtime.lastError
        ? reject(new Error(chrome.runtime.lastError.message)) : resolve());
    });
    let parent;
    for (let index = 0; index < (message.depth || 0); index++) {
      const id = 'parent-' + index;
      await create({id, title: 'Probe parent ' + index, contexts: ['all'], ...(parent ? {parentId: parent} : {})});
      parent = id;
    }
    for (let index = 0; index < (message.count || 0); index++) {
      await create({id: 'leaf-' + index, title: message.title || ('Probe leaf ' + index),
        contexts: ['all'], ...(parent ? {parentId: parent} : {})});
    }
    return true;
  })().then(value => respond({ok: value}), error => respond({ok: false, error: error.message}));
  return true;
});

// Clicks delivered to the extension (A12: items in Alloy/Peek menus). Kept in
// memory: the rows read them back within seconds of the click.
const clicks = [];
chrome.contextMenus.onClicked.addListener((info, tab) => {
  clicks.push({menuItemId: info.menuItemId, pageUrl: info.pageUrl || null, linkUrl: info.linkUrl || null,
    frameId: info.frameId ?? null, hasTab: !!tab});
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.op !== 'clicks') return;
  respond({ok: true, clicks: clicks.splice(0)});
});
