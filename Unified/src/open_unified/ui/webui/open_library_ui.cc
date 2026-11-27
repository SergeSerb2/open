// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/ui/webui/open_library_ui.h"

#include <algorithm>
#include <map>
#include <set>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/base64url.h"
#include "base/base_paths.h"
#include "base/environment.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/ref_counted_memory.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/strings/strcat.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "build/build_config.h"
#include "chrome/browser/platform_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_paths.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "open_unified/browser/open_download_bridge.h"
#include "open_unified/browser/open_json.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/browser/open_window_controller.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/core/documents/document_store.h"
#include "open_unified/core/store/sqlite_stores.h"
#include "ui/base/clipboard/file_info.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/shell_dialogs/select_file_dialog.h"   // nogncheck
#include "ui/shell_dialogs/select_file_policy.h"   // nogncheck
#include "ui/shell_dialogs/selected_file_info.h"   // nogncheck
#include "url/gurl.h"

#if BUILDFLAG(IS_WIN)
#include <windows.h>

#include <shellapi.h>

// Guard against Win32 macro collision with BrowserModel::FindWindow (keep
// base/win/windows_types.h's file_util.h macros intact so base::CreateDirectory
// resolves to its *W export).
#ifdef FindWindow
#undef FindWindow
#endif
#endif

