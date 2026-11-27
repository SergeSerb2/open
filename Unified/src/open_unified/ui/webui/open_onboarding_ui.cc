// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_onboarding_ui.h"

#include <algorithm>
#include <iterator>
#include <map>
#include <set>
#include <utility>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/ref_counted_memory.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "build/build_config.h"
#include "chrome/browser/favicon/large_icon_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/favicon/core/large_icon_service.h"
#include "components/favicon_base/fallback_icon_style.h"
#include "components/favicon_base/favicon_types.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "open/adblock/open_adblock_service.h"
#include "open_unified/browser/open_boost_controller.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "open_unified/ui/views/open_command_bar_view.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "third_party/skia/include/core/SkColor.h"
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

constexpr size_t kMaxFavorites = 12;
constexpr size_t kMaxImportedBookmarks = 20000;
constexpr size_t kMaxImportedHistory = 50000;
constexpr size_t kMaxNameBytes = 64;
constexpr size_t kMaxFaviconUrls = 32;
constexpr size_t kMaxSourceIdBytes = 256;
constexpr int kFaviconMinSourcePx = 16;
constexpr int kFaviconDesiredPx = 64;

constexpr char kStateDir[] = "State";
constexpr char kImportLedgerFile[] = "import-ledger.json";
constexpr char kWelcomeChecklistFile[] = "welcome-checklist.json";
// A neutral page for "Try Peek" and the Split View companion tab.
constexpr char kDemoPageUrl[] = "https://en.wikipedia.org/wiki/Doorway";

// Every import kind the pages may send. "favorites" on a Chromium-family
// source means its bookmarks (Settings' import modal sends it).
bool IsKnownImportKind(const std::string& kind) {
  static const base::NoDestructor<std::set<std::string>> kinds(
      std::set<std::string>{"bookmarks", "favorites", "history", "spaces",
                            "boosts", "documents", "archive", "preferences",
                            "extensions", "passwords"});
  return kinds->contains(kind);
}

// Kinds that are not protected by deterministic sidebar ids: the ledger
// remembers them per source so a replay does not add them twice.
bool IsLedgerKind(const std::string& kind) {
  return kind == "history" || kind == "boosts" || kind == "documents" ||
         kind == "archive" || kind == "preferences";
}

bool Wants(const std::vector<std::string>& kinds, std::string_view kind) {
  return std::find(kinds.begin(), kinds.end(), kind) != kinds.end();
}

std::string_view FamilyName(BrowserFamily family) {
  switch (family) {
    case BrowserFamily::kArc:
      return "arc";
    case BrowserFamily::kChromium:
      return "chromium";
    case BrowserFamily::kFirefox:
      return "firefox";
    case BrowserFamily::kSafari:
      return "safari";
    case BrowserFamily::kOpenLegacy:
      return "open-legacy";
    case BrowserFamily::kHtmlBookmarks:
      return "html";
  }
  return "chromium";
}

std::vector<std::string_view> SupportedKinds(BrowserFamily family) {
  switch (family) {
    case BrowserFamily::kArc:
      return {"spaces", "favorites", "history",
              "boosts", "documents", "archive"};
    case BrowserFamily::kOpenLegacy:
      return {"spaces",    "favorites", "history",    "boosts",
              "documents", "archive",   "preferences"};
    case BrowserFamily::kChromium:
    case BrowserFamily::kFirefox:
    case BrowserFamily::kSafari:
      return {"bookmarks", "history"};
    case BrowserFamily::kHtmlBookmarks:
      return {"bookmarks"};
  }
  return {};
}

// One sequence for Open's small onboarding/welcome state files.
scoped_refptr<base::SequencedTaskRunner> StateFileRunner() {
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> runner(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}));
  return *runner;
}

base::FilePath StateFilePath(const char* name) {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service
             ? service->user_data_dir().AppendASCII(kStateDir).AppendASCII(name)
             : base::FilePath();
}

// Blocking.
base::DictValue ReadJsonDict(const base::FilePath& path) {
  std::string contents;
  if (path.empty() ||
      !base::ReadFileToStringWithMaxSize(path, &contents, 1024 * 1024)) {
    return base::DictValue();
  }
  std::optional<base::DictValue> dict =
      base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  return dict ? std::move(*dict) : base::DictValue();
}

// Blocking.
bool WriteJsonDict(const base::FilePath& path, const base::DictValue& dict) {
  std::string json;
  if (path.empty() || !base::JSONWriter::Write(dict, &json)) {
    return false;
  }
  base::CreateDirectory(path.DirName());
  return base::ImportantFileWriter::WriteFileAtomically(path, json);
}

// The kinds the ledger recorded for |source_id|.
std::vector<std::string> LedgerKinds(const base::DictValue& ledger,
                                     const std::string& source_id) {
  std::vector<std::string> out;
  if (const base::DictValue* entry = ledger.FindDict(source_id)) {
    if (const base::ListValue* kinds = entry->FindList("kinds")) {
      for (const base::Value& kind : *kinds) {
        if (kind.is_string()) {
          out.push_back(kind.GetString());
        }
      }
    }
  }
  return out;
}

// Blocking: adds |kinds| to the ledger entry of |source_id|.
void RecordLedgerKinds(base::FilePath path,
                       std::string source_id,
                       std::vector<std::string> kinds) {
  base::DictValue ledger = ReadJsonDict(path);
  std::vector<std::string> merged = LedgerKinds(ledger, source_id);
  for (const std::string& kind : kinds) {
    if (!Wants(merged, kind)) {
      merged.push_back(kind);
    }
  }
  base::ListValue list;
  for (const std::string& kind : merged) {
    list.Append(kind);
  }
  ledger.Set(source_id, base::DictValue()
                            .Set("kinds", std::move(list))
                            .Set("imported_at",
                                 base::Time::Now().InSecondsFSinceUnixEpoch()));
  WriteJsonDict(path, ledger);
}

// --- Welcome checklist
// ---------------------------------------------------------

struct WelcomeStepDef {
  const char* id;
  const char* title;
  const char* action;
};

constexpr WelcomeStepDef kWelcomeSteps[] = {
    {"command-bar", "Open the Command Bar", "open-command-bar"},
    {"sidebar", "Hide and show the sidebar", "toggle-sidebar"},
    {"peek", "Peek at a link", "peek"},
    {"split", "Open a Split View", "split-view"},
    {"boosts", "Make a Boost", "new-boost"},
    {"library", "Open the Library", "view-library"},
    {"theme", "Edit your Space theme", "edit-theme"},
};

bool IsWelcomeStep(std::string_view id) {
  for (const WelcomeStepDef& step : kWelcomeSteps) {
    if (id == step.id) {
      return true;
    }
  }
  return false;
}

// The checklist step a welcome action completes (empty for none).
std::string_view StepForAction(std::string_view action) {
  if (action == "open-command-bar" || action == "new_tab")
    return "command-bar";
  if (action == "toggle-sidebar")
    return "sidebar";
  if (action == "peek")
    return "peek";
  if (action == "split-view" || action == "split")
    return "split";
  if (action == "new-boost" || action == "boost-gallery")
    return "boosts";
  if (action == "view-library")
    return "library";
  if (action == "edit-theme")
    return "theme";
  return {};
}

std::vector<std::string> DoneSteps(const base::DictValue& checklist) {
  std::vector<std::string> out;
  if (const base::ListValue* done = checklist.FindList("done")) {
    for (const base::Value& id : *done) {
      if (id.is_string() && IsWelcomeStep(id.GetString())) {
        out.push_back(id.GetString());
      }
    }
  }
  return out;
}

// Blocking: marks |step| done (or not) and returns the done list.
std::vector<std::string> UpdateChecklist(base::FilePath path,
                                         std::string step,
                                         bool done) {
  base::DictValue checklist = ReadJsonDict(path);
  std::vector<std::string> steps = DoneSteps(checklist);
  std::erase(steps, step);
  if (done) {
    steps.push_back(step);
  }
  base::ListValue list;
  for (const std::string& id : steps) {
    list.Append(id);
  }
  checklist.Set("done", std::move(list));
  WriteJsonDict(path, checklist);
  return steps;
}

base::ListValue StepsValue(const std::vector<std::string>& done) {
  base::ListValue list;
  for (const WelcomeStepDef& step : kWelcomeSteps) {
    list.Append(base::DictValue()
                    .Set("id", step.id)
                    .Set("title", step.title)
                    .Set("action", step.action)
                    .Set("done", Wants(done, step.id)));
  }
  return list;
}

// --- Shortcuts reference
// ----------------------------------------------------------

// "Mod+Shift+T" (bridge.ts ShortcutBinding.keys; same format as
// open_settings_ui.cc FormatShortcut).
std::string FormatKeys(const KeyboardShortcut& shortcut) {
  std::vector<std::string> parts;
  uint32_t modifiers = shortcut.modifiers;
  if (modifiers & kModPrimary) {
    parts.push_back("Mod");
    modifiers &= ~static_cast<uint32_t>(kModPrimary);
  }
  if (modifiers & kModCtrl)
    parts.push_back("Ctrl");
  if (modifiers & kModAlt)
    parts.push_back("Alt");
  if (modifiers & kModShift)
    parts.push_back("Shift");
  if (modifiers & kModMeta)
    parts.push_back("Meta");
  std::string key = shortcut.key;
  if (key.size() == 1) {
    key = base::ToUpperASCII(key);
  } else if (!key.empty()) {
    key[0] = base::ToUpperASCII(key[0]);
  }
  parts.push_back(key);
  return base::JoinString(parts, "+");
}

