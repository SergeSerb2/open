// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// library.* methods: History, Archive, Downloads, Media, Spaces and Easels
// sections of open://library (the Library overlay's pages).
class OpenLibraryUI : public OpenRpcDomain {
 public:
  explicit OpenLibraryUI(OpenWebUIMessageHandler* handler);
  ~OpenLibraryUI() override;

  void RegisterMethods() override;

  static base::DictValue SpaceSummary(const Space& space);

 private:
  void GetHistory(const base::DictValue& payload, Reply reply);
  void DeleteHistory(const base::DictValue& payload, Reply reply);
  void GetArchive(const base::DictValue& payload, Reply reply);
  void RestoreArchived(const base::DictValue& payload, Reply reply);
  void GetDownloads(const base::DictValue& payload, Reply reply);
  void OpenDownload(const base::DictValue& payload, Reply reply);
  void GetSpaces(const base::DictValue& payload, Reply reply);
  void UpdateSpace(const base::DictValue& payload, Reply reply);
  void DeleteSpace(const base::DictValue& payload, Reply reply);
  void GetMedia(const base::DictValue& payload, Reply reply);
  void GetEasels(const base::DictValue& payload, Reply reply);
  void OpenUrl(const base::DictValue& payload, Reply reply);

  base::WeakPtrFactory<OpenLibraryUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_LIBRARY_UI_H_
