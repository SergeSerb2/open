# Tabs probe (e2e fixture)

An unpacked MV3 extension for `tools/e2e/engine_e2e.py --only tabstrip`
(fork patch P1, docs/engine-patches.md). Its service worker records
`chrome.tabs` and `chrome.windows` events in `chrome.storage.session` and sets
a badge; its popup shows the current tab. The manifest `key` is a test key
generated for this fixture (id `ajfcefhgbdgihmnmnjpbejdkclfopicb`); it signs
nothing.
