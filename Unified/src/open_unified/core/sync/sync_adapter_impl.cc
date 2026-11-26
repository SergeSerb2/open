// Copyright 2026 The Open Authors. All rights reserved.
// Complete 16-collection SyncStorageAdapterImpl implementation.

#include "open_unified/core/sync/sync_adapter_impl.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

#include "base/containers/span.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/string_view_util.h"
#include "base/time/time.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/commands/command_registry.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/model/browser_model.h"
#include "open_unified/core/model/uuid_util.h"
#include "open_unified/core/store/sqlite_stores.h"

namespace open_unified {

namespace {

constexpr int kMaxBackupRetention = 3;
constexpr size_t kMaxWorkspaceNodes = 10000;
constexpr int kMaxWorkspaceDepth = 32;
constexpr size_t kMaxProfileDirLength = 64;
constexpr size_t kMaxPrefsFileBytes = 4 * 1024 * 1024;
constexpr size_t kMaxAdBlockConfigBytes = 4 * 1024 * 1024;

bool BundleHasCollection(const SyncRemoteBundle& bundle,
                         SyncCollection collection) {
  for (const auto& rec : bundle.records) {
    if (rec.collection == collection) {
      return true;
    }
  }
  return false;
}

std::vector<const SyncRemoteRecord*> RecordsInCollection(
    const SyncRemoteBundle& bundle,
    SyncCollection collection) {
  std::vector<const SyncRemoteRecord*> out;
  for (const auto& rec : bundle.records) {
    if (rec.collection == collection) {
      out.push_back(&rec);
    }
  }
  return out;
}

const char* PriorityToString(ShortcutPriority p) {
  switch (p) {
    case ShortcutPriority::kBrowser:
      return "browser";
    case ShortcutPriority::kSite:
      return "site";
    case ShortcutPriority::kSiteThenBrowser:
      return "site-then-browser";
  }
  return "browser";
}

bool WriteAssetAtomicIfChanged(const base::FilePath& path,
                               const std::vector<uint8_t>& data) {
  std::string existing;
  if (base::PathExists(path) &&
      base::ReadFileToStringWithMaxSize(path, &existing, kSyncMaxBlobBytes)) {
    const auto existing_bytes = base::as_byte_span(existing);
    const auto new_bytes = base::span<const uint8_t>(data);
    if (existing_bytes.size() == new_bytes.size() &&
        std::equal(existing_bytes.begin(), existing_bytes.end(),
                   new_bytes.begin())) {
      return true;
    }
  }
  if (!base::CreateDirectory(path.DirName())) {
    return false;
  }
  return base::ImportantFileWriter::WriteFileAtomically(
      path, base::as_string_view(base::span<const uint8_t>(data)));
}

// Rebuilds SidebarNodes from decoded remote data while enforcing depth/node
// caps, global ID uniqueness, and preserving live TabLiveState + active URLs
// of tabs that already hold live WebContents.
struct WorkspaceNodeMerger {
  const BrowserModel* model = nullptr;
  std::set<ItemID> used_ids;
  size_t built_count = 0;

  bool Reserve() {
    if (built_count >= kMaxWorkspaceNodes) {
      return false;
    }
    ++built_count;
    return true;
  }

  std::optional<Tab> MergeTab(const Tab& remote) {
    auto norm = NormalizeUuid(remote.id);
    std::string id = norm.value_or(remote.id);
    if (id.empty() || used_ids.contains(id) || !Reserve()) {
      return std::nullopt;
    }
    used_ids.insert(id);
    Tab result = remote;
    result.id = id;
    if (model) {
      if (const Tab* existing = model->FindTab(id)) {
        result.live_state = existing->live_state;
        if (existing->live_state.has_web_content) {
          result.url = existing->url;
          result.title = existing->title;
        }
      }
    }
    return result;
  }

  std::optional<SidebarNode> MergeNode(const SidebarNode& remote,
                                       int depth = 0) {
    if (const Tab* t = remote.as_tab()) {
      auto merged = MergeTab(*t);
      if (!merged) return std::nullopt;
      return SidebarNode(std::move(*merged));
    }
    if (const Folder* f = remote.as_folder()) {
      if (depth >= kMaxWorkspaceDepth) return std::nullopt;
      auto norm = NormalizeUuid(f->id);
      std::string id = norm.value_or(f->id);
      if (id.empty() || used_ids.contains(id) || !Reserve()) {
        return std::nullopt;
      }
      used_ids.insert(id);
      Folder out;
      out.id = id;
      out.title = f->title;
      out.is_expanded = f->is_expanded;
      out.custom_icon = f->custom_icon;
      out.icon_override = f->icon_override;
      out.live = f->live;
      for (const SidebarNode& child : f->children) {
        if (auto merged = MergeNode(child, depth + 1)) {
          out.children.push_back(std::move(*merged));
        }
      }
      if (f->peeked_child_id) {
        std::string pid =
            NormalizeUuid(*f->peeked_child_id).value_or(*f->peeked_child_id);
        for (const SidebarNode& c : out.children) {
          if (c.id() == pid) {
            out.peeked_child_id = pid;
            break;
          }
        }
      }
      if (model) {
        if (const Folder* existing = model->FindFolder(id)) {
          out.live_sso_url = existing->live_sso_url;
        }
      }
      return SidebarNode(std::move(out));
    }
    if (const Split* s = remote.as_split()) {
      auto norm = NormalizeUuid(s->id);
      std::string id = norm.value_or(s->id);
      if (id.empty() || used_ids.contains(id) || !Reserve()) {
        return std::nullopt;
      }
      std::vector<Tab> panes;
      for (const Tab& pane : s->panes) {
        if (panes.size() >= BrowserModel::kMaxSplitPanes) break;
        if (auto merged = MergeTab(pane)) {
          panes.push_back(std::move(*merged));
        }
      }
      if (panes.empty()) return std::nullopt;
      used_ids.insert(id);

      Split out;
      out.id = id;
      out.orientation = s->orientation;
      out.custom_title = s->custom_title;
      out.icon_override = s->icon_override;
      out.panes = std::move(panes);

      if (s->fractions.size() == out.panes.size()) {
        double sum = 0.0;
        bool valid = true;
        for (double v : s->fractions) {
          if (!std::isfinite(v) || v <= 0.0) {
            valid = false;
            break;
          }
          sum += v;
        }
        if (valid && std::isfinite(sum) && sum > 0.0) {
          for (double v : s->fractions) {
            out.fractions.push_back(v / sum);
          }
        }
      }
      if (s->focused_pane_id) {
        std::string fid =
            NormalizeUuid(*s->focused_pane_id).value_or(*s->focused_pane_id);
        for (const Tab& p : out.panes) {
          if (p.id == fid) {
            out.focused_pane_id = fid;
            break;
          }
        }
      }
      return SidebarNode(std::move(out));
    }
    return std::nullopt;
  }

  static void CollectIds(const SidebarNode& node, std::vector<ItemID>* out) {
    out->push_back(node.id());
    if (const Folder* f = node.as_folder()) {
      for (const SidebarNode& c : f->children) {
        CollectIds(c, out);
      }
    } else if (const Split* s = node.as_split()) {
      for (const Tab& p : s->panes) {
        out->push_back(p.id);
      }
    }
  }

  std::optional<SidebarNode> AdoptLocal(const SidebarNode& local) {
    std::vector<ItemID> ids;
    CollectIds(local, &ids);
    for (const ItemID& id : ids) {
      if (used_ids.contains(id)) {
        return std::nullopt;
      }
    }
    for (const ItemID& id : ids) {
      used_ids.insert(id);
    }
    return local;
  }
};

std::vector<std::string> OrderedUnique(const std::vector<std::string>& source,
                                       const std::set<std::string>& keep) {
  std::vector<std::string> out;
  std::set<std::string> seen;
  for (const std::string& id : source) {
    if (keep.contains(id) && seen.insert(id).second) {
      out.push_back(id);
    }
  }
  return out;
}

void PruneOldBackups(const base::FilePath& backups_parent, int max_keep) {
  if (!base::DirectoryExists(backups_parent) || max_keep <= 0) {
    return;
  }
  std::vector<base::FilePath> dirs;
  base::FileEnumerator enumerator(backups_parent, /*recursive=*/false,
                                  base::FileEnumerator::DIRECTORIES);
  for (base::FilePath d = enumerator.Next(); !d.empty(); d = enumerator.Next()) {
    dirs.push_back(std::move(d));
  }
  if (static_cast<int>(dirs.size()) <= max_keep) {
    return;
  }
  std::sort(dirs.begin(), dirs.end());
  const size_t to_remove = dirs.size() - static_cast<size_t>(max_keep);
  for (size_t i = 0; i < to_remove; ++i) {
    base::DeletePathRecursively(dirs[i]);
  }
}

void CopyFileIfPresent(const base::FilePath& src, const base::FilePath& dst) {
  if (!base::PathExists(src) || base::IsLink(src)) {
    return;
  }
  if (!base::CreateDirectory(dst.DirName())) {
    return;
  }
  base::CopyFile(src, dst);
}

// Normalizes a Preferences.json key to canonical `open.*` when portable.
std::optional<std::string> CanonicalPortablePrefKey(std::string_view raw_key) {
  if (SyncCollectionCodecs::IsPortablePreferenceKey(raw_key)) {
    return std::string(raw_key);
  }
  if (!base::StartsWith(raw_key, "open.")) {
    std::string prefixed = "open." + std::string(raw_key);
    if (SyncCollectionCodecs::IsPortablePreferenceKey(prefixed)) {
      return prefixed;
    }
  }
  return std::nullopt;
}

base::FilePath ResolveExistingSqlite(const base::FilePath& state_dir,
                                     const char* primary_name,
                                     const char* legacy_name) {
  base::FilePath primary = state_dir.AppendASCII(primary_name);
  if (base::PathExists(primary)) {
    return primary;
  }
  base::FilePath legacy = state_dir.AppendASCII(legacy_name);
  if (base::PathExists(legacy)) {
    return legacy;
  }
  return primary;
}

bool ReadAdBlockProfileFromDisk(const base::FilePath& adblock_dir,
                                bool* global_enabled_out,
                                SyncedAdBlockProfilePayload* out) {
  if (!base::DirectoryExists(adblock_dir)) {
    return false;
  }
  bool read_any = false;
  std::string raw_cfg;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII("adblock-config.json"), &raw_cfg,
          kMaxAdBlockConfigBytes)) {
    if (auto dict = base::JSONReader::ReadDict(raw_cfg, base::JSON_PARSE_RFC)) {
      read_any = true;
      if (auto en = dict->FindBool("enabled"); en && global_enabled_out) {
        *global_enabled_out = *en;
      }
      if (const auto* lists = dict->FindList("enabled_list_ids")) {
        for (const auto& v : *lists) {
          if (v.is_string()) out->enabled_list_ids.push_back(v.GetString());
        }
      }
    }
  }
  std::string raw_excl;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII("exclusions.json"), &raw_excl,
          kMaxAdBlockConfigBytes)) {
    if (auto val = base::JSONReader::Read(raw_excl, base::JSON_PARSE_RFC)) {
      const base::ListValue* list = val->GetIfList();
      if (!list && val->is_dict()) {
        list = val->GetDict().FindList("excluded_domains");
        if (!list) list = val->GetDict().FindList("domains");
      }
      if (list) {
        read_any = true;
        for (const auto& v : *list) {
          if (v.is_string()) out->excluded_domains.push_back(v.GetString());
        }
      }
    }
  }
  std::string raw_custom;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII("custom-rules.txt"), &raw_custom,
          2 * 1024 * 1024)) {
    out->custom_rules = std::move(raw_custom);
    read_any = true;
  }
  return read_any;
}