struct ShortcutRef {
  const char* id;
  const char* group;
};

// The Essential Shortcuts sheet, in display order.
constexpr ShortcutRef kEssentialShortcuts[] = {
    {"new-tab", "Navigation"},
    {"open-command-bar", "Navigation"},
    {"toggle-sidebar", "Navigation"},
    {"go-back", "Navigation"},
    {"go-forward", "Navigation"},
    {"find", "Navigation"},
    {"copy-url", "Navigation"},
    {"view-library", "Navigation"},
    {"pin-unpin-tab", "Tabs"},
    {"archive-tab", "Tabs"},
    {"restore-last-closed-tab", "Tabs"},
    {"tab-switcher-forward", "Tabs"},
    {"next-tab", "Tabs"},
    {"previous-tab", "Tabs"},
    {"duplicate-tab", "Tabs"},
    {"new-folder", "Tabs"},
    {"next-space", "Spaces"},
    {"previous-space", "Spaces"},
    {"new-space", "Spaces"},
    {"go-to-space-1", "Spaces"},
    {"edit-theme", "Spaces"},
    {"add-split-view", "Split & Peek"},
    {"close-split-pane", "Split & Peek"},
    {"next-split-pane", "Split & Peek"},
    {"new-little-open-window", "Split & Peek"},
    {"new-boost", "Boosts & Capture"},
    {"capture-page", "Boosts & Capture"},
    {"capture-full-page", "Boosts & Capture"},
    {"new-easel", "Boosts & Capture"},
    {"new-note", "Boosts & Capture"},
};

base::ListValue EssentialShortcutsValue(CommandRegistry& registry) {
  base::ListValue list;
  for (const ShortcutRef& ref : kEssentialShortcuts) {
    const CommandDefinition* command = registry.FindByStringId(ref.id);
    if (!command) {
      continue;
    }
    const std::vector<KeyboardShortcut> keys =
        registry.EffectiveShortcuts(command->command_id);
    list.Append(base::DictValue()
                    .Set("id", command->id)
                    .Set("title", command->title)
                    .Set("group", ref.group)
                    .Set("keys", keys.empty() ? std::string()
                                              : FormatKeys(keys.front())));
  }
  return list;
}

std::string_view PlatformName() {
#if BUILDFLAG(IS_MAC)
  return "mac";
#elif BUILDFLAG(IS_WIN)
  return "windows";
#else
  return "linux";
#endif
}

// --- Model helpers
// ----------------------------------------------------------------

bool IsWelcomeUrl(const std::string& spec) {
  const GURL url(spec);
  const bool host_ok =
      (url.SchemeIs(kOpenScheme) && url.host() == kHostWelcome) ||
      (url.SchemeIs("chrome") && url.host() == InternalHost(kHostWelcome));
  if (!host_ok) {
    return false;
  }
  // The Basics page only (not /help or /shortcuts).
  const std::string_view path = url.path();
  return path.empty() || path == "/";
}

std::optional<ItemID> FindWelcomeIn(const std::vector<SidebarNode>& nodes,
                                    const std::optional<ItemID>& exclude) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      if (tab->id != exclude && IsWelcomeUrl(tab->url)) {
        return tab->id;
      }
    } else if (const Folder* folder = node.as_folder()) {
      if (auto found = FindWelcomeIn(folder->children, exclude)) {
        return found;
      }
    } else if (const Split* split = node.as_split()) {
      for (const Tab& pane : split->panes) {
        if (pane.id != exclude && IsWelcomeUrl(pane.url)) {
          return pane.id;
        }
      }
    }
  }
  return std::nullopt;
}

// An existing Welcome tab of |space| (Today, Pinned, folders, splits).
std::optional<ItemID> FindWelcomeTab(const BrowserModel& model,
                                     const SpaceID& space_id,
                                     const std::optional<ItemID>& exclude) {
  const Space* space = model.FindSpace(space_id);
  if (!space) {
    return std::nullopt;
  }
  if (auto found = FindWelcomeIn(space->today, exclude)) {
    return found;
  }
  return FindWelcomeIn(space->pinned, exclude);
}

// "github.com/" for https://www.github.com and http://github.com/:
// Favorites are deduplicated on host (without www.) + path.
std::string UrlKey(const GURL& url) {
  std::string host(url.host());
  if (base::StartsWith(host, "www.")) {
    host = host.substr(4);
  }
  std::string path(url.path());
  while (path.size() > 1 && path.back() == '/') {
    path.pop_back();
  }
  if (path.empty()) {
    path = "/";
  }
  return base::StrCat({host, path});
}

// UI-thread cache of recently prefetched onboarding favicon PNG bytes keyed by
// UrlKey(url), so newly added starter Favorites immediately show icons.
std::map<std::string, std::vector<uint8_t>>& PrefetchedFaviconCache() {
  static base::NoDestructor<std::map<std::string, std::vector<uint8_t>>> cache;
  return *cache;
}

void CachePrefetchedFavicon(const GURL& url, const std::vector<uint8_t>& png) {
  if (!url.is_valid() || png.empty()) {
    return;
  }
  auto& cache = PrefetchedFaviconCache();
  if (cache.size() >= 128) {
    cache.clear();
  }
  cache[UrlKey(url)] = png;
}

const std::vector<uint8_t>* FindCachedPrefetchedFavicon(const GURL& url) {
  if (!url.is_valid()) {
    return nullptr;
  }
  const auto& cache = PrefetchedFaviconCache();
  auto it = cache.find(UrlKey(url));
  return it != cache.end() ? &it->second : nullptr;
}

void ApplyFaviconToExistingFavorites(BrowserModel& model,
                                     const ProfileID& profile_id,
                                     const GURL& url,
                                     const std::vector<uint8_t>& png) {
  if (png.empty() || !url.is_valid()) {
    return;
  }
  const Profile* profile = model.FindProfile(profile_id);
  if (!profile) {
    return;
  }
  const std::string target_key = UrlKey(url);
  std::vector<ItemID> matching_ids;
  for (const Tab& tab : profile->favorites) {
    if (tab.live_state.favicon_png.empty() &&
        UrlKey(GURL(tab.url)) == target_key) {
      matching_ids.push_back(tab.id);
    }
  }
  for (const ItemID& id : matching_ids) {
    model_util::UpdateLive(model, id, [&](TabLiveState& live) {
      if (live.favicon_png.empty()) {
        live.favicon_png = png;
      }
    });
  }
}

std::optional<SpaceID> FirstSpaceOf(const BrowserModel& model,
                                    const ProfileID& profile) {
  for (const Space& space : model.spaces()) {
    if (space.profile_id == profile) {
      return space.id;
    }
  }
  return std::nullopt;
}

// The focused Space when it belongs to |profile|, else its first Space.
std::optional<SpaceID> TargetSpace(const BrowserModel& model,
                                   const ProfileID& profile) {
  if (std::optional<SpaceID> focused =
          model_util::FocusedSpace(model, WindowID())) {
    if (const Space* space = model.FindSpace(*focused);
        space && space->profile_id == profile) {
      return focused;
    }
  }
  return FirstSpaceOf(model, profile);
}

// Imports change the model directly (BrowserImporter::Apply*), which emits no
// tree change. A folder kUpdate without a Space makes every sidebar page
// reconcile against the model (OpenSidebarView::OnTreeChanged), so the
// imported rows appear at once. Expands the folder, which also reveals the
// imported bookmarks.
void RevealImportedNodes(BrowserModel& model,
                         const std::vector<ItemID>& created) {
  // Bookmark imports list the root folder last.
  for (auto it = created.rbegin(); it != created.rend(); ++it) {
    if (const Folder* folder = model.FindFolder(*it)) {
      if (!folder->is_expanded) {
        model.SetFolderExpanded(*it, true);
      } else {
        model.SetFolderExpanded(*it, false);
        model.SetFolderExpanded(*it, true);
      }
      return;
    }
  }
}

int CountTabs(const BrowserModel& model, const std::vector<ItemID>& ids) {
  int tabs = 0;
  for (const ItemID& id : ids) {
    if (model.FindTab(id)) {
      ++tabs;
    }
  }
  return tabs;
}

// --- Store phase of an import (Boosts, Easels/Notes, Archive, History)
// --------

struct StoreApplyState {
  OpenOnboardingUI::ImportCounts counts;
  base::OnceCallback<void(OpenOnboardingUI::ImportCounts)> done;
  ProfileID fallback_profile;
  std::string source_id;
  std::vector<std::string> ledger_kinds;
  std::vector<std::pair<ProfileID, std::vector<Boost>>> boosts;
  std::vector<EaselDocument> easels;
  std::vector<NoteDocument> notes;
  std::vector<std::pair<ProfileID, std::vector<ArchivedTabRecord>>> archive;
  std::vector<std::pair<ProfileID, std::vector<HistoryEntry>>> history;
};

