// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_library_ui.h"

#include <algorithm>
#include <utility>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/profiles/profile.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "base/time/time.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "url/gurl.h"

namespace open_unified::webui {

namespace {

constexpr int kDefaultLimit = 200;
constexpr int kMaxLimit = 2000;
constexpr size_t kMaxQueryBytes = 512;

std::string Query(const base::DictValue& payload) {
  std::string query = json::GetString(payload, "query");
  if (query.size() > kMaxQueryBytes) {
    query.resize(kMaxQueryBytes);
  }
  return query;
}

int Limit(const base::DictValue& payload) {
  return std::clamp(json::GetInt(payload, "limit", kDefaultLimit), 1,
                    kMaxLimit);
}

ProfileServices* ServicesFor(const ProfileID& id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service ? service->ProfileServicesFor(id) : nullptr;
}

std::string SpaceTitle(const std::optional<SpaceID>& id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  const Space* space =
      id && service ? service->model().FindSpace(*id) : nullptr;
  return space ? space->title.value_or(std::string()) : std::string();
}

int CountTabs(const std::vector<SidebarNode>& nodes) {
  int count = 0;
  for (const SidebarNode& node : nodes) {
    if (node.as_tab()) {
      ++count;
    } else if (const Folder* folder = node.as_folder()) {
      count += CountTabs(folder->children);
    } else if (const Split* split = node.as_split()) {
      count += static_cast<int>(split->panes.size());
    }
  }
  return count;
}

}  // namespace

OpenLibraryUI::OpenLibraryUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenLibraryUI::~OpenLibraryUI() = default;

void OpenLibraryUI::RegisterMethods() {
  auto bind = [this](void (OpenLibraryUI::*method)(const base::DictValue&,
                                                   Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  Register(kLibraryGetHistory, bind(&OpenLibraryUI::GetHistory));
  Register(kLibraryDeleteHistory, bind(&OpenLibraryUI::DeleteHistory));
  Register(kLibraryGetArchive, bind(&OpenLibraryUI::GetArchive));
  Register(kLibraryRestoreArchived, bind(&OpenLibraryUI::RestoreArchived));
  Register(kLibraryGetDownloads, bind(&OpenLibraryUI::GetDownloads));
  Register(kLibraryOpenDownload, bind(&OpenLibraryUI::OpenDownload));
  Register(kLibraryGetSpaces, bind(&OpenLibraryUI::GetSpaces));
  Register(kLibraryUpdateSpace, bind(&OpenLibraryUI::UpdateSpace));
  Register(kLibraryDeleteSpace, bind(&OpenLibraryUI::DeleteSpace));
  Register(kLibraryGetMedia, bind(&OpenLibraryUI::GetMedia));
  Register(kLibraryGetEasels, bind(&OpenLibraryUI::GetEasels));
  Register(kLibraryOpenUrl, bind(&OpenLibraryUI::OpenUrl));
}

// --- History -----------------------------------------------------------------

void OpenLibraryUI::GetHistory(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = ServicesFor(profile);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  RunOnStore(
      ps->history,
      base::BindOnce(
          [](std::string query, int limit, HistoryStore* store) {
            return query.empty() ? store->Recent(limit)
                                 : store->Search(query, limit);
          },
          Query(payload), Limit(payload)),
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             std::vector<HistoryEntry> entries) {
            base::ListValue list;
            for (const HistoryEntry& entry : entries) {
              list.Append(json::HistoryEntryToValue(entry, profile));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("entries", std::move(list)));
          },
          profile, std::move(reply)));
}

void OpenLibraryUI::DeleteHistory(const base::DictValue& payload,
                                  Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  auto done = base::BindOnce(
      [](Reply reply, int64_t remaining) {
        // Deleted pages leave the command bar's history rows too.
        if (OpenBrowserService* service = OpenBrowserService::Get()) {
          service->RefreshRecentHistory();
        }
        ReplyOk(std::move(reply),
                base::DictValue()
                    .Set("ok", true)
                    .Set("remaining", static_cast<double>(remaining)));
      },
      std::move(reply));
  if (json::GetBool(payload, "clear_all", false)) {
    RunOnStore(ps->history,
               base::BindOnce(
                   [](TimestampSec now, HistoryStore* store) {
                     store->ClearRange(std::nullopt, now);
                     return store->UrlCount();
                   },
                   base::Time::Now().InSecondsFSinceUnixEpoch() + 1),
               std::move(done));
    return;
  }
  std::vector<int64_t> ids;
  if (const base::ListValue* list = payload.FindList("ids")) {
    for (const base::Value& id : *list) {
      if (id.is_int()) {
        ids.push_back(id.GetInt());
      } else if (id.is_double() && id.GetDouble() >= 0) {
        ids.push_back(static_cast<int64_t>(id.GetDouble()));
      }
    }
  }
  // One DELETE by entry id (the page sends HistoryEntry ids).
  RunOnStore(ps->history,
             base::BindOnce(
                 [](std::vector<int64_t> ids, HistoryStore* store) {
                   if (!ids.empty()) {
                     store->DeleteIds(ids);
                   }
                   return store->UrlCount();
                 },
                 std::move(ids)),
             std::move(done));
}

// --- Archive -----------------------------------------------------------------

void OpenLibraryUI::GetArchive(const base::DictValue& payload, Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  RunOnStore(
      ps->archive,
      base::BindOnce(
          [](std::string query, ArchiveStore* store) {
            return store->List(kMaxLimit, 0, query);
          },
          Query(payload)),
      base::BindOnce(
          [](Reply reply, std::vector<ArchivedTabRecord> records) {
            base::ListValue items;
            for (const ArchivedTabRecord& record : records) {
              items.Append(json::ArchivedTabToValue(
                  record, SpaceTitle(record.space_id)));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("items", std::move(items)));
          },
          std::move(reply)));
}

void OpenLibraryUI::RestoreArchived(const base::DictValue& payload,
                                    Reply reply) {
  const std::string id = json::GetString(payload, "id");
  // The row's Profile (Library lists every Profile's Archive).
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps || id.empty()) {
    ReplyError(std::move(reply), "no such item");
    return;
  }
  RunOnStore(
      ps->archive,
      base::BindOnce(
          [](std::string id, ArchiveStore* store) {
            return store->Restore(id);  // Removes the row.
          },
          id),
      base::BindOnce(
          [](Reply reply, std::optional<ArchivedTabRecord> record) {
            OpenBrowserService* service = OpenBrowserService::Get();
            if (!record || !service) {
              ReplyError(std::move(reply), "no such item");
              return;
            }
            // Back into Today of its Space (or the focused one), selected.
            const ItemID restored =
                service->model().RestoreArchivedTab(*record);
            if (restored.empty()) {
              ReplyError(std::move(reply), "cannot restore");
              return;
            }
            service->tab_bridge()->SelectNode(restored);
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("restored_url", record->url));
          },
          std::move(reply)));
}