bool WriteAdBlockProfileToDisk(const base::FilePath& adblock_dir,
                               bool global_enabled,
                               const SyncedAdBlockProfilePayload& payload) {
  if (!base::CreateDirectory(adblock_dir)) {
    return false;
  }
  bool ok = true;
  {
    base::DictValue cfg;
    cfg.Set("enabled", global_enabled);
    base::ListValue lists;
    for (const auto& id : payload.enabled_list_ids) {
      lists.Append(id);
    }
    cfg.Set("enabled_list_ids", std::move(lists));
    std::string json;
    if (base::JSONWriter::WriteWithOptions(
            cfg, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
      ok &= base::ImportantFileWriter::WriteFileAtomically(
          adblock_dir.AppendASCII("adblock-config.json"), json);
    }
  }
  {
    base::ListValue excl;
    for (const auto& dom : payload.excluded_domains) {
      excl.Append(dom);
    }
    std::string json;
    if (base::JSONWriter::WriteWithOptions(
            excl, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
      ok &= base::ImportantFileWriter::WriteFileAtomically(
          adblock_dir.AppendASCII("exclusions.json"), json);
    }
  }
  if (!payload.custom_rules.empty() ||
      base::PathExists(adblock_dir.AppendASCII("custom-rules.txt"))) {
    ok &= base::ImportantFileWriter::WriteFileAtomically(
        adblock_dir.AppendASCII("custom-rules.txt"), payload.custom_rules);
  }
  return ok;
}

}  // namespace

SyncAdapterDeps::SyncAdapterDeps() = default;
SyncAdapterDeps::SyncAdapterDeps(SyncAdapterDeps&&) noexcept = default;
SyncAdapterDeps& SyncAdapterDeps::operator=(SyncAdapterDeps&&) noexcept =
    default;
SyncAdapterDeps::~SyncAdapterDeps() = default;

SyncStorageAdapterImpl::SyncStorageAdapterImpl(SyncAdapterDeps deps)
    : deps_(std::move(deps)) {}

SyncStorageAdapterImpl::~SyncStorageAdapterImpl() = default;

// static
std::string SyncStorageAdapterImpl::SanitizeProfileDirectoryName(
    std::string_view raw,
    std::set<std::string>* used_lower) {
  std::string filtered;
  filtered.reserve(std::min(raw.size(), kMaxProfileDirLength));
  for (unsigned char c : raw) {
    if (filtered.size() >= kMaxProfileDirLength) break;
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == ' ' || c == '-' || c == '_') {
      filtered.push_back(static_cast<char>(c));
    }
  }
  std::string base =
      std::string(base::TrimWhitespaceASCII(filtered, base::TRIM_ALL));
  if (base.empty()) {
    base = "Profile";
  }
  if (base::EqualsCaseInsensitiveASCII(base, "default")) {
    base = "Default";
  }
  if (!used_lower) {
    return base;
  }
  if (used_lower->insert(base::ToLowerASCII(base)).second) {
    return base;
  }
  int idx = 1;
  while (true) {
    std::string candidate = "Profile " + base::NumberToString(idx);
    if (used_lower->insert(base::ToLowerASCII(candidate)).second) {
      return candidate;
    }
    ++idx;
  }
}

// static
bool SyncStorageAdapterImpl::IsValidWebStoreExtensionId(std::string_view id) {
  if (id.size() != 32) {
    return false;
  }
  for (char c : id) {
    if (c < 'a' || c > 'p') {
      return false;
    }
  }
  return true;
}

base::FilePath SyncStorageAdapterImpl::StateDir() const {
  return deps_.user_data_dir.AppendASCII("State");
}

base::FilePath SyncStorageAdapterImpl::PreferencesFilePath() const {
  return StateDir().AppendASCII("Preferences.json");
}

base::FilePath SyncStorageAdapterImpl::KeybindingsFilePath() const {
  return StateDir().AppendASCII("keybindings.json");
}

base::FilePath SyncStorageAdapterImpl::ProfileDirFor(
    const Profile& profile) const {
  return deps_.user_data_dir.AppendASCII("Profiles")
      .AppendASCII(profile.data_directory_name);
}

DocumentStore SyncStorageAdapterImpl::ResolveDocumentStore() const {
  return DocumentStore(deps_.user_data_dir);
}

// ============================================================================
// CollectLocalData (all 16 collections)
// ============================================================================

SyncLocalBundle SyncStorageAdapterImpl::CollectLocalData(
    const SyncCategorySettings& categories,
    const SyncVaultKeys& vault_keys) {
  SyncLocalBundle bundle;

  if (categories.IsEnabled(SyncCategory::kWorkspace) ||
      categories.IsEnabled(SyncCategory::kTodayTabs)) {
    CollectWorkspace(categories, &bundle);
  }
  if (categories.IsEnabled(SyncCategory::kArchive)) {
    CollectArchive(&bundle);
  }
  if (categories.IsEnabled(SyncCategory::kSettingsAndShortcuts)) {
    CollectPreferences(&bundle);
    CollectKeybindings(&bundle);
  }
  if (categories.IsEnabled(SyncCategory::kAdBlocking)) {
    CollectAdBlock(&bundle);
  }
  if (categories.IsEnabled(SyncCategory::kBoostsEaselsNotes)) {
    CollectBoosts(&bundle);
    CollectEasels(vault_keys, &bundle);
    CollectNotes(vault_keys, &bundle);
  }
  if (categories.IsEnabled(SyncCategory::kHistory)) {
    CollectHistory(&bundle);
  }
  if (categories.IsEnabled(SyncCategory::kExtensions)) {
    CollectExtensions(&bundle);
  }
  if (categories.IsEnabled(SyncCategory::kCredentialsAndPermissions)) {
    CollectCredentials(&bundle);
    CollectSitePermissions(&bundle);
  }

  // Deduplicate blobs by content-addressed blob_id.
  std::set<std::string> seen_blobs;
  std::vector<SyncLocalBlob> unique_blobs;
  unique_blobs.reserve(bundle.blobs.size());
  for (auto& blob : bundle.blobs) {
    if (seen_blobs.insert(blob.blob_id).second) {
      unique_blobs.push_back(std::move(blob));
    }
  }
  bundle.blobs = std::move(unique_blobs);

  return bundle;
}

void SyncStorageAdapterImpl::CollectWorkspace(
    const SyncCategorySettings& categories,
    SyncLocalBundle* out) {
  if (!deps_.model) {
    return;
  }

  if (categories.IsEnabled(SyncCategory::kWorkspace)) {
    // 1. workspace.meta ("global")
    SyncedWorkspaceMetaPayload meta;
    for (const Profile& profile : deps_.model->profiles()) {
      meta.ordered_profile_ids.push_back(profile.id);
    }
    for (const Space& space : deps_.model->spaces()) {
      meta.ordered_space_ids.push_back(space.id);
    }
    meta.routing_rules = deps_.model->routing_rules();
    meta.default_destination = deps_.model->default_destination();

    out->records.push_back(SyncLocalRecord{
        SyncCollection::kWorkspaceMeta,
        SyncCollectionSingletonId(SyncCollection::kWorkspaceMeta)
            .value_or("global"),
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeWorkspaceMeta(meta)),
    });

    // 2. workspace.profile (<ProfileUUID>)
    for (const Profile& profile : deps_.model->profiles()) {
      out->records.push_back(SyncLocalRecord{
          SyncCollection::kWorkspaceProfile,
          profile.id,
          SyncCollectionCodecs::EncodeDeterministicJson(
              SyncCollectionCodecs::EncodeProfile(profile)),
      });
    }

    // 3. workspace.space (<SpaceUUID>)
    for (const Space& space : deps_.model->spaces()) {
      out->records.push_back(SyncLocalRecord{
          SyncCollection::kWorkspaceSpace,
          space.id,
          SyncCollectionCodecs::EncodeDeterministicJson(
              SyncCollectionCodecs::EncodeSpace(space)),
      });
    }

    out->complete_collections.insert(SyncCollection::kWorkspaceMeta);
    out->complete_collections.insert(SyncCollection::kWorkspaceProfile);
    out->complete_collections.insert(SyncCollection::kWorkspaceSpace);

    // 5. workspace.windowLayout ("default")
    const BrowserWindowState* layout_window = nullptr;
    if (deps_.get_layout_window_id) {
      const WindowID preferred_id = deps_.get_layout_window_id.Run();
      if (!preferred_id.empty()) {
        if (const BrowserWindowState* w =
                deps_.model->FindWindow(preferred_id);
            w && w->style == WindowStyle::kStandard && !w->is_incognito) {
          layout_window = w;
        }
      }
    }
    if (!layout_window) {
      for (const BrowserWindowState& w : deps_.model->windows()) {
        if (w.style == WindowStyle::kStandard && !w.is_incognito) {
          layout_window = &w;
          break;
        }
      }
    }
    if (layout_window) {
      SyncedWindowLayoutPayload layout;
      layout.sidebar_width = layout_window->sidebar_width;
      layout.sidebar_mode = layout_window->sidebar_mode;
      layout.shows_toolbar = layout_window->shows_toolbar;
      out->records.push_back(SyncLocalRecord{
          SyncCollection::kWorkspaceWindowLayout,
          SyncCollectionSingletonId(SyncCollection::kWorkspaceWindowLayout)
              .value_or("default"),
          SyncCollectionCodecs::EncodeDeterministicJson(
              SyncCollectionCodecs::EncodeWindowLayout(layout)),
      });
      out->complete_collections.insert(SyncCollection::kWorkspaceWindowLayout);
    }
  }

  // 4. workspace.today (<SpaceUUID>)
  if (categories.IsEnabled(SyncCategory::kTodayTabs)) {
    for (const Space& space : deps_.model->spaces()) {
      out->records.push_back(SyncLocalRecord{
          SyncCollection::kWorkspaceToday,
          space.id,
          SyncCollectionCodecs::EncodeDeterministicJson(
              SyncCollectionCodecs::EncodeTodayTabs(space.id, space.today)),
      });
    }
    out->complete_collections.insert(SyncCollection::kWorkspaceToday);
  }
}

