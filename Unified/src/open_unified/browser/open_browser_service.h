// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/power_monitor/power_observer.h"
#include "base/scoped_multi_source_observation.h"
#include "base/sequence_checker.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/threading/sequence_bound.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "open_unified/buildflags.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/core/routing/routing_evaluator.h"
#include "url/gurl.h"

class Profile;

namespace content {
class BrowserContext;
class WebContents;
}

namespace network {
class SharedURLLoaderFactory;
namespace mojom {
class NetworkContext;
}  // namespace mojom
}  // namespace network

namespace open_unified {

class ArchiveStore;
class BoostStore;
class CommandRegistry;
class DocumentStore;
class DownloadHistoryStore;
class FaviconStore;
class HistoryStore;
class OpenAdBlockProfileService;
class OpenAutomationServer;
class OpenBoostController;
class OpenCaptureController;
class OpenDownloadBridge;
class OpenExtensionBridge;
class OpenHandoffController;
class OpenLittleOpenController;
class OpenLiveDataService;
class OpenMediaBridge;
class OpenSleepController;
class OpenTabBridge;
class OpenTranslateController;
class OpenUpdaterService;
class OpenViewController;
class OpenWindowController;
class SleepStore;
class SnapshotStore;
class SuggestEngine;
class SyncDataAdapter;
class SyncEngine;

// Runs |task| with the store on the store's sequence and |reply| with the
// result on the calling sequence. The stores (SQLite, files) are not
// thread-safe and must not block the UI thread.
template <typename Store, typename Result>
void RunOnStore(const base::SequenceBound<Store>& store,
                base::OnceCallback<Result(Store*)> task,
                base::OnceCallback<void(Result)> reply) {
  store.PostTaskWithThisObject(base::BindOnce(
      [](base::OnceCallback<Result(Store*)> task,
         base::OnceCallback<void(Result)> reply, Store* object) {
        std::move(reply).Run(std::move(task).Run(object));
      },
      std::move(task), base::BindPostTaskToCurrentDefault(std::move(reply))));
}

// Fire-and-forget variant.
template <typename Store>
void RunOnStore(const base::SequenceBound<Store>& store,
                base::OnceCallback<void(Store*)> task) {
  store.PostTaskWithThisObject(std::move(task));
}

// Everything Open keeps per Open Profile. The Chromium Profile lives at
// <user data>/<Profile::data_directory_name>; Open's own files live under
// <user data>/Profiles/<data_directory_name>/{State,Documents} (macOS Open
// layout, docs/plans/profiles.md §5).
struct ProfileServices {
  ProfileServices();
  ~ProfileServices();
  ProfileServices(const ProfileServices&) = delete;
  ProfileServices& operator=(const ProfileServices&) = delete;

  ProfileID id;
  raw_ptr<::Profile> chrome_profile = nullptr;
  base::FilePath state_dir;

  // One sequence for every blocking store of the Profile.
  scoped_refptr<base::SequencedTaskRunner> store_runner;
  base::SequenceBound<HistoryStore> history;
  base::SequenceBound<ArchiveStore> archive;
  base::SequenceBound<SleepStore> sleep;
  base::SequenceBound<DownloadHistoryStore> downloads;
  base::SequenceBound<FaviconStore> favicons;
  base::SequenceBound<BoostStore> boosts;
  base::SequenceBound<DocumentStore> documents;

  // UI thread. Account & Sync is app-wide (OpenBrowserService::sync()):
  // one Open Account syncs every Profile.
  std::unique_ptr<OpenExtensionBridge> extensions;

  // The KeyedService of |chrome_profile| (owned by its factory).
  OpenAdBlockProfileService* adblock() const;
};

// Process-wide coordinator of Open on top of Chromium (Unified/PLAN.md §1).
// Created in PreBrowserStart() by OpenBrowserMainExtraParts (it loads
// State/browser.json while blocking is still allowed), started in
// PostBrowserStart(), destroyed in PostMainMessageLoopRun(); UI thread only.
class OpenBrowserService : public BrowserModel::Observer,
                           public BrowserModel::ArchiveSink,
                           public ProfileObserver,
                           public base::PowerSuspendObserver {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Push events for open:// pages (open_ipc_contract.h kEvent*).
    virtual void OnOpenEvent(const std::string& event_name,
                             const base::Value& payload) {}
  };

