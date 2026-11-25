// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// easel.* and note.* methods of open://easel and open://note. Documents
// live per Profile under <user data>/Profiles/<dir>/Documents
// (DocumentStore, Track 3).
class OpenDocumentsUI : public OpenRpcDomain {
 public:
  explicit OpenDocumentsUI(OpenWebUIMessageHandler* handler);
  ~OpenDocumentsUI() override;

  void RegisterMethods() override;

 private:
  void EaselLoad(const base::DictValue& payload, Reply reply);
  void EaselSave(const base::DictValue& payload, Reply reply);
  void EaselExportHtml(const base::DictValue& payload, Reply reply);
  void NoteLoad(const base::DictValue& payload, Reply reply);
  void NoteSave(const base::DictValue& payload, Reply reply);

  base::WeakPtrFactory<OpenDocumentsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_DOCUMENTS_UI_H_
