// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_onboarding_ui.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "open/adblock/open_adblock_service.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/browser/platform/open_platform.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/core/import/browser_importer.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "open_unified/ui/views/open_command_bar_view.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

constexpr size_t kMaxFavorites = 12;
constexpr size_t kMaxImportedBookmarks = 2000;
constexpr size_t kMaxImportedHistory = 50000;
constexpr size_t kMaxNameBytes = 64;

bool IsKnownImportKind(const std::string& kind) {
  return kind == "bookmarks" || kind == "history" || kind == "favorites" ||
         kind == "extensions" || kind == "passwords";
}

// The main window's Track 5 coordinator (owns its Command Bar).
OpenWindowUi* MainWindowUi() {
  OpenBrowserService* service = OpenBrowserService::Get();
  OpenWindowController* windows =
      service ? service->window_controller() : nullptr;
  return windows ? windows->MainWindowUi() : nullptr;
}

}  // namespace

OpenOnboardingUI::OpenOnboardingUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenOnboardingUI::~OpenOnboardingUI() = default;

void OpenOnboardingUI::RegisterMethods() {
  auto bind = [this](void (OpenOnboardingUI::*method)(const base::DictValue&,
                                                      Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kOnboardingGetState, bind(&OpenOnboardingUI::GetState));
  Register(kOnboardingComplete, bind(&OpenOnboardingUI::Complete));
  Register(kImportProbeBrowsers, bind(&OpenOnboardingUI::ProbeBrowsers));
  Register(kImportRun, bind(&OpenOnboardingUI::RunImport));
  Register(kWelcomeTriggerAction,
           bind(&OpenOnboardingUI::TriggerWelcomeAction));
}

void OpenOnboardingUI::GetState(const base::DictValue& payload,
                                Reply reply) {
  const ProfileID profile = profile_id();
  // The first Space's style is the default the theme step starts from.
  SpaceStyle style;
  for (const Space& space : service()->model().spaces()) {
    if (space.profile_id == profile && space.theme.style) {
      style = *space.theme.style;
      break;
    }
  }
  ProfileServices* ps = service()->ProfileServicesFor(profile);
  OpenAdBlockProfileService* adblock = ps ? ps->adblock() : nullptr;
  OpenPlatform* platform = OpenPlatform::Get();
  ReplyOk(std::move(reply),
          base::DictValue()
              .Set("completed", service()->onboarding_completed())
              .Set("default_space_style", json::SpaceStyleToValue(style))
              .Set("is_default_browser",
                   platform && platform->IsDefaultBrowser())
              .Set("adblock_enabled", adblock && adblock->service() &&
                                          adblock->service()->IsEnabled()));
}

void OpenOnboardingUI::Complete(const base::DictValue& payload,
                                Reply reply) {
  OpenBrowserService* s = service();
  const ProfileID profile = profile_id();
  BrowserModel& model = s->model();

  std::optional<SpaceStyle> style =
      json::SpaceStyleFromValue(payload.Find("space_style"));
  if (payload.Find("space_style") && !style) {
    ReplyError(std::move(reply), "invalid space style");
    return;
  }

  // Name: stored as an app preference (shown on open://welcome).
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

  // Theme of the Profile's first Space.
  if (style) {
    for (const Space& space : model.spaces()) {
      if (space.profile_id == profile) {
        SpaceTheme theme = space.theme;
        theme.style = *style;
        model.UpdateSpace(space.id, std::nullopt, std::nullopt, theme);
        break;
      }
    }
  }

  // Favorites chosen on the favorites step (http(s) only, at most 12).
  if (const base::ListValue* urls = payload.FindList("favorite_urls")) {
    const Profile* p = model.FindProfile(profile);
    size_t index = p ? p->favorites.size() : 0;
    size_t added = 0;
    for (const base::Value& value : *urls) {
      if (!value.is_string() || added >= kMaxFavorites) {
        continue;
      }
      const GURL url(value.GetString());
      if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
        continue;
      }
      // A Favorite starts as a tab, then moves to the Profile's Favorites.
      std::optional<SpaceID> space = model_util::FocusedSpace(model, {});
      const ItemID id =
          space ? model.NewTab(*space, url.spec(), std::string(url.host()))
                : ItemID();
      if (!id.empty() && model.AddFavorite(id, profile, index)) {
        ++index;
        ++added;
      }
    }
  }

  // Ad blocking choice (every Profile; one master switch).
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
    base::ThreadPool::PostTask(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
        base::BindOnce([] {
          if (OpenPlatform* platform = OpenPlatform::Get();
              platform && !platform->IsDefaultBrowser()) {
            platform->SetDefaultBrowser();
          }
        }));
  }

  s->MarkOnboardingCompleted();
  s->ScheduleSave();
  ReplyOk(std::move(reply),
          base::DictValue()
              .Set("ok", true)
              .Set("welcome_url", OpenWebUIURL(kHostWelcome)));
}

