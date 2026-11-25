// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// boosts.* methods of open://boosts (Boost editor and Zap).
class OpenBoostsUI : public OpenRpcDomain {
 public:
  explicit OpenBoostsUI(OpenWebUIMessageHandler* handler);
  ~OpenBoostsUI() override;

  void RegisterMethods() override;

 private:
  void List(const base::DictValue& payload, Reply reply);
  void Save(const base::DictValue& payload, Reply reply);
  void Delete(const base::DictValue& payload, Reply reply);
  void Toggle(const base::DictValue& payload, Reply reply);
  void StartZap(const base::DictValue& payload, Reply reply);
  void RemoveZap(const base::DictValue& payload, Reply reply);

  // Saves |boost| (store runner), refreshes the controller's cache and
  // replies {boost}.
  void SaveAndReply(Boost boost, Reply reply);

  base::WeakPtrFactory<OpenBoostsUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_BOOSTS_UI_H_