  explicit OpenBrowserService(base::FilePath user_data_dir);
  ~OpenBrowserService() override;

  OpenBrowserService(const OpenBrowserService&) = delete;
  OpenBrowserService& operator=(const OpenBrowserService&) = delete;

  // The single instance, or null outside PreBrowserStart..Shutdown.
  static OpenBrowserService* Get();

  // Profiles, windows (adopting Chromium's startup Browser), sleep, Boosts,
  // automation; open://onboarding on a first run.
  void Start();
  // Saves browser.json, stops timers and servers, drops Profile services.
  void Shutdown();

  bool started() const { return started_; }
  bool is_first_run() const { return first_run_; }
  const base::FilePath& user_data_dir() const { return user_data_dir_; }

  BrowserModel& model() { return *model_; }
  const BrowserModel& model() const { return *model_; }
  CommandRegistry& commands() { return *commands_; }
  SuggestEngine& suggest() { return *suggest_; }
  RoutingEvaluator& routing() { return *routing_; }
  OpenTabBridge* tab_bridge() { return tab_bridge_.get(); }
  OpenSleepController* sleep_controller() { return sleep_controller_.get(); }
  OpenBoostController* boost_controller() { return boost_controller_.get(); }
  OpenDownloadBridge* download_bridge() { return download_bridge_.get(); }
  OpenMediaBridge* media_bridge() { return media_bridge_.get(); }
  OpenLiveDataService* livedata() { return livedata_.get(); }
  OpenCaptureController* capture_controller() {
    return capture_controller_.get();
  }
  OpenTranslateController* translate_controller() {
    return translate_controller_.get();
  }
  OpenUpdaterService* updater() { return updater_.get(); }
  OpenHandoffController* handoff() { return handoff_.get(); }
  // Track 4's OpenViewController (hook 0002 passes it to
  // OpenBrowserView::Install) and the per-window Track 5 coordinators.
  OpenViewController* view_controller();
  OpenWindowController* window_controller() { return window_controller_.get(); }
  // Extension bridge of the active Profile.
  OpenExtensionBridge* extension_bridge();
  // The extension bridges of every Profile with services (observers such as
  // OpenWindowController follow all of them, see OnProfileWillBeDestroyed).
  std::vector<OpenExtensionBridge*> AllExtensionBridges();
  // The one app-wide Account & Sync engine (state in <user data>/State/Sync,
  // credentials under a secret-store key unique to that directory). Null
  // before Start() and after Shutdown().
  SyncEngine* sync() { return sync_.get(); }

  // Applies live runtime effects of preferences stored in OpenPreferences
  // (downloads, Auto-PiP, Translate, App Icon, Boosts, Global Hotkeys) and
  // schedules a debounced Sync push when signed in.
  void ApplyPreferencesNow();

  // URLs the OS hands over (hook 0011: command line, a second launch, macOS
  // application:openURLs:). Air Traffic Control places each one; before
  // Start() they wait and are routed once the windows exist.
  void RouteExternalUrls(const std::vector<GURL>& urls);
  void RouteExternalUrls(const std::vector<GURL>& urls,
                         std::optional<std::string> source_app_id);
  void RouteExternalUrl(
      const GURL& url,
      std::optional<std::string> source_app_id,
      std::optional<ProfileID> profile_override = std::nullopt);
  RoutingDecisionLog& routing_log() { return routing_log_; }
  const RoutingDecisionLog& routing_log() const { return routing_log_; }
  const ExternalLinkDeduper& link_deduper() const { return link_deduper_; }

  ProfileServices* ProfileServicesFor(const ProfileID& id);
  ProfileServices* ProfileServicesForBrowserContext(
      content::BrowserContext* context);
  ::Profile* ChromeProfileFor(const ProfileID& id);
  std::optional<ProfileID> OpenProfileIdFor(content::BrowserContext* context);
  ProfileID ActiveProfileId() const;
  WindowID MainWindowId() const;
  WindowID ActiveWindowId() const;
  WindowID ReopenLastClosedWindow();
  bool IsIncognitoWindow(const WindowID& window_id) const;

  // Periodic & wakeup Auto-Archive sweep across all Profiles (Today tabs +
  // Little Open expiry).
  void RunAutoArchiveSweep();