void SyncStorageAdapterImpl::CollectArchive(SyncLocalBundle* out) {
  if (!deps_.model) {
    return;
  }
  bool all_ok = true;
  for (const Profile& profile : deps_.model->profiles()) {
    std::optional<std::vector<ArchivedTabRecord>> records;
    if (deps_.read_archive) {
      records = deps_.read_archive.Run(profile.id);
    } else if (!deps_.user_data_dir.empty()) {
      base::FilePath db_path = ResolveExistingSqlite(
          ProfileDirFor(profile).AppendASCII("State"), "Archive.sqlite",
          "archive.sqlite3");
      if (base::PathExists(db_path)) {
        ArchiveStore store(db_path);
        if (store.Open()) {
          records = store.List(
              static_cast<int>(kSyncMaxArchiveRecordsPerProfile), 0);
        }
      } else {
        records = std::vector<ArchivedTabRecord>{};
      }
    }
    if (!records.has_value()) {
      all_ok = false;
      continue;
    }
    out->records.push_back(SyncLocalRecord{
        SyncCollection::kArchiveProfile,
        profile.id,
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeArchiveProfile(profile.id,
                                                       std::move(*records))),
    });
  }
  if (all_ok) {
    out->complete_collections.insert(SyncCollection::kArchiveProfile);
  }
}

std::map<std::string, base::Value>
SyncStorageAdapterImpl::ReadLocalPortablePreferences() const {
  std::map<std::string, base::Value> raw_prefs;
  if (deps_.read_preferences) {
    raw_prefs = deps_.read_preferences.Run();
  } else if (!deps_.user_data_dir.empty()) {
    std::string raw;
    if (base::ReadFileToStringWithMaxSize(PreferencesFilePath(), &raw,
                                          kMaxPrefsFileBytes)) {
      if (auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
        for (const auto [k, v] : *dict) {
          raw_prefs.emplace(k, v.Clone());
        }
      }
    }
  }

  std::map<std::string, base::Value> portable;
  for (auto& [k, v] : raw_prefs) {
    if (auto canon = CanonicalPortablePrefKey(k)) {
      portable.emplace(std::move(*canon), std::move(v));
    }
  }
  return portable;
}

bool SyncStorageAdapterImpl::WriteLocalPortablePreferences(
    const std::map<std::string, base::Value>& values,
    bool remove_missing) const {
  if (deps_.write_preferences) {
    deps_.write_preferences.Run(values, remove_missing);
    return true;
  }
  if (deps_.user_data_dir.empty()) {
    return false;
  }

  base::DictValue root;
  std::string raw;
  if (base::ReadFileToStringWithMaxSize(PreferencesFilePath(), &raw,
                                        kMaxPrefsFileBytes)) {
    if (auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
      root = std::move(*dict);
    }
  }

  if (remove_missing) {
    std::vector<std::string> to_remove;
    for (const auto [k, _] : root) {
      auto canon = CanonicalPortablePrefKey(k);
      if (canon && !values.contains(*canon)) {
        to_remove.push_back(k);
      }
    }
    for (const std::string& k : to_remove) {
      root.Remove(k);
    }
  }

  for (const auto& [k, v] : values) {
    if (!SyncCollectionCodecs::IsPortablePreferenceKey(k)) {
      continue;
    }
    root.Set(k, v.Clone());
  }

  if (!base::CreateDirectory(PreferencesFilePath().DirName())) {
    return false;
  }
  std::string encoded;
  if (!base::JSONWriter::WriteWithOptions(
          root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &encoded)) {
    return false;
  }
  return base::ImportantFileWriter::WriteFileAtomically(PreferencesFilePath(),
                                                        encoded);
}

void SyncStorageAdapterImpl::CollectPreferences(SyncLocalBundle* out) {
  auto portable = ReadLocalPortablePreferences();
  out->records.push_back(SyncLocalRecord{
      SyncCollection::kSettingsPreferences,
      SyncCollectionSingletonId(SyncCollection::kSettingsPreferences)
          .value_or("global"),
      SyncCollectionCodecs::EncodeDeterministicJson(
          SyncCollectionCodecs::EncodePreferences(portable)),
  });
  out->complete_collections.insert(SyncCollection::kSettingsPreferences);
}

base::DictValue SyncStorageAdapterImpl::SerializeKeybindingsDict() const {
  base::DictValue root;
  root.Set("version", CommandRegistry::kKeybindingsSchemaVersion);
  base::DictValue bindings;
  if (deps_.command_registry) {
    for (const auto& [cmd_id, ov] : deps_.command_registry->overrides()) {
      base::DictValue bd;
      base::ListValue sclist;
      for (const KeyboardShortcut& sc : ov.shortcuts) {
        base::DictValue sd;
        sd.Set("key", sc.key);
        base::ListValue mods;
        for (const std::string& m : sc.ModifierNames()) {
          mods.Append(m);
        }
        sd.Set("modifiers", std::move(mods));
        sclist.Append(std::move(sd));
      }
      bd.Set("shortcuts", std::move(sclist));
      if (ov.priority.has_value()) {
        bd.Set("priority", PriorityToString(*ov.priority));
      }
      bindings.Set(cmd_id, std::move(bd));
    }
    root.Set("bindings", std::move(bindings));
    return root;
  }

  if (!deps_.user_data_dir.empty() && base::PathExists(KeybindingsFilePath())) {
    std::string raw;
    if (base::ReadFileToStringWithMaxSize(KeybindingsFilePath(), &raw,
                                          kMaxPrefsFileBytes)) {
      if (auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
        return std::move(*dict);
      }
    }
  }
  root.Set("bindings", std::move(bindings));
  return root;
}

void SyncStorageAdapterImpl::CollectKeybindings(SyncLocalBundle* out) {
  if (!deps_.command_registry && deps_.user_data_dir.empty()) {
    return;
  }
  base::DictValue store_dict = SerializeKeybindingsDict();
  out->records.push_back(SyncLocalRecord{
      SyncCollection::kSettingsKeybindings,
      SyncCollectionSingletonId(SyncCollection::kSettingsKeybindings)
          .value_or("global"),
      SyncCollectionCodecs::EncodeDeterministicJson(
          SyncCollectionCodecs::EncodeKeybindings(store_dict)),
  });
  out->complete_collections.insert(SyncCollection::kSettingsKeybindings);
}

void SyncStorageAdapterImpl::CollectAdBlock(SyncLocalBundle* out) {
  std::optional<SyncedAdBlockConfigPayload> payload;
  if (deps_.read_adblock) {
    payload = deps_.read_adblock.Run();
  } else if (deps_.model) {
    SyncedAdBlockConfigPayload cfg;
    bool all_ok = true;
    bool any_enabled_set = false;
    for (const Profile& profile : deps_.model->profiles()) {
      if (deps_.get_adblock_service) {
        OpenAdBlockProfileService* svc =
            deps_.get_adblock_service.Run(profile.id);
        if (!svc) {
          all_ok = false;
          continue;
        }
        if (!any_enabled_set) {
          cfg.global_enabled = svc->IsEnabled();
          any_enabled_set = true;
        }
        SyncedAdBlockProfilePayload p;
        p.enabled_list_ids = svc->GetEnabledListIds();
        p.excluded_domains = svc->GetExcludedDomains();
        p.custom_rules = svc->GetCustomRules();
        cfg.profiles[profile.id] = std::move(p);
      } else if (!deps_.user_data_dir.empty()) {
        SyncedAdBlockProfilePayload p;
        bool prof_enabled = cfg.global_enabled;
        if (ReadAdBlockProfileFromDisk(
                ProfileDirFor(profile).AppendASCII("AdBlock"), &prof_enabled,
                &p)) {
          if (!any_enabled_set) {
            cfg.global_enabled = prof_enabled;
            any_enabled_set = true;
          }
          cfg.profiles[profile.id] = std::move(p);
        }
      }
    }
    if (all_ok) {
      payload = std::move(cfg);
    }
  }

  if (!payload.has_value()) {
    out->warnings.push_back(
        "Ad blocking settings were not synced: store unavailable.");
    return;
  }

  out->records.push_back(SyncLocalRecord{
      SyncCollection::kAdblockConfig,
      SyncCollectionSingletonId(SyncCollection::kAdblockConfig)
          .value_or("global"),
      SyncCollectionCodecs::EncodeDeterministicJson(
          SyncCollectionCodecs::EncodeAdBlockConfig(*payload)),
  });
  out->complete_collections.insert(SyncCollection::kAdblockConfig);
}

void SyncStorageAdapterImpl::CollectBoosts(SyncLocalBundle* out) {
  if (!deps_.model) {
    return;
  }
  bool complete = true;
  for (const Profile& profile : deps_.model->profiles()) {
    std::optional<std::vector<Boost>> boosts;
    if (deps_.read_boosts) {
      boosts = deps_.read_boosts.Run(profile.id);
    } else if (deps_.get_boost_store) {
      if (BoostStore* store = deps_.get_boost_store.Run(profile.id)) {
        boosts = store->AllBoosts();
      }
    } else if (!deps_.user_data_dir.empty()) {
      BoostStore store(profile.id, ProfileDirFor(profile));
      boosts = store.Load();
    }
    if (!boosts.has_value()) {
      complete = false;
      continue;
    }
    for (const Boost& b : *boosts) {
      const std::string rec_id =
          SyncCollectionCodecs::BoostRecordId(profile.id, b.id);
      if (!IsValidSyncRecordId(rec_id)) {
        continue;
      }
      out->records.push_back(SyncLocalRecord{
          SyncCollection::kBoostItem,
          rec_id,
          SyncCollectionCodecs::EncodeDeterministicJson(
              SyncCollectionCodecs::EncodeBoostItem(profile.id, b)),
      });
    }
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kBoostItem);
  }
}