// --- Downloads and Media -----------------------------------------------------

void OpenLibraryUI::GetDownloads(const base::DictValue& payload,
                                 Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = ServicesFor(profile);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  RunOnStore(
      ps->downloads,
      base::BindOnce([](DownloadHistoryStore* store) { return store->List(); }),
      base::BindOnce(
          [](ProfileID profile, std::string query, Reply reply,
             std::vector<DownloadRecord> records) {
            base::ListValue downloads;
            for (const DownloadRecord& record : records) {
              const std::string needle = base::ToLowerASCII(query);
              if (!needle.empty() &&
                  base::ToLowerASCII(record.filename).find(needle) ==
                      std::string::npos &&
                  base::ToLowerASCII(record.url).find(needle) ==
                      std::string::npos) {
                continue;
              }
              downloads.Append(json::DownloadToValue(record, profile));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("downloads", std::move(downloads)));
          },
          profile, Query(payload), std::move(reply)));
}

void OpenLibraryUI::OpenDownload(const base::DictValue& payload,
                                 Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const bool reveal = json::GetBool(payload, "reveal", false);
  // The download's Profile (Library lists every Profile's downloads).
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps || id.empty()) {
    ReplyError(std::move(reply), "no such download");
    return;
  }
  // Only a path the download store recorded may be opened; the page never
  // supplies a path.
  RunOnStore(
      ps->downloads,
      base::BindOnce([](DownloadHistoryStore* store) { return store->List(); }),
      base::BindOnce(
          [](std::string id, bool reveal, ProfileID profile, Reply reply,
             std::vector<DownloadRecord> records) {
            auto it = std::find_if(
                records.begin(), records.end(),
                [&](const DownloadRecord& r) { return r.id == id; });
            OpenBrowserService* service = OpenBrowserService::Get();
            ::Profile* chrome_profile =
                service ? service->ChromeProfileFor(profile) : nullptr;
            if (it == records.end() || it->state != "completed" ||
                !chrome_profile) {
              ReplyError(std::move(reply), "the file is not available");
              return;
            }
            const base::FilePath path =
                base::FilePath::FromUTF8Unsafe(it->target_path);
            if (reveal) {
              platform_util::ShowItemInFolder(chrome_profile, path);
            } else {
              platform_util::OpenItem(chrome_profile, path,
                                      platform_util::OPEN_FILE,
                                      platform_util::OpenOperationCallback());
            }
            ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
          },
          id, reveal, profile_id(), std::move(reply)));
}

void OpenLibraryUI::GetMedia(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = ServicesFor(profile);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  // Media = completed image and video downloads (Arc's Library Media).
  RunOnStore(
      ps->downloads,
      base::BindOnce([](DownloadHistoryStore* store) { return store->List(); }),
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             std::vector<DownloadRecord> records) {
            base::ListValue items;
            for (const DownloadRecord& record : records) {
              if (record.state != "completed" ||
                  !(base::StartsWith(record.mime_type, "image/") ||
                    base::StartsWith(record.mime_type, "video/"))) {
                continue;
              }
              items.Append(base::DictValue()
                               .Set("id", record.id)
                               .Set("title", record.filename)
                               .Set("source_url", record.url)
                               .Set("captured_at", record.ended_at)
                               .Set("width", 0)
                               .Set("height", 0)
                               .Set("preview_gradient", "")
                               .Set("profile_id", profile));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("items", std::move(items)));
          },
          profile, std::move(reply)));
}