void OpenOnboardingUI::ProbeBrowsers(const base::DictValue& payload,
                                     Reply reply) {
  // Reads other browsers' profile folders: blocking file I/O.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&BrowserImporter::ProbeInstalledBrowsers),
      base::BindOnce(
          [](Reply reply, std::vector<DetectedBrowser> browsers) {
            base::ListValue list;
            for (const DetectedBrowser& browser : browsers) {
              // Arc imports whole sidebars (Spaces, Profiles), a separate
              // flow; onboarding imports bookmarks and history.
              if (browser.family == BrowserFamily::kArc) {
                continue;
              }
              for (const DetectedBrowserProfile& profile : browser.profiles) {
                // Cheap counts from the probe (bookmark URLs, history
                // URLs); the rest is not imported by onboarding.
                list.Append(base::DictValue()
                                .Set("id", browser.id + "/" + profile.id)
                                .Set("browser_name", browser.name)
                                .Set("profile_name", profile.name)
                                .Set("bookmarks_count", profile.bookmark_count)
                                .Set("history_count", profile.history_count)
                                .Set("extensions_count", 0)
                                .Set("passwords_count", 0)
                                .Set("favorites_count", 0));
              }
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("sources", std::move(list)));
          },
          std::move(reply)));
}

void OpenOnboardingUI::RunImport(const base::DictValue& payload,
                                 Reply reply) {
  const std::string source_id = json::GetString(payload, "source_id");
  std::vector<std::string> kinds;
  if (const base::ListValue* list = payload.FindList("kinds")) {
    for (const base::Value& kind : *list) {
      if (kind.is_string() && IsKnownImportKind(kind.GetString())) {
        kinds.push_back(kind.GetString());
      }
    }
  }
  if (source_id.empty() || source_id.size() > 256 || kinds.empty()) {
    ReplyError(std::move(reply), "choose a browser and what to import");
    return;
  }
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", source_id)
                                             .Set("phase", "reading")));
  const ProfileID profile = profile_id();
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&ReadImportData, source_id, kinds),
      base::BindOnce(&OpenOnboardingUI::ApplyImport,
                     weak_factory_.GetWeakPtr(), source_id, profile,
                     std::move(reply)));
}

// static
OpenOnboardingUI::ImportData OpenOnboardingUI::ReadImportData(
    std::string source_id,
    std::vector<std::string> kinds) {
  ImportData data;
  const size_t slash = source_id.find('/');
  if (slash == std::string::npos) {
    data.error = "unknown browser";
    return data;
  }
  const std::string browser_id = source_id.substr(0, slash);
  const std::string profile_id = source_id.substr(slash + 1);
  for (const DetectedBrowser& browser :
       BrowserImporter::ProbeInstalledBrowsers()) {
    if (browser.id != browser_id || browser.family == BrowserFamily::kArc) {
      continue;
    }
    for (const DetectedBrowserProfile& profile : browser.profiles) {
      if (profile.id != profile_id) {
        continue;
      }
      data.browser_name = browser.name;
      const bool firefox = browser.family == BrowserFamily::kFirefox;
      auto wants = [&](const char* kind) {
        return std::find(kinds.begin(), kinds.end(), kind) != kinds.end();
      };
      if (wants("bookmarks") || wants("favorites")) {
        std::vector<ImportedBookmarkNode> roots;
        const bool ok =
            firefox ? BrowserImporter::ReadFirefoxBookmarks(profile.directory,
                                                            &roots)
                    : BrowserImporter::ReadChromiumBookmarks(profile.directory,
                                                             &roots);
        if (ok) {
          data.bookmarks = BrowserImporter::BuildImportedBookmarksFolder(
              browser.name, source_id, roots);
        }
      }
      if (wants("history")) {
        auto on_batch = base::BindRepeating(
            [](std::vector<HistoryEntry>* out,
               const std::vector<HistoryEntry>& batch) {
              if (out->size() < kMaxImportedHistory) {
                out->insert(out->end(), batch.begin(), batch.end());
              }
            },
            base::Unretained(&data.history));
        if (firefox) {
          BrowserImporter::ReadFirefoxHistory(profile.directory, on_batch);
        } else {
          BrowserImporter::ReadChromiumHistory(profile.directory, on_batch);
        }
        if (data.history.size() > kMaxImportedHistory) {
          data.history.resize(kMaxImportedHistory);
        }
      }
      return data;
    }
  }
  data.error = "that browser profile was not found";
  return data;
}