void SyncStorageAdapterImpl::CollectEasels(const SyncVaultKeys& vault_keys,
                                           SyncLocalBundle* out) {
  std::optional<DocumentStore> fallback_store;
  const DocumentStore* store = deps_.document_store.get();
  if (!store) {
    if (deps_.user_data_dir.empty()) return;
    fallback_store.emplace(deps_.user_data_dir);
    store = &*fallback_store;
  }

  bool complete = true;
  const std::vector<EaselIndexEntry> entries = store->ListEasels();
  for (const EaselIndexEntry& entry : entries) {
    auto doc = store->LoadEasel(entry.id);
    if (!doc) {
      complete = false;
      out->warnings.push_back(
          "An Easel could not be read and was skipped during sync.");
      continue;
    }
    std::set<std::string> image_files;
    for (const EaselElement& el : doc->elements) {
      if (el.type == "image" &&
          DocumentStore::IsValidAssetFilename(el.content)) {
        image_files.insert(el.content);
      }
    }
    const base::FilePath images_dir = store->EaselImagesDir(doc->id);
    if (base::DirectoryExists(images_dir)) {
      base::FileEnumerator enumerator(images_dir, /*recursive=*/false,
                                      base::FileEnumerator::FILES);
      for (base::FilePath f = enumerator.Next(); !f.empty();
           f = enumerator.Next()) {
        std::string name = f.BaseName().AsUTF8Unsafe();
        if (DocumentStore::IsValidAssetFilename(name)) {
          image_files.insert(std::move(name));
        }
      }
    }

    std::vector<SyncedAssetRef> assets;
    for (const std::string& filename : image_files) {
      auto resolved = store->ResolveEaselImagePath(doc->id, filename);
      if (!resolved || !base::PathExists(*resolved)) {
        continue;
      }
      auto fsize = base::GetFileSize(*resolved);
      if (!fsize || *fsize <= 0 ||
          static_cast<size_t>(*fsize) > kSyncMaxBlobBytes) {
        out->warnings.push_back(
            "An Easel image exceeds the 20 MB sync limit and was skipped.");
        continue;
      }
      std::string raw;
      if (!base::ReadFileToStringWithMaxSize(*resolved, &raw,
                                             kSyncMaxBlobBytes)) {
        continue;
      }
      std::vector<uint8_t> bytes(raw.begin(), raw.end());
      SyncedAssetRef ref;
      ref.filename = filename;
      ref.blob_id =
          SyncCrypto::ComputeBlobId(bytes.data(), bytes.size(), vault_keys);
      ref.sha256 = SyncCrypto::Sha256Hex(bytes.data(), bytes.size());
      ref.byte_length = static_cast<int64_t>(bytes.size());
      out->blobs.push_back(SyncLocalBlob{ref.blob_id, std::move(bytes)});
      assets.push_back(std::move(ref));
    }

    out->records.push_back(SyncLocalRecord{
        SyncCollection::kEaselDocument,
        base::ToLowerASCII(doc->id),
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeEaselDocument(*doc, std::move(assets))),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kEaselDocument);
  }
}

void SyncStorageAdapterImpl::CollectNotes(const SyncVaultKeys& vault_keys,
                                          SyncLocalBundle* out) {
  std::optional<DocumentStore> fallback_store;
  const DocumentStore* store = deps_.document_store.get();
  if (!store) {
    if (deps_.user_data_dir.empty()) return;
    fallback_store.emplace(deps_.user_data_dir);
    store = &*fallback_store;
  }

  bool complete = true;
  const std::vector<NoteIndexEntry> entries = store->ListNotes();
  for (const NoteIndexEntry& entry : entries) {
    auto doc = store->LoadNote(entry.id);
    if (!doc) {
      complete = false;
      out->warnings.push_back(
          "A Note could not be read and was skipped during sync.");
      continue;
    }
    std::vector<SyncedAssetRef> assets;
    const base::FilePath assets_dir = store->NoteAssetsDir(doc->id);
    if (base::DirectoryExists(assets_dir)) {
      std::vector<std::string> names;
      base::FileEnumerator enumerator(assets_dir, /*recursive=*/false,
                                      base::FileEnumerator::FILES);
      for (base::FilePath f = enumerator.Next(); !f.empty();
           f = enumerator.Next()) {
        std::string name = f.BaseName().AsUTF8Unsafe();
        if (DocumentStore::IsValidAssetFilename(name)) {
          names.push_back(std::move(name));
        }
      }
      std::sort(names.begin(), names.end());
      for (const std::string& filename : names) {
        auto resolved = store->ResolveNoteAssetPath(doc->id, filename);
        if (!resolved || !base::PathExists(*resolved)) {
          continue;
        }
        auto fsize = base::GetFileSize(*resolved);
        if (!fsize || *fsize <= 0 ||
            static_cast<size_t>(*fsize) > kSyncMaxBlobBytes) {
          out->warnings.push_back(
              "A Note attachment exceeds the 20 MB sync limit and was skipped.");
          continue;
        }
        std::string raw;
        if (!base::ReadFileToStringWithMaxSize(*resolved, &raw,
                                               kSyncMaxBlobBytes)) {
          continue;
        }
        std::vector<uint8_t> bytes(raw.begin(), raw.end());
        SyncedAssetRef ref;
        ref.filename = filename;
        ref.blob_id =
            SyncCrypto::ComputeBlobId(bytes.data(), bytes.size(), vault_keys);
        ref.sha256 = SyncCrypto::Sha256Hex(bytes.data(), bytes.size());
        ref.byte_length = static_cast<int64_t>(bytes.size());
        out->blobs.push_back(SyncLocalBlob{ref.blob_id, std::move(bytes)});
        assets.push_back(std::move(ref));
      }
    }

    out->records.push_back(SyncLocalRecord{
        SyncCollection::kNoteDocument,
        base::ToLowerASCII(doc->id),
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeNoteDocument(*doc, std::move(assets))),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kNoteDocument);
  }
}

void SyncStorageAdapterImpl::CollectHistory(SyncLocalBundle* out) {
  if (!deps_.model) {
    return;
  }
  bool complete = true;
  for (const Profile& profile : deps_.model->profiles()) {
    std::optional<std::vector<HistoryEntry>> entries;
    if (deps_.read_history) {
      entries = deps_.read_history.Run(profile.id);
    } else if (!deps_.user_data_dir.empty()) {
      base::FilePath db_path = ResolveExistingSqlite(
          ProfileDirFor(profile).AppendASCII("State"), "History.sqlite",
          "history.sqlite3");
      if (base::PathExists(db_path)) {
        HistoryStore store(db_path);
        if (store.Open()) {
          std::vector<HistoryEntry> rows;
          while (rows.size() < kSyncMaxHistoryEntriesPerProfile) {
            auto page = store.Recent(1000, static_cast<int>(rows.size()));
            if (page.empty()) break;
            rows.insert(rows.end(), std::make_move_iterator(page.begin()),
                        std::make_move_iterator(page.end()));
            if (page.size() < 1000) break;
          }
          entries = std::move(rows);
        }
      } else {
        entries = std::vector<HistoryEntry>{};
      }
    }
    if (!entries.has_value()) {
      complete = false;
      continue;
    }
    out->records.push_back(SyncLocalRecord{
        SyncCollection::kHistoryProfile,
        profile.id,
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeHistoryProfile(profile.id,
                                                       std::move(*entries))),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kHistoryProfile);
  }
}

void SyncStorageAdapterImpl::CollectExtensions(SyncLocalBundle* out) {
  if (!deps_.model || !deps_.read_extensions) {
    return;
  }
  bool complete = true;
  for (const Profile& profile : deps_.model->profiles()) {
    auto exts = deps_.read_extensions.Run(profile.id);
    if (!exts.has_value()) {
      complete = false;
      continue;
    }
    std::vector<SyncedExtensionRecord> filtered;
    for (auto& ext : *exts) {
      if (ext.from_web_store && IsValidWebStoreExtensionId(ext.extension_id)) {
        filtered.push_back(std::move(ext));
      }
    }
    out->records.push_back(SyncLocalRecord{
        SyncCollection::kExtensionsProfile,
        profile.id,
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeExtensionsProfile(
                profile.id, std::move(filtered))),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kExtensionsProfile);
  }
}

void SyncStorageAdapterImpl::CollectCredentials(SyncLocalBundle* out) {
  if (!deps_.model || !deps_.read_credentials) {
    return;
  }
  bool complete = true;
  for (const Profile& profile : deps_.model->profiles()) {
    auto creds = deps_.read_credentials.Run(profile.id);
    if (!creds.has_value()) {
      complete = false;
      continue;
    }
    creds->profile_id = profile.id;
    out->records.push_back(SyncLocalRecord{
        SyncCollection::kCredentialsProfile,
        profile.id,
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeCredentialsProfile(*creds)),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kCredentialsProfile);
  }
}

void SyncStorageAdapterImpl::CollectSitePermissions(SyncLocalBundle* out) {
  if (!deps_.model || !deps_.read_site_permissions) {
    return;
  }
  bool complete = true;
  for (const Profile& profile : deps_.model->profiles()) {
    auto perms = deps_.read_site_permissions.Run(profile.id);
    if (!perms.has_value()) {
      complete = false;
      continue;
    }
    perms->profile_id = profile.id;
    out->records.push_back(SyncLocalRecord{
        SyncCollection::kSitePermissionsProfile,
        profile.id,
        SyncCollectionCodecs::EncodeDeterministicJson(
            SyncCollectionCodecs::EncodeSitePermissionsProfile(*perms)),
    });
  }
  if (complete) {
    out->complete_collections.insert(SyncCollection::kSitePermissionsProfile);
  }
}

// ============================================================================
// ApplyRemoteData (all 16 collections)
// ============================================================================

SyncApplyOutcome SyncStorageAdapterImpl::ApplyRemoteData(
    const SyncRemoteBundle& bundle,
    SyncApplyMode mode,
    const SyncCategorySettings& categories) {
  SyncApplyOutcome outcome;
  const bool full_replace =
      (mode == SyncApplyMode::kReplaceLocal && bundle.is_full_snapshot);
  auto applies = [&](SyncCollection c) {
    return full_replace || BundleHasCollection(bundle, c);
  };

  // 1-5: Workspace & Today first (other per-profile collections reference Profiles).
  ApplyWorkspace(bundle, mode, categories, &outcome);

  // 6: Archive
  if (categories.IsEnabled(SyncCategory::kArchive) &&
      applies(SyncCollection::kArchiveProfile)) {
    ApplyArchive(bundle, mode, &outcome);
  }

  // 7-8: Settings & Shortcuts
  if (categories.IsEnabled(SyncCategory::kSettingsAndShortcuts)) {
    if (applies(SyncCollection::kSettingsPreferences)) {
      ApplyPreferences(bundle, mode, &outcome);
    }
    if (applies(SyncCollection::kSettingsKeybindings)) {
      ApplyKeybindings(bundle, mode, &outcome);
    }
  }

  // 9: AdBlock
  if (categories.IsEnabled(SyncCategory::kAdBlocking) &&
      applies(SyncCollection::kAdblockConfig)) {
    ApplyAdBlock(bundle, mode, &outcome);
  }

  // 10-12: Boosts, Easels, Notes
  if (categories.IsEnabled(SyncCategory::kBoostsEaselsNotes)) {
    if (applies(SyncCollection::kBoostItem)) {
      ApplyBoosts(bundle, mode, &outcome);
    }
    if (applies(SyncCollection::kEaselDocument)) {
      ApplyEasels(bundle, mode, &outcome);
    }
    if (applies(SyncCollection::kNoteDocument)) {
      ApplyNotes(bundle, mode, &outcome);
    }
  }

  // 13: History
  if (categories.IsEnabled(SyncCategory::kHistory) &&
      applies(SyncCollection::kHistoryProfile)) {
    ApplyHistory(bundle, mode, &outcome);
  }

  // 14: Extensions
  if (categories.IsEnabled(SyncCategory::kExtensions) &&
      BundleHasCollection(bundle, SyncCollection::kExtensionsProfile)) {
    ApplyExtensions(bundle, &outcome);
  }

  // 15-16: Credentials & Site Permissions
  if (categories.IsEnabled(SyncCategory::kCredentialsAndPermissions)) {
    if (applies(SyncCollection::kSitePermissionsProfile)) {
      ApplySitePermissions(bundle, mode, &outcome);
    }
    if (BundleHasCollection(bundle, SyncCollection::kCredentialsProfile)) {
      ApplyCredentials(bundle, mode, &outcome);
    }
  }

  return outcome;
}