// The services of |profile|, or of the fallback Profile (imported Profiles
// may not have services yet).
ProfileServices* ServicesOrFallback(OpenBrowserService* service,
                                    const ProfileID& profile,
                                    const ProfileID& fallback) {
  if (ProfileServices* ps = service->ProfileServicesFor(profile)) {
    return ps;
  }
  return service->ProfileServicesFor(fallback);
}

void ContinueStoreApply(std::unique_ptr<StoreApplyState> state);

// Continuation of one store batch: adds |added| to |target| (a counter in
// |state|) and goes on.
void OnStoreBatchDone(std::unique_ptr<StoreApplyState> state,
                      int* target,
                      int added) {
  *target += added;
  ContinueStoreApply(std::move(state));
}

void ContinueStoreApply(std::unique_ptr<StoreApplyState> state) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    state->counts.error = "shutting down";
    std::move(state->done).Run(std::move(state->counts));
    return;
  }
  StoreApplyState* raw = state.get();

  if (!raw->boosts.empty()) {
    auto [profile, boosts] = std::move(raw->boosts.back());
    raw->boosts.pop_back();
    ProfileServices* ps =
        ServicesOrFallback(service, profile, raw->fallback_profile);
    if (!ps) {
      ContinueStoreApply(std::move(state));
      return;
    }
    const ProfileID target = ps->id;
    int* counter = &raw->counts.boosts;
    RunOnStore(
        ps->boosts,
        base::BindOnce(
            [](std::vector<Boost> boosts, ProfileID target, BoostStore* store) {
              int added = 0;
              for (Boost& boost : boosts) {
                if (boost.id.empty() || store->GetBoost(boost.id)) {
                  continue;
                }
                boost.profile_id = target;
                store->Upsert(std::move(boost));
                ++added;
              }
              if (added) {
                store->SaveNow();
              }
              return added;
            },
            std::move(boosts), target),
        base::BindOnce(
            [](std::unique_ptr<StoreApplyState> state, ProfileID target,
               int* counter, int added) {
              if (OpenBrowserService* s = OpenBrowserService::Get();
                  s && s->boost_controller() && added) {
                s->boost_controller()->ReloadBoosts(target);
              }
              OnStoreBatchDone(std::move(state), counter, added);
            },
            std::move(state), target, counter));
    return;
  }

  if (!raw->easels.empty() || !raw->notes.empty()) {
    ProfileServices* ps = service->ProfileServicesFor(raw->fallback_profile);
    std::vector<EaselDocument> easels = std::move(raw->easels);
    std::vector<NoteDocument> notes = std::move(raw->notes);
    raw->easels.clear();
    raw->notes.clear();
    if (!ps) {
      ContinueStoreApply(std::move(state));
      return;
    }
    int* counter = &raw->counts.documents;
    RunOnStore(
        ps->documents,
        base::BindOnce(
            [](std::vector<EaselDocument> easels,
               std::vector<NoteDocument> notes, DocumentStore* store) {
              int added = 0;
              for (const EaselDocument& easel : easels) {
                if (!store->LoadEasel(easel.id) && store->SaveEasel(easel)) {
                  ++added;
                }
              }
              for (const NoteDocument& note : notes) {
                if (!store->LoadNote(note.id) && store->SaveNote(note)) {
                  ++added;
                }
              }
              return added;
            },
            std::move(easels), std::move(notes)),
        base::BindOnce(&OnStoreBatchDone, std::move(state), counter));
    return;
  }

  if (!raw->archive.empty()) {
    auto [profile, records] = std::move(raw->archive.back());
    raw->archive.pop_back();
    ProfileServices* ps =
        ServicesOrFallback(service, profile, raw->fallback_profile);
    if (!ps) {
      ContinueStoreApply(std::move(state));
      return;
    }
    int* counter = &raw->counts.archive;
    RunOnStore(
        ps->archive,
        base::BindOnce(
            [](std::vector<ArchivedTabRecord> records, ArchiveStore* store) {
              std::vector<ArchivedTabRecord> fresh;
              for (ArchivedTabRecord& record : records) {
                if (!store->Get(record.id)) {
                  fresh.push_back(std::move(record));
                }
              }
              if (fresh.empty() || !store->Archive(fresh)) {
                return 0;
              }
              return static_cast<int>(fresh.size());
            },
            std::move(records)),
        base::BindOnce(&OnStoreBatchDone, std::move(state), counter));
    return;
  }

  if (!raw->history.empty()) {
    auto [profile, entries] = std::move(raw->history.back());
    raw->history.pop_back();
    ProfileServices* ps =
        ServicesOrFallback(service, profile, raw->fallback_profile);
    if (!ps) {
      ContinueStoreApply(std::move(state));
      return;
    }
    int* counter = &raw->counts.history;
    RunOnStore(
        ps->history,
        base::BindOnce(
            [](std::vector<HistoryEntry> entries, HistoryStore* store) {
              int recorded = 0;
              for (const HistoryEntry& entry : entries) {
                if (store->RecordVisit(entry.url, entry.title, entry.last_visit,
                                       "imported", entry.typed_count > 0)) {
                  ++recorded;
                }
              }
              return recorded;
            },
            std::move(entries)),
        base::BindOnce(
            [](std::unique_ptr<StoreApplyState> state, int* counter,
               int added) {
              // Imported pages show up in the command bar at once.
              if (OpenBrowserService* s = OpenBrowserService::Get()) {
                s->RefreshRecentHistory();
              }
              OnStoreBatchDone(std::move(state), counter, added);
            },
            std::move(state), counter));
    return;
  }

  // Everything written: remember the ledger kinds, then report.
  if (!raw->ledger_kinds.empty()) {
    StateFileRunner()->PostTask(
        FROM_HERE,
        base::BindOnce(&RecordLedgerKinds, StateFilePath(kImportLedgerFile),
                       raw->source_id, raw->ledger_kinds));
  }
  service->ScheduleSave();
  std::move(state->done).Run(std::move(state->counts));
}

// --- Favicons
// ---------------------------------------------------------------------

// Sites onboarding suggests (and close relatives). Only these hosts may be
// sent to Google's favicon server; anything a person types stays local.
bool IsCuratedFaviconHost(std::string_view host) {
  static const base::NoDestructor<std::set<std::string, std::less<>>> hosts(
      std::set<std::string, std::less<>>{
          "mail.google.com",
          "maps.google.com",
          "calendar.google.com",
          "docs.google.com",
          "drive.google.com",
          "github.com",
          "www.youtube.com",
          "youtube.com",
          "www.notion.com",
          "notion.com",
          "www.notion.so",
          "linear.app",
          "www.figma.com",
          "figma.com",
          "en.wikipedia.org",
          "open.spotify.com",
          "www.reddit.com",
          "reddit.com",
          "news.ycombinator.com",
          "x.com",
          "twitter.com",
          "app.slack.com",
          "slack.com",
          "chatgpt.com",
          "web.whatsapp.com",
          "outlook.live.com",
          "www.netflix.com",
          "www.amazon.com",
          "www.linkedin.com",
          "discord.com",
          "web.telegram.org",
          "www.instagram.com",
          "music.apple.com",
          "claude.ai",
          "www.dropbox.com",
          "trello.com",
      });
  return hosts->contains(host);
}

std::string PngDataUrl(base::span<const uint8_t> bytes) {
  return base::StrCat({"data:image/png;base64,", base::Base64Encode(bytes)});
}

std::string ColorHex(SkColor color) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out = "#";
  for (unsigned value :
       {SkColorGetR(color), SkColorGetG(color), SkColorGetB(color)}) {
    out.push_back(kHex[(value >> 4) & 0xF]);
    out.push_back(kHex[value & 0xF]);
  }
  return out;
}

constexpr net::NetworkTrafficAnnotationTag kFaviconTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_onboarding_favicons", R"(
        semantics {
          sender: "Open first-run setup"
          description:
            "Fetches the icon of a site that Open's first-run setup suggests "
            "as a Favorite (for example GitHub or Wikipedia), so its tile "
            "shows the real icon."
          trigger: "The Favorites step of first-run setup is shown."
          data:
            "The origin of a fixed, curated suggestion. Never a URL the "
            "user typed or visited."
          destination: GOOGLE_OWNED_SERVICE
        }
        policy {
          cookies_allowed: NO
          setting: "Skip the Favorites step."
          policy_exception_justification: "First-run only, curated sites."
        })");

}  // namespace

// --- Structs
// -----------------------------------------------------------------------

OpenOnboardingUI::ImportData::ImportData() = default;
OpenOnboardingUI::ImportData::ImportData(ImportData&&) noexcept = default;
OpenOnboardingUI::ImportData& OpenOnboardingUI::ImportData::operator=(
    ImportData&&) noexcept = default;
OpenOnboardingUI::ImportData::~ImportData() = default;

