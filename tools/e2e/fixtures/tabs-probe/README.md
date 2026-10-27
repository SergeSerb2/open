# Tabs probe (e2e fixture)

An unpacked MV3 extension for `tools/e2e/engine_e2e.py --only tabstrip`
(fork patch P1, docs/engine-patches.md). Its service worker records
`chrome.tabs` and `chrome.windows` events in `chrome.storage.session` and sets
a badge; its popup shows the current tab. It adds one page context-menu item
("Tabs probe item"), which Open's context-menu allowlist must keep. The manifest `key` is a test key
generated for this fixture (id `ajfcefhgbdgihmnmnjpbejdkclfopicb`); it signs
nothing.