void SyncStorageAdapterImpl::ApplyWorkspace(
    const SyncRemoteBundle& bundle,
    SyncApplyMode mode,
    const SyncCategorySettings& categories,
    SyncApplyOutcome* outcome) {
  if (!deps_.model) {
    return;
  }

  const bool include_workspace = categories.IsEnabled(SyncCategory::kWorkspace);
  const bool include_today = categories.IsEnabled(SyncCategory::kTodayTabs);
  const bool replace = (mode == SyncApplyMode::kReplaceLocal);
  const bool clears_today =
      replace && include_today && bundle.is_full_snapshot;

  bool changed = false;

  // Apply window layout first (portable sidebar width/mode/toolbar visibility).
  if (include_workspace) {
    auto layout_recs =
        RecordsInCollection(bundle, SyncCollection::kWorkspaceWindowLayout);
    for (auto it = layout_recs.rbegin(); it != layout_recs.rend(); ++it) {
      if ((*it)->deleted || !(*it)->payload_json) continue;
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*(*it)->payload_json);
      auto layout =
          dict ? SyncCollectionCodecs::DecodeWindowLayout(*dict) : std::nullopt;
      if (layout) {
        std::vector<WindowID> std_win_ids;
        for (const BrowserWindowState& w : deps_.model->windows()) {
          if (w.style == WindowStyle::kStandard && !w.is_incognito) {
            std_win_ids.push_back(w.id);
          }
        }
        for (const WindowID& wid : std_win_ids) {
          deps_.model->SetSidebarWidth(wid, layout->sidebar_width);
          deps_.model->SetSidebarMode(wid, layout->sidebar_mode,
                                      /*register_undo=*/false);
          if (BrowserWindowState* w = deps_.model->FindWindow(wid)) {
            w->shows_toolbar = layout->shows_toolbar;
          }
        }
        changed = true;
      }
      break;
    }
  }

  const bool has_structural_changes =
      clears_today ||
      (include_workspace &&
       (BundleHasCollection(bundle, SyncCollection::kWorkspaceMeta) ||
        BundleHasCollection(bundle, SyncCollection::kWorkspaceProfile) ||
        BundleHasCollection(bundle, SyncCollection::kWorkspaceSpace))) ||
      (include_today &&
       BundleHasCollection(bundle, SyncCollection::kWorkspaceToday));

  if (!has_structural_changes) {
    if (changed && deps_.on_workspace_applied) {
      deps_.on_workspace_applied.Run({});
    }
    return;
  }

  // Build maps starting from current local workspace state.
  std::map<ProfileID, Profile> profiles;
  std::map<ProfileID, std::string> preferred_dirs;
  std::vector<ProfileID> local_profile_order;
  for (const Profile& p : deps_.model->profiles()) {
    profiles[p.id] = p;
    preferred_dirs[p.id] = p.data_directory_name;
    local_profile_order.push_back(p.id);
  }

  std::map<SpaceID, Space> spaces;
  std::vector<SpaceID> local_space_order;
  for (const Space& s : deps_.model->spaces()) {
    spaces[s.id] = s;
    local_space_order.push_back(s.id);
  }

  SyncedWorkspaceMetaPayload local_meta;
  local_meta.ordered_profile_ids = local_profile_order;
  local_meta.ordered_space_ids = local_space_order;
  local_meta.routing_rules = deps_.model->routing_rules();
  local_meta.default_destination = deps_.model->default_destination();
  SyncedWorkspaceMetaPayload meta = local_meta;

  bool remote_has_structure = false;
  for (const SyncRemoteRecord& r : bundle.records) {
    if (!r.deleted && (r.collection == SyncCollection::kWorkspaceProfile ||
                       r.collection == SyncCollection::kWorkspaceSpace)) {
      remote_has_structure = true;
      break;
    }
  }
  if (replace && include_workspace && remote_has_structure) {
    profiles.clear();
    spaces.clear();
  }

  if (include_workspace) {
    for (const SyncRemoteRecord* rec :
         RecordsInCollection(bundle, SyncCollection::kWorkspaceProfile)) {
      auto norm = NormalizeUuid(rec->record_id);
      if (!norm) continue;
      if (rec->deleted) {
        profiles.erase(*norm);
        continue;
      }
      if (!rec->payload_json) continue;
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodeProfile(*dict) : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("workspace.profile " + rec->record_id +
                                    ": unreadable payload.");
        continue;
      }
      decoded->id = *norm;
      if (dict) {
        const base::DictValue* inner = dict->FindDict("profile");
        const std::string* raw_dir =
            (inner ? inner : &*dict)->FindString("dataDirectoryName");
        preferred_dirs[*norm] = raw_dir ? *raw_dir : decoded->name;
      }
      profiles[*norm] = std::move(*decoded);
    }

    for (const SyncRemoteRecord* rec :
         RecordsInCollection(bundle, SyncCollection::kWorkspaceSpace)) {
      auto norm = NormalizeUuid(rec->record_id);
      if (!norm) continue;
      if (rec->deleted) {
        spaces.erase(*norm);
        continue;
      }
      if (!rec->payload_json) continue;
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodeSpace(*dict) : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("workspace.space " + rec->record_id +
                                    ": unreadable payload.");
        continue;
      }
      decoded->id = *norm;
      spaces[*norm] = std::move(*decoded);
    }

    auto meta_recs =
        RecordsInCollection(bundle, SyncCollection::kWorkspaceMeta);
    for (auto it = meta_recs.rbegin(); it != meta_recs.rend(); ++it) {
      if ((*it)->deleted || !(*it)->payload_json) continue;
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*(*it)->payload_json);
      auto remote_meta =
          dict ? SyncCollectionCodecs::DecodeWorkspaceMeta(*dict) : std::nullopt;
      if (!remote_meta) break;
      if (bundle.is_full_snapshot && mode == SyncApplyMode::kMergeOrDelta) {
        // First-sign-in merge: cloud order first, then local unique items/rules.
        meta.ordered_profile_ids = remote_meta->ordered_profile_ids;
        for (const auto& pid : local_meta.ordered_profile_ids) {
          if (std::find(meta.ordered_profile_ids.begin(),
                        meta.ordered_profile_ids.end(),
                        pid) == meta.ordered_profile_ids.end()) {
            meta.ordered_profile_ids.push_back(pid);
          }
        }
        meta.ordered_space_ids = remote_meta->ordered_space_ids;
        for (const auto& sid : local_meta.ordered_space_ids) {
          if (std::find(meta.ordered_space_ids.begin(),
                        meta.ordered_space_ids.end(),
                        sid) == meta.ordered_space_ids.end()) {
            meta.ordered_space_ids.push_back(sid);
          }
        }
        std::set<RuleID> remote_rule_ids;
        meta.routing_rules = remote_meta->routing_rules;
        for (const RoutingRule& r : remote_meta->routing_rules) {
          remote_rule_ids.insert(r.id);
        }
        for (const RoutingRule& r : local_meta.routing_rules) {
          if (!remote_rule_ids.contains(r.id)) {
            meta.routing_rules.push_back(r);
          }
        }
        meta.default_destination = remote_meta->default_destination;
      } else {
        meta = std::move(*remote_meta);
      }
      break;
    }
  }

  std::map<SpaceID, std::vector<SidebarNode>> remote_today;
  if (include_today) {
    for (const SyncRemoteRecord* rec :
         RecordsInCollection(bundle, SyncCollection::kWorkspaceToday)) {
      auto norm = NormalizeUuid(rec->record_id);
      if (!norm) continue;
      if (rec->deleted) {
        remote_today[*norm] = {};
        continue;
      }
      if (!rec->payload_json) continue;
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodeTodayTabs(*dict) : std::nullopt;
      if (decoded) {
        remote_today[*norm] = std::move(*decoded);
      }
    }
  }

  std::set<ProfileID> valid_profile_keys;
  std::vector<ProfileID> all_profile_candidates = meta.ordered_profile_ids;
  all_profile_candidates.insert(all_profile_candidates.end(),
                                local_profile_order.begin(),
                                local_profile_order.end());
  for (const auto& [pid, _] : profiles) {
    valid_profile_keys.insert(pid);
    all_profile_candidates.push_back(pid);
  }
  const std::vector<ProfileID> profile_order =
      OrderedUnique(all_profile_candidates, valid_profile_keys);

  std::set<SpaceID> valid_space_keys;
  std::vector<SpaceID> all_space_candidates = meta.ordered_space_ids;
  all_space_candidates.insert(all_space_candidates.end(),
                              local_space_order.begin(),
                              local_space_order.end());
  for (const auto& [sid, _] : spaces) {
    valid_space_keys.insert(sid);
    all_space_candidates.push_back(sid);
  }
  const std::vector<SpaceID> space_order =
      OrderedUnique(all_space_candidates, valid_space_keys);

  // Never collapse the workspace to zero Profiles or zero Spaces.
  if (profile_order.empty() || space_order.empty()) {
    return;
  }

  // Reserve taken profile directory names.
  std::set<std::string> used_dirs;
  if (deps_.get_reserved_profile_dirs) {
    for (const std::string& d : deps_.get_reserved_profile_dirs.Run()) {
      used_dirs.insert(base::ToLowerASCII(d));
    }
  }
  for (const Profile& local : deps_.model->profiles()) {
    used_dirs.insert(base::ToLowerASCII(local.data_directory_name));
  }
  bool keeps_default_dir = false;
  for (const ProfileID& pid : profile_order) {
    if (const Profile* local = deps_.model->FindProfile(pid);
        local &&
        base::EqualsCaseInsensitiveASCII(local->data_directory_name,
                                         "default")) {
      keeps_default_dir = true;
      break;
    }
  }
  if (!keeps_default_dir) {
    used_dirs.erase("default");
  }

  WorkspaceNodeMerger merger{deps_.model.get()};
  std::set<ProfileID> new_profile_ids;
  std::vector<Profile> built_profiles;
  for (const ProfileID& pid : profile_order) {
    Profile p = profiles[pid];
    if (const Profile* local = deps_.model->FindProfile(pid)) {
      p.data_directory_name = local->data_directory_name;
    } else {
      std::string pref = preferred_dirs.contains(pid) ? preferred_dirs[pid]
                                                      : p.name;
      p.data_directory_name = SanitizeProfileDirectoryName(pref, &used_dirs);
      new_profile_ids.insert(pid);
    }
    std::vector<Tab> merged_favs;
    for (const Tab& fav : p.favorites) {
      if (auto mt = merger.MergeTab(fav)) {
        merged_favs.push_back(std::move(*mt));
      }
    }
    p.favorites = std::move(merged_favs);
    built_profiles.push_back(std::move(p));
  }

  ProfileID fallback_profile_id = built_profiles.front().id;
  for (const Profile& p : built_profiles) {
    if (base::EqualsCaseInsensitiveASCII(p.data_directory_name, "default")) {
      fallback_profile_id = p.id;
      break;
    }
  }
  std::set<ProfileID> built_profile_set;
  for (const Profile& p : built_profiles) {
    built_profile_set.insert(p.id);
  }

  // Merge pinned nodes first so tabs moved Today -> Pinned land in Pinned.
  std::map<SpaceID, std::vector<SidebarNode>> merged_pinned;
  for (const SpaceID& sid : space_order) {
    std::vector<SidebarNode> nodes;
    for (const SidebarNode& n : spaces[sid].pinned) {
      if (auto mn = merger.MergeNode(n)) {
        nodes.push_back(std::move(*mn));
      }
    }
    merged_pinned[sid] = std::move(nodes);
  }

  std::vector<Space> built_spaces;
  for (const SpaceID& sid : space_order) {
    Space s = spaces[sid];
    s.pinned = std::move(merged_pinned[sid]);

    std::vector<SidebarNode> today_nodes;
    if (include_today && remote_today.contains(sid)) {
      for (const SidebarNode& n : remote_today[sid]) {
        if (auto mn = merger.MergeNode(n)) {
          today_nodes.push_back(std::move(*mn));
        }
      }
    } else if (clears_today) {
      today_nodes.clear();
    } else if (const Space* local_space = deps_.model->FindSpace(sid)) {
      for (const SidebarNode& n : local_space->today) {
        if (auto adopted = merger.AdoptLocal(n)) {
          today_nodes.push_back(std::move(*adopted));
        }
      }
    }
    s.today = std::move(today_nodes);

    if (!built_profile_set.contains(s.profile_id)) {
      s.profile_id = fallback_profile_id;
    }
    built_spaces.push_back(std::move(s));
  }

  // Install into BrowserModel using public API + RebuildIndex.
  // Step 1: Upsert profiles.
  for (const Profile& bp : built_profiles) {
    if (Profile* existing = deps_.model->FindProfile(bp.id)) {
      *existing = bp;
    } else {
      const std::string temp_name =
          "SyncProfile-" + GenerateUuidV4().substr(0, 8);
      ProfileID tmp_id =
          deps_.model->CreateProfile(temp_name, bp.icon, bp.settings);
      if (Profile* created = deps_.model->FindProfile(tmp_id)) {
        *created = bp;
        deps_.model->RebuildIndex();
      }
    }
  }

  // Step 2: Upsert spaces.
  std::set<SpaceID> target_space_ids;
  for (const Space& bs : built_spaces) {
    target_space_ids.insert(bs.id);
    if (Space* existing = deps_.model->FindSpace(bs.id)) {
      *existing = bs;
    } else {
      SpaceID tmp_id = deps_.model->CreateSpace(bs.profile_id, bs.title,
                                                bs.icon, bs.theme);
      if (Space* created = deps_.model->FindSpace(tmp_id)) {
        *created = bs;
        deps_.model->RebuildIndex();
      }
    }
  }

  // Step 3: Remove obsolete spaces (preserving at least one).
  std::vector<SpaceID> doomed_spaces;
  for (const Space& s : deps_.model->spaces()) {
    if (!target_space_ids.contains(s.id)) {
      doomed_spaces.push_back(s.id);
    }
  }
  for (const SpaceID& sid : doomed_spaces) {
    if (deps_.model->spaces().size() <= 1) break;
    deps_.model->DeleteSpace(sid, /*archive_tabs=*/false);
  }

  // Step 4: Remove obsolete profiles (after spaces have been reassigned/deleted).
  std::vector<ProfileID> doomed_profiles;
  for (const Profile& p : deps_.model->profiles()) {
    if (!built_profile_set.contains(p.id)) {
      doomed_profiles.push_back(p.id);
    }
  }
  for (const ProfileID& pid : doomed_profiles) {
    deps_.model->DeleteProfile(pid);
  }

  // Step 5: Routing rules & default destination.
  deps_.model->SetRoutingRules(std::move(meta.routing_rules));
  deps_.model->SetDefaultDestination(std::move(meta.default_destination));

  // Ensure every window points to a valid Space.
  const SpaceID first_space_id = deps_.model->spaces().front().id;
  for (const BrowserWindowState& w : deps_.model->windows()) {
    if (!deps_.model->FindSpace(w.focused_space_id)) {
      deps_.model->FocusSpace(w.id, first_space_id);
    }
  }

  deps_.model->RebuildIndex();
  deps_.model->ClearUndoHistory();

  if (deps_.on_workspace_applied) {
    deps_.on_workspace_applied.Run(new_profile_ids);
  }
}