base::DictValue OpenOnboardingUI::ImportCounts::ToValue() const {
  base::DictValue value;
  value.Set("ok", error.empty());
  // import.run's original fields (Settings' import modal reads these).
  value.Set("imported_bookmarks", bookmarks + tabs);
  value.Set("imported_history", history);
  value.Set("imported_favorites", favorites);
  value.Set("imported_spaces", spaces);
  value.Set("imported_tabs", tabs);
  value.Set("imported_boosts", boosts);
  value.Set("imported_documents", documents);
  value.Set("imported_archive", archive);
  value.Set("skipped_already_imported", skipped_already_imported);
  if (!error.empty()) {
    value.Set("error", error);
  }
  return value;
}

struct OpenOnboardingUI::FaviconJob {
  Reply reply;
  std::vector<GURL> urls;
  std::vector<base::DictValue> results;
  size_t pending = 0;
};

// --- Domain
// ------------------------------------------------------------------------

OpenOnboardingUI::OpenOnboardingUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenOnboardingUI::~OpenOnboardingUI() = default;

void OpenOnboardingUI::RegisterMethods() {
  auto bind =
      [this](void (OpenOnboardingUI::*method)(const base::DictValue&, Reply)) {
        return base::BindRepeating(method, weak_factory_.GetWeakPtr());
      };
  Register(kOnboardingGetState, bind(&OpenOnboardingUI::GetState));
  Register(kOnboardingComplete, bind(&OpenOnboardingUI::Complete));
  Register(onboarding_rpc::kPrefetchFavicons,
           bind(&OpenOnboardingUI::PrefetchFavicons));
  Register(kImportProbeBrowsers, bind(&OpenOnboardingUI::ProbeBrowsers));
  Register(kImportRun, bind(&OpenOnboardingUI::RunImport));
  Register(onboarding_rpc::kWelcomeGetState,
           bind(&OpenOnboardingUI::WelcomeGetState));
  Register(kWelcomeTriggerAction,
           bind(&OpenOnboardingUI::TriggerWelcomeAction));
  Register(onboarding_rpc::kWelcomeMarkStepDone,
           bind(&OpenOnboardingUI::MarkStepDone));
}

std::optional<ItemID> OpenOnboardingUI::PageTabId() {
  content::WebUI* ui = web_ui();
  content::WebContents* contents = ui ? ui->GetWebContents() : nullptr;
  return contents ? OpenTabBridge::TabIdForWebContents(contents) : std::nullopt;
}

OpenWindowUi* OpenOnboardingUI::PageWindowUi() {
  OpenBrowserService* s = service();
  OpenWindowController* windows = s ? s->window_controller() : nullptr;
  if (!windows) {
    return nullptr;
  }
  if (OpenTabBridge* bridge = s->tab_bridge()) {
    if (std::optional<ItemID> tab = PageTabId()) {
      if (BrowserWindowInterface* browser = bridge->BrowserForTab(*tab)) {
        if (std::optional<WindowID> window =
                bridge->WindowIdForBrowser(browser)) {
          if (OpenWindowUi* ui = windows->WindowUiFor(*window)) {
            return ui;
          }
        }
      }
    }
  }
  return windows->MainWindowUi();
}

// --- onboarding.getState
// -------------------------------------------------------------

void OpenOnboardingUI::GetState(const base::DictValue& payload, Reply reply) {
  OpenBrowserService* s = service();
  const ProfileID profile = profile_id();
  BrowserModel& model = s->model();
  // The theme step starts from the target Space's style.
  SpaceStyle style;
  std::string space_title;
  if (std::optional<SpaceID> space_id = TargetSpace(model, profile)) {
    if (const Space* space = model.FindSpace(*space_id)) {
      if (space->theme.style) {
        style = *space->theme.style;
      }
      space_title = space->title.value_or(std::string());
    }
  }
  base::ListValue favorites;
  if (const Profile* p = model.FindProfile(profile)) {
    for (const Tab& tab : p->favorites) {
      favorites.Append(tab.url);
    }
  }
  ProfileServices* ps = s->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  OpenPlatform* platform = OpenPlatform::Get();
  const base::Value name = OpenPreferences::Get()->GetValue("general.userName");
  ReplyOk(
      std::move(reply),
      base::DictValue()
          .Set("completed", s->onboarding_completed())
          .Set("first_run", s->is_first_run())
          .Set("default_space_style", json::SpaceStyleToValue(style))
          .Set("space_title", space_title)
          .Set("user_name", name.is_string() ? name.GetString() : "")
          .Set("existing_favorite_urls", std::move(favorites))
          .Set("is_default_browser", platform && platform->IsDefaultBrowser())
          .Set("adblock_enabled",
               adblock && adblock->service() && adblock->service()->IsEnabled())
          .Set("platform", PlatformName()));
}

// --- import.probeBrowsers
// --------------------------------------------------------

void OpenOnboardingUI::ProbeBrowsers(const base::DictValue& payload,
                                     Reply reply) {
  // Reads other browsers' profile folders: blocking file I/O.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(
          [](base::FilePath ledger_path) {
            return std::make_pair(BrowserImporter::ProbeInstalledBrowsers(),
                                  ReadJsonDict(ledger_path));
          },
          StateFilePath(kImportLedgerFile)),
      base::BindOnce(
          [](Reply reply,
             std::pair<std::vector<DetectedBrowser>, base::DictValue> probe) {
            base::ListValue list;
            for (const DetectedBrowser& browser : probe.first) {
              for (const DetectedBrowserProfile& profile : browser.profiles) {
                const std::string id =
                    base::StrCat({browser.id, "/", profile.id});
                base::ListValue kinds;
                for (std::string_view kind : SupportedKinds(browser.family)) {
                  kinds.Append(kind);
                }
                base::ListValue done;
                for (const std::string& kind : LedgerKinds(probe.second, id)) {
                  done.Append(kind);
                }
                const bool legacy =
                    browser.family == BrowserFamily::kOpenLegacy;
                base::DictValue source =
                    base::DictValue()
                        .Set("id", id)
                        .Set("browser_id", browser.id)
                        .Set("browser_name", browser.name)
                        .Set("profile_name", profile.name)
                        .Set("family", FamilyName(browser.family))
                        .Set("is_default", profile.is_default)
                        .Set("recommended", legacy)
                        .Set("read_only", true)
                        .Set("access_denied", profile.access_denied)
                        .Set("bookmarks_count", profile.bookmark_count)
                        .Set("history_count", profile.history_count)
                        .Set("extensions_count", 0)
                        .Set("passwords_count", 0)
                        .Set("favorites_count", 0)
                        .Set("supported_kinds", std::move(kinds))
                        .Set("imported_kinds", std::move(done));
                if (!profile.access_error.empty()) {
                  source.Set("access_error", profile.access_error);
                }
                list.Append(std::move(source));
              }
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("sources", std::move(list)));
          },
          std::move(reply)));
}

// --- import.run
// ----------------------------------------------------------------------

void OpenOnboardingUI::RunImport(const base::DictValue& payload, Reply reply) {
  const std::string source_id = json::GetString(payload, "source_id");
  std::vector<std::string> kinds;
  if (const base::ListValue* list = payload.FindList("kinds")) {
    for (const base::Value& kind : *list) {
      if (kind.is_string() && IsKnownImportKind(kind.GetString())) {
        kinds.push_back(kind.GetString());
      }
    }
  }
  if (source_id.empty() || source_id.size() > kMaxSourceIdBytes ||
      kinds.empty()) {
    ReplyError(std::move(reply), "choose a browser and what to import");
    return;
  }
  StartImport(source_id, std::move(kinds), profile_id(),
              base::BindOnce(
                  [](Reply reply, ImportCounts counts) {
                    if (!counts.error.empty()) {
                      ReplyError(std::move(reply), counts.error);
                      return;
                    }
                    ReplyOk(std::move(reply), counts.ToValue());
                  },
                  std::move(reply)));
}

void OpenOnboardingUI::StartImport(std::string source_id,
                                   std::vector<std::string> kinds,
                                   ProfileID profile,
                                   ImportDone done) {
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", source_id)
                                             .Set("phase", "reading")
                                             .Set("progress", 0.1)));
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&ReadImportData, source_id, std::move(kinds),
                     StateFilePath(kImportLedgerFile)),
      // The page may close while the source is read: then nothing is
      // applied and |done| reports it.
      base::BindOnce(
          [](base::WeakPtr<OpenOnboardingUI> page, ProfileID profile,
             ImportDone done, ImportData data) {
            if (page) {
              page->ApplyImport(std::move(profile), std::move(done),
                                std::move(data));
              return;
            }
            ImportCounts counts;
            counts.error = "page closed";
            std::move(done).Run(std::move(counts));
          },
          weak_factory_.GetWeakPtr(), std::move(profile), std::move(done)));
}

