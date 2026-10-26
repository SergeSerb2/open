# action-probe

Unpacked test extension for `tools/e2e/engine_e2e.py --only actions` (fork
patch P2): a toolbar action with a popup, per-tab state set from the popup,
a popup-less mode (`chrome.action.setPopup({popup: ""})`) whose
`chrome.action.onClicked` clicks it counts, and `chrome.action.openPopup()`
on request. Extension id `jihnllejimhgcmfmcnchbekapeajboik` (from the
manifest `key`). The icons are plain generated squares.
