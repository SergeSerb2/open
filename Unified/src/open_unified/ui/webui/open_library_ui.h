// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_

#include <string>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "content/public/browser/web_ui_data_source.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace content {
class BrowserContext;
}

namespace open_unified {
class OpenDownloadBridge;
}

namespace open_unified::webui {

// library.* methods of open://library: the L3 in-window Library drawer
// (Spaces, Downloads, Archive, History, Media, Easels & Notes, Boosts).
//
// Every list method takes profile_id (a Profile id, or "all" for the merged
// view; each row then carries its own profile_id) and every row action takes
// the row's profile_id back. The legacy names (library.getHistory, ...) stay
// registered for open://settings and older pages.
//
// Binary routes (open_webui_config.cc installs them on the library data
// source): /thumb/<media id>, /media-file/<media id> and /favicon/<page>.
class OpenLibraryUI : public OpenRpcDomain {
 public:
  explicit OpenLibraryUI(OpenWebUIMessageHandler* handler);
  ~OpenLibraryUI() override;

  void RegisterMethods() override;

  static base::DictValue SpaceSummary(const Space& space);
  // The drawer palette of |space| as CSS colors: {bg, fg, accent, surface,
  // mode: "light"|"dark", space_id}. The host may push it to open pages with
  // BroadcastEvent("library.setSpaceTheme", payload).
  static base::DictValue SpaceThemePayload(const Space& space, bool dark);

  // The app-wide OpenDownloadBridge (live Chromium downloads). Until
  // OpenBrowserService exposes download_bridge(), the service calls
  // SetDownloadBridge(bridge) once the bridge exists and
  // SetDownloadBridge(nullptr) before destroying it. Without a bridge the
  // Library falls back to DownloadHistoryStore rows plus each Profile's
  // content::DownloadManager items.
  static void SetDownloadBridge(OpenDownloadBridge* bridge);
  static OpenDownloadBridge* download_bridge();

  // WebUIDataSource request filter of open://library.
  static bool ShouldHandleResource(const std::string& path);
  static void HandleResource(
      content::BrowserContext* context,
      const std::string& path,
      content::WebUIDataSource::GotDataCallback callback);

 private:
  // Drawer.
  void Close(const base::DictValue& payload, Reply reply);
  void GetTheme(const base::DictValue& payload, Reply reply);

  // History.
  void ListHistory(const base::DictValue& payload, Reply reply);
  void DeleteHistory(const base::DictValue& payload, Reply reply);
  void ClearHistory(const base::DictValue& payload, Reply reply);
  void LegacyDeleteHistory(const base::DictValue& payload, Reply reply);

  // Archive.
  void ListArchive(const base::DictValue& payload, Reply reply);
  void RestoreArchived(const base::DictValue& payload, Reply reply);
  void DeleteArchived(const base::DictValue& payload, Reply reply);
  void ClearArchive(const base::DictValue& payload, Reply reply);
  void PeekArchived(const base::DictValue& payload, Reply reply);

  // Downloads.
  void ListDownloads(const base::DictValue& payload, Reply reply);
  void DownloadAction(const std::string& action,
                      const base::DictValue& payload,
                      Reply reply);
  void ClearDownloads(const base::DictValue& payload, Reply reply);
  void LegacyOpenDownload(const base::DictValue& payload, Reply reply);

  // Media.
  void ListMedia(const base::DictValue& payload, Reply reply);
  void AddMediaFolder(const base::DictValue& payload, Reply reply);
  void RemoveMediaFolder(const base::DictValue& payload, Reply reply);
  void MediaAction(const std::string& action,
                   const base::DictValue& payload,
                   Reply reply);

  // Spaces.
  void GetSpaces(const base::DictValue& payload, Reply reply);
  void CreateSpace(const base::DictValue& payload, Reply reply);
  void UpdateSpace(const base::DictValue& payload, Reply reply);
  void DeleteSpace(const base::DictValue& payload, Reply reply);
  void SwitchSpace(const base::DictValue& payload, Reply reply);
  void ReorderSpaces(const base::DictValue& payload, Reply reply);
  void SetSpaceProfile(const base::DictValue& payload, Reply reply);

  // Boosts, Easels and Notes.
  void ListBoosts(const base::DictValue& payload, Reply reply);
  void ListDocuments(const base::DictValue& payload, Reply reply);
  void CreateDocument(const base::DictValue& payload, Reply reply);
  void DeleteDocument(const base::DictValue& payload, Reply reply);

  // Navigation.
  void OpenUrl(const base::DictValue& payload, Reply reply);

  // The window this page acts on: payload "window_id" when known, else the
  // active window.
  WindowID TargetWindow(const base::DictValue& payload) const;
  // Asks the host to close the Library drawer of |window_id| (and closes
  // the page's sidebar tab when open://library is shown as a tab).
  bool RequestClose(const WindowID& window_id);

  base::WeakPtrFactory<OpenLibraryUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_