// static
OpenOnboardingUI::ImportData OpenOnboardingUI::ReadImportData(
    std::string source_id,
    std::vector<std::string> kinds,
    base::FilePath ledger_path) {
  ImportData data;
  data.source_id = source_id;
  const size_t slash = source_id.find('/');
  if (slash == std::string::npos) {
    data.error = "unknown browser";
    return data;
  }
  const std::string browser_id = source_id.substr(0, slash);
  const std::string profile_id = source_id.substr(slash + 1);

  // Kinds a previous run already brought in for this source.
  const std::vector<std::string> ledger =
      LedgerKinds(ReadJsonDict(ledger_path), source_id);
  for (const std::string& kind : kinds) {
    if (IsLedgerKind(kind) && Wants(ledger, kind)) {
      data.already_done.push_back(kind);
    } else if (!Wants(data.kinds, kind)) {
      data.kinds.push_back(kind);
    }
  }
  const std::vector<std::string>& wanted = data.kinds;

  for (const DetectedBrowser& browser :
       BrowserImporter::ProbeInstalledBrowsers()) {
    if (browser.id != browser_id) {
      continue;
    }
    for (const DetectedBrowserProfile& profile : browser.profiles) {
      if (profile.id != profile_id) {
        continue;
      }
      data.browser_name = browser.name;
      data.family = browser.family;
      if (profile.access_denied) {
        data.error =
            browser.family == BrowserFamily::kSafari
                ? "Open needs Full Disk Access to read Safari. Turn it on in "
                  "System Settings > Privacy & Security > Full Disk Access, "
                  "then try again."
                : (profile.access_error.empty() ? "access denied"
                                                : profile.access_error);
        return data;
      }
      auto on_batch = base::BindRepeating(
          [](std::vector<HistoryEntry>* out,
             const std::vector<HistoryEntry>& batch) {
            if (out->size() < kMaxImportedHistory) {
              out->insert(out->end(), batch.begin(), batch.end());
            }
          },
          base::Unretained(&data.history));
      const bool bookmarks =
          Wants(wanted, "bookmarks") || Wants(wanted, "favorites");
      const bool history = Wants(wanted, "history");
      switch (browser.family) {
        case BrowserFamily::kChromium:
          if (bookmarks) {
            BrowserImporter::ReadChromiumBookmarks(profile.directory,
                                                   &data.bookmark_roots);
          }
          if (history) {
            BrowserImporter::ReadChromiumHistory(profile.directory, on_batch);
          }
          break;
        case BrowserFamily::kFirefox:
          if (bookmarks) {
            BrowserImporter::ReadFirefoxBookmarks(profile.directory,
                                                  &data.bookmark_roots);
          }
          if (history) {
            BrowserImporter::ReadFirefoxHistory(profile.directory, on_batch);
          }
          break;
        case BrowserFamily::kSafari: {
          SafariImportErrorInfo error;
          if (bookmarks &&
              !BrowserImporter::ReadSafariBookmarks(
                  profile.directory, &data.bookmark_roots, nullptr, &error) &&
              error.permission_denied) {
            data.error =
                "Open needs Full Disk Access to read Safari. Turn it on in "
                "System Settings > Privacy & Security > Full Disk Access, "
                "then try again.";
            return data;
          }
          if (history) {
            BrowserImporter::ReadSafariHistory(profile.directory, on_batch);
          }
          break;
        }
        case BrowserFamily::kArc: {
          ArcImportOptions options;
          options.include_history = history;
          options.include_boosts = Wants(wanted, "boosts");
          options.include_easels = Wants(wanted, "documents");
          options.include_notes = Wants(wanted, "documents");
          options.include_archive = Wants(wanted, "archive");
          options.max_history_entries = kMaxImportedHistory;
          ArcSidebarImportResult result =
              BrowserImporter::ImportArcDirectory(profile.directory, options);
          if (!result.ok) {
            data.error = result.error_message.empty()
                             ? "could not read that browser's sidebar"
                             : result.error_message;
            return data;
          }
          if (!Wants(wanted, "spaces")) {
            result.spaces.clear();
          }
          if (!Wants(wanted, "favorites")) {
            for (Profile& p : result.profiles) {
              p.favorites.clear();
            }
          }
          if (result.spaces.empty() && !Wants(wanted, "favorites")) {
            result.profiles.clear();
          }
          data.arc = std::move(result);
          break;
        }
        case BrowserFamily::kOpenLegacy: {
          // Read-only: ImportOpenLegacyDirectory never writes there.
          OpenLegacyImportOptions options;
          options.include_workspace =
              Wants(wanted, "spaces") || Wants(wanted, "favorites");
          options.include_preferences = Wants(wanted, "preferences");
          options.include_shortcuts = false;
          options.include_boosts = Wants(wanted, "boosts");
          options.include_documents = Wants(wanted, "documents");
          options.include_history = history;
          options.include_archive = Wants(wanted, "archive");
          options.include_adblock = false;
          options.max_history_per_profile = kMaxImportedHistory;
          OpenLegacyImportResult result =
              BrowserImporter::ImportOpenLegacyDirectory(profile.directory,
                                                         options);
          if (!result.ok) {
            data.error = result.error_message.empty()
                             ? "could not read the earlier Open data"
                             : result.error_message;
            return data;
          }
          if (!Wants(wanted, "spaces")) {
            result.spaces.clear();
            result.windows.clear();
          }
          if (!Wants(wanted, "favorites")) {
            for (Profile& p : result.profiles) {
              p.favorites.clear();
            }
          }
          if (result.spaces.empty() && !Wants(wanted, "favorites")) {
            result.profiles.clear();
          }
          data.legacy = std::move(result);
          break;
        }
        case BrowserFamily::kHtmlBookmarks:
          break;
      }
      if (data.history.size() > kMaxImportedHistory) {
        data.history.resize(kMaxImportedHistory);
      }
      return data;
    }
  }
  data.error = "that browser profile was not found";
  return data;
}

void OpenOnboardingUI::ApplyImport(ProfileID profile,
                                   ImportDone done,
                                   ImportData data) {
  OpenBrowserService* s = service();
  ImportCounts counts;
  counts.skipped_already_imported = static_cast<int>(data.already_done.size());
  if (!s) {
    counts.error = "shutting down";
    std::move(done).Run(std::move(counts));
    return;
  }
  if (!data.error.empty()) {
    counts.error = data.error;
    Emit(kEventImportProgress, base::Value(base::DictValue()
                                               .Set("source_id", data.source_id)
                                               .Set("phase", "error")
                                               .Set("message", data.error)));
    std::move(done).Run(std::move(counts));
    return;
  }
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", data.source_id)
                                             .Set("phase", "applying")
                                             .Set("progress", 0.6)));
  BrowserModel& model = s->model();
  auto state = std::make_unique<StoreApplyState>();
  state->fallback_profile = profile;
  state->source_id = data.source_id;
  for (const std::string& kind : data.kinds) {
    if (IsLedgerKind(kind)) {
      state->ledger_kinds.push_back(kind);
    }
  }

  const std::optional<SpaceID> space = TargetSpace(model, profile);
  // Sidebar items: deterministic ids, so a second run adds nothing.
  if (!data.bookmark_roots.empty() && space) {
    const ImportReceipt receipt =
        BrowserImporter::ApplyImportedBookmarksToModel(
            &model, *space, data.browser_name, data.family, data.source_id,
            data.bookmark_roots, kMaxImportedBookmarks);
    counts.bookmarks = CountTabs(model, receipt.created_node_ids);
    RevealImportedNodes(model, receipt.created_node_ids);
  }
  if (data.arc) {
    const ImportReceipt receipt =
        BrowserImporter::ApplyArcImportToModel(&model, *data.arc, nullptr);
    counts.spaces = static_cast<int>(receipt.created_space_ids.size());
    counts.tabs = CountTabs(model, receipt.created_node_ids);
    counts.favorites = static_cast<int>(receipt.created_favorite_ids.size());
    RevealImportedNodes(model, receipt.created_node_ids);
    auto target = [&](const ProfileID& id) {
      return model.FindProfile(id) ? id : profile;
    };
    std::map<ProfileID, std::vector<Boost>> boosts;
    for (Boost& boost : data.arc->boosts) {
      boosts[target(boost.profile_id)].push_back(std::move(boost));
    }
    for (auto& [id, list] : boosts) {
      state->boosts.emplace_back(id, std::move(list));
    }
    state->easels = std::move(data.arc->easels);
    state->notes = std::move(data.arc->notes);
    if (!data.arc->archive_records.empty()) {
      state->archive.emplace_back(profile,
                                  std::move(data.arc->archive_records));
    }
    if (!data.arc->history.empty()) {
      state->history.emplace_back(profile, std::move(data.arc->history));
    }
  }
  if (data.legacy) {
    const ImportReceipt receipt = BrowserImporter::ApplyOpenLegacyImportToModel(
        &model, *data.legacy, nullptr);
    counts.spaces = static_cast<int>(receipt.created_space_ids.size());
    counts.tabs = CountTabs(model, receipt.created_node_ids);
    counts.favorites = static_cast<int>(receipt.created_favorite_ids.size());
    RevealImportedNodes(model, receipt.created_node_ids);
    auto target = [&](const ProfileID& id) {
      return model.FindProfile(id) ? id : profile;
    };
    for (auto& [id, list] : data.legacy->boosts_by_profile) {
      state->boosts.emplace_back(target(id), std::move(list));
    }
    state->easels = std::move(data.legacy->easels);
    state->notes = std::move(data.legacy->notes);
    for (auto& [id, list] : data.legacy->archive_by_profile) {
      state->archive.emplace_back(target(id), std::move(list));
    }
    for (auto& [id, list] : data.legacy->history_by_profile) {
      state->history.emplace_back(target(id), std::move(list));
    }
    // Portable app preferences (validated by OpenPreferences).
    if (Wants(data.kinds, "preferences")) {
      OpenPreferences* prefs = OpenPreferences::Get();
      for (const auto& [key, value] : data.legacy->preferences) {
        std::string error;
        prefs->Set(OpenPreferences::TranslateLegacyKey(key), value, profile,
                   false, &error);
      }
    }
  }
  if (!data.history.empty()) {
    state->history.emplace_back(profile, std::move(data.history));
  }
  s->ScheduleSave();

  state->done = base::BindOnce(
      [](base::WeakPtr<OpenOnboardingUI> page, std::string source_id,
         ImportDone done, ImportCounts counts) {
        if (page) {
          page->Emit(kEventImportProgress,
                     base::Value(base::DictValue()
                                     .Set("source_id", source_id)
                                     .Set("phase", "done")
                                     .Set("progress", 1.0)
                                     .Set("done", true)));
        }
        std::move(done).Run(std::move(counts));
      },
      weak_factory_.GetWeakPtr(), data.source_id, std::move(done));
  state->counts = counts;
  ContinueStoreApply(std::move(state));
}

