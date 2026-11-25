// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_
#define OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_

#include <optional>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "open_unified/ui/webui/open_webui_config.h"

namespace open_unified::webui {

// onboarding.*, import.* and welcome.* methods of open://onboarding and
// open://welcome (Open's own first-run identity, the doorway-and-sun mark).
class OpenOnboardingUI : public OpenRpcDomain {
 public:
  explicit OpenOnboardingUI(OpenWebUIMessageHandler* handler);
  ~OpenOnboardingUI() override;

  void RegisterMethods() override;

 private:
  void GetState(const base::DictValue& payload, Reply reply);
  void Complete(const base::DictValue& payload, Reply reply);
  void ProbeBrowsers(const base::DictValue& payload, Reply reply);
  void RunImport(const base::DictValue& payload, Reply reply);
  void TriggerWelcomeAction(const base::DictValue& payload, Reply reply);

  // Bookmarks and history read off the UI thread (BrowserImporter).
  struct ImportData {
    std::string browser_name;
    std::optional<Folder> bookmarks;
    std::vector<HistoryEntry> history;
    std::string error;
  };
  static ImportData ReadImportData(std::string source_id,
                                   std::vector<std::string> kinds);
  void ApplyImport(std::string source_id,
                   ProfileID profile,
                   Reply reply,
                   ImportData data);
  static void CollectTabs(const std::vector<SidebarNode>& nodes,
                          std::vector<const Tab*>* out);

  base::WeakPtrFactory<OpenOnboardingUI> weak_factory_{this};
};

}  // namespace open_unified::webui

#endif  // OPEN_UNIFIED_UI_WEBUI_OPEN_ONBOARDING_UI_H_