void SyncStorageAdapterImpl::ApplyArchive(const SyncRemoteBundle& bundle,
                                          SyncApplyMode mode,
                                          SyncApplyOutcome* outcome) {
  if (!deps_.model) {
    return;
  }
  const bool replace_all = (mode == SyncApplyMode::kReplaceLocal);
  std::set<ProfileID> seen_profiles;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kArchiveProfile)) {
    auto norm = NormalizeUuid(rec->record_id);
    if (!norm) continue;
    const Profile* profile = deps_.model->FindProfile(*norm);
    if (!profile) continue;
    seen_profiles.insert(*norm);

    std::vector<ArchivedTabRecord> records;
    if (!rec->deleted && rec->payload_json) {
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded = dict ? SyncCollectionCodecs::DecodeArchiveProfile(*dict)
                          : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("archive.profile " + rec->record_id +
                                    ": unreadable payload.");
        continue;
      }
      records = std::move(*decoded);
    }

    if (deps_.apply_archive) {
      if (!deps_.apply_archive.Run(*norm, records, replace_all || rec->deleted)) {
        outcome->warnings.push_back("Archived tabs for profile \"" +
                                    profile->name + "\" could not be updated.");
      }
    } else if (!deps_.user_data_dir.empty()) {
      base::FilePath db_path = ResolveExistingSqlite(
          ProfileDirFor(*profile).AppendASCII("State"), "Archive.sqlite",
          "archive.sqlite3");
      ArchiveStore store(db_path);
      if (store.Open()) {
        if (replace_all || rec->deleted) {
          store.DeleteAll();
        }
        if (!records.empty()) {
          store.Archive(records);
        }
      }
    }
  }

  // Full cloud replacement: clear local archive on profiles absent in cloud.
  if (replace_all && bundle.is_full_snapshot) {
    for (const Profile& profile : deps_.model->profiles()) {
      if (seen_profiles.contains(profile.id)) continue;
      if (deps_.apply_archive) {
        deps_.apply_archive.Run(profile.id, {}, /*replace_all=*/true);
      } else if (!deps_.user_data_dir.empty()) {
        base::FilePath db_path = ResolveExistingSqlite(
            ProfileDirFor(profile).AppendASCII("State"), "Archive.sqlite",
            "archive.sqlite3");
        if (base::PathExists(db_path)) {
          ArchiveStore store(db_path);
          if (store.Open()) {
            store.DeleteAll();
          }
        }
      }
    }
  }
}

void SyncStorageAdapterImpl::ApplyPreferences(const SyncRemoteBundle& bundle,
                                              SyncApplyMode mode,
                                              SyncApplyOutcome* outcome) {
  auto recs = RecordsInCollection(bundle, SyncCollection::kSettingsPreferences);
  std::map<std::string, base::Value> remote_values;
  bool have_payload = false;

  if (!recs.empty()) {
    const SyncRemoteRecord* last = recs.back();
    if (last->deleted) {
      have_payload = true;
    } else if (last->payload_json) {
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*last->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodePreferences(*dict) : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back(
            "settings.preferences: unreadable payload.");
        return;
      }
      remote_values = std::move(*decoded);
      have_payload = true;
    }
  } else if (mode == SyncApplyMode::kReplaceLocal && bundle.is_full_snapshot) {
    have_payload = true;
  }

  if (!have_payload) {
    return;
  }

  const bool remove_missing =
      (mode == SyncApplyMode::kReplaceLocal || !bundle.is_full_snapshot);
  if (!WriteLocalPortablePreferences(remote_values, remove_missing)) {
    outcome->warnings.push_back(
        "Synced preferences could not be saved locally.");
  }
}

void SyncStorageAdapterImpl::ApplyKeybindings(const SyncRemoteBundle& bundle,
                                              SyncApplyMode mode,
                                              SyncApplyOutcome* outcome) {
  auto recs = RecordsInCollection(bundle, SyncCollection::kSettingsKeybindings);
  if (recs.empty()) {
    if (mode == SyncApplyMode::kReplaceLocal && bundle.is_full_snapshot) {
      if (!deps_.user_data_dir.empty()) {
        base::DeleteFile(KeybindingsFilePath());
      }
      if (deps_.command_registry) {
        deps_.command_registry->ResetAllOverrides();
      }
      if (deps_.on_keybindings_applied) {
        deps_.on_keybindings_applied.Run();
      }
    }
    return;
  }

  const SyncRemoteRecord* last = recs.back();
  if (last->deleted) {
    if (!deps_.user_data_dir.empty()) {
      base::DeleteFile(KeybindingsFilePath());
    }
    if (deps_.command_registry) {
      deps_.command_registry->ResetAllOverrides();
    }
    if (deps_.on_keybindings_applied) {
      deps_.on_keybindings_applied.Run();
    }
    return;
  }

  if (!last->payload_json) {
    return;
  }
  auto dict = SyncCollectionCodecs::DecodeJsonDict(*last->payload_json);
  auto store_dict =
      dict ? SyncCollectionCodecs::DecodeKeybindings(*dict) : std::nullopt;
  if (!store_dict) {
    outcome->warnings.push_back("settings.keybindings: unreadable payload.");
    return;
  }

  if (!deps_.user_data_dir.empty()) {
    if (!store_dict->FindInt("version")) {
      store_dict->Set("version", CommandRegistry::kKeybindingsSchemaVersion);
    }
    if (!base::CreateDirectory(KeybindingsFilePath().DirName())) {
      outcome->warnings.push_back(
          "Synced keyboard shortcuts could not create State directory.");
      return;
    }
    std::string json;
    if (!base::JSONWriter::WriteWithOptions(
            *store_dict, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json) ||
        !base::ImportantFileWriter::WriteFileAtomically(KeybindingsFilePath(),
                                                        json)) {
      outcome->warnings.push_back(
          "Synced keyboard shortcuts could not be written.");
      return;
    }
    if (deps_.command_registry) {
      std::string err;
      if (!deps_.command_registry->LoadOverrides(KeybindingsFilePath(), &err)) {
        outcome->warnings.push_back(
            "Synced keyboard shortcuts failed to load: " + err);
      }
    }
  }
  if (deps_.on_keybindings_applied) {
    deps_.on_keybindings_applied.Run();
  }
}