// --- onboarding.complete
// -----------------------------------------------------------

void OpenOnboardingUI::Complete(const base::DictValue& payload, Reply reply) {
  const base::Value* style_value = payload.Find("space_style");
  if (style_value && !json::SpaceStyleFromValue(style_value)) {
    ReplyError(std::move(reply), "invalid space style");
    return;
  }
  const ProfileID profile = profile_id();
  const bool replay = json::GetBool(payload, "replay", false);

  // The import chosen in the wizard runs now, once (never mid-wizard).
  std::string source_id;
  std::vector<std::string> kinds;
  if (const base::DictValue* import = payload.FindDict("import")) {
    source_id = json::GetString(*import, "source_id");
    if (const base::ListValue* list = import->FindList("kinds")) {
      for (const base::Value& kind : *list) {
        if (kind.is_string() && IsKnownImportKind(kind.GetString())) {
          kinds.push_back(kind.GetString());
        }
      }
    }
  }
  if (!replay && !source_id.empty() && source_id.size() <= kMaxSourceIdBytes &&
      !kinds.empty()) {
    StartImport(source_id, std::move(kinds), profile,
                base::BindOnce(&OpenOnboardingUI::FinishComplete,
                               weak_factory_.GetWeakPtr(), payload.Clone(),
                               profile, std::move(reply)));
    return;
  }
  FinishComplete(payload.Clone(), profile, std::move(reply), ImportCounts());
}

void OpenOnboardingUI::FinishComplete(base::DictValue payload,
                                      ProfileID profile,
                                      Reply reply,
                                      ImportCounts counts) {
  OpenBrowserService* s = service();
  if (!s) {
    ReplyError(std::move(reply), "shutting down");
    return;
  }
  // A failed import keeps Ready open for a retry (or a skip); nothing else
  // is written and no Welcome tab is added.
  if (!counts.error.empty()) {
    ReplyError(std::move(reply),
               base::StrCat({"Import failed: ", counts.error}));
    return;
  }
  const bool replay = json::GetBool(payload, "replay", false);
  BrowserModel& model = s->model();
  int favorites_added = 0;

  if (!replay) {
    // Name: an app preference (shown on open://welcome).
    std::string name = std::string(base::TrimWhitespaceASCII(
        json::GetString(payload, "user_name"), base::TRIM_ALL));
    if (name.size() > kMaxNameBytes) {
      name.resize(kMaxNameBytes);
    }
    OpenPreferences::Get()->WhenLoaded(base::BindOnce(
        [](std::string name, ProfileID profile) {
          std::string error;
          OpenPreferences::Get()->Set("general.userName", base::Value(name),
                                      profile, false, &error);
        },
        name, profile));

    // Theme of the Space the hand-off lands in.
    std::optional<SpaceID> theme_space;
    if (std::optional<ItemID> self = PageTabId()) {
      theme_space = model_util::SpaceOfNode(model, *self);
    }
    if (!theme_space) {
      theme_space = TargetSpace(model, profile);
    }
    if (std::optional<SpaceStyle> style =
            json::SpaceStyleFromValue(payload.Find("space_style"));
        style && theme_space) {
      if (const Space* space = model.FindSpace(*theme_space)) {
        SpaceTheme theme = space->theme;
        if (!theme.style || !(*theme.style == *style)) {
          theme.style = *style;
          model.UpdateSpace(*theme_space, std::nullopt, std::nullopt, theme);
        }
      }
    }

    // Favorites: http(s) only, at most 12 new ones, none the Profile has.
    if (const base::ListValue* urls = payload.FindList("favorite_urls")) {
      std::set<std::string> existing;
      size_t index = 0;
      if (const Profile* p = model.FindProfile(profile)) {
        index = p->favorites.size();
        for (const Tab& tab : p->favorites) {
          existing.insert(UrlKey(GURL(tab.url)));
        }
      }
      const std::optional<SpaceID> space = TargetSpace(model, profile);
      for (const base::Value& value : *urls) {
        if (!value.is_string() || !space ||
            static_cast<size_t>(favorites_added) >= kMaxFavorites) {
          continue;
        }
        const GURL url(value.GetString());
        if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() ||
            !existing.insert(UrlKey(url)).second) {
          continue;
        }
        // A Favorite starts as a tab, then moves to the Profile's Favorites.
        const ItemID id =
            model.NewTab(*space, url.spec(), std::string(url.host()));
        if (id.empty()) {
          continue;
        }
        if (model.AddFavorite(id, profile, index)) {
          ++index;
          ++favorites_added;
          if (const std::vector<uint8_t>* cached =
                  FindCachedPrefetchedFavicon(url);
              cached && !cached->empty()) {
            model_util::UpdateLive(model, id, [&](TabLiveState& live) {
              live.favicon_png = *cached;
            });
          } else if (ProfileServices* ps = s->ProfileServicesFor(profile)) {
            RunOnStore(
                ps->favicons,
                base::BindOnce(
                    [](std::string page_url, std::string origin_url,
                       FaviconStore* store)
                        -> std::optional<std::vector<uint8_t>> {
                      for (const std::string& key : {page_url, origin_url}) {
                        std::optional<FaviconRecord> record = store->Get(key);
                        if (!record || record->status != 0) {
                          continue;
                        }
                        if (!record->png64.empty()) {
                          return record->png64;
                        }
                        if (!record->png32.empty()) {
                          return record->png32;
                        }
                      }
                      return std::nullopt;
                    },
                    url.spec(), url.DeprecatedGetOriginAsURL().spec()),
                base::BindOnce(
                    [](ItemID tab_id, std::optional<std::vector<uint8_t>> png) {
                      OpenBrowserService* svc = OpenBrowserService::Get();
                      if (!svc || !png || png->empty()) {
                        return;
                      }
                      model_util::UpdateLive(
                          svc->model(), tab_id, [&](TabLiveState& live) {
                            if (live.favicon_png.empty()) {
                              live.favicon_png = std::move(*png);
                            }
                          });
                    },
                    id));
          }
        } else {
          model.CloseTab(id);
        }
      }
    }

    // Ad blocking (every Profile; one master switch).
    if (std::optional<bool> adblock = payload.FindBool("adblock_enabled")) {
      for (const Profile& p : model.profiles()) {
        ProfileServices* ps = s->ProfileServicesFor(p.id);
        if (OpenAdBlockProfileService* adblock_service =
                ps ? ps->adblock() : nullptr) {
          adblock_service->SetEnabled(*adblock);
        }
      }
    }

    if (json::GetBool(payload, "make_default_browser", false)) {
#if BUILDFLAG(IS_MAC)
      if (OpenPlatform* platform = OpenPlatform::Get();
          platform && !platform->IsDefaultBrowser()) {
        platform->SetDefaultBrowser();
      }
#else
      base::ThreadPool::PostTask(
          FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
          base::BindOnce([] {
            if (OpenPlatform* platform = OpenPlatform::Get();
                platform && !platform->IsDefaultBrowser()) {
              platform->SetDefaultBrowser();
            }
          }));
#endif
    }
    s->ScheduleSave();
  }

  // Hand-off before completion: a failure here leaves Ready open.
  const std::optional<ItemID> onboarding_tab = PageTabId();
  std::string welcome_tab_id;
  const std::string handoff = HandOff(profile, replay, &welcome_tab_id);
  if (!s->onboarding_completed()) {
    s->MarkOnboardingCompleted();
  }
  s->ScheduleSave();

  ReplyOk(std::move(reply), base::DictValue()
                                .Set("ok", true)
                                .Set("replay", replay)
                                .Set("welcome_url", OpenWebUIURL(kHostWelcome))
                                .Set("handoff", handoff)
                                .Set("welcome_tab_id", welcome_tab_id)
                                .Set("favorites_added", favorites_added)
                                .Set("import", counts.ToValue()));

  // OpenBrowserService observers (OpenWindowController) and open:// pages.
  s->BroadcastEvent(onboarding_rpc::kEventOnboardingCompleted,
                    base::Value(base::DictValue()
                                    .Set("handoff", handoff)
                                    .Set("replay", replay)
                                    .Set("welcome_tab_id", welcome_tab_id)
                                    .Set("onboarding_tab_id",
                                         onboarding_tab.value_or(ItemID()))));
}

