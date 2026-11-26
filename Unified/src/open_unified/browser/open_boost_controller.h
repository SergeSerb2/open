// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/model/open_types.h"

namespace content {
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace open_unified {

class OpenBrowserService;

// Applies Boosts (docs/boosts.md) to matching pages of non-incognito tabs:
//
// - The managed applier (color filter, font, text zoom/transform, saved
//   Zaps, custom CSS) runs in Open's isolated world
//   (ISOLATED_WORLD_ID_OPEN = 6, hook 0004): its state and Boost ids stay
//   private from page scripts; it owns one <style> element it re-inserts
//   after SPA swaps.
// - User-authored Boost JavaScript runs in the page's main world, as on
//   macOS (inserted as a script element by the applier, so it follows the
//   page's CSP for inline script). Draft previews never run JavaScript.
// - `advanced.enableBoosts` (Settings > Advanced) off: no Boost styles or
//   JavaScript are injected, pages that had a Boost get an empty payload on
//   the next refresh, and Zap cannot start.
// - Zap: StartZapForTab() arms a multi-shot picker in world 6 with a fresh
//   session nonce (macOS ZapPicker behavior). The picker swallows
//   pointerdown / mousedown / mouseup / click in the capture phase so links
//   and buttons never fire, hides each picked element at once with a live
//   world-6 <style>, and stays armed until Escape, Done (CancelZap) or a
//   navigation. Picks queue in world-private state; the browser collects
//   them (a 200 ms timer, only while a session is armed), checks the boost
//   id, nonce, selector size/shape and that the selector still matches,
//   then appends them to the Boost's Zaps in the BoostStore. A page cannot
//   forge a pick or replay an old nonce.
// - Observers (the floating Boost editor, Site Control) get
//   OnBoostsChanged / OnZapStateChanged pushes: no polling on their side.
class OpenBoostController : public OpenTabBridge::Observer {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // The cached Boosts of |profile_id| changed (load, save, delete, Zap
    // edits, sync reload).
    virtual void OnBoostsChanged(const ProfileID& profile_id) {}
    // Zap armed/disarmed, or the armed Boost's Zap count changed.
    // |boost_id| is the session's Boost (the last one when disarmed).
    virtual void OnZapStateChanged(bool armed,
                                   const std::string& boost_id,
                                   int zap_count) {}
  };

  // Result of a save: the stored Boost (id and timestamps filled), or
  // nullopt when the Profile has no services.
  using SaveCallback = base::OnceCallback<void(std::optional<Boost>)>;

  explicit OpenBoostController(OpenBrowserService* service);
  ~OpenBoostController() override;

  OpenBoostController(const OpenBoostController&) = delete;
  OpenBoostController& operator=(const OpenBoostController&) = delete;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Re-reads the Profile's Boosts (after a WebUI edit or sync) and
  // re-applies them to its loaded pages.
  void ReloadBoosts(const ProfileID& profile_id);
  // Cached Boosts of a Profile (empty until the first load finishes).
  const std::vector<Boost>& BoostsFor(const ProfileID& profile_id);
  // The cached Boost |boost_id| of |profile_id|, if any.
  std::optional<Boost> FindBoost(const ProfileID& profile_id,
                                 const std::string& boost_id) const;
  // Boosts that match |url| (enabled ones only; ignores the global switch).
  std::vector<Boost> MatchingBoosts(const ProfileID& profile_id,
                                    const GURL& url);

  // `advanced.enableBoosts` (default true).
  static bool BoostsGloballyEnabled();
  // Re-reads `advanced.enableBoosts` and re-applies every loaded tab when
  // it changed (Settings calls this after a write; the controller also
  // checks lazily on each new document).
  void OnBoostsPreferenceChanged();

  // --- Editing (floating Boost editor) ---------------------------------

  // Live draft preview on |tab_id| (CSS only: color, font, size, case,
  // Zaps, custom CSS; never JavaScript). Replaces the stored Boost with the
  // same id for that tab until SaveBoost/EndPreview. Cheap enough to call
  // on every drag event (one isolated-world script, no store round trip).
  void PreviewBoost(const ItemID& tab_id, const Boost& draft);
  // Drops |tab_id|'s draft and re-applies the stored Boosts.
  void EndPreview(const ItemID& tab_id);
  // Saves |boost| (insert or update). The cache and pages update at once;
  // the store write and a reload follow on the store sequence.
  void SaveBoost(const ProfileID& profile_id,
                 const Boost& boost,
                 SaveCallback done = SaveCallback());
  void DeleteBoost(const ProfileID& profile_id, const std::string& boost_id);

  // --- Zap ---------------------------------------------------------------

  // Arms Zap for |boost_id| in the active tab. Returns false when the
  // active page is not a matching, non-incognito http(s) page.
  bool StartZap(const std::string& boost_id, std::string* message);
  // Arms Zap for |boost_id| in |tab_id| (the editor passes its page).
  bool StartZapForTab(const ItemID& tab_id,
                      const std::string& boost_id,
                      std::string* message);
  // Ends the session (Done, Escape, navigation, editor closed).
  void CancelZap();
  bool zap_armed() const { return zap_.has_value(); }
  // The armed session's Boost, if any.
  std::optional<std::string> zap_boost_id() const;
  // Removes the newest Zap of |boost_id| and refreshes its pages. Returns
  // false when the Boost has no Zaps.
  bool UndoLastZap(const std::string& boost_id);
  // Removes every Zap of |boost_id| and refreshes its pages.
  bool ClearAllZaps(const std::string& boost_id);
  // Stored Zap count of |boost_id| (any Profile), 0 when unknown.
  int ZapCount(const std::string& boost_id) const;

  // Automation readback.
  base::DictValue StateForAutomation() const;

  // Generated stylesheet for |boosts| (exposed for automation readback).
  static std::string BuildStylesheet(const std::vector<Boost>& boosts);
  static bool HostMatches(const std::string& host, const std::string& pattern);

  // OpenTabBridge::Observer:
  void OnTabDocumentAvailable(const ItemID& tab_id,
                              content::WebContents* contents) override;
  void OnTabPrimaryPageCommitted(const ItemID& tab_id,
                                 content::WebContents* contents) override;
  void OnTabContentsDetaching(const ItemID& tab_id,
                              content::WebContents* contents) override;

 private:
  struct ZapSession {
    std::string boost_id;
    ProfileID profile_id;
    ItemID tab_id;
    base::UnguessableToken nonce;
    // Selectors saved in this session, newest last (in-page Undo).
    std::vector<std::string> picked;
  };

  // The Profile that holds |boost_id| in the cache.
  std::optional<ProfileID> ProfileOfBoost(const std::string& boost_id) const;
  Boost* MutableBoost(const ProfileID& profile_id, const std::string& boost_id);

  // |refresh|: Boosts changed while the page is open (also removes styles
  // of a Boost that no longer applies).
  void ApplyToContents(const ItemID& tab_id,
                       content::WebContents* contents,
                       bool refresh);
  // Re-applies every loaded tab of |profile_id| (all Profiles when empty).
  void RefreshTabs(const std::optional<ProfileID>& profile_id);
  // The Boosts that apply to |url| in |tab_id|, drafts included.
  std::vector<Boost> EffectiveBoosts(const ItemID& tab_id,
                                     const ProfileID& profile_id,
                                     const GURL& url);
  void OnBoostsLoaded(const ProfileID& profile_id, std::vector<Boost> boosts);
  void NotifyBoostsChanged(const ProfileID& profile_id);
  void NotifyZapState(const std::string& boost_id);
  void RunInZapPage(const std::u16string& script);

  void PollZap();
  void OnZapPicks(ZapSession session, base::Value result);
  void OnZapAppended(ProfileID profile_id, std::string boost_id, bool ok);

  raw_ptr<OpenBrowserService> service_;
  std::map<ProfileID, std::vector<Boost>> boosts_;
  // Draft Boosts previewed per tab (the floating editor).
  std::map<ItemID, Boost> previews_;
  // Saves in flight per Boost id (only the newest reply updates the cache).
  std::map<std::string, int> pending_saves_;
  // Tabs whose current document has Boost styles applied.
  std::set<ItemID> boosted_tabs_;
  std::optional<ZapSession> zap_;
  base::RepeatingTimer zap_poll_;
  bool poll_in_flight_ = false;
  bool global_enabled_ = true;
  int applied_count_ = 0;
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenBoostController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_BOOST_CONTROLLER_H_