namespace open_unified::webui {

namespace {

// --- Method and event names --------------------------------------------------
//
// open_ipc_contract.h holds the legacy library.* names; the drawer's methods
// are local to this domain (bridge-free pages call them by string).
constexpr char kClose[] = "library.close";
constexpr char kThemeGet[] = "library.theme.get";
constexpr char kHistoryList[] = "library.history.list";
constexpr char kHistoryDelete[] = "library.history.delete";
constexpr char kHistoryClear[] = "library.history.clear";
constexpr char kArchiveList[] = "library.archive.list";
constexpr char kArchiveRestore[] = "library.archive.restore";
constexpr char kArchiveDelete[] = "library.archive.delete";
constexpr char kArchiveClearAll[] = "library.archive.clearAll";
constexpr char kArchivePeek[] = "library.archive.peek";
constexpr char kDownloadsList[] = "library.downloads.list";
constexpr char kDownloadsClear[] = "library.downloads.clear";
constexpr const char* kDownloadActions[] = {"pause",  "resume", "cancel",
                                            "retry",  "open",   "reveal",
                                            "trash",  "remove"};
constexpr char kMediaList[] = "library.media.list";
constexpr char kMediaAddFolder[] = "library.media.addFolder";
constexpr char kMediaRemoveFolder[] = "library.media.removeFolder";
constexpr char kMediaPickFolder[] = "library.pickMediaFolder";
constexpr const char* kMediaActions[] = {"open", "reveal", "copyImage",
                                         "delete"};
constexpr char kSpacesList[] = "library.spaces.list";
constexpr char kSpacesCreate[] = "library.spaces.create";
constexpr char kSpacesUpdate[] = "library.spaces.update";
constexpr char kSpacesDelete[] = "library.spaces.delete";
constexpr char kSpacesSwitch[] = "library.spaces.switch";
constexpr char kSpacesReorder[] = "library.spaces.reorder";
constexpr char kSpacesSetProfile[] = "library.spaces.setProfile";
constexpr char kBoostsListAll[] = "library.boosts.list";
constexpr char kDocumentsList[] = "library.documents.list";
constexpr char kDocumentsCreate[] = "library.documents.create";
constexpr char kDocumentsDelete[] = "library.documents.delete";

// Host-facing events (OpenBrowserService::Observer receives every
// BroadcastEvent; open:// pages ignore names they do not know).
constexpr char kEventCloseRequested[] = "open.libraryCloseRequested";

// --- Limits ------------------------------------------------------------------

constexpr int kDefaultLimit = 200;
constexpr int kMaxLimit = 2000;
constexpr int kMaxOffset = 100000;
// Merged ("all" or search) History pages read at most this many rows per
// Profile.
constexpr int kMaxHistoryWindow = 5000;
constexpr size_t kMaxQueryBytes = 512;
constexpr size_t kMaxMediaPerRoot = 400;
constexpr size_t kMaxFolderSources = 16;
constexpr int64_t kMaxThumbBytes = 40 * 1024 * 1024;
constexpr int64_t kMaxMediaFileBytes = 256 * 1024 * 1024;
constexpr size_t kMaxFolderSourcesFileBytes = 64 * 1024;
constexpr char kFolderSourcesFile[] = "LibraryFolderSources.json";
constexpr char kCapturesDir[] = "Captures";

constexpr net::NetworkTrafficAnnotationTag kRetryTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_library_download_retry", R"(
        semantics {
          sender: "Open Library"
          description:
            "Downloads a file again after the user chose Retry on a failed "
            "download in the Library's Downloads section."
          trigger: "The user clicks Retry on a failed download."
          data: "The URL of the original download."
          destination: WEBSITE
        }
        policy {
          cookies_allowed: YES
          cookies_store: "user"
          setting: "This request runs only after a user action."
          policy_exception_justification: "Not implemented."
        })");

// --- Small helpers -----------------------------------------------------------

std::string Query(const base::DictValue& payload) {
  std::string query =
      std::string(base::TrimWhitespaceASCII(json::GetString(payload, "query"),
                                            base::TRIM_ALL));
  if (query.size() > kMaxQueryBytes) {
    query.resize(kMaxQueryBytes);
  }
  return query;
}

int Limit(const base::DictValue& payload) {
  return std::clamp(json::GetInt(payload, "limit", kDefaultLimit), 1,
                    kMaxLimit);
}

int Offset(const base::DictValue& payload) {
  return std::clamp(json::GetInt(payload, "offset", 0), 0, kMaxOffset);
}

TimestampSec NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

TimestampSec LocalDayStart(TimestampSec t) {
  return base::Time::FromSecondsSinceUnixEpoch(t)
      .LocalMidnight()
      .InSecondsFSinceUnixEpoch();
}

ProfileServices* ServicesFor(const ProfileID& id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  return service && !id.empty() ? service->ProfileServicesFor(id) : nullptr;
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

std::string B64(std::string_view value) {
  std::string out;
  base::Base64UrlEncode(value, base::Base64UrlEncodePolicy::OMIT_PADDING,
                        &out);
  return out;
}

std::optional<std::string> UnB64(std::string_view value) {
  std::string out;
  if (value.empty() ||
      !base::Base64UrlDecode(value, base::Base64UrlDecodePolicy::IGNORE_PADDING,
                             &out)) {
    return std::nullopt;
  }
  return out;
}

// Every whitespace-separated word of |query| occurs in one of |fields|
// (ASCII case-insensitive).
bool MatchesAllWords(std::string_view query,
                     std::initializer_list<std::string_view> fields) {
  if (query.empty()) {
    return true;
  }
  std::string haystack;
  for (std::string_view field : fields) {
    haystack += base::ToLowerASCII(field);
    haystack += '\n';
  }
  for (std::string_view word : base::SplitStringPiece(
           query, " \t", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (haystack.find(base::ToLowerASCII(word)) == std::string::npos) {
      return false;
    }
  }
  return true;
}

// "/favicon/<profile>/<base64url page URL>.png": FaviconStore's 32/64 px
// PNG of a page (the Library shows a monogram on 404).
std::string FaviconPath(const ProfileID& profile, const std::string& url) {
  if (url.empty() || profile.empty()) {
    return std::string();
  }
  return base::StrCat({"/favicon/", profile, "/", B64(url), ".png"});
}

std::string HostOf(const std::string& url) {
  const GURL gurl(url);
  if (!gurl.is_valid()) {
    return std::string();
  }
  std::string host(gurl.host());
  if (base::StartsWith(host, "www.")) {
    host.erase(0, 4);
  }
  return host;
}

bool SystemDark() {
  OpenBrowserService* service = OpenBrowserService::Get();
  OpenWindowController* windows =
      service ? service->window_controller() : nullptr;
  return windows && windows->IsSystemDarkMode();
}

// --- Trash -------------------------------------------------------------------

#if !BUILDFLAG(IS_WIN)
base::FilePath UniqueIn(const base::FilePath& dir,
                        const base::FilePath& name) {
  base::FilePath candidate = dir.Append(name);
  for (int i = 2; base::PathExists(candidate) && i < 1000; ++i) {
    candidate = dir.Append(name.InsertBeforeExtensionASCII(
        base::StringPrintf(" %d", i)));
  }
  return candidate;
}
#endif

#if !BUILDFLAG(IS_WIN) && !BUILDFLAG(IS_MAC)
std::string PercentEncodeTrashPath(std::string_view raw) {
  std::string encoded;
  encoded.reserve(raw.size());
  for (unsigned char c : raw) {
    const bool unreserved =
        (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
        c == '~' || c == '/';
    if (unreserved) {
      encoded.push_back(static_cast<char>(c));
    } else {
      base::StringAppendF(&encoded, "%%%02X", static_cast<unsigned int>(c));
    }
  }
  return encoded;
}
#endif

// Moves a regular file to the user's Trash (recoverable). Blocking.
bool MoveFileToTrash(const base::FilePath& path) {
  if (path.empty() || !base::PathExists(path) ||
      base::DirectoryExists(path)) {
    return false;
  }
#if BUILDFLAG(IS_WIN)
  std::wstring from = path.value();
  from.push_back(L'\0');
  from.push_back(L'\0');
  SHFILEOPSTRUCTW op = {};
  op.wFunc = FO_DELETE;
  op.pFrom = from.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
  return SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted;
#elif BUILDFLAG(IS_MAC)
  base::FilePath home;
  if (!base::PathService::Get(base::DIR_HOME, &home) || home.empty()) {
    return false;
  }
  const base::FilePath trash = home.AppendASCII(".Trash");
  if (!base::DirectoryExists(trash) && !base::CreateDirectory(trash)) {
    return false;
  }
  return base::Move(path, UniqueIn(trash, path.BaseName()));
#else
  // freedesktop.org Trash: files/<name> plus info/<name>.trashinfo.
  base::FilePath trash;
  if (auto env = base::Environment::Create()) {
    if (auto xdg = env->GetVar("XDG_DATA_HOME"); xdg && !xdg->empty()) {
      trash = base::FilePath::FromUTF8Unsafe(*xdg).AppendASCII("Trash");
    }
  }
  if (trash.empty()) {
    base::FilePath home;
    if (!base::PathService::Get(base::DIR_HOME, &home) || home.empty()) {
      return false;
    }
    trash =
        home.AppendASCII(".local").AppendASCII("share").AppendASCII("Trash");
  }
  const base::FilePath files = trash.AppendASCII("files");
  const base::FilePath info = trash.AppendASCII("info");
  if (!base::CreateDirectory(files) || !base::CreateDirectory(info)) {
    return false;
  }
  const base::FilePath dest = UniqueIn(files, path.BaseName());
  base::Time::Exploded now;
  base::Time::Now().LocalExplode(&now);
  const std::string info_text = base::StringPrintf(
      "[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",
      PercentEncodeTrashPath(path.value()).c_str(), now.year, now.month,
      now.day_of_month, now.hour, now.minute, now.second);
  const base::FilePath info_file =
      info.Append(dest.BaseName().AddExtensionASCII("trashinfo"));
  if (!base::WriteFile(info_file, info_text)) {
    return false;
  }
  if (base::Move(path, dest)) {
    return true;
  }
  const bool copied = base::DirectoryExists(path)
                          ? base::CopyDirectory(path, dest, /*recursive=*/true)
                          : base::CopyFile(path, dest);
  if (copied) {
    if (base::DeletePathRecursively(path)) {
      return true;
    }
    base::DeletePathRecursively(dest);
    base::DeleteFile(info_file);
    return false;
  }
  base::DeletePathRecursively(dest);
  base::DeleteFile(info_file);
  return false;
#endif
}

// --- Download bridge ---------------------------------------------------------

OpenDownloadBridge* g_download_bridge = nullptr;

// Forwards bridge updates to every open:// page as open.downloadUpdated.
class DownloadEventForwarder : public OpenDownloadBridge::Observer {
 public:
  void OnDownloadUpdatedForProfile(const ProfileID& profile_id,
                                   const DownloadRecord& record) override {
    if (OpenBrowserService* service = OpenBrowserService::Get()) {
      service->BroadcastEvent(
          kEventDownloadUpdated,
          base::Value(json::DownloadToValue(record, profile_id)));
    }
  }
  void OnDownloadRemoved(const std::string& id) override {
    if (OpenBrowserService* service = OpenBrowserService::Get()) {
      service->BroadcastEvent(
          kEventDownloadUpdated,
          base::Value(
              base::DictValue().Set("id", id).Set("removed", true)));
    }
  }
};

DownloadEventForwarder& Forwarder() {
  static base::NoDestructor<DownloadEventForwarder> forwarder;
  return *forwarder;
}

void BroadcastDownloadChange(const std::string& id,
                             const ProfileID& profile,
                             bool removed) {
  if (OpenBrowserService* service = OpenBrowserService::Get()) {
    service->BroadcastEvent(kEventDownloadUpdated,
                            base::Value(base::DictValue()
                                            .Set("id", id)
                                            .Set("profile_id", profile)
                                            .Set("removed", removed)));
  }
}

bool IsActiveDownloadState(std::string_view state) {
  return state == "in_progress" || state == "paused";
}

// The same record shape OpenDownloadBridge persists (GUID ids).
DownloadRecord RecordFromLiveItem(download::DownloadItem* item) {
  DownloadRecord rec;
  rec.id = item->GetGuid();
  const GURL& url =
      item->GetURL().is_valid() ? item->GetURL() : item->GetOriginalUrl();
  rec.url = url.spec();
  const base::FilePath name = item->GetFileNameToReportUser();
  rec.filename = !name.empty() ? name.BaseName().AsUTF8Unsafe()
                 : !item->GetTargetFilePath().empty()
                     ? item->GetTargetFilePath().BaseName().AsUTF8Unsafe()
                     : item->GetSuggestedFilename();
  if (rec.filename.empty()) {
    rec.filename = "download";
  }
  const base::FilePath& path = !item->GetTargetFilePath().empty()
                                   ? item->GetTargetFilePath()
                                   : item->GetFullPath();
  rec.target_path = path.AsUTF8Unsafe();
  rec.mime_type = !item->GetMimeType().empty() ? item->GetMimeType()
                                               : item->GetOriginalMimeType();
  switch (item->GetState()) {
    case download::DownloadItem::IN_PROGRESS:
      rec.state = item->IsPaused() ? "paused" : "in_progress";
      break;
    case download::DownloadItem::COMPLETE:
      rec.state = "completed";
      break;
    case download::DownloadItem::CANCELLED:
      rec.state = "cancelled";
      break;
    default:
      rec.state = "interrupted";
      break;
  }
  rec.received_bytes = item->GetReceivedBytes();
  rec.total_bytes = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;
  rec.started_at = item->GetStartTime().is_null()
                       ? NowSec()
                       : item->GetStartTime().InSecondsFSinceUnixEpoch();
  rec.ended_at = item->GetEndTime().is_null()
                     ? 0.0
                     : item->GetEndTime().InSecondsFSinceUnixEpoch();
  return rec;
}

download::DownloadItem* LiveItem(const ProfileID& profile,
                                 const std::string& id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  ::Profile* chrome_profile =
      service ? service->ChromeProfileFor(profile) : nullptr;
  content::DownloadManager* manager =
      chrome_profile ? chrome_profile->GetDownloadManager() : nullptr;
  return manager && !id.empty() ? manager->GetDownloadByGuid(id) : nullptr;
}

// --- Media -------------------------------------------------------------------

std::string LowerExtension(const base::FilePath& path) {
  const std::string name = path.BaseName().AsUTF8Unsafe();
  const size_t dot = name.rfind('.');
  return dot == std::string::npos || dot == 0
             ? std::string()
             : base::ToLowerASCII(name.substr(dot + 1));
}

bool IsImageExtension(std::string_view ext) {
  static constexpr std::string_view kImages[] = {"png",  "jpg",  "jpeg",
                                                 "gif",  "webp", "bmp",
                                                 "avif"};
  return std::find(std::begin(kImages), std::end(kImages), ext) !=
         std::end(kImages);
}

bool IsVideoExtension(std::string_view ext) {
  static constexpr std::string_view kVideos[] = {"mp4", "m4v", "mov", "webm"};
  return std::find(std::begin(kVideos), std::end(kVideos), ext) !=
         std::end(kVideos);
}

bool IsMediaExtension(std::string_view ext) {
  return IsImageExtension(ext) || IsVideoExtension(ext);
}

// WebUIDataSource picks the response MIME type from the URL's extension
// (png, jpg, svg, mp4); other image/video types are sniffed by the renderer.
std::string UrlSuffix(std::string_view ext) {
  if (ext == "jpeg") {
    return ".jpg";
  }
  return ext.empty() ? std::string() : base::StrCat({".", ext});
}

bool IsSafeMediaUrlSuffix(std::string_view suffix, bool allow_video) {
  if (suffix.size() < 2 || suffix.front() != '.' ||
      suffix.find('.', 1) != std::string_view::npos) {
    return false;
  }
  const std::string lower = base::ToLowerASCII(suffix);
  if (lower == ".js" || lower == ".mjs" || lower == ".html" ||
      lower == ".htm" || lower == ".svg" || lower == ".xhtml") {
    return false;
  }
  const std::string_view ext = suffix.substr(1);
  return IsImageExtension(ext) || (allow_video && IsVideoExtension(ext));
}

// A media id: base64url("<kind>\x1f<profile>\x1f<a>\x1f<b>").
//   capture:  a = "app" | "profile" (Captures root), b = file name
//   download: a = download id
//   folder:   a = Folder Source path, b = file name
struct MediaToken {
  std::string kind;
  ProfileID profile;
  std::string a;
  std::string b;
};

std::string EncodeMediaToken(const MediaToken& token) {
  return B64(base::StrCat(
      {token.kind, "\x1f", token.profile, "\x1f", token.a, "\x1f", token.b}));
}

std::optional<MediaToken> DecodeMediaToken(std::string_view encoded) {
  const size_t dot = encoded.find('.');
  if (dot != std::string_view::npos) {
    const std::string_view suffix = encoded.substr(dot);
    if (!IsSafeMediaUrlSuffix(suffix, /*allow_video=*/true)) {
      return std::nullopt;
    }
    encoded = encoded.substr(0, dot);
  }
  std::optional<std::string> raw = UnB64(encoded);
  if (!raw) {
    return std::nullopt;
  }
  std::vector<std::string> parts = base::SplitString(
      *raw, "\x1f", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
  if (parts.size() != 4 ||
      (parts[0] != "capture" && parts[0] != "download" &&
       parts[0] != "folder")) {
    return std::nullopt;
  }
  return MediaToken{parts[0], parts[1], parts[2], parts[3]};
}

// Paths the media task needs (bound on the UI thread, used off it).
struct MediaRoots {
  base::FilePath app_captures;
  base::FilePath profile_captures;
  base::FilePath folders_file;
  base::FilePath user_data_dir;
};

MediaRoots RootsFor(const ProfileServices& ps) {
  OpenBrowserService* service = OpenBrowserService::Get();
  MediaRoots roots;
  if (service) {
    roots.user_data_dir = service->user_data_dir();
    roots.app_captures = service->user_data_dir().AppendASCII(kCapturesDir);
  }
  // <user data>/Profiles/<dir>/Captures (the parent of State/).
  roots.profile_captures = ps.state_dir.DirName().AppendASCII(kCapturesDir);
  roots.folders_file = ps.state_dir.AppendASCII(kFolderSourcesFile);
  return roots;
}

// The Profile's Library Folder Sources (absolute paths). Blocking.
std::vector<base::FilePath> ReadFolderSources(const base::FilePath& file) {
  std::vector<base::FilePath> folders;
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(file, &contents,
                                         kMaxFolderSourcesFileBytes)) {
    return folders;
  }
  std::optional<base::ListValue> list =
      base::JSONReader::ReadList(contents, base::JSON_PARSE_RFC);
  if (!list) {
    return folders;
  }
  for (const base::Value& value : *list) {
    if (value.is_string() && folders.size() < kMaxFolderSources) {
      const base::FilePath path =
          base::FilePath::FromUTF8Unsafe(value.GetString());
      if (path.IsAbsolute() && !path.ReferencesParent()) {
        folders.push_back(path);
      }
    }
  }
  return folders;
}

bool WriteFolderSources(const base::FilePath& file,
                        const std::vector<base::FilePath>& folders) {
  base::ListValue list;
  for (const base::FilePath& folder : folders) {
    list.Append(folder.AsUTF8Unsafe());
  }
  std::optional<std::string> json = base::WriteJson(list);
  return json && base::CreateDirectory(file.DirName()) &&
         base::ImportantFileWriter::WriteFileAtomically(file, *json);
}

// A plain file name (no separators, no "..", not hidden).
bool IsSafeFileName(std::string_view name) {
  return !name.empty() && name.size() <= 255 && name != "." &&
         name != ".." && name.front() != '.' &&
         name.find_first_of("/\\") == std::string_view::npos &&
         name.find('\0') == std::string_view::npos;
}

base::FilePath CanonicalizePath(const base::FilePath& path) {
  if (path.empty()) {
    return base::FilePath();
  }
#if BUILDFLAG(IS_WIN)
  base::FilePath normalized;
  if (!base::NormalizeFilePath(path, &normalized)) {
    return base::FilePath();
  }
  return normalized;
#else
  return base::MakeAbsoluteFilePath(path);
#endif
}

// Validates that |real| (already canonicalized) is an existing directory safe
// to scan for Library media. Allows non-home drives on Windows and external
// volumes on POSIX while rejecting drive/filesystem roots, OS system trees,
// and Open's own user-data directory. Blocking.
bool ValidateMediaFolder(const base::FilePath& real,
                         const base::FilePath& real_data,
                         std::string* error) {
  if (real.empty() || !base::DirectoryExists(real)) {
    if (error) {
      *error = "that folder does not exist";
    }
    return false;
  }
  if (!real_data.empty() &&
      (real_data == real || real_data.IsParent(real) ||
       real.IsParent(real_data))) {
    if (error) {
      *error = "choose a folder outside Open's data directory";
    }
    return false;
  }
  if (real == real.DirName()) {
    if (error) {
      *error = "choose a subfolder instead of a drive or filesystem root";
    }
    return false;
  }
#if BUILDFLAG(IS_WIN)
  std::string lower = base::ToLowerASCII(real.AsUTF8Unsafe());
  std::replace(lower.begin(), lower.end(), '/', '\\');
  while (lower.size() > 3 && lower.back() == '\\') {
    lower.pop_back();
  }
  std::vector<std::string> blocked_roots = {
      "c:\\windows",
      "c:\\program files",
      "c:\\program files (x86)",
      "c:\\programdata",
  };
  if (std::unique_ptr<base::Environment> env = base::Environment::Create()) {
    for (base::cstring_view var :
         {base::cstring_view("SystemRoot"), base::cstring_view("WINDIR")}) {
      if (auto val = env->GetVar(var); val && !val->empty()) {
        std::string b = base::ToLowerASCII(*val);
        std::replace(b.begin(), b.end(), '/', '\\');
        while (b.size() > 3 && b.back() == '\\') {
          b.pop_back();
        }
        blocked_roots.push_back(std::move(b));
      }
    }
  }
  for (const std::string& blocked : blocked_roots) {
    if (lower == blocked || base::StartsWith(lower, blocked + "\\")) {
      if (error) {
        *error = "system folders cannot be added";
      }
      return false;
    }
  }
#else
  static constexpr const char* kBlockedPosixRoots[] = {
      "/System",      "/usr", "/etc", "/private/etc", "/bin",
      "/sbin",        "/var", "/private/var",         "/proc",
      "/sys",
  };
  for (const char* raw_root : kBlockedPosixRoots) {
    const base::FilePath blocked(raw_root);
    if (real == blocked || blocked.IsParent(real)) {
      if (error) {
        *error = "system folders cannot be added";
      }
      return false;
    }
  }
#endif
  return true;
}

// Returns candidate filesystem paths for a built-in media folder id
// ("screenshots", "desktop", "downloads", "documents", "pictures"). Safe on
// the UI thread (no disk stat); the blocking store sequence picks the first
// existing directory.
std::vector<base::FilePath> ResolveBuiltinMediaFolderCandidates(
    std::string_view folder_id) {
  std::vector<base::FilePath> candidates;
  auto add_key = [&](int key) {
    base::FilePath p;
    if (base::PathService::Get(key, &p) && !p.empty()) {
      candidates.push_back(std::move(p));
    }
  };
  if (folder_id == "desktop") {
    add_key(base::DIR_USER_DESKTOP);
  } else if (folder_id == "documents") {
    add_key(chrome::DIR_USER_DOCUMENTS);
  } else if (folder_id == "downloads") {
    add_key(chrome::DIR_DEFAULT_DOWNLOADS);
    base::FilePath home;
    if (base::PathService::Get(base::DIR_HOME, &home) && !home.empty()) {
      candidates.push_back(home.AppendASCII("Downloads"));
    }
  } else if (folder_id == "pictures") {
    add_key(chrome::DIR_USER_PICTURES);
  } else if (folder_id == "screenshots") {
    base::FilePath pictures;
    if (base::PathService::Get(chrome::DIR_USER_PICTURES, &pictures) &&
        !pictures.empty()) {
      candidates.push_back(pictures.AppendASCII("Screenshots"));
    }
#if BUILDFLAG(IS_MAC)
    // macOS stores screenshots on Desktop by default when no custom location
    // is configured.
    add_key(base::DIR_USER_DESKTOP);
#else
    if (!pictures.empty()) {
      candidates.push_back(pictures);
    }
#endif
  }
  return candidates;
}

// |path| resolved (symlinks and junctions too) to a regular file inside |root|.
std::optional<base::FilePath> ContainedFile(const base::FilePath& root,
                                            const base::FilePath& path) {
  const base::FilePath real_root = CanonicalizePath(root);
  const base::FilePath real_path = CanonicalizePath(path);
  if (real_root.empty() || real_path.empty() ||
      !real_root.IsParent(real_path) || base::DirectoryExists(real_path)) {
    return std::nullopt;
  }
  return real_path;
}

struct MediaEntry {
  MediaToken token;
  std::string title;
  std::string source;  // "capture" | "download" | "folder"
  std::string source_url;
  std::string folder;  // Folder Source path or "Captures".
  std::string path;
  std::string ext;
  TimestampSec captured_at = 0;
  int64_t size = 0;
};

struct MediaScan {
  std::vector<MediaEntry> items;
  std::vector<std::string> folders;
};

// Image/video files directly inside |root| (newest first). Blocking.
void ScanMediaDir(const base::FilePath& root,
                  const MediaToken& base_token,
                  const std::string& source,
                  const std::string& folder_label,
                  std::vector<MediaEntry>* out) {
  if (root.empty() || !base::DirectoryExists(root)) {
    return;
  }
  std::vector<MediaEntry> found;
  base::FileEnumerator files(root, /*recursive=*/false,
                             base::FileEnumerator::FILES);
  for (base::FilePath path = files.Next(); !path.empty();
       path = files.Next()) {
    const std::string name = path.BaseName().AsUTF8Unsafe();
    const std::string ext = LowerExtension(path);
    if (!IsSafeFileName(name) || !IsMediaExtension(ext)) {
      continue;
    }
    const base::FileEnumerator::FileInfo info = files.GetInfo();
    MediaEntry entry;
    entry.token = base_token;
    entry.token.b = name;
    entry.title = name;
    entry.source = source;
    entry.folder = folder_label;
    entry.path = path.AsUTF8Unsafe();
    entry.ext = ext;
    entry.captured_at = info.GetLastModifiedTime().InSecondsFSinceUnixEpoch();
    entry.size = info.GetSize();
    // Optional capture sidecar <stem>.json {"title", "url"} (guess at the
    // macOS capture metadata; ignored when absent or malformed).
    if (source == "capture") {
      std::string sidecar;
      if (base::ReadFileToStringWithMaxSize(
              path.ReplaceExtension(FILE_PATH_LITERAL("json")), &sidecar,
              16 * 1024)) {
        if (std::optional<base::DictValue> meta =
                base::JSONReader::ReadDict(sidecar, base::JSON_PARSE_RFC)) {
          if (const std::string* t = meta->FindString("title")) {
            entry.title = *t;
          }
          if (const std::string* u = meta->FindString("url")) {
            entry.source_url = *u;
          }
        }
      }
    }
    found.push_back(std::move(entry));
  }
  std::sort(found.begin(), found.end(),
            [](const MediaEntry& a, const MediaEntry& b) {
              return a.captured_at > b.captured_at;
            });
  if (found.size() > kMaxMediaPerRoot) {
    found.resize(kMaxMediaPerRoot);
  }
  for (MediaEntry& entry : found) {
    out->push_back(std::move(entry));
  }
}

// Captures, image/video downloads and Folder Sources of one Profile; runs
// on the Profile's store sequence (blocking allowed).
MediaScan ScanMedia(ProfileID profile,
                    MediaRoots roots,
                    DownloadHistoryStore* store) {
  MediaScan scan;
  ScanMediaDir(roots.app_captures, MediaToken{"capture", profile, "app", ""},
               "capture", "Captures", &scan.items);
  ScanMediaDir(roots.profile_captures,
               MediaToken{"capture", profile, "profile", ""}, "capture",
               "Captures", &scan.items);
  for (const DownloadRecord& record : store->List()) {
    const base::FilePath path =
        base::FilePath::FromUTF8Unsafe(record.target_path);
    const std::string ext = LowerExtension(path);
    // The file must carry a media extension (it is served by extension).
    if (record.state != "completed" || path.empty() ||
        !IsMediaExtension(ext) || !base::PathExists(path)) {
      continue;
    }
    MediaEntry entry;
    entry.token = MediaToken{"download", profile, record.id, ""};
    entry.title = record.filename;
    entry.source = "download";
    entry.source_url = record.url;
    entry.folder = "Downloads";
    entry.path = record.target_path;
    entry.ext = ext;
    entry.captured_at =
        record.ended_at > 0 ? record.ended_at : record.started_at;
    entry.size = record.received_bytes;
    scan.items.push_back(std::move(entry));
  }
  for (const base::FilePath& folder : ReadFolderSources(roots.folders_file)) {
    scan.folders.push_back(folder.AsUTF8Unsafe());
    ScanMediaDir(folder,
                 MediaToken{"folder", profile, folder.AsUTF8Unsafe(), ""},
                 "folder", folder.BaseName().AsUTF8Unsafe(), &scan.items);
  }
  return scan;
}

// The real path of |token| when it names an allowed media file; blocking.
std::optional<base::FilePath> ResolveMedia(const MediaToken& token,
                                           const MediaRoots& roots,
                                           DownloadHistoryStore* store,
                                           bool allow_video) {
  auto allowed = [allow_video](const base::FilePath& path) {
    const std::string ext = LowerExtension(path);
    return IsImageExtension(ext) || (allow_video && IsVideoExtension(ext));
  };
  if (token.kind == "capture" || token.kind == "folder") {
    if (!IsSafeFileName(token.b)) {
      return std::nullopt;
    }
    base::FilePath root;
    if (token.kind == "capture") {
      root = token.a == "app"       ? roots.app_captures
             : token.a == "profile" ? roots.profile_captures
                                    : base::FilePath();
    } else {
      const base::FilePath wanted = base::FilePath::FromUTF8Unsafe(token.a);
      for (const base::FilePath& folder :
           ReadFolderSources(roots.folders_file)) {
        if (folder == wanted) {
          root = folder;
        }
      }
    }
    if (root.empty()) {
      return std::nullopt;
    }
    const base::FilePath path =
        root.Append(base::FilePath::FromUTF8Unsafe(token.b));
    std::optional<base::FilePath> resolved = ContainedFile(root, path);
    if (!resolved || !allowed(*resolved)) {
      return std::nullopt;
    }
    return resolved;
  }
  // download: only the completed record's own target file.
  for (const DownloadRecord& record : store->List()) {
    if (record.id != token.a || record.state != "completed") {
      continue;
    }
    const base::FilePath path =
        CanonicalizePath(base::FilePath::FromUTF8Unsafe(record.target_path));
    if (path.empty() || !allowed(path) || base::DirectoryExists(path)) {
      return std::nullopt;
    }
    return path;
  }
  return std::nullopt;
}

scoped_refptr<base::RefCountedMemory> ReadCapped(const base::FilePath& path,
                                                 int64_t max_bytes) {
  std::optional<int64_t> size = base::GetFileSize(path);
  if (!size || *size > max_bytes) {
    return nullptr;
  }
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents,
                                         static_cast<size_t>(max_bytes))) {
    return nullptr;
  }
  return base::MakeRefCounted<base::RefCountedString>(std::move(contents));
}

base::DictValue MediaEntryToValue(const MediaEntry& entry) {
  const std::string id = EncodeMediaToken(entry.token);
  const bool video = IsVideoExtension(entry.ext);
  const std::string suffix = UrlSuffix(entry.ext);
  base::DictValue value;
  value.Set("id", id);
  value.Set("title", entry.title);
  value.Set("source", entry.source);
  value.Set("source_url", entry.source_url);
  value.Set("folder", entry.folder);
  value.Set("path", entry.path);
  value.Set("kind", video ? "video" : "image");
  value.Set("ext", entry.ext);
  value.Set("captured_at", entry.captured_at);
  value.Set("size", static_cast<double>(entry.size));
  value.Set("file_url", base::StrCat({"/media-file/", id, suffix}));
  value.Set("profile_id", entry.token.profile);
  value.Set("width", 0);
  value.Set("height", 0);
  value.Set("preview_gradient", "");
  if (!video) {
    value.Set("thumb_url", base::StrCat({"/thumb/", id, suffix}));
  }
  return value;
}

// --- Downloads ---------------------------------------------------------------

base::DictValue DownloadEntryToValue(const RecentDownloadEntry& entry) {
  const DownloadRecord& r = entry.record;
  base::DictValue value = json::DownloadToValue(r, entry.profile_id);
  double progress = -1;
  if (r.state == "completed") {
    progress = 1;
  } else if (r.total_bytes > 0) {
    progress = std::clamp(static_cast<double>(r.received_bytes) /
                              static_cast<double>(r.total_bytes),
                          0.0, 1.0);
  }
  value.Set("fileExists", entry.file_exists);
  value.Set("bytesPerSecond", static_cast<double>(entry.bytes_per_second));
  value.Set("canResume", entry.can_resume);
  value.Set("isLive", entry.is_live);
  value.Set("progress", progress);
  value.Set("host", HostOf(r.url));
  const std::string ext =
      LowerExtension(base::FilePath::FromUTF8Unsafe(r.target_path));
  if (r.state == "completed" && entry.file_exists && IsImageExtension(ext)) {
    value.Set("thumb_url",
              base::StrCat({"/thumb/",
                            EncodeMediaToken(MediaToken{
                                "download", entry.profile_id, r.id, ""}),
                            UrlSuffix(ext)}));
  }
  return value;
}

using DownloadEntries = std::vector<RecentDownloadEntry>;

void FinishDownloads(int limit,
                     base::OnceCallback<void(DownloadEntries)> done,
                     DownloadEntries entries) {
  std::sort(entries.begin(), entries.end(),
            [](const RecentDownloadEntry& a, const RecentDownloadEntry& b) {
              return a.record.started_at > b.record.started_at;
            });
  if (static_cast<int>(entries.size()) > limit) {
    entries.resize(static_cast<size_t>(limit));
  }
  std::move(done).Run(std::move(entries));
}

// Store rows of |profiles| merged with their live content::DownloadManager
// items (used while no OpenDownloadBridge is registered).
void CollectDownloadsFromStores(
    std::vector<ProfileID> profiles,
    int limit,
    base::OnceCallback<void(DownloadEntries)> done) {
  RunOnProfileStores<DownloadHistoryStore, std::vector<DownloadRecord>>(
      profiles, &ProfileServices::downloads,
      base::BindRepeating(
          [](DownloadHistoryStore* store) { return store->List(); }),
      base::BindOnce(
          [](int limit, base::OnceCallback<void(DownloadEntries)> done,
             std::vector<std::pair<ProfileID, std::vector<DownloadRecord>>>
                 results) {
            OpenBrowserService* service = OpenBrowserService::Get();
            DownloadEntries entries;
            for (auto& [profile, records] : results) {
              std::map<std::string, size_t> index;
              for (DownloadRecord& record : records) {
                RecentDownloadEntry entry;
                index[record.id] = entries.size();
                entry.record = std::move(record);
                entry.profile_id = profile;
                entries.push_back(std::move(entry));
              }
              ::Profile* chrome_profile =
                  service ? service->ChromeProfileFor(profile) : nullptr;
              content::DownloadManager* manager =
                  chrome_profile ? chrome_profile->GetDownloadManager()
                                 : nullptr;
              if (!manager) {
                continue;
              }
              content::DownloadManager::DownloadVector items;
              manager->GetAllDownloads(&items);
              for (download::DownloadItem* item : items) {
                if (!item || item->IsTemporary() || item->IsTransient() ||
                    item->GetGuid().empty()) {
                  continue;
                }
                auto it = index.find(item->GetGuid());
                if (it == index.end()) {
                  RecentDownloadEntry entry;
                  entry.profile_id = profile;
                  index[item->GetGuid()] = entries.size();
                  entries.push_back(std::move(entry));
                  it = index.find(item->GetGuid());
                }
                RecentDownloadEntry& entry = entries[it->second];
                entry.record = RecordFromLiveItem(item);
                entry.is_live = true;
                entry.can_resume = item->CanResume();
                entry.bytes_per_second =
                    item->GetState() == download::DownloadItem::IN_PROGRESS
                        ? item->CurrentSpeed()
                        : 0;
              }
            }
            // File availability off the UI thread.
            std::vector<base::FilePath> paths;
            for (const RecentDownloadEntry& entry : entries) {
              paths.push_back(entry.record.state == "completed"
                                  ? base::FilePath::FromUTF8Unsafe(
                                        entry.record.target_path)
                                  : base::FilePath());
            }
            base::ThreadPool::PostTaskAndReplyWithResult(
                FROM_HERE,
                {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                base::BindOnce(
                    [](std::vector<base::FilePath> paths) {
                      std::vector<bool> exists;
                      for (const base::FilePath& path : paths) {
                        exists.push_back(!path.empty() &&
                                         base::PathExists(path) &&
                                         !base::DirectoryExists(path));
                      }
                      return exists;
                    },
                    std::move(paths)),
                base::BindOnce(
                    [](int limit,
                       base::OnceCallback<void(DownloadEntries)> done,
                       DownloadEntries entries, std::vector<bool> exists) {
                      for (size_t i = 0;
                           i < entries.size() && i < exists.size(); ++i) {
                        entries[i].file_exists = exists[i];
                      }
                      FinishDownloads(limit, std::move(done),
                                      std::move(entries));
                    },
                    limit, std::move(done), std::move(entries)));
          },
          limit, std::move(done)));
}

void CollectDownloads(std::vector<ProfileID> profiles,
                      int limit,
                      base::OnceCallback<void(DownloadEntries)> done) {
  OpenDownloadBridge* bridge = OpenLibraryUI::download_bridge();
  if (!bridge) {
    CollectDownloadsFromStores(std::move(profiles), limit, std::move(done));
    return;
  }
  for (const ProfileID& profile : profiles) {
    // Ensure each requested Profile's services and DownloadManager binding exist.
    ServicesFor(profile);
  }
  auto barrier = base::BarrierCallback<DownloadEntries>(
      profiles.size(),
      base::BindOnce(
          [](int limit, base::OnceCallback<void(DownloadEntries)> done,
             std::vector<DownloadEntries> parts) {
            DownloadEntries all;
            for (DownloadEntries& part : parts) {
              for (RecentDownloadEntry& entry : part) {
                all.push_back(std::move(entry));
              }
            }
            FinishDownloads(limit, std::move(done), std::move(all));
          },
          limit, std::move(done)));
  for (const ProfileID& profile : profiles) {
    bridge->GetRecentDownloadsAsync(profile, limit, barrier);
  }
}

// Runs |next| with |id|'s DownloadHistoryStore row (or nullopt).
void WithDownloadRecord(
    ProfileServices* ps,
    const std::string& id,
    base::OnceCallback<void(std::optional<DownloadRecord>)> next) {
  RunOnStore(ps->downloads,
             base::BindOnce(
                 [](std::string id, DownloadHistoryStore* store)
                     -> std::optional<DownloadRecord> {
                   for (DownloadRecord& record : store->List()) {
                     if (record.id == id) {
                       return std::move(record);
                     }
                   }
                   return std::nullopt;
                 },
                 id),
             std::move(next));
}

// --- Archive -----------------------------------------------------------------

struct ArchivedChild {
  std::string id;
  std::string url;
  std::string title;
};

// Child tabs of an archived folder's payload_json, nested folders
// flattened: {"title", "children"|"tabs": [{"id","url","title",
// "children"?}]}. The macOS archive payload shape is a guess (no Unified
// writer produces folder rows yet); unknown shapes give no children.
void CollectChildren(const base::ListValue& list,
                     int depth,
                     std::vector<ArchivedChild>* out) {
  for (const base::Value& value : list) {
    const base::DictValue* dict = value.GetIfDict();
    if (!dict || out->size() >= 500) {
      continue;
    }
    const base::ListValue* nested = dict->FindList("children");
    if (!nested) {
      nested = dict->FindList("tabs");
    }
    if (nested && depth < 8) {
      CollectChildren(*nested, depth + 1, out);
    }
    const std::string* url = dict->FindString("url");
    if (url && !url->empty()) {
      ArchivedChild child;
      child.url = *url;
      if (const std::string* title = dict->FindString("title")) {
        child.title = *title;
      }
      if (const std::string* id = dict->FindString("id")) {
        child.id = *id;
      }
      out->push_back(std::move(child));
    }
  }
}

std::vector<ArchivedChild> FolderChildren(const ArchivedTabRecord& record,
                                          std::string* folder_title) {
  std::vector<ArchivedChild> children;
  if (record.kind != "folder" || record.payload_json.empty()) {
    return children;
  }
  std::optional<base::DictValue> payload =
      base::JSONReader::ReadDict(record.payload_json, base::JSON_PARSE_RFC);
  if (!payload) {
    return children;
  }
  if (folder_title) {
    if (const std::string* title = payload->FindString("title")) {
      *folder_title = *title;
    }
  }
  const base::ListValue* list = payload->FindList("children");
  if (!list) {
    list = payload->FindList("tabs");
  }
  if (list) {
    CollectChildren(*list, 0, &children);
  }
  return children;
}

base::DictValue ArchivedToValue(const ArchivedTabRecord& record,
                                const ProfileID& profile) {
  ArchivedTabRecord copy = record;
  if (!copy.profile_id || copy.profile_id->empty()) {
    copy.profile_id = profile;
  }
  base::DictValue value =
      json::ArchivedTabToValue(copy, SpaceTitle(copy.space_id));
  value.Set("favicon_url", FaviconPath(*copy.profile_id, copy.url));
  value.Set("host", HostOf(copy.url));
  value.Set("day_start", LocalDayStart(copy.archived_at));
  if (copy.kind == "folder") {
    std::string folder_title;
    base::ListValue children;
    for (const ArchivedChild& child : FolderChildren(copy, &folder_title)) {
      children.Append(base::DictValue()
                          .Set("id", child.id)
                          .Set("url", child.url)
                          .Set("title", child.title)
                          .Set("host", HostOf(child.url))
                          .Set("favicon_url",
                               FaviconPath(*copy.profile_id, child.url)));
    }
    if (copy.title.empty() && !folder_title.empty()) {
      value.Set("title", folder_title);
    }
    value.Set("child_count", static_cast<int>(children.size()));
    value.Set("children", std::move(children));
  }
  return value;
}

// The focused Space of |window_id| (else of any window).
SpaceID FocusedSpace(const WindowID& window_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return SpaceID();
  }
  if (const BrowserWindowState* window =
          service->model().FindWindow(window_id)) {
    return window->focused_space_id;
  }
  const auto& windows = service->model().windows();
  return windows.empty() ? SpaceID() : windows.front().focused_space_id;
}

// Puts an archived folder back as a Today folder of its Space (or the
// focused Space) with its child tabs; the folder id, or empty.
ItemID RestoreArchivedFolder(const ArchivedTabRecord& record,
                             const WindowID& window_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return ItemID();
  }
  BrowserModel& model = service->model();
  std::string folder_title;
  const std::vector<ArchivedChild> children =
      FolderChildren(record, &folder_title);
  SpaceID space = record.space_id && model.FindSpace(*record.space_id)
                      ? *record.space_id
                      : FocusedSpace(window_id);
  if (space.empty()) {
    return ItemID();
  }
  const std::string title = !record.title.empty() ? record.title
                            : !folder_title.empty() ? folder_title
                                                    : std::string("Folder");
  const ItemID folder =
      model.CreateFolder(NodeParent{NodeParentKind::kSpaceToday, space}, title);
  if (folder.empty()) {
    return ItemID();
  }
  for (const ArchivedChild& child : children) {
    ArchivedTabRecord tab;
    // A fresh id: an old id may belong to a live tab again.
    tab.url = child.url;
    tab.title = child.title;
    tab.space_id = space;
    tab.profile_id = record.profile_id;
    tab.archived_at = record.archived_at;
    tab.kind = "tab";
    const ItemID restored = model.RestoreArchivedTab(tab);
    if (!restored.empty()) {
      model.MoveNode(restored, NodeParent{NodeParentKind::kFolder, folder});
    }
  }
  return folder;
}

// --- Spaces ------------------------------------------------------------------

RGBAColor Mix(const RGBAColor& a, const RGBAColor& b, double t) {
  return RGBAColor{a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1.0};
}

std::string Css(const RGBAColor& c) {
  auto channel = [](double v) {
    return static_cast<int>(std::clamp(v, 0.0, 1.0) * 255.0 + 0.5);
  };
  return base::StringPrintf("rgb(%d, %d, %d)", channel(c.r), channel(c.g),
                            channel(c.b));
}

double Luminance(const RGBAColor& c) {
  return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

bool SpaceIsDark(const Space& space, bool system_dark) {
  const SpaceStyle style = space.theme.style.value_or(SpaceStyle());
  switch (style.appearance) {
    case ThemeAppearance::kDark:
      return true;
    case ThemeAppearance::kLight:
      return false;
    case ThemeAppearance::kAutomatic:
      return system_dark;
  }
  return system_dark;
}

}  // namespace

// --- Statics -----------------------------------------------------------------

// static
void OpenLibraryUI::SetDownloadBridge(OpenDownloadBridge* bridge) {
  if (g_download_bridge == bridge) {
    return;
  }
  if (g_download_bridge) {
    g_download_bridge->RemoveObserver(&Forwarder());
  }
  g_download_bridge = bridge;
  if (g_download_bridge) {
    g_download_bridge->AddObserver(&Forwarder());
  }
}

// static
OpenDownloadBridge* OpenLibraryUI::download_bridge() {
  return g_download_bridge;
}

// static
base::DictValue OpenLibraryUI::SpaceThemePayload(const Space& space,
                                                 bool dark) {
  const SpaceStyle style = space.theme.style.value_or(SpaceStyle());
  const RGBAColor key = style.key_color;
  const RGBAColor white{1, 1, 1, 1};
  const RGBAColor ink_light{0.11, 0.11, 0.13, 1};
  const RGBAColor ink_dark{0.96, 0.96, 0.97, 1};
  const RGBAColor night{0.075, 0.075, 0.095, 1};
  RGBAColor bg;
  RGBAColor fg;
  if (dark) {
    bg = space.theme.dark_background.value_or(Mix(key, night, 0.80));
    fg = space.theme.dark_foreground.value_or(ink_dark);
  } else {
    bg = space.theme.light_background.value_or(Mix(key, white, 0.84));
    fg = space.theme.light_foreground.value_or(ink_light);
  }
  RGBAColor accent = space.theme.accent.value_or(key);
  // Keep the accent readable on the drawer surface.
  if (!dark && Luminance(accent) > 0.62) {
    accent = Mix(accent, ink_light, 0.45);
  } else if (dark && Luminance(accent) < 0.22) {
    accent = Mix(accent, white, 0.40);
  }
  return base::DictValue()
      .Set("space_id", space.id)
      .Set("bg", Css(bg))
      .Set("fg", Css(fg))
      .Set("accent", Css(accent))
      .Set("surface", dark ? "rgba(255, 255, 255, 0.09)"
                           : "rgba(0, 0, 0, 0.06)")
      .Set("mode", dark ? "dark" : "light");
}

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

// static
bool OpenLibraryUI::ToggleMediaFolderSource(const std::string& folder_id) {
  OpenBrowserService* service = OpenBrowserService::Get();
  if (!service) {
    return false;
  }
  ProfileServices* ps = service->ProfileServicesFor(service->ActiveProfileId());
  if (!ps) {
    return false;
  }
  std::vector<base::FilePath> candidates =
      ResolveBuiltinMediaFolderCandidates(folder_id);
  if (candidates.empty()) {
    return false;
  }
  RunOnStore(
      ps->downloads,
      base::BindOnce(
          [](std::vector<base::FilePath> candidates, MediaRoots roots,
             DownloadHistoryStore*) -> bool {
            std::vector<base::FilePath> folders =
                ReadFolderSources(roots.folders_file);
            // If any canonical candidate is already enabled, remove it.
            bool removed = false;
            for (const base::FilePath& candidate : candidates) {
              const base::FilePath real = CanonicalizePath(candidate);
              const size_t before = folders.size();
              std::erase_if(folders, [&](const base::FilePath& existing) {
                return existing == candidate ||
                       (!real.empty() &&
                        (existing == real || CanonicalizePath(existing) == real));
              });
              if (folders.size() != before) {
                removed = true;
              }
            }
            if (removed) {
              return WriteFolderSources(roots.folders_file, folders);
            }
            // Otherwise add the first existing valid candidate folder.
            if (folders.size() >= kMaxFolderSources) {
              return false;
            }
            const base::FilePath real_data =
                CanonicalizePath(roots.user_data_dir);
            for (const base::FilePath& candidate : candidates) {
              const base::FilePath real = CanonicalizePath(candidate);
              if (ValidateMediaFolder(real, real_data, nullptr)) {
                folders.push_back(real);
                return WriteFolderSources(roots.folders_file, folders);
              }
            }
            return false;
          },
          std::move(candidates), RootsFor(*ps)),
      base::BindOnce([](bool changed) {
        if (changed) {
          if (OpenBrowserService* svc = OpenBrowserService::Get()) {
            svc->BroadcastEvent(kEventStateChanged,
                                base::Value(base::DictValue()));
          }
        }
      }));
  return true;
}

// static
bool OpenLibraryUI::ShouldHandleResource(const std::string& path) {
  return base::StartsWith(path, "thumb/") ||
         base::StartsWith(path, "media-file/") ||
         base::StartsWith(path, "favicon/");
}

// static
void OpenLibraryUI::HandleResource(
    content::BrowserContext* context,
    const std::string& raw_path,
    content::WebUIDataSource::GotDataCallback callback) {
  OpenBrowserService* service = OpenBrowserService::Get();
  // Only a Profile Open knows may read (never an off-the-record context).
  if (!service || !context || context->IsOffTheRecord() ||
      !service->OpenProfileIdFor(context)) {
    std::move(callback).Run(nullptr);
    return;
  }
  std::string_view path(raw_path);
  path = path.substr(0, path.find_first_of("?#"));

  if (base::StartsWith(path, "favicon/")) {
    // favicon/<profile>/<base64url page URL>.png
    const std::vector<std::string_view> parts = base::SplitStringPiece(
        path.substr(8), "/", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
    std::optional<std::string> url;
    ProfileServices* ps = nullptr;
    if (parts.size() == 2 && base::EndsWith(parts[1], ".png")) {
      const std::string_view stem = parts[1].substr(0, parts[1].size() - 4);
      if (!stem.empty() && stem.find('.') == std::string_view::npos) {
        url = UnB64(stem);
        ps = ServicesFor(std::string(parts[0]));
      }
    }
    if (!url || !ps || !GURL(*url).is_valid()) {
      std::move(callback).Run(nullptr);
      return;
    }
    RunOnStore(ps->favicons,
               base::BindOnce(
                   [](std::string url, FaviconStore* store)
                       -> scoped_refptr<base::RefCountedMemory> {
                     std::optional<FaviconRecord> record = store->Get(url);
                     if (!record || record->status != 0) {
                       return nullptr;
                     }
                     std::vector<uint8_t> png = !record->png64.empty()
                                                    ? record->png64
                                                    : record->png32;
                     if (png.empty()) {
                       return nullptr;
                     }
                     return base::MakeRefCounted<base::RefCountedBytes>(
                         std::move(png));
                   },
                   *url),
               std::move(callback));
    return;
  }

  const bool thumb = base::StartsWith(path, "thumb/");
  path.remove_prefix(thumb ? 6 : 11);  // "thumb/" or "media-file/".
  const size_t dot = path.find('.');
  if (dot == std::string_view::npos ||
      path.find_first_of("/\\") != std::string_view::npos) {
    std::move(callback).Run(nullptr);
    return;
  }
  const std::string requested_suffix(path.substr(dot));
  if (!IsSafeMediaUrlSuffix(requested_suffix, /*allow_video=*/!thumb)) {
    std::move(callback).Run(nullptr);
    return;
  }
  std::optional<MediaToken> token = DecodeMediaToken(path);
  ProfileServices* ps = token ? ServicesFor(token->profile) : nullptr;
  if (!ps) {
    std::move(callback).Run(nullptr);
    return;
  }
  RunOnStore(ps->downloads,
             base::BindOnce(
                 [](MediaToken token, MediaRoots roots, bool thumb,
                    std::string requested_suffix, DownloadHistoryStore* store)
                     -> scoped_refptr<base::RefCountedMemory> {
                   std::optional<base::FilePath> file = ResolveMedia(
                       token, roots, store, /*allow_video=*/!thumb);
                   if (!file ||
                       UrlSuffix(LowerExtension(*file)) != requested_suffix) {
                     return nullptr;
                   }
                   return ReadCapped(*file, thumb ? kMaxThumbBytes
                                                  : kMaxMediaFileBytes);
                 },
                 *token, RootsFor(*ps), thumb, requested_suffix),
             std::move(callback));
}

// --- OpenLibraryUI::FolderDialog ---------------------------------------------

class OpenLibraryUI::FolderDialog : public ui::SelectFileDialog::Listener {
 public:
  using Done = base::OnceCallback<void(std::optional<base::FilePath>)>;

  explicit FolderDialog(Done done) : done_(std::move(done)) {}
  ~FolderDialog() override {
    if (dialog_) {
      dialog_->ListenerDestroyed();
    }
  }

  void Show(const std::u16string& title,
            const base::FilePath& default_path,
            gfx::NativeWindow owner) {
    dialog_ = ui::SelectFileDialog::Create(this, /*policy=*/nullptr);
    if (!dialog_) {
      Finish(std::nullopt);
      return;
    }
    dialog_->SelectFile(ui::SelectFileDialog::SELECT_FOLDER, title,
                        default_path, /*file_types=*/nullptr, 0,
                        base::FilePath::StringType(), owner);
  }

  // ui::SelectFileDialog::Listener:
  void FileSelected(const ui::SelectedFileInfo& file, int index) override {
    Finish(file.path());
  }
  void FileSelectionCanceled() override { Finish(std::nullopt); }

 private:
  void Finish(std::optional<base::FilePath> path) {
    if (done_) {
      std::move(done_).Run(std::move(path));
    }
  }

  Done done_;
  scoped_refptr<ui::SelectFileDialog> dialog_;
};

// --- OpenLibraryUI -----------------------------------------------------------

OpenLibraryUI::OpenLibraryUI(OpenWebUIMessageHandler* handler)
    : OpenRpcDomain(handler) {}

OpenLibraryUI::~OpenLibraryUI() = default;

void OpenLibraryUI::RegisterMethods() {
  auto bind = [this](void (OpenLibraryUI::*method)(const base::DictValue&,
                                                   Reply)) {
    return base::BindRepeating(method, weak_factory_.GetWeakPtr());
  };
  // Drawer.
  Register(kClose, bind(&OpenLibraryUI::Close));
  Register(kThemeGet, bind(&OpenLibraryUI::GetTheme));
  // History.
  Register(kHistoryList, bind(&OpenLibraryUI::ListHistory));
  Register(kHistoryDelete, bind(&OpenLibraryUI::DeleteHistory));
  Register(kHistoryClear, bind(&OpenLibraryUI::ClearHistory));
  Register(kLibraryGetHistory, bind(&OpenLibraryUI::ListHistory));
  Register(kLibraryDeleteHistory, bind(&OpenLibraryUI::LegacyDeleteHistory));
  // Archive.
  Register(kArchiveList, bind(&OpenLibraryUI::ListArchive));
  Register(kArchiveRestore, bind(&OpenLibraryUI::RestoreArchived));
  Register(kArchiveDelete, bind(&OpenLibraryUI::DeleteArchived));
  Register(kArchiveClearAll, bind(&OpenLibraryUI::ClearArchive));
  Register(kArchivePeek, bind(&OpenLibraryUI::PeekArchived));
  Register(kLibraryGetArchive, bind(&OpenLibraryUI::ListArchive));
  Register(kLibraryRestoreArchived, bind(&OpenLibraryUI::RestoreArchived));
  // Downloads.
  Register(kDownloadsList, bind(&OpenLibraryUI::ListDownloads));
  Register(kDownloadsClear, bind(&OpenLibraryUI::ClearDownloads));
  for (const char* action : kDownloadActions) {
    Register(base::StrCat({"library.downloads.", action}),
             base::BindRepeating(&OpenLibraryUI::DownloadAction,
                                 weak_factory_.GetWeakPtr(),
                                 std::string(action)));
  }
  Register(kLibraryGetDownloads, bind(&OpenLibraryUI::ListDownloads));
  Register(kLibraryOpenDownload, bind(&OpenLibraryUI::LegacyOpenDownload));
  // Media.
  Register(kMediaList, bind(&OpenLibraryUI::ListMedia));
  Register(kMediaAddFolder, bind(&OpenLibraryUI::AddMediaFolder));
  Register(kMediaRemoveFolder, bind(&OpenLibraryUI::RemoveMediaFolder));
  Register(kMediaPickFolder, bind(&OpenLibraryUI::PickMediaFolder));
  for (const char* action : kMediaActions) {
    Register(base::StrCat({"library.media.", action}),
             base::BindRepeating(&OpenLibraryUI::MediaAction,
                                 weak_factory_.GetWeakPtr(),
                                 std::string(action)));
  }
  Register(kLibraryGetMedia, bind(&OpenLibraryUI::ListMedia));
  // Spaces.
  Register(kSpacesList, bind(&OpenLibraryUI::GetSpaces));
  Register(kSpacesCreate, bind(&OpenLibraryUI::CreateSpace));
  Register(kSpacesUpdate, bind(&OpenLibraryUI::UpdateSpace));
  Register(kSpacesDelete, bind(&OpenLibraryUI::DeleteSpace));
  Register(kSpacesSwitch, bind(&OpenLibraryUI::SwitchSpace));
  Register(kSpacesReorder, bind(&OpenLibraryUI::ReorderSpaces));
  Register(kSpacesSetProfile, bind(&OpenLibraryUI::SetSpaceProfile));
  Register(kLibraryGetSpaces, bind(&OpenLibraryUI::GetSpaces));
  Register(kLibraryUpdateSpace, bind(&OpenLibraryUI::UpdateSpace));
  Register(kLibraryDeleteSpace, bind(&OpenLibraryUI::DeleteSpace));
  // Boosts, Easels and Notes.
  Register(kBoostsListAll, bind(&OpenLibraryUI::ListBoosts));
  Register(kDocumentsList, bind(&OpenLibraryUI::ListDocuments));
  Register(kDocumentsCreate, bind(&OpenLibraryUI::CreateDocument));
  Register(kDocumentsDelete, bind(&OpenLibraryUI::DeleteDocument));
  Register(kLibraryGetEasels, bind(&OpenLibraryUI::ListDocuments));
  // Navigation.
  Register(kLibraryOpenUrl, bind(&OpenLibraryUI::OpenUrl));
}

WindowID OpenLibraryUI::TargetWindow(const base::DictValue& payload) const {
  const std::string* id = payload.FindString("window_id");
  if (id && service()->model().FindWindow(*id)) {
    return *id;
  }
  return service()->ActiveWindowId();
}

bool OpenLibraryUI::RequestClose(const WindowID& window_id) {
  // The drawer's host (the window's Library overlay) closes on this event.
  service()->BroadcastEvent(
      kEventCloseRequested,
      base::Value(base::DictValue().Set("window_id", window_id)));
  // open://library shown as a sidebar tab: close that tab.
  content::WebContents* contents =
      web_ui() ? web_ui()->GetWebContents() : nullptr;
  std::optional<ItemID> tab =
      contents ? OpenTabBridge::TabIdForWebContents(contents) : std::nullopt;
  if (tab && service()->tab_bridge()) {
    return service()->tab_bridge()->CloseNode(*tab);
  }
  return false;
}

// --- Drawer ------------------------------------------------------------------

void OpenLibraryUI::Close(const base::DictValue& payload, Reply reply) {
  const bool closed_tab = RequestClose(TargetWindow(payload));
  ReplyOk(std::move(reply),
          base::DictValue().Set("ok", true).Set("closed_tab", closed_tab));
}

void OpenLibraryUI::GetTheme(const base::DictValue& payload, Reply reply) {
  std::string space_id = json::GetString(payload, "space_id");
  if (space_id.empty()) {
    space_id = FocusedSpace(TargetWindow(payload));
  }
  const Space* space = service()->model().FindSpace(space_id);
  if (!space && !service()->model().spaces().empty()) {
    space = &service()->model().spaces().front();
  }
  if (!space) {
    ReplyError(std::move(reply), "no space");
    return;
  }
  const bool system_dark = SystemDark();
  ReplyOk(std::move(reply),
          base::DictValue()
              .Set("theme", SpaceThemePayload(*space,
                                              SpaceIsDark(*space, system_dark)))
              .Set("space", SpaceSummary(*space))
              .Set("system_dark", system_dark));
}

// --- History -----------------------------------------------------------------

void OpenLibraryUI::ListHistory(const base::DictValue& payload, Reply reply) {
  const std::vector<ProfileID> profiles = ProfilesFromPayload(payload);
  const std::string query = Query(payload);
  const int offset = Offset(payload);
  const int limit = Limit(payload);
  // One Profile without a query pages in SQL; otherwise every Profile reads
  // its first offset+limit+1 rows and the merge pages them.
  const bool direct = profiles.size() == 1 && query.empty();
  const int window =
      std::min(direct ? limit + 1 : offset + limit + 1, kMaxHistoryWindow);
  RunOnProfileStores<HistoryStore, std::vector<HistoryEntry>>(
      profiles, &ProfileServices::history,
      base::BindRepeating(
          [](std::string query, int window, int sql_offset,
             HistoryStore* store) {
            return query.empty() ? store->Recent(window, sql_offset)
                                 : store->Search(query, window);
          },
          query, window, direct ? offset : 0),
      base::BindOnce(
          [](bool direct, int offset, int limit, Reply reply,
             std::vector<std::pair<ProfileID, std::vector<HistoryEntry>>>
                 results) {
            std::vector<std::pair<const HistoryEntry*, const ProfileID*>>
                rows;
            for (const auto& [profile, entries] : results) {
              for (const HistoryEntry& entry : entries) {
                rows.emplace_back(&entry, &profile);
              }
            }
            std::stable_sort(rows.begin(), rows.end(),
                             [](const auto& a, const auto& b) {
                               return a.first->last_visit >
                                      b.first->last_visit;
                             });
            const size_t start = direct ? 0 : static_cast<size_t>(offset);
            const size_t end =
                std::min(rows.size(), start + static_cast<size_t>(limit));
            base::ListValue list;
            for (size_t i = start; i < end; ++i) {
              const HistoryEntry& entry = *rows[i].first;
              const ProfileID& profile = *rows[i].second;
              list.Append(
                  json::HistoryEntryToValue(entry, profile)
                      .Set("favicon_url", FaviconPath(profile, entry.url))
                      .Set("host", HostOf(entry.url))
                      .Set("day_start", LocalDayStart(entry.last_visit)));
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("entries", std::move(list))
                        .Set("offset", offset)
                        .Set("has_more", rows.size() > end));
          },
          direct, offset, limit, std::move(reply)));
}

void OpenLibraryUI::DeleteHistory(const base::DictValue& payload,
                                  Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  std::vector<int64_t> ids;
  if (const base::ListValue* list = payload.FindList("ids")) {
    for (const base::Value& id : *list) {
      if (id.is_int() && id.GetInt() >= 0) {
        ids.push_back(id.GetInt());
      } else if (id.is_double() && id.GetDouble() >= 0) {
        ids.push_back(static_cast<int64_t>(id.GetDouble()));
      }
    }
  }
  std::vector<std::string> urls;
  if (const base::ListValue* list = payload.FindList("urls")) {
    for (const base::Value& url : *list) {
      if (url.is_string() && GURL(url.GetString()).is_valid()) {
        urls.push_back(url.GetString());
      }
    }
  }
  RunOnStore(ps->history,
             base::BindOnce(
                 [](std::vector<int64_t> ids, std::vector<std::string> urls,
                    HistoryStore* store) {
                   if (!ids.empty()) {
                     store->DeleteIds(ids);
                   }
                   for (const std::string& url : urls) {
                     store->DeleteUrl(url);
                   }
                   return store->UrlCount();
                 },
                 std::move(ids), std::move(urls)),
             base::BindOnce(
                 [](Reply reply, int64_t remaining) {
                   // Deleted pages leave the command bar's history rows too.
                   if (OpenBrowserService* service = OpenBrowserService::Get()) {
                     service->RefreshRecentHistory();
                   }
                   ReplyOk(std::move(reply),
                           base::DictValue()
                               .Set("ok", true)
                               .Set("remaining",
                                    static_cast<double>(remaining)));
                 },
                 std::move(reply)));
}

void OpenLibraryUI::ClearHistory(const base::DictValue& payload,
                                 Reply reply) {
  const std::string range = json::GetString(payload, "range", "all");
  const TimestampSec now = NowSec();
  std::optional<TimestampSec> since;
  if (range == "lastHour") {
    since = now - 3600;
  } else if (range == "today") {
    since = LocalDayStart(now);
  } else if (range == "last7Days") {
    since = LocalDayStart(now) - 6 * 86400;
  } else if (range != "all") {
    ReplyError(std::move(reply), "unknown range");
    return;
  }
  RunOnProfileStores<HistoryStore, int64_t>(
      ProfilesFromPayload(payload), &ProfileServices::history,
      base::BindRepeating(
          [](std::optional<TimestampSec> since, TimestampSec through,
             HistoryStore* store) {
            store->ClearRange(since, through);
            return store->UrlCount();
          },
          since, now + 1),
      base::BindOnce(
          [](Reply reply,
             std::vector<std::pair<ProfileID, int64_t>> results) {
            int64_t remaining = 0;
            for (const auto& [profile, count] : results) {
              remaining += count;
            }
            if (OpenBrowserService* service = OpenBrowserService::Get()) {
              service->RefreshRecentHistory();
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("ok", true)
                        .Set("remaining", static_cast<double>(remaining)));
          },
          std::move(reply)));
}

void OpenLibraryUI::LegacyDeleteHistory(const base::DictValue& payload,
                                        Reply reply) {
  if (json::GetBool(payload, "clear_all", false)) {
    base::DictValue clear = payload.Clone();
    clear.Set("range", "all");
    ClearHistory(clear, std::move(reply));
    return;
  }
  DeleteHistory(payload, std::move(reply));
}

// --- Archive -----------------------------------------------------------------

void OpenLibraryUI::ListArchive(const base::DictValue& payload, Reply reply) {
  RunOnProfileStores<ArchiveStore, std::vector<ArchivedTabRecord>>(
      ProfilesFromPayload(payload), &ProfileServices::archive,
      base::BindRepeating(
          [](std::string query, ArchiveStore* store) {
            return store->List(kMaxLimit, 0, query);
          },
          Query(payload)),
      base::BindOnce(
          [](Reply reply,
             std::vector<std::pair<ProfileID, std::vector<ArchivedTabRecord>>>
                 results) {
            std::vector<std::pair<const ArchivedTabRecord*, const ProfileID*>>
                rows;
            for (const auto& [profile, records] : results) {
              for (const ArchivedTabRecord& record : records) {
                rows.emplace_back(&record, &profile);
              }
            }
            std::stable_sort(rows.begin(), rows.end(),
                             [](const auto& a, const auto& b) {
                               return a.first->archived_at >
                                      b.first->archived_at;
                             });
            base::ListValue items;
            for (const auto& [record, profile] : rows) {
              items.Append(ArchivedToValue(*record, *profile));
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
          [](ProfileID profile, WindowID window, Reply reply,
             std::optional<ArchivedTabRecord> record) {
            OpenBrowserService* service = OpenBrowserService::Get();
            if (!record || !service) {
              ReplyError(std::move(reply), "no such item");
              return;
            }
            if (!record->profile_id || record->profile_id->empty()) {
              record->profile_id = profile;
            }
            // Back into Today of its Space (or the focused one), selected.
            const ItemID restored =
                record->kind == "folder"
                    ? RestoreArchivedFolder(*record, window)
                    : service->model().RestoreArchivedTab(*record);
            if (restored.empty()) {
              // Keep the row: the restore did not happen.
              if (ProfileServices* ps = service->ProfileServicesFor(profile)) {
                RunOnStore(ps->archive,
                           base::BindOnce(
                               [](ArchivedTabRecord record,
                                  ArchiveStore* store) {
                                 store->Archive(record);
                               },
                               *record));
              }
              ReplyError(std::move(reply), "cannot restore");
              return;
            }
            if (record->kind != "folder") {
              service->tab_bridge()->SelectNode(restored);
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("restored_id", restored)
                                          .Set("kind", record->kind)
                                          .Set("restored_url", record->url));
          },
          ProfileFromPayload(payload), TargetWindow(payload),
          std::move(reply)));
}

void OpenLibraryUI::DeleteArchived(const base::DictValue& payload,
                                   Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  std::vector<ItemID> ids;
  if (const base::ListValue* list = payload.FindList("ids")) {
    for (const base::Value& id : *list) {
      if (id.is_string() && !id.GetString().empty()) {
        ids.push_back(id.GetString());
      }
    }
  }
  if (const std::string* id = payload.FindString("id"); id && !id->empty()) {
    ids.push_back(*id);
  }
  if (!ps || ids.empty()) {
    ReplyError(std::move(reply), "no such item");
    return;
  }
  RunOnStore(ps->archive,
             base::BindOnce(
                 [](std::vector<ItemID> ids, ArchiveStore* store) {
                   return store->DeleteIds(ids);
                 },
                 std::move(ids)),
             base::BindOnce(
                 [](Reply reply, bool ok) {
                   ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
                 },
                 std::move(reply)));
}

void OpenLibraryUI::ClearArchive(const base::DictValue& payload,
                                 Reply reply) {
  RunOnProfileStores<ArchiveStore, bool>(
      ProfilesFromPayload(payload), &ProfileServices::archive,
      base::BindRepeating([](ArchiveStore* store) {
        return store->DeleteAll();
      }),
      base::BindOnce(
          [](Reply reply, std::vector<std::pair<ProfileID, bool>> results) {
            bool ok = true;
            for (const auto& [profile, cleared] : results) {
              ok = ok && cleared;
            }
            ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
          },
          std::move(reply)));
}

void OpenLibraryUI::PeekArchived(const base::DictValue& payload,
                                 Reply reply) {
  const GURL url(json::GetString(payload, "url"));
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    ReplyError(std::move(reply), "only http(s) pages can be peeked");
    return;
  }
  OpenWindowController* windows = service()->window_controller();
  OpenWindowUi* ui =
      windows ? windows->WindowUiFor(TargetWindow(payload)) : nullptr;
  if (!ui) {
    ui = windows ? windows->MainWindowUi() : nullptr;
  }
  if (!ui) {
    ReplyError(std::move(reply), "Peek is not available");
    return;
  }
  // Peek opens over the page; the Library drawer stays open.
  ui->OpenPeek(url, std::nullopt);
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

// --- Downloads ---------------------------------------------------------------

void OpenLibraryUI::ListDownloads(const base::DictValue& payload,
                                  Reply reply) {
  CollectDownloads(
      ProfilesFromPayload(payload), Limit(payload),
      base::BindOnce(
          [](std::string query, Reply reply, DownloadEntries entries) {
            base::ListValue downloads;
            for (const RecentDownloadEntry& entry : entries) {
              if (!MatchesAllWords(query, {entry.record.filename,
                                           entry.record.url})) {
                continue;
              }
              downloads.Append(DownloadEntryToValue(entry));
            }
            ReplyOk(std::move(reply),
                    base::DictValue()
                        .Set("downloads", std::move(downloads))
                        .Set("live_bridge",
                             OpenLibraryUI::download_bridge() != nullptr));
          },
          Query(payload), std::move(reply)));
}

void OpenLibraryUI::DownloadAction(const std::string& action,
                                   const base::DictValue& payload,
                                   Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const ProfileID profile = ProfileFromPayload(payload);
  ProfileServices* ps = ServicesFor(profile);
  if (id.empty() || !ps) {
    ReplyError(std::move(reply), "no such download");
    return;
  }
  if (OpenDownloadBridge* bridge = download_bridge()) {
    if (action == "trash") {
      bridge->MoveToTrash(
          id, base::BindOnce(
                  [](Reply reply, bool ok) {
                    if (ok) {
                      ReplyOk(std::move(reply),
                              base::DictValue().Set("ok", true));
                    } else {
                      ReplyError(std::move(reply),
                                 "the file could not be moved to the Trash");
                    }
                  },
                  std::move(reply)));
      return;
    }
    bool ok = false;
    if (action == "pause") {
      ok = bridge->Pause(id);
    } else if (action == "resume") {
      ok = bridge->Resume(id);
    } else if (action == "cancel") {
      ok = bridge->Cancel(id);
    } else if (action == "retry") {
      ok = bridge->Retry(id);
    } else if (action == "open") {
      ok = bridge->OpenFile(id);
    } else if (action == "reveal") {
      ok = bridge->RevealInFolder(id);
    } else if (action == "remove") {
      ok = bridge->RemoveFromHistory(id);
    }
    if (ok) {
      ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
    } else {
      ReplyError(std::move(reply), "the download cannot do that now");
    }
    return;
  }

  // No bridge: the live Chromium item when there is one, else the stored
  // row (the page never supplies a path).
  WithDownloadRecord(
      ps, id,
      base::BindOnce(
          [](std::string action, std::string id, ProfileID profile,
             Reply reply, std::optional<DownloadRecord> record) {
            OpenBrowserService* service = OpenBrowserService::Get();
            ProfileServices* ps =
                service ? service->ProfileServicesFor(profile) : nullptr;
            download::DownloadItem* item = LiveItem(profile, id);
            if (!ps || (!item && !record)) {
              ReplyError(std::move(reply), "no such download");
              return;
            }
            const DownloadRecord current =
                item ? RecordFromLiveItem(item) : *record;
            const base::FilePath path =
                base::FilePath::FromUTF8Unsafe(current.target_path);
            ::Profile* chrome_profile = ps->chrome_profile;
            auto fail = [&reply](const char* message) {
              ReplyError(std::move(reply), message);
            };
            bool ok = true;
            if (action == "pause") {
              ok = item && item->GetState() ==
                               download::DownloadItem::IN_PROGRESS &&
                   !item->IsPaused();
              if (ok) {
                item->Pause();
              }
            } else if (action == "resume") {
              ok = item && item->CanResume();
              if (ok) {
                item->Resume(/*user_resume=*/true);
              }
            } else if (action == "cancel") {
              ok = item && IsActiveDownloadState(current.state);
              if (ok) {
                item->Cancel(/*user_cancel=*/true);
              }
            } else if (action == "retry") {
              if (item && item->CanResume()) {
                item->Resume(/*user_resume=*/true);
              } else {
                const GURL url(current.url);
                content::DownloadManager* manager =
                    chrome_profile ? chrome_profile->GetDownloadManager()
                                   : nullptr;
                ok = manager && url.is_valid() && url.SchemeIsHTTPOrHTTPS();
                if (ok) {
                  auto params =
                      std::make_unique<download::DownloadUrlParameters>(
                          url, kRetryTrafficAnnotation);
                  manager->DownloadUrl(std::move(params),
                                       /*blob_url_loader_factory=*/nullptr);
                }
              }
            } else if (action == "open") {
              if (item &&
                  item->GetState() == download::DownloadItem::COMPLETE &&
                  item->CanOpenDownload()) {
                item->OpenDownload();
              } else {
                ok = current.state == "completed" && !path.empty() &&
                     chrome_profile;
                if (ok) {
                  platform_util::OpenItem(
                      chrome_profile, path, platform_util::OPEN_FILE,
                      platform_util::OpenOperationCallback());
                }
              }
            } else if (action == "reveal") {
              ok = !path.empty() && chrome_profile;
              if (ok) {
                platform_util::ShowItemInFolder(chrome_profile, path);
              }
            } else if (action == "remove" || action == "trash") {
              if (IsActiveDownloadState(current.state)) {
                fail("cancel the download first");
                return;
              }
              const bool trash = action == "trash";
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                  base::BindOnce(
                      [](bool trash, base::FilePath path) {
                        return !trash || MoveFileToTrash(path);
                      },
                      trash, path),
                  base::BindOnce(
                      [](std::string id, ProfileID profile, bool trash,
                         Reply reply, bool done) {
                        if (!done) {
                          ReplyError(
                              std::move(reply),
                              "the file could not be moved to the Trash");
                          return;
                        }
                        if (download::DownloadItem* live =
                                LiveItem(profile, id)) {
                          live->Remove();
                        }
                        if (ProfileServices* ps = ServicesFor(profile)) {
                          RunOnStore(ps->downloads,
                                     base::BindOnce(
                                         [](std::string id,
                                            DownloadHistoryStore* store) {
                                           store->Remove(id);
                                         },
                                         id));
                        }
                        BroadcastDownloadChange(id, profile, /*removed=*/true);
                        ReplyOk(std::move(reply),
                                base::DictValue().Set("ok", true).Set(
                                    "trashed", trash));
                      },
                      id, profile, trash, std::move(reply)));
              return;
            } else {
              ok = false;
            }
            if (!ok) {
              fail("the download cannot do that now");
              return;
            }
            BroadcastDownloadChange(id, profile, /*removed=*/false);
            ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
          },
          action, id, profile, std::move(reply)));
}

void OpenLibraryUI::ClearDownloads(const base::DictValue& payload,
                                   Reply reply) {
  const std::vector<ProfileID> profiles = ProfilesFromPayload(payload);
  if (OpenDownloadBridge* bridge = download_bridge()) {
    bool ok = true;
    for (const ProfileID& profile : profiles) {
      ok = bridge->ClearHistory(profile, std::nullopt, NowSec() + 1) && ok;
    }
    ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
    return;
  }
  // Finished rows only; running transfers stay.
  for (const ProfileID& profile : profiles) {
    OpenBrowserService* s = service();
    ::Profile* chrome_profile = s->ChromeProfileFor(profile);
    if (content::DownloadManager* manager =
            chrome_profile ? chrome_profile->GetDownloadManager() : nullptr) {
      content::DownloadManager::DownloadVector items;
      manager->GetAllDownloads(&items);
      for (download::DownloadItem* item : items) {
        if (item && item->GetState() != download::DownloadItem::IN_PROGRESS) {
          item->Remove();
        }
      }
    }
  }
  RunOnProfileStores<DownloadHistoryStore, int>(
      profiles, &ProfileServices::downloads,
      base::BindRepeating([](DownloadHistoryStore* store) {
        int removed = 0;
        for (const DownloadRecord& record : store->List()) {
          if (!IsActiveDownloadState(record.state) &&
              store->Remove(record.id)) {
            ++removed;
          }
        }
        return removed;
      }),
      base::BindOnce(
          [](Reply reply, std::vector<std::pair<ProfileID, int>> results) {
            int removed = 0;
            for (const auto& [profile, count] : results) {
              removed += count;
            }
            BroadcastDownloadChange(std::string(), ProfileID(),
                                    /*removed=*/true);
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("ok", true)
                                          .Set("removed", removed));
          },
          std::move(reply)));
}

void OpenLibraryUI::LegacyOpenDownload(const base::DictValue& payload,
                                       Reply reply) {
  DownloadAction(json::GetBool(payload, "reveal", false) ? "reveal" : "open",
                 payload, std::move(reply));
}

// --- Media -------------------------------------------------------------------

void OpenLibraryUI::ListMedia(const base::DictValue& payload, Reply reply) {
  const std::vector<ProfileID> profiles = ProfilesFromPayload(payload);
  std::vector<ProfileServices*> targets;
  for (const ProfileID& profile : profiles) {
    if (ProfileServices* ps = ServicesFor(profile)) {
      targets.push_back(ps);
    }
  }
  auto finish = base::BindOnce(
      [](std::string query, std::string source, Reply reply,
         std::vector<MediaScan> scans) {
        std::vector<const MediaEntry*> rows;
        base::ListValue folders;
        std::set<std::string> seen_folders;
        for (const MediaScan& scan : scans) {
          for (const MediaEntry& entry : scan.items) {
            if ((source.empty() || source == "all" ||
                 entry.source == source) &&
                MatchesAllWords(query, {entry.title, entry.source_url,
                                        entry.folder})) {
              rows.push_back(&entry);
            }
          }
          for (const std::string& folder : scan.folders) {
            if (seen_folders.insert(folder).second) {
              folders.Append(folder);
            }
          }
        }
        std::stable_sort(rows.begin(), rows.end(),
                         [](const MediaEntry* a, const MediaEntry* b) {
                           return a->captured_at > b->captured_at;
                         });
        base::ListValue items;
        for (const MediaEntry* entry : rows) {
          items.Append(MediaEntryToValue(*entry));
        }
        ReplyOk(std::move(reply), base::DictValue()
                                      .Set("items", std::move(items))
                                      .Set("folders", std::move(folders)));
      },
      Query(payload), json::GetString(payload, "source"), std::move(reply));
  auto barrier = base::BarrierCallback<MediaScan>(targets.size(),
                                                  std::move(finish));
  for (ProfileServices* ps : targets) {
    RunOnStore(ps->downloads,
               base::BindOnce(&ScanMedia, ps->id, RootsFor(*ps)),
               base::BindOnce([](base::RepeatingCallback<void(MediaScan)> b,
                                 MediaScan scan) { b.Run(std::move(scan)); },
                              barrier));
  }
}

void OpenLibraryUI::AddMediaFolder(const base::DictValue& payload,
                                   Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps) {
    ReplyError(std::move(reply), "no such profile");
    return;
  }
  // A preset resolves in the browser; a custom path comes from the user's
  // own typing or native folder picker and is validated below.
  const std::string preset = json::GetString(payload, "preset");
  std::vector<base::FilePath> candidates;
  if (!preset.empty()) {
    candidates = ResolveBuiltinMediaFolderCandidates(preset);
    if (candidates.empty()) {
      ReplyError(std::move(reply), "unknown folder");
      return;
    }
  } else {
    const base::FilePath folder =
        base::FilePath::FromUTF8Unsafe(json::GetString(payload, "path"));
    if (folder.empty() || !folder.IsAbsolute() || folder.ReferencesParent()) {
      ReplyError(std::move(reply), "choose a full folder path");
      return;
    }
    candidates.push_back(folder);
  }
  RunOnStore(
      ps->downloads,
      base::BindOnce(
          [](std::vector<base::FilePath> candidates, MediaRoots roots,
             DownloadHistoryStore*) -> std::string {
            const base::FilePath real_data =
                CanonicalizePath(roots.user_data_dir);
            base::FilePath chosen;
            std::string last_error = "that folder does not exist";
            for (const base::FilePath& candidate : candidates) {
              const base::FilePath real = CanonicalizePath(candidate);
              std::string err;
              if (ValidateMediaFolder(real, real_data, &err)) {
                chosen = real;
                break;
              }
              if (!err.empty()) {
                last_error = std::move(err);
              }
            }
            if (chosen.empty()) {
              return last_error;
            }
            std::vector<base::FilePath> folders =
                ReadFolderSources(roots.folders_file);
            if (std::find(folders.begin(), folders.end(), chosen) !=
                folders.end()) {
              return std::string();
            }
            if (folders.size() >= kMaxFolderSources) {
              return "too many folders";
            }
            folders.push_back(chosen);
            return WriteFolderSources(roots.folders_file, folders)
                       ? std::string()
                       : "the folder list could not be saved";
          },
          std::move(candidates), RootsFor(*ps)),
      base::BindOnce(
          [](Reply reply, std::string error) {
            if (!error.empty()) {
              ReplyError(std::move(reply), std::move(error));
              return;
            }
            ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
          },
          std::move(reply)));
}

void OpenLibraryUI::RemoveMediaFolder(const base::DictValue& payload,
                                      Reply reply) {
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  const base::FilePath folder =
      base::FilePath::FromUTF8Unsafe(json::GetString(payload, "path"));
  if (!ps || folder.empty()) {
    ReplyError(std::move(reply), "no such folder");
    return;
  }
  RunOnStore(ps->downloads,
             base::BindOnce(
                 [](base::FilePath folder, MediaRoots roots,
                    DownloadHistoryStore*) {
                   std::vector<base::FilePath> folders =
                       ReadFolderSources(roots.folders_file);
                   const base::FilePath real = CanonicalizePath(folder);
                   std::erase_if(folders, [&](const base::FilePath& existing) {
                     return existing == folder ||
                            (!real.empty() &&
                             (existing == real ||
                              CanonicalizePath(existing) == real));
                   });
                   return WriteFolderSources(roots.folders_file, folders);
                 },
                 folder, RootsFor(*ps)),
             base::BindOnce(
                 [](Reply reply, bool ok) {
                   ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
                 },
                 std::move(reply)));
}

void OpenLibraryUI::PickMediaFolder(const base::DictValue& payload,
                                    Reply reply) {
  content::WebContents* contents =
      web_ui() ? web_ui()->GetWebContents() : nullptr;
  if (folder_dialog_ || !contents) {
    ReplyOk(std::move(reply), base::DictValue().Set("cancelled", true));
    return;
  }
  const std::string title =
      json::GetString(payload, "title", "Choose Media Folder");
  const base::FilePath default_path =
      base::FilePath::FromUTF8Unsafe(json::GetString(payload, "default_path"));
  folder_dialog_ = std::make_unique<FolderDialog>(
      base::BindOnce(&OpenLibraryUI::OnFolderDialogDone,
                     weak_factory_.GetWeakPtr(), std::move(reply)));
  folder_dialog_->Show(base::UTF8ToUTF16(title), default_path,
                       contents->GetTopLevelNativeWindow());
}

void OpenLibraryUI::OnFolderDialogDone(Reply reply,
                                       std::optional<base::FilePath> path) {
  // The listener is still on the stack: delete it after this task.
  if (folder_dialog_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(folder_dialog_));
  }
  base::DictValue result;
  result.Set("cancelled", !path.has_value());
  if (path) {
    result.Set("path", path->AsUTF8Unsafe());
  }
  ReplyOk(std::move(reply), std::move(result));
}

void OpenLibraryUI::MediaAction(const std::string& action,
                                const base::DictValue& payload,
                                Reply reply) {
  std::optional<MediaToken> token =
      DecodeMediaToken(json::GetString(payload, "id"));
  ProfileServices* ps = token ? ServicesFor(token->profile) : nullptr;
  if (!ps) {
    ReplyError(std::move(reply), "no such item");
    return;
  }
  const MediaRoots roots = RootsFor(*ps);
  RunOnStore(
      ps->downloads,
      base::BindOnce(
          [](MediaToken token, MediaRoots roots,
             DownloadHistoryStore* store) {
            return ResolveMedia(token, roots, store, /*allow_video=*/true);
          },
          *token, roots),
      base::BindOnce(
          [](std::string action, MediaToken token, Reply reply,
             std::optional<base::FilePath> path) {
            ProfileServices* ps = ServicesFor(token.profile);
            if (!path || !ps) {
              ReplyError(std::move(reply), "the file is not available");
              return;
            }
            if (action == "open") {
              platform_util::OpenItem(ps->chrome_profile, *path,
                                      platform_util::OPEN_FILE,
                                      platform_util::OpenOperationCallback());
            } else if (action == "reveal") {
              platform_util::ShowItemInFolder(ps->chrome_profile, *path);
            } else if (action == "copyImage") {
              // The page copies decoded pixels itself (async clipboard);
              // this writes the file for apps that paste files, plus its
              // path as text.
              ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
              writer.WriteFilenames(
                  ui::FileInfosToURIList({ui::FileInfo(*path, base::FilePath())}));
              writer.WriteText(base::UTF8ToUTF16(path->AsUTF8Unsafe()));
            } else if (action == "delete") {
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
                  base::BindOnce(&MoveFileToTrash, *path),
                  base::BindOnce(
                      [](MediaToken token, Reply reply, bool ok) {
                        if (!ok) {
                          ReplyError(std::move(reply),
                                     "the file could not be moved to the "
                                     "Trash");
                          return;
                        }
                        if (token.kind == "download") {
                          BroadcastDownloadChange(token.a, token.profile,
                                                  /*removed=*/false);
                        }
                        ReplyOk(std::move(reply),
                                base::DictValue().Set("ok", true));
                      },
                      token, std::move(reply)));
              return;
            }
            ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
          },
          action, *token, std::move(reply)));
}