std::string OpenOnboardingUI::HandOff(const ProfileID& profile,
                                      bool replay,
                                      std::string* welcome_tab_id) {
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s->tab_bridge();
  BrowserModel& model = s->model();
  if (!bridge) {
    return "none";
  }
  const std::optional<ItemID> self = PageTabId();
  std::optional<SpaceID> space =
      self ? model_util::SpaceOfNode(model, *self) : std::nullopt;
  if (!space) {
    space = TargetSpace(model, profile);
  }
  if (!space) {
    return "none";
  }
  const GURL welcome(OpenWebUIURL(kHostWelcome));

  // 1. A Welcome tab exists: select it; the onboarding tab goes away.
  if (std::optional<ItemID> existing = FindWelcomeTab(model, *space, self)) {
    *welcome_tab_id = *existing;
    bridge->SelectNode(*existing);
    if (self) {
      // After the reply: closing destroys this page.
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(
                         [](ItemID tab) {
                           OpenBrowserService* service =
                               OpenBrowserService::Get();
                           if (service && service->tab_bridge() &&
                               service->model().FindTab(tab)) {
                             service->tab_bridge()->CloseNode(tab);
                           }
                         },
                         *self));
    }
    return "selected_existing";
  }

  // 2. The onboarding tab becomes the Welcome tab at Today index 0.
  if (self) {
    *welcome_tab_id = *self;
    std::optional<NodeParent> parent = model.GetParent(*self);
    const NodeParent today{NodeParentKind::kSpaceToday, *space};
    if (parent && parent->kind == NodeParentKind::kSpaceToday) {
      std::optional<NodeIndexEntry> entry = model.GetIndexEntry(*self);
      if (!(parent->owner_id == *space && entry && entry->index == 0)) {
        model.MoveNode(*self, today, 0);
      }
    }
    // After the reply reaches the page.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](ItemID tab, GURL url) {
                         OpenBrowserService* service =
                             OpenBrowserService::Get();
                         if (service && service->tab_bridge()) {
                           service->tab_bridge()->Navigate(tab, url);
                           service->tab_bridge()->SelectNode(tab);
                         }
                       },
                       *self, welcome));
    return "navigated";
  }

  // 3. Not a sidebar tab (a dedicated window): open one in the Space.
  const ItemID id = bridge->OpenTabInSpace(welcome, *space, false);
  *welcome_tab_id = id;
  return id.empty() ? "none" : "opened";
}

// --- onboarding.prefetchFavicons
// ---------------------------------------------------

void OpenOnboardingUI::PrefetchFavicons(const base::DictValue& payload,
                                        Reply reply) {
  auto job = std::make_shared<FaviconJob>();
  job->reply = std::move(reply);
  if (const base::ListValue* urls = payload.FindList("urls")) {
    for (const base::Value& value : *urls) {
      if (job->urls.size() >= kMaxFaviconUrls || !value.is_string()) {
        continue;
      }
      const GURL url(value.GetString());
      if (url.is_valid() && url.SchemeIsHTTPOrHTTPS()) {
        job->urls.push_back(url);
      }
    }
  }
  job->results.resize(job->urls.size());
  job->pending = job->urls.size();
  if (job->urls.empty()) {
    ReplyOk(std::move(job->reply),
            base::DictValue().Set("icons", base::ListValue()));
    return;
  }
  for (size_t i = 0; i < job->urls.size(); ++i) {
    PrefetchOne(job, i);
  }
}

void OpenOnboardingUI::PrefetchOne(std::shared_ptr<FaviconJob> job,
                                   size_t index) {
  ProfileServices* ps =
      service() ? service()->ProfileServicesFor(profile_id()) : nullptr;
  if (!ps) {
    OnStoreIcon(std::move(job), index, std::nullopt);
    return;
  }
  const GURL& url = job->urls[index];
  RunOnStore(
      ps->favicons,
      base::BindOnce(
          [](std::string page, std::string origin,
             FaviconStore* store) -> std::optional<std::vector<uint8_t>> {
            for (const std::string& key : {page, origin}) {
              std::optional<FaviconRecord> record = store->Get(key);
              if (!record || record->status != 0) {
                continue;
              }
              if (!record->png64.empty()) {
                return record->png64;
              }
              if (!record->png32.empty()) {
                return record->png32;
              }
            }
            return std::nullopt;
          },
          url.spec(), url.DeprecatedGetOriginAsURL().spec()),
      base::BindOnce(
          [](base::WeakPtr<OpenOnboardingUI> page,
             std::shared_ptr<FaviconJob> job, size_t index,
             std::optional<std::vector<uint8_t>> png) {
            if (!page) {
              return;
            }
            if (png && !png->empty()) {
              const GURL& page_url = job->urls[index];
              CachePrefetchedFavicon(page_url, *png);
              if (OpenBrowserService* s = page->service()) {
                ApplyFaviconToExistingFavorites(s->model(), page->profile_id(),
                                                page_url, *png);
              }
              page->OnStoreIcon(std::move(job), index, PngDataUrl(*png));
              return;
            }
            page->OnStoreIcon(std::move(job), index, std::nullopt);
          },
          weak_factory_.GetWeakPtr(), job, index));
}

void OpenOnboardingUI::OnStoreIcon(std::shared_ptr<FaviconJob> job,
                                   size_t index,
                                   std::optional<std::string> data_url) {
  if (data_url) {
    FinishFavicon(
        std::move(job), index,
        base::DictValue().Set("icon", *data_url).Set("source", "open-store"));
    return;
  }
  QueryLargeIcon(std::move(job), index, /*after_server=*/false);
}

void OpenOnboardingUI::QueryLargeIcon(std::shared_ptr<FaviconJob> job,
                                      size_t index,
                                      bool after_server) {
  ::Profile* chrome_profile = profile();
  favicon::LargeIconService* icons =
      chrome_profile
          ? LargeIconServiceFactory::GetForBrowserContext(chrome_profile)
          : nullptr;
  if (!icons) {
    FinishFavicon(std::move(job), index, base::DictValue());
    return;
  }
  const GURL url = job->urls[index];
  icons->GetLargeIconRawBitmapOrFallbackStyleForPageUrl(
      url, kFaviconMinSourcePx, kFaviconDesiredPx,
      base::BindOnce(
          [](base::WeakPtr<OpenOnboardingUI> page,
             std::shared_ptr<FaviconJob> job, size_t index, bool after_server,
             const favicon_base::LargeIconResult& result) {
            if (result.bitmap.is_valid()) {
              const base::span<const uint8_t> span(*result.bitmap.bitmap_data);
              std::vector<uint8_t> png(span.begin(), span.end());
              const GURL& page_url = job->urls[index];
              if (!png.empty()) {
                CachePrefetchedFavicon(page_url, png);
                if (page) {
                  if (OpenBrowserService* s = page->service()) {
                    const ProfileID pid = page->profile_id();
                    if (ProfileServices* ps = s->ProfileServicesFor(pid)) {
                      std::optional<std::string> icon_url =
                          result.bitmap.icon_url.is_valid()
                              ? std::optional<std::string>(
                                    result.bitmap.icon_url.spec())
                              : std::nullopt;
                      RunOnStore(
                          ps->favicons,
                          base::BindOnce(
                              [](std::string url,
                                 std::vector<uint8_t> png_bytes,
                                 std::optional<std::string> icon_url,
                                 FaviconStore* store) {
                                store->Put(url, png_bytes, {}, icon_url);
                              },
                              page_url.spec(), png, std::move(icon_url)));
                    }
                    ApplyFaviconToExistingFavorites(s->model(), pid, page_url,
                                                    png);
                  }
                }
              }
              FinishFavicon(
                  std::move(job), index,
                  base::DictValue()
                      .Set("icon", PngDataUrl(span))
                      .Set("source", after_server ? "server" : "history")
                      .Set("pixel_size", result.bitmap.pixel_size.width()));
              return;
            }
            const GURL& url = job->urls[index];
            if (!after_server && page && IsCuratedFaviconHost(url.host())) {
              favicon::LargeIconService* icons =
                  page->profile()
                      ? LargeIconServiceFactory::GetForBrowserContext(
                            page->profile())
                      : nullptr;
              if (icons) {
                icons
                    ->GetLargeIconOrFallbackStyleFromGoogleServerSkippingLocalCache(
                        url, /*should_trim_page_url_path=*/true,
                        kFaviconTrafficAnnotation,
                        base::BindOnce(
                            [](base::WeakPtr<OpenOnboardingUI> page,
                               std::shared_ptr<FaviconJob> job, size_t index,
                               favicon_base::GoogleFaviconServerRequestStatus
                                   status) {
                              if (page &&
                                  status ==
                                      favicon_base::
                                          GoogleFaviconServerRequestStatus::
                                              SUCCESS) {
                                page->QueryLargeIcon(std::move(job), index,
                                                     /*after_server=*/true);
                                return;
                              }
                              FinishFavicon(std::move(job), index,
                                            base::DictValue());
                            },
                            page, job, index));
                return;
              }
            }
            base::DictValue fallback;
            if (result.fallback_icon_style &&
                !result.fallback_icon_style->is_default_background_color) {
              fallback.Set(
                  "fallback_color",
                  ColorHex(result.fallback_icon_style->background_color));
            }
            FinishFavicon(std::move(job), index, std::move(fallback));
          },
          weak_factory_.GetWeakPtr(), job, index, after_server),
      &favicon_tracker_);
}

