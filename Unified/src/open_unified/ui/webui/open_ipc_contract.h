// Copyright 2026 The Open Authors. All rights reserved.
// Canonical WebUI host names and JSON RPC method names shared between
// C++ Chromium WebUI handlers (Unified/src/open_unified/ui/webui/) and
// Preact + TypeScript frontend (Unified/webui/src/shared/bridge.ts).

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_IPC_CONTRACT_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_IPC_CONTRACT_H_

namespace open_unified::webui {

inline constexpr char kOpenScheme[] = "open";

// Registered open:// hosts
inline constexpr char kHostSettings[] = "settings";
inline constexpr char kHostLibrary[] = "library";
inline constexpr char kHostBoosts[] = "boosts";
inline constexpr char kHostEasel[] = "easel";
inline constexpr char kHostNote[] = "note";
inline constexpr char kHostOnboarding[] = "onboarding";
inline constexpr char kHostWelcome[] = "welcome";

// Single typed RPC channel via chrome.send("open.rpc", [requestId, method, payload])
// Response resolved via window.__openRpcResolve(requestId, ok, resultOrError)
// Push events delivered via window.__openRpcEvent(eventName, payload)
inline constexpr char kRpcMessageName[] = "open.rpc";

// --- Settings methods ---
inline constexpr char kSettingsGetAll[] = "settings.getAll";
inline constexpr char kSettingsSetPreference[] = "settings.setPreference";
inline constexpr char kSettingsResetPreference[] = "settings.resetPreference";
inline constexpr char kSettingsListProfiles[] = "settings.listProfiles";
inline constexpr char kSettingsCreateProfile[] = "settings.createProfile";
inline constexpr char kSettingsRenameProfile[] = "settings.renameProfile";
inline constexpr char kSettingsDeleteProfile[] = "settings.deleteProfile";
inline constexpr char kSettingsGetShortcuts[] = "settings.getShortcuts";
inline constexpr char kSettingsSetShortcut[] = "settings.setShortcut";
inline constexpr char kSettingsResetShortcut[] = "settings.resetShortcut";
inline constexpr char kSettingsGetRoutingRules[] = "settings.getRoutingRules";
inline constexpr char kSettingsSaveRoutingRule[] = "settings.saveRoutingRule";
inline constexpr char kSettingsDeleteRoutingRule[] = "settings.deleteRoutingRule";
inline constexpr char kSettingsTestRoutingUrl[] = "settings.testRoutingUrl";
inline constexpr char kSettingsGetAdBlockState[] = "settings.getAdBlockState";
inline constexpr char kSettingsSetAdBlockEnabled[] = "settings.setAdBlockEnabled";
inline constexpr char kSettingsToggleAdBlockList[] = "settings.toggleAdBlockList";
inline constexpr char kSettingsAddAdBlockExclusion[] = "settings.addAdBlockExclusion";
inline constexpr char kSettingsRemoveAdBlockExclusion[] = "settings.removeAdBlockExclusion";
inline constexpr char kSettingsClearBrowsingData[] = "settings.clearBrowsingData";
inline constexpr char kSettingsSetDefaultBrowser[] = "settings.setDefaultBrowser";
inline constexpr char kSettingsGetExtensions[] = "settings.getExtensions";
inline constexpr char kSettingsToggleExtension[] = "settings.toggleExtension";

// --- Account & Sync methods ---
inline constexpr char kSyncGetStatus[] = "sync.getStatus";
inline constexpr char kSyncConfigureServer[] = "sync.configureServer";
inline constexpr char kSyncRegister[] = "sync.register";
inline constexpr char kSyncLogin[] = "sync.login";
inline constexpr char kSyncLogout[] = "sync.logout";
inline constexpr char kSyncTriggerNow[] = "sync.triggerNow";
inline constexpr char kSyncRecover[] = "sync.recover";
inline constexpr char kSyncListDevices[] = "sync.listDevices";
inline constexpr char kSyncRevokeDevice[] = "sync.revokeDevice";

// --- Library methods ---
inline constexpr char kLibraryGetHistory[] = "library.getHistory";
inline constexpr char kLibraryDeleteHistory[] = "library.deleteHistory";
inline constexpr char kLibraryGetArchive[] = "library.getArchive";
inline constexpr char kLibraryRestoreArchived[] = "library.restoreArchived";
inline constexpr char kLibraryGetDownloads[] = "library.getDownloads";
inline constexpr char kLibraryOpenDownload[] = "library.openDownload";
inline constexpr char kLibraryGetSpaces[] = "library.getSpaces";
inline constexpr char kLibraryUpdateSpace[] = "library.updateSpace";
inline constexpr char kLibraryDeleteSpace[] = "library.deleteSpace";
inline constexpr char kLibraryGetMedia[] = "library.getMedia";
inline constexpr char kLibraryGetEasels[] = "library.getEasels";
inline constexpr char kLibraryOpenUrl[] = "library.openUrl";

// --- Boosts & Zap methods ---
inline constexpr char kBoostsList[] = "boosts.list";
inline constexpr char kBoostsSave[] = "boosts.save";
inline constexpr char kBoostsDelete[] = "boosts.delete";
inline constexpr char kBoostsToggle[] = "boosts.toggle";
inline constexpr char kBoostsStartZap[] = "boosts.startZap";
inline constexpr char kBoostsRemoveZap[] = "boosts.removeZap";

// --- Documents (Easel & Note) methods ---
inline constexpr char kEaselLoad[] = "easel.load";
inline constexpr char kEaselSave[] = "easel.save";
inline constexpr char kEaselExportHtml[] = "easel.exportHtml";
inline constexpr char kNoteLoad[] = "note.load";
inline constexpr char kNoteSave[] = "note.save";

// --- Onboarding, Welcome & Import methods ---
inline constexpr char kOnboardingGetState[] = "onboarding.getState";
inline constexpr char kOnboardingComplete[] = "onboarding.complete";
inline constexpr char kImportProbeBrowsers[] = "import.probeBrowsers";
inline constexpr char kImportRun[] = "import.run";
inline constexpr char kWelcomeTriggerAction[] = "welcome.triggerAction";

// --- Push Events (C++ -> WebUI) ---
inline constexpr char kEventStateChanged[] = "open.stateChanged";
inline constexpr char kEventSyncStatusChanged[] = "open.syncStatusChanged";
inline constexpr char kEventDownloadUpdated[] = "open.downloadUpdated";
inline constexpr char kEventAdBlockUpdated[] = "open.adBlockUpdated";
inline constexpr char kEventImportProgress[] = "open.importProgress";

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_IPC_CONTRACT_H_