// --- Spaces ------------------------------------------------------------------

void OpenLibraryUI::GetSpaces(const base::DictValue& payload, Reply reply) {
  const bool all = WantsAllProfiles(payload) || !payload.Find("profile_id");
  const ProfileID only = ProfileFromPayload(payload);
  const SpaceID active = FocusedSpace(TargetWindow(payload));
  const bool system_dark = SystemDark();
  base::ListValue spaces;
  for (const Space& space : service()->model().spaces()) {
    if (!all && space.profile_id != only) {
      continue;
    }
    const Profile* owner = service()->model().FindProfile(space.profile_id);
    spaces.Append(SpaceSummary(space)
                      .Set("profile_name",
                           owner ? owner->name : std::string())
                      .Set("is_active", space.id == active)
                      .Set("theme",
                           SpaceThemePayload(
                               space, SpaceIsDark(space, system_dark))));
  }
  ReplyOk(std::move(reply), base::DictValue()
                                .Set("spaces", std::move(spaces))
                                .Set("active_space_id", active));
}

void OpenLibraryUI::CreateSpace(const base::DictValue& payload, Reply reply) {
  std::optional<std::string> title = json::FindString(payload, "title");
  if (title && title->size() > 128) {
    ReplyError(std::move(reply), "the title is too long");
    return;
  }
  const SpaceID id = service()->model().CreateSpace(
      ProfileFromPayload(payload), title,
      json::SpaceIconFromValue(payload.Find("icon")));
  const Space* space = service()->model().FindSpace(id);
  if (!space) {
    ReplyError(std::move(reply), "the Space could not be created");
    return;
  }
  if (json::GetBool(payload, "focus", false)) {
    service()->tab_bridge()->FocusSpace(id, TargetWindow(payload));
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set("space", SpaceSummary(*space)));
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
  ReplyOk(std::move(reply),
          base::DictValue().Set("space", SpaceSummary(*space)));
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

void OpenLibraryUI::SwitchSpace(const base::DictValue& payload,
                                Reply reply) {
  const std::string id = json::GetString(payload, "id");
  if (!service()->model().FindSpace(id)) {
    ReplyError(std::move(reply), "no such space");
    return;
  }
  const WindowID window = TargetWindow(payload);
  const bool ok = service()->tab_bridge()->FocusSpace(id, window);
  // Choosing a Space leaves the Library (as the sidebar's Space switcher).
  if (ok && json::GetBool(payload, "close", true)) {
    RequestClose(window);
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
}

void OpenLibraryUI::ReorderSpaces(const base::DictValue& payload,
                                  Reply reply) {
  const base::ListValue* list = payload.FindList("ids");
  if (!list) {
    list = payload.FindList("ordered_ids");
  }
  if (!list || list->empty()) {
    ReplyError(std::move(reply), "ids list required");
    return;
  }
  std::vector<SpaceID> ordered_ids;
  ordered_ids.reserve(list->size());
  for (const base::Value& v : *list) {
    if (!v.is_string() || v.GetString().empty()) {
      ReplyError(std::move(reply), "invalid space id");
      return;
    }
    ordered_ids.push_back(v.GetString());
  }
  if (!service()->model().ReorderSpaces(ordered_ids)) {
    ReplyError(std::move(reply), "invalid space order");
    return;
  }
  service()->ScheduleSave();
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

void OpenLibraryUI::SetSpaceProfile(const base::DictValue& payload,
                                    Reply reply) {
  const std::string id = json::GetString(payload, "id");
  const std::string* profile = payload.FindString("profile_id");
  if (!profile || !service()->model().FindProfile(*profile) ||
      !service()->model().FindSpace(id)) {
    ReplyError(std::move(reply), "no such space or profile");
    return;
  }
  ReplyOk(std::move(reply),
          base::DictValue().Set(
              "ok", service()->model().MoveSpaceToProfile(id, *profile)));
}

// --- Boosts, Easels and Notes ------------------------------------------------

void OpenLibraryUI::ListBoosts(const base::DictValue& payload, Reply reply) {
  RunOnProfileStores<BoostStore, std::vector<Boost>>(
      ProfilesFromPayload(payload), &ProfileServices::boosts,
      base::BindRepeating([](BoostStore* store) { return store->List(); }),
      base::BindOnce(
          [](std::string query, Reply reply,
             std::vector<std::pair<ProfileID, std::vector<Boost>>> results) {
            base::ListValue boosts;
            for (auto& [profile, list] : results) {
              for (Boost& boost : list) {
                if (boost.profile_id.empty()) {
                  boost.profile_id = profile;
                }
                if (MatchesAllWords(query, {boost.name, boost.host_pattern})) {
                  boosts.Append(json::BoostToValue(boost));
                }
              }
            }
            ReplyOk(std::move(reply),
                    base::DictValue().Set("boosts", std::move(boosts)));
          },
          Query(payload), std::move(reply)));
}

void OpenLibraryUI::ListDocuments(const base::DictValue& payload,
                                  Reply reply) {
  using Docs =
      std::pair<std::vector<EaselIndexEntry>, std::vector<NoteIndexEntry>>;
  RunOnProfileStores<DocumentStore, Docs>(
      ProfilesFromPayload(payload), &ProfileServices::documents,
      base::BindRepeating([](DocumentStore* store) {
        return Docs(store->ListEasels(), store->ListNotes());
      }),
      base::BindOnce(
          [](std::string query, Reply reply,
             std::vector<std::pair<ProfileID, Docs>> results) {
            base::ListValue easels;
            base::ListValue notes;
            for (const auto& [profile, docs] : results) {
              for (const EaselIndexEntry& easel : docs.first) {
                if (!MatchesAllWords(query, {easel.title})) {
                  continue;
                }
                easels.Append(
                    base::DictValue()
                        .Set("id", easel.id)
                        .Set("kind", "easel")
                        .Set("title", easel.title)
                        .Set("element_count",
                             static_cast<int>(easel.element_count))
                        .Set("palette", "vibrant")
                        .Set("modified_at", easel.modified_at)
                        .Set("url", OpenWebUIURL(kHostEasel, easel.id))
                        .Set("profile_id", profile));
              }
              for (const NoteIndexEntry& note : docs.second) {
                if (!MatchesAllWords(query, {note.title})) {
                  continue;
                }
                notes.Append(base::DictValue()
                                 .Set("id", note.id)
                                 .Set("kind", "note")
                                 .Set("title", note.title)
                                 .Set("modified_at", note.modified_at)
                                 .Set("url", OpenWebUIURL(kHostNote, note.id))
                                 .Set("profile_id", profile));
              }
            }
            ReplyOk(std::move(reply), base::DictValue()
                                          .Set("easels", std::move(easels))
                                          .Set("notes", std::move(notes)));
          },
          Query(payload), std::move(reply)));
}

void OpenLibraryUI::CreateDocument(const base::DictValue& payload,
                                   Reply reply) {
  const std::string kind = json::GetString(payload, "kind");
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps || (kind != "easel" && kind != "note")) {
    ReplyError(std::move(reply), "unknown document kind");
    return;
  }
  RunOnStore(ps->documents,
             base::BindOnce(
                 [](bool easel, DocumentStore* store) -> std::string {
                   if (easel) {
                     EaselDocument doc = store->CreateEasel();
                     return store->SaveEasel(doc) ? doc.id : std::string();
                   }
                   NoteDocument doc = store->CreateNote();
                   return store->SaveNote(doc) ? doc.id : std::string();
                 },
                 kind == "easel"),
             base::BindOnce(
                 [](std::string kind, bool open, Reply reply, std::string id) {
                   OpenBrowserService* service = OpenBrowserService::Get();
                   if (id.empty() || !service) {
                     ReplyError(std::move(reply),
                                "the document could not be created");
                     return;
                   }
                   const std::string url = OpenWebUIURL(
                       kind == "easel" ? kHostEasel : kHostNote, id);
                   if (open) {
                     service->tab_bridge()->OpenTab(GURL(url),
                                                    /*background=*/false);
                   }
                   ReplyOk(std::move(reply),
                           base::DictValue().Set("id", id).Set("url", url));
                 },
                 kind, json::GetBool(payload, "open", true),
                 std::move(reply)));
}

void OpenLibraryUI::DeleteDocument(const base::DictValue& payload,
                                   Reply reply) {
  const std::string kind = json::GetString(payload, "kind");
  const std::string id = json::GetString(payload, "id");
  ProfileServices* ps = ServicesFor(ProfileFromPayload(payload));
  if (!ps || (kind != "easel" && kind != "note") ||
      !DocumentStore::IsValidDocumentId(id)) {
    ReplyError(std::move(reply), "no such document");
    return;
  }
  RunOnStore(ps->documents,
             base::BindOnce(
                 [](bool easel, std::string id, DocumentStore* store) {
                   return easel ? store->DeleteEasel(id)
                                : store->DeleteNote(id);
                 },
                 kind == "easel", id),
             base::BindOnce(
                 [](Reply reply, bool ok) {
                   ReplyOk(std::move(reply), base::DictValue().Set("ok", ok));
                 },
                 std::move(reply)));
}

// --- Navigation --------------------------------------------------------------

void OpenLibraryUI::OpenUrl(const base::DictValue& payload, Reply reply) {
  const GURL url(json::GetString(payload, "url"));
  // Web pages, Open's own pages and a short list of Chromium settings pages
  // (Settings' Site Permissions / Passwords / Payment Methods rows). Never
  // file:, javascript: or other chrome:// pages.
  static constexpr std::string_view kChromeHosts[] = {
      "settings", "password-manager", "extensions"};
  const bool chrome_page =
      url.SchemeIs("chrome") &&
      std::find(std::begin(kChromeHosts), std::end(kChromeHosts),
                url.host()) != std::end(kChromeHosts);
  if (!url.is_valid() || !(url.SchemeIsHTTPOrHTTPS() ||
                           url.SchemeIs(kOpenScheme) || chrome_page)) {
    ReplyError(std::move(reply), "only http(s) and open:// URLs can be opened");
    return;
  }
  OpenTabBridge* bridge = service()->tab_bridge();
  const bool background = json::GetBool(payload, "background", false);
  if (json::GetBool(payload, "new_tab", true)) {
    bridge->OpenTab(url, background);
  } else if (std::optional<ItemID> active = bridge->ActiveTabId()) {
    bridge->Navigate(*active, url);
  } else {
    bridge->OpenTab(url, /*background=*/false);
  }
  if (json::GetBool(payload, "close_library", false)) {
    RequestClose(TargetWindow(payload));
  }
  ReplyOk(std::move(reply), base::DictValue().Set("ok", true));
}

}  // namespace open_unified::webui