// static
void OpenOnboardingUI::FinishFavicon(std::shared_ptr<FaviconJob> job,
                                     size_t index,
                                     base::DictValue result) {
  result.Set("page_url", job->urls[index].spec());
  job->results[index] = std::move(result);
  if (--job->pending > 0 || !job->reply) {
    return;
  }
  base::ListValue icons;
  for (base::DictValue& icon : job->results) {
    icons.Append(std::move(icon));
  }
  ReplyOk(std::move(job->reply),
          base::DictValue().Set("icons", std::move(icons)));
}

// --- welcome.*
// -----------------------------------------------------------------------

void OpenOnboardingUI::WelcomeGetState(const base::DictValue& payload,
                                       Reply reply) {
  StateFileRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](base::FilePath path) { return DoneSteps(ReadJsonDict(path)); },
          StateFilePath(kWelcomeChecklistFile)),
      base::BindOnce(
          [](base::WeakPtr<OpenOnboardingUI> page, Reply reply,
             std::vector<std::string> done) {
            OpenBrowserService* s = OpenBrowserService::Get();
            if (!page || !s) {
              ReplyError(std::move(reply), "shutting down");
              return;
            }
            BrowserModel& model = s->model();
            const ProfileID profile = page->profile_id();
            std::optional<SpaceID> space_id;
            if (std::optional<ItemID> self = page->PageTabId()) {
              space_id = model_util::SpaceOfNode(model, *self);
            }
            if (!space_id) {
              space_id = TargetSpace(model, profile);
            }
            base::DictValue space;
            if (const Space* sp =
                    space_id ? model.FindSpace(*space_id) : nullptr) {
              space.Set("id", sp->id);
              space.Set("title", sp->title.value_or(std::string()));
              space.Set("style", json::SpaceStyleToValue(
                                     sp->theme.style.value_or(SpaceStyle())));
              if (sp->theme.accent) {
                space.Set("accent", json::ColorToValue(*sp->theme.accent));
              }
            }
            const base::Value name =
                OpenPreferences::Get()->GetValue("general.userName");
            const int done_count = static_cast<int>(done.size());
            ReplyOk(
                std::move(reply),
                base::DictValue()
                    .Set("user_name", name.is_string() ? name.GetString() : "")
                    .Set("steps", StepsValue(done))
                    .Set("done_count", done_count)
                    .Set("total", static_cast<int>(std::size(kWelcomeSteps)))
                    .Set("shortcuts", EssentialShortcutsValue(s->commands()))
                    .Set("space", std::move(space))
                    .Set("platform", PlatformName())
                    .Set("onboarding_completed", s->onboarding_completed()));
          },
          weak_factory_.GetWeakPtr(), std::move(reply)));
}

void OpenOnboardingUI::MarkStepDone(const base::DictValue& payload,
                                    Reply reply) {
  const std::string step = json::GetString(payload, "step");
  if (!IsWelcomeStep(step)) {
    ReplyError(std::move(reply), "unknown step");
    return;
  }
  StateFileRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&UpdateChecklist, StateFilePath(kWelcomeChecklistFile),
                     step, json::GetBool(payload, "done", true)),
      base::BindOnce(
          [](Reply reply, std::vector<std::string> done) {
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("steps", StepsValue(done))
                        .Set("done_count", static_cast<int>(done.size())));
          },
          std::move(reply)));
}

void OpenOnboardingUI::TriggerWelcomeAction(const base::DictValue& payload,
                                            Reply reply) {
  const std::string action = json::GetString(payload, "action");
  OpenBrowserService* s = service();
  OpenTabBridge* bridge = s->tab_bridge();
  OpenWindowController* windows = s->window_controller();
  OpenWindowUi* ui = PageWindowUi();
  if (!bridge) {
    ReplyError(std::move(reply), "no browser window");
    return;
  }
  auto open_page = [&](std::string_view host, std::string_view path) {
    if (ui) {
      bridge->OpenTab(GURL(OpenWebUIURL(host, path)), /*background=*/false,
                      ui->window_id());
    } else {
      bridge->OpenTab(GURL(OpenWebUIURL(host, path)), /*background=*/false);
    }
  };
  auto fail = [&](std::string message) {
    ReplyOk(std::move(reply),
            base::DictValue().Set("ok", false).Set("message", message));
  };

  if (action == "open-command-bar" || action == "new_tab") {
    if (!ui) {
      return fail("Open a browser window first.");
    }
    ui->ActivateWindow();
    ui->ShowCommandBar(CommandBarMode::kNewTab, std::u16string(), std::nullopt);
  } else if (action == "toggle-sidebar") {
    if (!ui || !windows) {
      return fail("Open a browser window first.");
    }
    windows->HandleIntent(ui->window_id(),
                          OpenIntent::Of(OpenIntentKind::kToggleSidebar));
  } else if (action == "edit-theme") {
    std::optional<SpaceID> space;
    if (std::optional<ItemID> self = PageTabId()) {
      space = model_util::SpaceOfNode(s->model(), *self);
    }
    if (!space && ui) {
      space = model_util::FocusedSpace(s->model(), ui->window_id());
    }
    if (!ui || !windows || !space) {
      return fail("Open a Space first.");
    }
    windows->HandleIntent(
        ui->window_id(),
        OpenIntent::ForSpace(OpenIntentKind::kEditSpaceTheme, *space));
  } else if (action == "view-library") {
    if (!ui || !windows) {
      open_page(kHostLibrary, "");
    } else {
      windows->HandleIntent(ui->window_id(),
                            OpenIntent::Of(OpenIntentKind::kShowLibrary));
    }
  } else if (action == "peek") {
    if (!ui) {
      return fail("Open a browser window first.");
    }
    ui->OpenPeek(GURL(kDemoPageUrl), PageTabId());
  } else if (action == "split-view" || action == "split") {
    std::optional<ItemID> active =
        ui ? ui->ActiveTabId() : bridge->ActiveTabId();
    if (!active) {
      return fail("Open a tab first, then try Split View.");
    }
    if (!bridge->ToggleSplit(*active)) {
      // Nothing to split with yet: add a companion page, then split.
      if (ui) {
        bridge->OpenTab(GURL(kDemoPageUrl), /*background=*/true,
                        ui->window_id());
      } else {
        bridge->OpenTab(GURL(kDemoPageUrl), /*background=*/true);
      }
      if (!bridge->ToggleSplit(*active)) {
        return fail("Open another tab first to split with it.");
      }
    }
  } else if (action == "new-boost") {
    open_page(kHostBoosts, "new");
  } else if (action == "boost-gallery") {
    open_page(kHostBoosts, "");
  } else if (action == "settings") {
    if (windows) {
      windows->OpenSettingsWindow("");
    } else {
      open_page(kHostSettings, "");
    }
  } else if (action == "customize-shortcuts") {
    if (windows) {
      windows->OpenSettingsWindow("shortcuts");
    } else {
      open_page(kHostSettings, "shortcuts");
    }
  } else if (action == "import-from-browser") {
    if (windows) {
      windows->OpenSettingsWindow("import");
    } else {
      open_page(kHostSettings, "import");
    }
  } else if (action == "shortcuts" || action == "keyboard-shortcuts-edu") {
    open_page(kHostWelcome, "shortcuts");
  } else if (action == "help") {
    open_page(kHostWelcome, "help");
  } else if (action == "next-space") {
    if (!ui) {
      return fail("Open a browser window first.");
    }
    ui->RunCommand("next-space");
  } else if (action == "replay-onboarding") {
    open_page(kHostOnboarding, "");
  } else if (action == "replay_all") {
    // Replay All only restarts the Basics playlist (in the page). It never
    // reopens setup, so nothing is written again.
  } else {
    ReplyError(std::move(reply), "unknown action");
    return;
  }

  // Trying a feature checks it off the Welcome checklist.
  const std::string_view step = StepForAction(action);
  if (step.empty()) {
    ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
    return;
  }
  StateFileRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&UpdateChecklist, StateFilePath(kWelcomeChecklistFile),
                     std::string(step), true),
      base::BindOnce(
          [](Reply reply, std::vector<std::string> done) {
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("ok", true)
                        .Set("steps", StepsValue(done))
                        .Set("done_count", static_cast<int>(done.size())));
          },
          std::move(reply)));
}

}  // namespace open_unified::webui
