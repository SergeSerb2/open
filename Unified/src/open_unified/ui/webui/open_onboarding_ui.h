// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/values.h"
#include "open_unified/core/import/browser_importer.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified {
class OpenWindowUi;
}  // namespace open_unified

namespace open_unified::webui {

// RPC names this domain adds beyond open_ipc_contract.h (the contract file
// is owned by another track; these strings are the canonical names and
// mirror Unified/webui/src/onboarding/rpc.ts). In their own namespace so a
// later copy in the contract cannot collide.
namespace onboarding_rpc {
inline constexpr char kPrefetchFavicons[] = "onboarding.prefetchFavicons";
inline constexpr char kWelcomeGetState[] = "welcome.getState";
inline constexpr char kWelcomeMarkStepDone[] = "welcome.markStepDone";
// Push event sent to every open:// page and OpenBrowserService observers
// once onboarding has handed off (payload: {handoff, welcome_tab_id,
// onboarding_tab_id, replay}). OpenWindowController can follow it to close
// a dedicated First Run window.
inline constexpr char kEventOnboardingCompleted[] = "open.onboardingCompleted";
}  // namespace onboarding_rpc

// onboarding.*, import.* and welcome.* methods of open://onboarding and
// open://welcome (Open's own first-run identity, the doorway-and-sun mark).
//
// Import is deferred: the wizard probes sources (import.probeBrowsers) and
// keeps the user's choice in the page; onboarding.complete runs it once,
// right before the hand-off. Every import is idempotent: sidebar items use
// BrowserImporter's deterministic ids (a replay finds them and adds
// nothing), and a per-source ledger (State/import-ledger.json) skips
// History, Boosts, Easels/Notes and Archive kinds that already ran.
class OpenOnboardingUI : public OpenRpcDomain {
 public:
  explicit OpenOnboardingUI(OpenWebUIMessageHandler* handler);
  ~OpenOnboardingUI() override;

  void RegisterMethods() override;

  // What one import run brought in (also the import.run reply).
  struct ImportCounts {
    int bookmarks = 0;
    int history = 0;
    int favorites = 0;
    int spaces = 0;
    int tabs = 0;
    int boosts = 0;
    int documents = 0;
    int archive = 0;
    int skipped_already_imported = 0;
    std::string error;
    base::DictValue ToValue() const;
  };

  // Data read off the UI thread for one source (BrowserImporter readers).
  struct ImportData {
    ImportData();
    ImportData(ImportData&&) noexcept;
    ImportData& operator=(ImportData&&) noexcept;
    ~ImportData();

    std::string source_id;
    std::string browser_name;
    BrowserFamily family = BrowserFamily::kChromium;
    std::vector<std::string> kinds;
    // Kinds the ledger says already ran for this source.
    std::vector<std::string> already_done;
    std::vector<ImportedBookmarkNode> bookmark_roots;
    std::vector<HistoryEntry> history;
    std::optional<ArcSidebarImportResult> arc;
    std::optional<OpenLegacyImportResult> legacy;
    std::string error;
  };

 private:
  using ImportDone = base::OnceCallback<void(ImportCounts)>;

  // --- onboarding.* / import.* ---
  void GetState(const base::DictValue& payload, Reply reply);
  void Complete(const base::DictValue& payload, Reply reply);
  void ProbeBrowsers(const base::DictValue& payload, Reply reply);
  void RunImport(const base::DictValue& payload, Reply reply);
  void PrefetchFavicons(const base::DictValue& payload, Reply reply);

  // --- welcome.* ---
  void WelcomeGetState(const base::DictValue& payload, Reply reply);
  void TriggerWelcomeAction(const base::DictValue& payload, Reply reply);
  void MarkStepDone(const base::DictValue& payload, Reply reply);

  // Reads |source_id| ("<browser id>/<profile id>") off the UI thread and
  // applies it on the UI thread; |done| always runs (error in counts).
  void StartImport(std::string source_id,
                   std::vector<std::string> kinds,
                   ProfileID profile,
                   ImportDone done);
  static ImportData ReadImportData(std::string source_id,
                                   std::vector<std::string> kinds,
                                   base::FilePath ledger_path);
  void ApplyImport(ProfileID profile, ImportDone done, ImportData data);

  // onboarding.complete, after the (optional) deferred import.
  void FinishComplete(base::DictValue payload,
                      ProfileID profile,
                      Reply reply,
                      ImportCounts counts);
  // Welcome tab at Today index 0 of the onboarding tab's Space (or the
  // focused Space): selects an existing one, or turns the onboarding tab
  // itself into it (no duplicate tab, no archived onboarding tab). Returns
  // the hand-off mode for the reply.
  std::string HandOff(const ProfileID& profile,
                      bool replay,
                      std::string* welcome_tab_id);

  // Favicon prefetch, per URL: Open's FaviconStore, then Chromium's favicon
  // database (LargeIconService), then, for curated hosts only, Google's
  // favicon server (the page URL is trimmed to its origin; user-typed URLs
  // never leave the machine).
  struct FaviconJob;
  void PrefetchOne(std::shared_ptr<FaviconJob> job, size_t index);
  void OnStoreIcon(std::shared_ptr<FaviconJob> job,
                   size_t index,
                   std::optional<std::string> data_url);
  void QueryLargeIcon(std::shared_ptr<FaviconJob> job,
                      size_t index,
                      bool after_server);
  static void FinishFavicon(std::shared_ptr<FaviconJob> job,
                            size_t index,
                            base::DictValue result);

  // The window coordinator of this page's tab (falls back to the main one).
  OpenWindowUi* PageWindowUi();
  std::optional<ItemID> PageTabId();

  base::CancelableTaskTracker favicon_tracker_;
  base::WeakPtrFactory<OpenOnboardingUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_