// --- Spaces ------------------------------------------------------------------

// static
base::DictValue OpenLibraryUI::SpaceSummary(const Space& space) {
  const SpaceIcon icon =
      space.icon.value_or(SpaceIcon{SpaceIconKind::kNamed, "circle"});
  return base::DictValue()
      .Set("id", space.id)
      .Set("title", space.title.value_or(std::string()))
      .Set("icon", json::SpaceIconToValue(icon))
      .Set("profile_id", space.profile_id)
      .Set("style", json::SpaceStyleToValue(
                        space.theme.style.value_or(SpaceStyle())))
      .Set("pinned_count", CountTabs(space.pinned))
      .Set("today_count", CountTabs(space.today));
}

void OpenLibraryUI::GetSpaces(const base::DictValue& payload, Reply reply) {
  base::ListValue spaces;
  for (const Space& space : service()->model().spaces()) {
    spaces.Append(SpaceSummary(space));
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("spaces", std::move(spaces)));
}

void OpenLibraryUI::UpdateSpace(const base::DictValue& payload,
                                Reply reply) {
  const std::string id = json::GetString(payload, "id");
  std::optional<std::string> title = json::FindString(payload, "title");
  if (title && title->size() > 128) {
    ReplyError(std::move(reply), "the title is too long");
    return;
  }
  std::optional<SpaceIcon> icon =
      json::SpaceIconFromValue(payload.Find("icon"));
  std::optional<SpaceStyle> style;
  if (payload.Find("style")) {
    style = json::SpaceStyleFromValue(payload.Find("style"));
    if (!style) {
      ReplyError(std::move(reply), "invalid style");
      return;
    }
  }
  const Space* current = service()->model().FindSpace(id);
  if (!current) {
    ReplyError(std::move(reply), "no such space");
    return;
  }
  std::optional<SpaceTheme> theme;
  if (style) {
    theme = current->theme;
    theme->style = *style;
  }
  std::optional<std::optional<SpaceIcon>> new_icon;
  if (icon) {
    new_icon = icon;
  }
  const bool updated =
      service()->model().UpdateSpace(id, title, new_icon, std::move(theme));
  const Space* space = service()->model().FindSpace(id);
  if (!updated || !space) {
    ReplyError(std::move(reply), "no such space");
    return;
  }
  ReplyOk(std::move(reply), base::DictValue().Set("space",
                                                    SpaceSummary(*space)));
}

void OpenLibraryUI::DeleteSpace(const base::DictValue& payload,
                                Reply reply) {
  const std::string id = json::GetString(payload, "id");
  if (service()->model().spaces().size() <= 1) {
    ReplyError(std::move(reply), "the last space cannot be deleted");
    return;
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("ok", service()->model().DeleteSpace(id)));
}

// --- Easels ------------------------------------------------------------------

void OpenLibraryUI::GetEasels(const base::DictValue& payload, Reply reply) {
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = ServicesFor(profile);
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  RunOnStore(
      ps->documents,
      base::BindOnce(
          [](std::string query, DocumentStore* store) {
            return store->ListEasels(std::string_view(query));
          },
          Query(payload)),
      base::BindOnce(
          [](ProfileID profile, Reply reply,
             std::vector<EaselDocument> easels) {
            base::ListValue list;
            for (const EaselDocument& easel : easels) {
              list.Append(
                  base::DictValue()
                      .Set("id", easel.id)
                      .Set("title", easel.title)
                      .Set("element_count",
                           static_cast<int>(easel.elements.size()))
                      .Set("palette", easel.palette)
                      .Set("modified_at", easel.modified_at)
                      .Set("profile_id", profile));
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("easels", std::move(list)));
          },
          profile, std::move(reply)));
}

// --- Navigation --------------------------------------------------------------

void OpenLibraryUI::OpenUrl(const base::DictValue& payload, Reply reply) {
  const GURL url(json::GetString(payload, "url"));
  // Web pages and Open's own pages only (no file:, javascript:, chrome:).
  if (!url.is_valid() ||
      !(url.SchemeIsHTTPOrHTTPS() || url.SchemeIs(kOpenScheme))) {
    ReplyError(std::move(reply), "only http(s) and open:// URLs can be opened");
    return;
  }
  OpenTabBridge* bridge = service()->tab_bridge();
  if (json::GetBool(payload, "new_tab", true)) {
    bridge->OpenTab(url, /*background=*/false);
  } else if (std::optional<ItemID> active = bridge->ActiveTabId()) {
    bridge->Navigate(*active, url);
  } else {
    bridge->OpenTab(url, /*background=*/false);
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

}  // namespace open_unified::webui
