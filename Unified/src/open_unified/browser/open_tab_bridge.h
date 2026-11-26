// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_TAB_BRIDGE_H_
#define OPEN_UNIFIED_BROWSER_OPEN_TAB_BRIDGE_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/scoped_multi_source_observation.h"
#include "base/scoped_observation.h"
#include "chrome/browser/ui/browser_window/public/browser_collection.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/open_types.h"
#include "url/gurl.h"

class BrowserWindowInterface;
class TabStripModel;

namespace content {
class WebContents;
}

namespace open_unified {

class OpenBrowserService;
class OpenTabObserver;

// Attached to every WebContents that backs an Open sidebar tab (or a split
// pane). Survives TabStripModel moves; moved to the new WebContents when
// Chromium replaces one (discard, prerender activation).
class OpenTabHandle : public content::WebContentsUserData<OpenTabHandle> {
 public:
  ~OpenTabHandle() override;
  OpenTabHandle(const OpenTabHandle&) = delete;
  OpenTabHandle& operator=(const OpenTabHandle&) = delete;

  const ItemID& tab_id() const { return tab_id_; }

 private:
  friend class content::WebContentsUserData<OpenTabHandle>;
  friend class OpenTabBridge;
  OpenTabHandle(content::WebContents* contents, ItemID tab_id);

  ItemID tab_id_;
  // Propagates title/URL/favicon/audio/loading/crash/background color.
  std::unique_ptr<OpenTabObserver> observer_;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

// Two-way bridge between Chromium's real TabStripModel and Open's
// BrowserModel (Favorites, Pinned, Folders, Today, Split).
//
// Shape:
// - One Chromium Browser per (Open window, Open Profile): a Browser is bound
//   to one Chromium Profile. The Browser of the focused Space's Profile is
//   the visible one; switching to a Space of another Profile shows that
//   Profile's Browser at the same frame.
// - A Browser's TabStripModel holds only *loaded* tabs (those with a
//   WebContents), ordered Space by Space, then in sidebar order
//   (BrowserModel::OrderedTabIds). chrome.tabs therefore sees every loaded
//   sidebar tab of that Profile with stable ids and a sensible index order.
// - Unloaded tabs (placeholders, slept tabs after a relaunch) have no
//   WebContents. Selecting one creates it lazily, restores its OPNH history
//   when the sleep store has one, and inserts it at its ordered index.
//
// Model -> Chromium: OnTreeChanged() coalesces inserts/removes/moves and
// selection. Chromium -> model: OnTabStripModelChanged() adopts tabs that
// Chromium or extensions created (window.open, chrome.tabs.create,
// middle-click), removes tabs Chromium closed (window.close(),
// chrome.tabs.remove), follows replacements and activations.
class OpenTabBridge : public BrowserModel::Observer,
                      public TabStripModelObserver,
                      public BrowserCollectionObserver {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // A WebContents now backs |tab_id| (created, adopted, or replaced).
    virtual void OnTabContentsAttached(const ItemID& tab_id,
                                       content::WebContents* contents) {}
    virtual void OnTabContentsDetaching(const ItemID& tab_id,
                                        content::WebContents* contents) {}
    // A new primary-page document committed in |tab_id|.
    virtual void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                           content::WebContents* contents) {}
    // The document element exists (Boost injection point).
    virtual void OnTabDocumentAvailable(const ItemID& tab_id,
                                        content::WebContents* contents) {}
    virtual void OnTabActivated(const ItemID& tab_id) {}
  };

  explicit OpenTabBridge(OpenBrowserService* service);
  ~OpenTabBridge() override;

  OpenTabBridge(const OpenTabBridge&) = delete;
  OpenTabBridge& operator=(const OpenTabBridge&) = delete;

  void Start();
  void Shutdown();

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // --- Commands (sidebar, command bar, automation, WebUI) ---

  // New Today tab at the top of the focused Space (Arc placement).
  ItemID OpenTab(const GURL& url, bool background);
  // Selects a sidebar node (tab, split, or folder's peeked child) in the
  // main window; loads it when needed.
  bool SelectNode(const ItemID& node_id);
  bool SelectIndex(size_t index);  // focused Space's OrderedTabIds()
  // Cmd-W semantics: Today tabs archive; pinned/favorites unload and reset.
  bool CloseNode(const ItemID& node_id);
  bool TogglePin(const ItemID& tab_id);
  // Split View with the next tab of the Space (or unsplit when |tab_id| is
  // in a split already).
  std::optional<ItemID> ToggleSplit(const ItemID& tab_id);
  bool Navigate(const ItemID& tab_id, const GURL& url);
  bool GoBack(const ItemID& tab_id);
  bool FocusSpace(const SpaceID& space_id);

  // Loads |tab_id| (creates its WebContents) without selecting it.
  content::WebContents* EnsureLoaded(const ItemID& tab_id);
  // Drops the WebContents of |tab_id| (the tab stays in the sidebar as a
  // placeholder). Used by sleep (after capture) and pinned-tab close.
  void UnloadTab(const ItemID& tab_id);