void SyncStorageAdapterImpl::ApplyAdBlock(const SyncRemoteBundle& bundle,
                                          SyncApplyMode mode,
                                          SyncApplyOutcome* outcome) {
  const bool full_replace =
      (mode == SyncApplyMode::kReplaceLocal && bundle.is_full_snapshot);
  auto recs = RecordsInCollection(bundle, SyncCollection::kAdblockConfig);
  if (recs.empty() && !full_replace) {
    return;
  }

  SyncedAdBlockConfigPayload config;
  bool has_remote = false;
  if (!recs.empty()) {
    const SyncRemoteRecord* last = recs.back();
    if (!last->deleted && last->payload_json) {
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*last->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodeAdBlockConfig(*dict) : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("adblock.config: unreadable payload.");
        return;
      }
      config = std::move(*decoded);
      has_remote = true;
    }
  }

  if (deps_.apply_adblock) {
    auto warns = deps_.apply_adblock.Run(
        config, mode == SyncApplyMode::kReplaceLocal, bundle.is_full_snapshot);
    outcome->warnings.insert(outcome->warnings.end(), warns.begin(),
                             warns.end());
    return;
  }

  if (!deps_.model) {
    return;
  }

  const bool remove_missing =
      (mode == SyncApplyMode::kReplaceLocal || !bundle.is_full_snapshot);

  for (const Profile& profile : deps_.model->profiles()) {
    auto it = config.profiles.find(profile.id);
    if (it == config.profiles.end() && !full_replace) {
      continue;
    }
    SyncedAdBlockProfilePayload target =
        (it != config.profiles.end()) ? it->second
                                      : SyncedAdBlockProfilePayload{};

    if (deps_.get_adblock_service) {
      OpenAdBlockProfileService* svc =
          deps_.get_adblock_service.Run(profile.id);
      if (!svc) {
        outcome->warnings.push_back("Ad blocking settings for profile \"" +
                                    profile.name + "\" could not be applied.");
        continue;
      }
      if (has_remote) {
        svc->SetEnabled(config.global_enabled);
      }
      if (it == config.profiles.end() && full_replace) {
        svc->SetExcludedDomains({});
        svc->ResetLists();
        continue;
      }
      if (remove_missing) {
        svc->SetExcludedDomains(target.excluded_domains);
        svc->SetEnabledListIds(target.enabled_list_ids);
      } else {
        for (const std::string& dom : target.excluded_domains) {
          svc->AddExcludedDomain(dom);
        }
        for (const std::string& lid : target.enabled_list_ids) {
          svc->SetListEnabled(lid, true);
        }
      }
      if (!target.custom_rules.empty() || remove_missing) {
        svc->SetCustomRules(target.custom_rules);
      }
    } else if (!deps_.user_data_dir.empty()) {
      WriteAdBlockProfileToDisk(ProfileDirFor(profile).AppendASCII("AdBlock"),
                                has_remote ? config.global_enabled : true,
                                target);
    }
  }
}

void SyncStorageAdapterImpl::ApplyBoosts(const SyncRemoteBundle& bundle,
                                         SyncApplyMode mode,
                                         SyncApplyOutcome* outcome) {
  if (!deps_.model) {
    return;
  }
  std::map<ProfileID, std::vector<Boost>> upserts_by_profile;
  std::map<ProfileID, std::vector<std::string>> deletes_by_profile;
  std::map<ProfileID, std::set<std::string>> remote_ids_by_profile;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kBoostItem)) {
    size_t colon = rec->record_id.find(':');
    if (colon == std::string::npos) continue;
    auto pid = NormalizeUuid(rec->record_id.substr(0, colon));
    auto bid = NormalizeUuid(rec->record_id.substr(colon + 1));
    if (!pid || !bid || !deps_.model->FindProfile(*pid)) continue;

    if (rec->deleted) {
      deletes_by_profile[*pid].push_back(*bid);
      continue;
    }
    if (!rec->payload_json) continue;
    auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
    ProfileID decoded_pid;
    auto boost = dict ? SyncCollectionCodecs::DecodeBoostItem(*dict, &decoded_pid)
                      : std::nullopt;
    if (!boost) {
      outcome->warnings.push_back("boost.item " + rec->record_id +
                                  ": unreadable payload.");
      continue;
    }
    boost->id = *bid;
    boost->profile_id = *pid;
    remote_ids_by_profile[*pid].insert(*bid);
    upserts_by_profile[*pid].push_back(std::move(*boost));
  }

  const bool replace_all = (mode == SyncApplyMode::kReplaceLocal);
  for (const Profile& profile : deps_.model->profiles()) {
    const auto& upserts = upserts_by_profile[profile.id];
    const auto& deletes = deletes_by_profile[profile.id];
    if (!replace_all && upserts.empty() && deletes.empty()) {
      continue;
    }

    if (deps_.apply_boosts) {
      if (!deps_.apply_boosts.Run(profile.id, upserts, deletes, replace_all)) {
        outcome->warnings.push_back("Boosts for profile \"" + profile.name +
                                    "\" could not be updated.");
      }
      continue;
    }

    std::unique_ptr<BoostStore> fallback_store;
    BoostStore* store =
        deps_.get_boost_store ? deps_.get_boost_store.Run(profile.id) : nullptr;
    if (!store && !deps_.user_data_dir.empty()) {
      fallback_store =
          std::make_unique<BoostStore>(profile.id, ProfileDirFor(profile));
      fallback_store->Load();
      store = fallback_store.get();
    }
    if (!store) continue;

    bool touched = false;
    for (const std::string& bid : deletes) {
      if (store->Delete(bid)) touched = true;
    }
    for (const Boost& b : upserts) {
      store->Upsert(b);
      touched = true;
    }
    if (replace_all) {
      const auto& keep = remote_ids_by_profile[profile.id];
      for (const Boost& existing : store->AllBoosts()) {
        if (!keep.contains(existing.id)) {
          if (store->Delete(existing.id)) touched = true;
        }
      }
    }
    if (touched) {
      store->SaveNow();
      if (deps_.on_boosts_changed) {
        deps_.on_boosts_changed.Run(profile.id);
      }
    }
  }
}

void SyncStorageAdapterImpl::ApplyEasels(const SyncRemoteBundle& bundle,
                                         SyncApplyMode mode,
                                         SyncApplyOutcome* outcome) {
  std::optional<DocumentStore> fallback_store;
  const DocumentStore* store = deps_.document_store.get();
  if (!store) {
    if (deps_.user_data_dir.empty()) return;
    fallback_store.emplace(deps_.user_data_dir);
    store = &*fallback_store;
  }

  std::set<std::string> remote_ids;
  bool changed = false;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kEaselDocument)) {
    std::string id = base::ToLowerASCII(rec->record_id);
    if (!DocumentStore::IsValidDocumentId(id)) continue;

    if (rec->deleted) {
      if (store->DeleteEasel(id)) changed = true;
      continue;
    }
    if (!rec->payload_json) continue;
    remote_ids.insert(id);

    auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
    std::vector<SyncedAssetRef> assets;
    auto doc = dict ? SyncCollectionCodecs::DecodeEaselDocument(*dict, &assets)
                    : std::nullopt;
    if (!doc) {
      outcome->warnings.push_back("easel.document " + id +
                                  ": unreadable payload.");
      continue;
    }
    doc->id = id;

    for (const SyncedAssetRef& asset : assets) {
      if (!DocumentStore::IsValidAssetFilename(asset.filename)) {
        outcome->warnings.push_back(
            "Skipped an Easel image with an invalid filename.");
        continue;
      }
      auto dest = store->ResolveEaselImagePath(id, asset.filename);
      if (!dest) continue;
      auto bit = bundle.blobs.find(asset.blob_id);
      if (bit == bundle.blobs.end()) {
        if (!base::PathExists(*dest)) {
          outcome->warnings.push_back("A synced Easel image is missing.");
        }
        continue;
      }
      if (!WriteAssetAtomicIfChanged(*dest, bit->second)) {
        outcome->warnings.push_back("Could not save a synced Easel image.");
      }
    }

    if (store->SaveEasel(*doc)) {
      changed = true;
    } else {
      outcome->warnings.push_back("A synced Easel could not be saved.");
    }
  }

  if (mode == SyncApplyMode::kReplaceLocal) {
    for (const EaselIndexEntry& entry : store->ListEasels()) {
      if (!remote_ids.contains(base::ToLowerASCII(entry.id))) {
        if (store->DeleteEasel(entry.id)) changed = true;
      }
    }
  }

  if (changed && deps_.on_documents_changed) {
    deps_.on_documents_changed.Run();
  }
}

void SyncStorageAdapterImpl::ApplyNotes(const SyncRemoteBundle& bundle,
                                        SyncApplyMode mode,
                                        SyncApplyOutcome* outcome) {
  std::optional<DocumentStore> fallback_store;
  const DocumentStore* store = deps_.document_store.get();
  if (!store) {
    if (deps_.user_data_dir.empty()) return;
    fallback_store.emplace(deps_.user_data_dir);
    store = &*fallback_store;
  }

  std::set<std::string> remote_ids;
  bool changed = false;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kNoteDocument)) {
    std::string id = base::ToLowerASCII(rec->record_id);
    if (!DocumentStore::IsValidDocumentId(id)) continue;

    if (rec->deleted) {
      if (store->DeleteNote(id)) changed = true;
      continue;
    }
    if (!rec->payload_json) continue;
    remote_ids.insert(id);

    auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
    std::vector<SyncedAssetRef> assets;
    auto doc = dict ? SyncCollectionCodecs::DecodeNoteDocument(*dict, &assets)
                    : std::nullopt;
    if (!doc) {
      outcome->warnings.push_back("note.document " + id +
                                  ": unreadable payload.");
      continue;
    }
    doc->id = id;

    for (const SyncedAssetRef& asset : assets) {
      if (!DocumentStore::IsValidAssetFilename(asset.filename)) {
        outcome->warnings.push_back(
            "Skipped a Note attachment with an invalid filename.");
        continue;
      }
      auto dest = store->ResolveNoteAssetPath(id, asset.filename);
      if (!dest) continue;
      auto bit = bundle.blobs.find(asset.blob_id);
      if (bit == bundle.blobs.end()) {
        if (!base::PathExists(*dest)) {
          outcome->warnings.push_back("A synced Note attachment is missing.");
        }
        continue;
      }
      if (!WriteAssetAtomicIfChanged(*dest, bit->second)) {
        outcome->warnings.push_back("Could not save a synced Note attachment.");
      }
    }

    if (store->SaveNote(*doc)) {
      changed = true;
    } else {
      outcome->warnings.push_back("A synced Note could not be saved.");
    }
  }

  if (mode == SyncApplyMode::kReplaceLocal) {
    for (const NoteIndexEntry& entry : store->ListNotes()) {
      if (!remote_ids.contains(base::ToLowerASCII(entry.id))) {
        if (store->DeleteNote(entry.id)) changed = true;
      }
    }
  }

  if (changed && deps_.on_documents_changed) {
    deps_.on_documents_changed.Run();
  }
}