void OpenOnboardingUI::ApplyImport(std::string source_id,
                                   ProfileID profile,
                                   Reply reply,
                                   ImportData data) {
  OpenBrowserService* s = service();
  if (!s) {
    ReplyError(std::move(reply), "shutting down");
    return;
  }
  if (!data.error.empty()) {
    ReplyError(std::move(reply), data.error);
    return;
  }
  BrowserModel& model = s->model();
  SpaceID space_id;
  for (const Space& space : model.spaces()) {
    if (space.profile_id == profile) {
      space_id = space.id;
      break;
    }
  }
  // Bookmarks: one pinned "Imported from <browser>" folder holding the
  // bookmark tabs (nested folders flattened; capped).
  int bookmarks = 0;
  if (data.bookmarks && !space_id.empty()) {
    std::vector<ItemID> ids;
    std::vector<const Tab*> tabs;
    CollectTabs(data.bookmarks->children, &tabs);
    for (const Tab* tab : tabs) {
      if (ids.size() >= kMaxImportedBookmarks) {
        break;
      }
      const ItemID id = model.NewTab(space_id, tab->url, tab->title);
      if (!id.empty() && model.PinTab(id)) {
        ids.push_back(id);
      }
    }
    if (!ids.empty()) {
      model.CreateFolder(NodeParent{NodeParentKind::kSpacePinned, space_id},
                         data.bookmarks->title, std::nullopt, ids);
    }
    bookmarks = static_cast<int>(ids.size());
  }
  const int history = static_cast<int>(data.history.size());
  if (ProfileServices* ps = s->ProfileServicesFor(profile); ps && history) {
    RunOnStore(ps->history,
               base::BindOnce(
                   [](std::vector<HistoryEntry> entries, HistoryStore* store) {
                     for (const HistoryEntry& entry : entries) {
                       store->RecordVisit(entry.url, entry.title,
                                          entry.last_visit, "imported",
                                          entry.typed_count > 0);
                     }
                     return true;
                   },
                   std::move(data.history)),
               // Imported pages show up in the command bar at once.
               base::BindOnce([](bool) {
                 if (OpenBrowserService* service = OpenBrowserService::Get()) {
                   service->RefreshRecentHistory();
                 }
               }));
  }
  Emit(kEventImportProgress, base::Value(base::DictValue()
                                             .Set("source_id", source_id)
                                             .Set("phase", "done")));
  ReplyOk(std::move(reply), base::DictValue()
                                .Set("ok", true)
                                .Set("imported_bookmarks", bookmarks)
                                .Set("imported_history", history)
                                .Set("imported_favorites", 0));
}

// static
void OpenOnboardingUI::CollectTabs(const std::vector<SidebarNode>& nodes,
                                   std::vector<const Tab*>* out) {
  for (const SidebarNode& node : nodes) {
    if (const Tab* tab = node.as_tab()) {
      out->push_back(tab);
    } else if (const Folder* folder = node.as_folder()) {
      CollectTabs(folder->children, out);
    }
  }
}

void OpenOnboardingUI::TriggerWelcomeAction(const base::DictValue& payload,
                                            Reply reply) {
  const std::string action = json::GetString(payload, "action");
  OpenTabBridge* bridge = service()->tab_bridge();
  if (action == "new_tab") {
    if (OpenWindowUi* ui = MainWindowUi()) {
      ui->ShowCommandBar(CommandBarMode::kNewTab, std::u16string(),
                         std::nullopt);
    }
  } else if (action == "split") {
    std::optional<ItemID> active = bridge->ActiveTabId();
    if (!active || !bridge->ToggleSplit(*active)) {
      ReplyOk(std::move(reply),
              base::DictValue()
                  .Set("ok", false)
                  .Set("message", "Open another tab first to split with it."));
      return;
    }
  } else if (action == "shortcuts") {
    bridge->OpenTab(GURL(OpenWebUIURL(kHostSettings, "shortcuts")),
                    /*background=*/false);
  } else if (action == "help") {
    bridge->OpenTab(GURL(OpenWebUIURL(kHostWelcome, "help")),
                    /*background=*/false);
  } else if (action == "replay_all") {
    bridge->OpenTab(GURL(OpenWebUIURL(kHostOnboarding)), /*background=*/false);
  } else {
    ReplyError(std::move(reply), "unknown action");
    return;
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

}  // namespace open_unified::webui