  // Re-registers or unregisters the system-wide Little Open global hotkey
  // from CommandRegistry + links.littleOpenHotkey preference.
  void ReloadGlobalHotkeys();

  // Creates an Open Profile and its Chromium Profile directory; |done| runs
  // when the Chromium Profile is ready.
  void CreateProfile(const std::string& name,
                     std::optional<SpaceIcon> icon,
                     base::OnceCallback<void(ProfileID)> done);

  // Crash-safe Profile teardown & disk deletion: closes windows/tabs for the
  // Profile, removes it from BrowserModel, journals deletion, closes SQLite
  // stores cleanly, schedules Chromium ProfileManager deletion, and deletes
  // Boosts/AdBlock/Documents/State folders on disk.
  bool DeleteProfileData(const ProfileID& profile_id,
                         base::OnceCallback<void(bool)> done = base::NullCallback());

  // Coalesced atomic write of browser.json.
  void ScheduleSave();
  // Writes keybindings.json after a shortcut change (off the UI thread).
  void PersistShortcuts();

  // A committed primary-page navigation (never for incognito). For the
  // active Profile it also refreshes the command bar's history feed.
  void RecordVisit(const ProfileID& profile_id,
                   const std::string& url,
                   const std::string& title,
                   bool typed);
  // Reloads SuggestEngine's history rows (the newest kRecentHistoryLimit
  // entries of the active Profile) from its HistoryStore on the store
  // sequence; after visits, deletions, imports and Profile switches.
  void RefreshRecentHistory();
  static constexpr int kRecentHistoryLimit = 500;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);
  void BroadcastEvent(const std::string& event_name, base::Value payload);

  bool onboarding_completed() const { return onboarding_completed_; }
  void MarkOnboardingCompleted();

  // BrowserModel::Observer:
  void OnTreeChanged(const TreeChange& change) override;

  // BrowserModel::ArchiveSink:
  void OnArchiveTabs(const std::vector<ArchivedTabRecord>& records) override;
  void OnDiscardArchived(const std::vector<ItemID>& ids) override;

  // ProfileObserver: a Chromium Profile going away (Profile deletion, or
  // ProfileManager unloading it) takes its ProfileServices with it, so no
  // raw_ptr<Profile> (ProfileServices::chrome_profile, the extension
  // bridge's) outlives it.
  void OnProfileWillBeDestroyed(::Profile* profile) override;

  // base::PowerSuspendObserver:
  void OnSuspend() override;
  void OnResume() override;

 private:
  class AdBlockObserverBridge;
  class DownloadObserverBridge;
  class TabObserverBridge;

  struct PendingExternalUrl {
    GURL url;
    std::optional<std::string> source_app_id;
  };

  void LoadOrCreateState();
  void ApplySessionRestorePreference();
  void ApplyPreferencesInternal(bool schedule_sync_push);
  void FinishPendingProfileWipes();
  void StartProfiles();
  void StartAutoArchiveSweeper();
  void SweepExpiredLittleOpens(TimestampSec now);
  void OnLittleOpenGlobalHotkey(const std::string& id);
  bool HandleDeepLink(const DeepLinkAction& action);
  bool HandleMailtoUrl(const GURL& url,
                       const std::optional<std::string>& source_app_id);
  void MaybeInstallDefaultGoogleMeetRule(const GURL& url);
  void RouteSingleExternalUrl(
      const GURL& url,
      std::optional<std::string> source_app_id,
      std::optional<ProfileID> profile_override,
      bool after_bootstrap);
  std::unique_ptr<ProfileServices> CreateProfileServices(
      const Profile& profile,
      ::Profile* chrome_profile);
  void MaybeStartAutomationServer();
  void StartSync();
  void ConfigureSyncFromCommandLine();
  void FlushPendingExternalUrls();
  scoped_refptr<network::SharedURLLoaderFactory>
  ResolveActiveURLLoaderFactory();
  network::mojom::NetworkContext* ResolveActiveNetworkContext();
  void RefreshNetworkFactories();
  void SyncLiveDataFromModel();
  void UpdateHandoffForTab(const ItemID& tab_id,
                           content::WebContents* contents);
  void OnTabContentsAttachedBridge(const ItemID& tab_id,
                                   content::WebContents* contents);
  void OnTabContentsDetachingBridge(const ItemID& tab_id,
                                    content::WebContents* contents);
  void OnTabActivatedBridge(const ItemID& tab_id);
  void OnTabPrimaryPageCommittedBridge(const ItemID& tab_id,
                                       content::WebContents* contents);
  base::FilePath ChromeProfileDir(const Profile& profile) const;
  base::FilePath OpenProfileDir(const Profile& profile) const;
  void OnNewChromeProfileReady(ProfileID id,
                               base::OnceCallback<void(ProfileID)> done,
                               ::Profile* chrome_profile);
  void BroadcastStateChanged();
  void OnRecentHistoryLoaded(ProfileID profile_id,
                             uint64_t generation,
                             std::vector<HistoryEntry> entries);

  SEQUENCE_CHECKER(sequence_checker_);

  const base::FilePath user_data_dir_;
  bool started_ = false;
  bool first_run_ = false;
  bool onboarding_completed_ = false;
  bool state_event_pending_ = false;
  // The Profile whose history SuggestEngine holds, and the newest request
  // (older replies are dropped).
  ProfileID recent_history_profile_;
  uint64_t recent_history_generation_ = 0;

  std::unique_ptr<SnapshotStore> snapshot_store_;
  std::unique_ptr<BrowserModel> model_;
  std::unique_ptr<CommandRegistry> commands_;
  std::unique_ptr<SuggestEngine> suggest_;
  std::unique_ptr<RoutingEvaluator> routing_;
  scoped_refptr<base::SequencedTaskRunner> file_runner_;

  std::map<ProfileID, std::unique_ptr<ProfileServices>> profiles_;
  // Set while OnProfileWillBeDestroyed() tears down services: nothing may
  // load that Profile again from inside the notification.
  raw_ptr<::Profile> destroying_profile_ = nullptr;
  base::ScopedMultiSourceObservation<::Profile, ProfileObserver>
      profile_observations_{this};

  std::unique_ptr<AdBlockObserverBridge> adblock_observer_;
  std::unique_ptr<OpenDownloadBridge> download_bridge_;
  std::unique_ptr<DownloadObserverBridge> download_observer_;

  // App-wide Account & Sync. The adapter is declared first so the engine,
  // which holds a raw pointer to it, is destroyed first.
  std::unique_ptr<SyncDataAdapter> sync_adapter_;
  std::unique_ptr<SyncEngine> sync_;

  // External URLs received before Start().
  std::vector<PendingExternalUrl> pending_external_urls_;
  ExternalLinkDeduper link_deduper_;
  RoutingDecisionLog routing_log_;
  bool did_set_default_meet_route_ = false;
  bool power_observer_registered_ = false;
  bool global_hotkey_registered_ = false;

  // Periodic auto-archive sweeper (60s + startup + resume) and Little Open
  // activity tracker.
  base::RepeatingTimer auto_archive_timer_;
  std::map<raw_ptr<OpenLittleOpenController>, TimestampSec>
      little_open_last_active_;

  std::unique_ptr<OpenMediaBridge> media_bridge_;
  scoped_refptr<network::SharedURLLoaderFactory> livedata_url_loader_factory_;
  std::unique_ptr<OpenLiveDataService> livedata_;
  std::map<ItemID, LiveFolderConfig> registered_live_folders_;
  std::map<ItemID, std::string> registered_calendar_favorites_;
  std::unique_ptr<OpenCaptureController> capture_controller_;
  std::unique_ptr<OpenTranslateController> translate_controller_;
  std::unique_ptr<OpenUpdaterService> updater_;
  std::unique_ptr<OpenHandoffController> handoff_;
  std::map<WindowID, ItemID> active_tab_by_window_;
  ItemID last_active_tab_id_;
  ItemID last_handoff_tab_id_;

  std::unique_ptr<OpenTabBridge> tab_bridge_;
  std::unique_ptr<TabObserverBridge> tab_observer_;
  std::unique_ptr<OpenSleepController> sleep_controller_;
  std::unique_ptr<OpenBoostController> boost_controller_;
  std::unique_ptr<OpenWindowController> window_controller_;
#if BUILDFLAG(OPEN_ENABLE_AUTOMATION)
  std::unique_ptr<OpenAutomationServer> automation_server_;
#endif

  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenBrowserService> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_BROWSER_SERVICE_H_
