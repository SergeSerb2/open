// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// easel.*, note.*, and documents.* methods of open://easel and open://note.
// Documents live per Profile under <user data>/Profiles/<dir>/{Easels,Notes}
// (DocumentStore) and uploaded binary assets under
// <user data>/Profiles/<dir>/documents/assets/<doc_id>/<asset_id>.
class OpenDocumentsUI : public OpenRpcDomain {
 public:
  explicit OpenDocumentsUI(OpenWebUIMessageHandler* handler);
  ~OpenDocumentsUI() override;

  void RegisterMethods() override;
  void OnJavascriptDisallowed() override;

 private:
  class UrlCaptureSession;

  // Existing easel.* / note.* RPCs.
  void EaselLoad(const base::DictValue& payload, Reply reply);
  void EaselSave(const base::DictValue& payload, Reply reply);
  void EaselExportHtml(const base::DictValue& payload, Reply reply);
  void NoteLoad(const base::DictValue& payload, Reply reply);
  void NoteSave(const base::DictValue& payload, Reply reply);

  // Unified documents.* RPCs (assets, live capture, export, rename, duplicate,
  // link navigation).
  void UploadAsset(const base::DictValue& payload, Reply reply);
  void DeleteAsset(const base::DictValue& payload, Reply reply);
  void ReadAsset(const base::DictValue& payload, Reply reply);
  void CaptureUrl(const base::DictValue& payload, Reply reply);
  void ExportMarkdown(const base::DictValue& payload, Reply reply);
  void ExportHtml(const base::DictValue& payload, Reply reply);
  void ExportImage(const base::DictValue& payload, Reply reply);
  void DuplicateDocument(const base::DictValue& payload, Reply reply);
  void RenameDocument(const base::DictValue& payload, Reply reply);
  void OpenUrl(const base::DictValue& payload, Reply reply);

  // Helpers.
  std::string CurrentDocType(const base::DictValue& payload) const;
  std::string ResolveDocumentId(const base::DictValue& payload) const;
  void SyncTabTitleAndUrl(std::string_view doc_type,
                          const std::string& doc_id,
                          const std::string& title);
  void FinishCaptureSession(uint64_t capture_id,
                            const std::string& doc_id,
                            const std::string& url,
                            const std::string& title,
                            std::vector<uint8_t> png_bytes,
                            const std::string& source,
                            Reply reply);

  uint64_t next_capture_id_ = 1;
  std::map<uint64_t, std::unique_ptr<UrlCaptureSession>> active_captures_;
  base::WeakPtrFactory<OpenDocumentsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_