  // --- Lookups ---
  content::WebContents* WebContentsForTab(const ItemID& tab_id) const;
  static std::optional<ItemID> TabIdForWebContents(
      content::WebContents* contents);
  content::WebContents* ActiveWebContents() const;
  std::optional<ItemID> ActiveTabId() const;
  // The visible Browser of the main window (null before Start()).
  BrowserWindowInterface* MainBrowser() const;
  BrowserWindowInterface* BrowserForTab(const ItemID& tab_id) const;
  // The Open window a Chromium Browser shows (null for Browsers Open does
  // not manage: popups, DevTools, app windows).
  std::optional<WindowID> WindowIdForBrowser(
      BrowserWindowInterface* browser) const {
    return WindowOfBrowser(browser);
  }
  std::vector<std::pair<ItemID, content::WebContents*>> LoadedTabs() const;

  // Called by OpenTabObserver.
  void OnTabTitleOrUrlChanged(const ItemID& tab_id,
                              content::WebContents* contents);
  void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                 content::WebContents* contents,
                                 bool typed);
  void OnTabDocumentAvailable(const ItemID& tab_id,
                              content::WebContents* contents);

  // BrowserModel::Observer:
  void OnTreeChanged(const TreeChange& change) override;

  // TabStripModelObserver:
  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override;
  void OnTabStripModelDestroyed(TabStripModel* tab_strip_model) override;

  // BrowserCollectionObserver:
  void OnBrowserCreated(BrowserWindowInterface* browser) override;
  void OnBrowserClosed(BrowserWindowInterface* browser) override;

 private:
  struct WindowBrowsers {
    WindowBrowsers();
    ~WindowBrowsers();
    WindowBrowsers(WindowBrowsers&&);
    WindowBrowsers& operator=(WindowBrowsers&&);
    // Open Profile id -> Chromium Browser of this window.
    std::map<ProfileID, raw_ptr<BrowserWindowInterface>> by_profile;
  };
  // Every normal Chromium window Open manages: the primary Browser of each
  // (window, Profile) above, and further windows of a Profile that Chromium
  // or an extension opened (chrome.windows.create, a dragged-out page).
  // Their pages are sidebar tabs of |window|.
  struct ManagedBrowser {
    WindowID window;
    ProfileID profile;
    bool primary = false;
  };

  BrowserWindowInterface* EnsureBrowser(const WindowID& window_id,
                         const ProfileID& profile_id);
  void AdoptStartupBrowsers();
  void ShowBrowserForSpace(const WindowID& window_id, const SpaceID& space_id);
  void ApplySelectionFromModel(const WindowID& window_id);
  // Coalesces structural model changes into one resync per task.
  void ScheduleResync();
  void RunScheduledResync();
  void ResyncAll();
  void ResyncBrowser(BrowserWindowInterface* browser);
  // ResyncBrowser() on a later task, if |browser| is still managed then
  // (looked up again: never a dangling pointer).
  void ResyncBrowserLater(BrowserWindowInterface* browser);
  void TrackBrowser(BrowserWindowInterface* browser,
                    const WindowID& window_id,
                    const ProfileID& profile_id,
                    bool primary);
  // Tracking only (map, observers); no model change. Runs for every
  // removal, including the bridge's own (|applying_|).
  void ForgetContents(const ItemID& tab_id, content::WebContents* contents);
  // Ordered tab ids of every Space of |profile_id| (Spaces in model order).
  std::vector<ItemID> StripOrderFor(const ProfileID& profile_id) const;
  int TargetStripIndex(BrowserWindowInterface* browser,
                       const ItemID& tab_id) const;
  void AttachHandle(content::WebContents* contents, const ItemID& tab_id);
  void InsertIntoStrip(BrowserWindowInterface* browser,
                       std::unique_ptr<content::WebContents> contents,
                       const ItemID& tab_id,
                       bool activate);
  std::unique_ptr<content::WebContents> CreateContentsFor(
      const Tab& tab,
      BrowserWindowInterface* browser);
  void AdoptChromiumTab(BrowserWindowInterface* browser,
                        content::WebContents* contents,
                        int index);
  void OnChromiumClosedTab(content::WebContents* contents);
  void PushLiveState(const ItemID& tab_id, content::WebContents* contents);
  std::optional<WindowID> WindowOfBrowser(
      BrowserWindowInterface* browser) const;
  std::optional<ProfileID> ProfileOfBrowser(
      BrowserWindowInterface* browser) const;
  void EnsureNonEmpty(BrowserWindowInterface* browser);

  raw_ptr<OpenBrowserService> service_;
  bool started_ = false;
  // Set while the bridge itself mutates a TabStripModel or the model, so the
  // resulting notifications are not mirrored back.
  bool applying_ = false;
  bool resync_pending_ = false;

  std::map<WindowID, WindowBrowsers> windows_;
  std::map<raw_ptr<BrowserWindowInterface>, ManagedBrowser> browsers_;
  // Loaded tabs: tab id -> WebContents (owned by its TabStripModel).
  std::map<ItemID, raw_ptr<content::WebContents>> contents_;

  void AddObservedStrip(TabStripModel* strip);
  void RemoveObservedStrip(TabStripModel* strip);
  void ClearObservedStrips();

  std::set<raw_ptr<TabStripModel>> observed_strips_;
  base::ScopedObservation<BrowserCollection, BrowserCollectionObserver>
      browser_collection_observation_{this};
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenTabBridge> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_TAB_BRIDGE_H_