void SyncStorageAdapterImpl::ApplyHistory(const SyncRemoteBundle& bundle,
                                          SyncApplyMode mode,
                                          SyncApplyOutcome* outcome) {
  if (!deps_.model) {
    return;
  }
  const bool replace_all = (mode == SyncApplyMode::kReplaceLocal);
  std::set<ProfileID> seen_profiles;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kHistoryProfile)) {
    auto norm = NormalizeUuid(rec->record_id);
    if (!norm) continue;
    const Profile* profile = deps_.model->FindProfile(*norm);
    if (!profile) continue;
    seen_profiles.insert(*norm);

    std::vector<HistoryEntry> entries;
    if (!rec->deleted && rec->payload_json) {
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded = dict ? SyncCollectionCodecs::DecodeHistoryProfile(*dict)
                          : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("history.profile " + rec->record_id +
                                    ": unreadable payload.");
        continue;
      }
      entries = std::move(*decoded);
    }

    if (deps_.apply_history) {
      if (!deps_.apply_history.Run(*norm, entries, replace_all || rec->deleted)) {
        outcome->warnings.push_back("History for profile \"" + profile->name +
                                    "\" could not be updated.");
      }
    } else if (!deps_.user_data_dir.empty()) {
      base::FilePath db_path = ResolveExistingSqlite(
          ProfileDirFor(*profile).AppendASCII("State"), "History.sqlite",
          "history.sqlite3");
      HistoryStore store(db_path);
      if (store.Open()) {
        if (replace_all || rec->deleted) {
          store.ClearRange(std::nullopt,
                           base::Time::Now().InSecondsFSinceUnixEpoch() +
                               86400.0);
        }
        for (const HistoryEntry& e : entries) {
          store.RecordVisit(e.url, e.title, e.last_visit, "sync",
                            e.typed_count > 0);
        }
      }
    }
  }

  if (replace_all && bundle.is_full_snapshot) {
    for (const Profile& profile : deps_.model->profiles()) {
      if (seen_profiles.contains(profile.id)) continue;
      if (deps_.apply_history) {
        deps_.apply_history.Run(profile.id, {}, /*replace_all=*/true);
      } else if (!deps_.user_data_dir.empty()) {
        base::FilePath db_path = ResolveExistingSqlite(
            ProfileDirFor(profile).AppendASCII("State"), "History.sqlite",
            "history.sqlite3");
        if (base::PathExists(db_path)) {
          HistoryStore store(db_path);
          if (store.Open()) {
            store.ClearRange(std::nullopt,
                             base::Time::Now().InSecondsFSinceUnixEpoch() +
                                 86400.0);
          }
        }
      }
    }
  }
}

void SyncStorageAdapterImpl::ApplyExtensions(const SyncRemoteBundle& bundle,
                                             SyncApplyOutcome* outcome) {
  if (!deps_.model) {
    return;
  }
  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kExtensionsProfile)) {
    if (rec->deleted || !rec->payload_json) continue;
    auto norm = NormalizeUuid(rec->record_id);
    if (!norm || !deps_.model->FindProfile(*norm)) continue;

    auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
    auto decoded = dict ? SyncCollectionCodecs::DecodeExtensionsProfile(*dict)
                        : std::nullopt;
    if (!decoded) {
      outcome->warnings.push_back("extensions.profile " + rec->record_id +
                                  ": unreadable payload.");
      continue;
    }

    std::vector<SyncedExtensionRecord> valid;
    for (auto& ext : *decoded) {
      if (ext.from_web_store && IsValidWebStoreExtensionId(ext.extension_id)) {
        valid.push_back(std::move(ext));
      }
    }

    if (deps_.apply_extensions) {
      auto pending = deps_.apply_extensions.Run(*norm, valid);
      outcome->pending_extension_installs.insert(
          outcome->pending_extension_installs.end(),
          std::make_move_iterator(pending.begin()),
          std::make_move_iterator(pending.end()));
    } else {
      for (const SyncedExtensionRecord& ext : valid) {
        SyncPendingExtension p;
        p.profile_id = *norm;
        p.extension_id = ext.extension_id;
        p.name = ext.name;
        p.is_enabled = ext.is_enabled;
        p.is_pinned = ext.is_pinned;
        p.pinned_index = ext.pinned_index;
        outcome->pending_extension_installs.push_back(std::move(p));
      }
    }
  }
}

void SyncStorageAdapterImpl::ApplyCredentials(const SyncRemoteBundle& bundle,
                                              SyncApplyMode mode,
                                              SyncApplyOutcome* outcome) {
  if (!deps_.model || !deps_.apply_credentials) {
    return;
  }
  const bool replace_all = (mode == SyncApplyMode::kReplaceLocal);
  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kCredentialsProfile)) {
    if (rec->deleted || !rec->payload_json) continue;
    auto norm = NormalizeUuid(rec->record_id);
    if (!norm || !deps_.model->FindProfile(*norm)) continue;

    auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
    auto decoded =
        dict ? SyncCollectionCodecs::DecodeCredentialsProfile(*dict)
             : std::nullopt;
    if (!decoded) {
      outcome->warnings.push_back("credentials.profile " + rec->record_id +
                                  ": unreadable payload.");
      continue;
    }
    decoded->profile_id = *norm;
    auto warns = deps_.apply_credentials.Run(*decoded, replace_all);
    outcome->warnings.insert(outcome->warnings.end(), warns.begin(),
                             warns.end());
  }
}

void SyncStorageAdapterImpl::ApplySitePermissions(
    const SyncRemoteBundle& bundle,
    SyncApplyMode mode,
    SyncApplyOutcome* outcome) {
  if (!deps_.model || !deps_.apply_site_permissions) {
    return;
  }
  const bool replace_all = (mode == SyncApplyMode::kReplaceLocal);
  std::set<ProfileID> seen_profiles;

  for (const SyncRemoteRecord* rec :
       RecordsInCollection(bundle, SyncCollection::kSitePermissionsProfile)) {
    auto norm = NormalizeUuid(rec->record_id);
    if (!norm || !deps_.model->FindProfile(*norm)) continue;
    seen_profiles.insert(*norm);

    SyncedSitePermissionsProfilePayload payload;
    payload.profile_id = *norm;
    if (!rec->deleted && rec->payload_json) {
      auto dict = SyncCollectionCodecs::DecodeJsonDict(*rec->payload_json);
      auto decoded =
          dict ? SyncCollectionCodecs::DecodeSitePermissionsProfile(*dict)
               : std::nullopt;
      if (!decoded) {
        outcome->warnings.push_back("sitePermissions.profile " +
                                    rec->record_id + ": unreadable payload.");
        continue;
      }
      payload = std::move(*decoded);
      payload.profile_id = *norm;
    }
    auto warns =
        deps_.apply_site_permissions.Run(payload, replace_all || rec->deleted);
    outcome->warnings.insert(outcome->warnings.end(), warns.begin(),
                             warns.end());
  }

  if (replace_all && bundle.is_full_snapshot) {
    for (const Profile& profile : deps_.model->profiles()) {
      if (seen_profiles.contains(profile.id)) continue;
      SyncedSitePermissionsProfilePayload empty;
      empty.profile_id = profile.id;
      deps_.apply_site_permissions.Run(empty, /*replace_all=*/true);
    }
  }
}

// ============================================================================
// PrepareLocalBackup
// ============================================================================

bool SyncStorageAdapterImpl::PrepareLocalBackup(
    const base::FilePath& backup_dir) {
  if (!base::CreateDirectory(backup_dir)) {
    return false;
  }
  if (!deps_.user_data_dir.empty()) {
    const base::FilePath state = StateDir();
    CopyFileIfPresent(state.AppendASCII("browser.json"),
                      backup_dir.AppendASCII("State").AppendASCII("browser.json"));
    CopyFileIfPresent(
        state.AppendASCII("Preferences.json"),
        backup_dir.AppendASCII("State").AppendASCII("Preferences.json"));
    CopyFileIfPresent(
        state.AppendASCII("keybindings.json"),
        backup_dir.AppendASCII("State").AppendASCII("keybindings.json"));

    if (deps_.model) {
      for (const Profile& profile : deps_.model->profiles()) {
        const base::FilePath src_prof = ProfileDirFor(profile);
        const base::FilePath dst_prof = backup_dir.AppendASCII("Profiles")
                                            .AppendASCII(
                                                profile.data_directory_name);
        CopyFileIfPresent(
            src_prof.AppendASCII("Boosts").AppendASCII("boosts.json"),
            dst_prof.AppendASCII("Boosts").AppendASCII("boosts.json"));
        CopyFileIfPresent(
            src_prof.AppendASCII("AdBlock").AppendASCII("adblock-config.json"),
            dst_prof.AppendASCII("AdBlock").AppendASCII("adblock-config.json"));
        CopyFileIfPresent(
            src_prof.AppendASCII("AdBlock").AppendASCII("exclusions.json"),
            dst_prof.AppendASCII("AdBlock").AppendASCII("exclusions.json"));
        CopyFileIfPresent(
            src_prof.AppendASCII("AdBlock").AppendASCII("custom-rules.txt"),
            dst_prof.AppendASCII("AdBlock").AppendASCII("custom-rules.txt"));
      }
    }

    // Back up Easel and Note JSON documents (bounded to avoid huge media copies).
    const base::FilePath easels_dir = deps_.user_data_dir.AppendASCII("Easels");
    if (base::DirectoryExists(easels_dir)) {
      base::FileEnumerator e(easels_dir, /*recursive=*/false,
                             base::FileEnumerator::DIRECTORIES);
      for (base::FilePath d = e.Next(); !d.empty(); d = e.Next()) {
        CopyFileIfPresent(
            d.AppendASCII("document.json"),
            backup_dir.AppendASCII("Easels")
                .Append(d.BaseName())
                .AppendASCII("document.json"));
      }
    }
    const base::FilePath notes_dir = deps_.user_data_dir.AppendASCII("Notes");
    if (base::DirectoryExists(notes_dir)) {
      base::FileEnumerator e(notes_dir, /*recursive=*/false,
                             base::FileEnumerator::FILES);
      for (base::FilePath f = e.Next(); !f.empty(); f = e.Next()) {
        if (f.Extension() == FILE_PATH_LITERAL(".json")) {
          CopyFileIfPresent(
              f, backup_dir.AppendASCII("Notes").Append(f.BaseName()));
        }
      }
    }
  }

  PruneOldBackups(backup_dir.DirName(), kMaxBackupRetention);
  return true;
}

}  // namespace open_unified
