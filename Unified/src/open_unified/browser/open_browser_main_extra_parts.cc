// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_browser_main_extra_parts.h"

#include "base/base_paths.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/path_service.h"
#include "build/build_config.h"
#include "chrome/common/chrome_paths.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_switches.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"

#if BUILDFLAG(IS_WIN)
#include <shobjidl.h>
#endif

namespace open_unified {

OpenBrowserMainExtraParts::OpenBrowserMainExtraParts() = default;

OpenBrowserMainExtraParts::~OpenBrowserMainExtraParts() = default;

void OpenBrowserMainExtraParts::PreProfileInit() {
  // Wire advanced.widevine before ChromeBrowserMainParts calls
  // component_updater::RegisterComponentsForUpdate() (hook 0008 gates Widevine
  // CDM registration on --open-enable-widevine). chrome::DIR_USER_DATA is
  // already initialized during PreEarlyInitialization() / OnLocalStateLoaded().
  if (base::CommandLine* cmd = base::CommandLine::ForCurrentProcess();
      cmd && !cmd->HasSwitch(switches::kEnableWidevine)) {
    base::FilePath user_data_dir;
    if (base::PathService::Get(chrome::DIR_USER_DATA, &user_data_dir) &&
        !user_data_dir.empty()) {
      const base::FilePath prefs_path = user_data_dir.AppendASCII("State")
                                            .AppendASCII("Preferences.json");
      std::string raw;
      if (base::PathExists(prefs_path) &&
          base::ReadFileToStringWithMaxSize(prefs_path, &raw, 1024 * 1024)) {
        if (std::optional<base::DictValue> dict =
                base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)) {
          if (dict->FindBool("advanced.widevine").value_or(false)) {
            cmd->AppendSwitch(switches::kEnableWidevine);
          }
        }
      }
    }
  }

  // A BrowserContextKeyedServiceFactory must exist before the first
  // Profile, so the dependency manager creates services for every context.
  OpenAdBlockProfileServiceFactory::GetInstance();
}

void OpenBrowserMainExtraParts::PreBrowserStart() {
#if BUILDFLAG(IS_WIN)
  ::SetCurrentProcessExplicitAppUserModelID(L"OpenBrowser.Open.Unified");
#endif
  base::FilePath user_data_dir;
  // chrome::DIR_USER_DATA honours --user-data-dir; the platform default is
  // set by hook 0008 (Open's product directory name).
  base::PathService::Get(chrome::DIR_USER_DATA, &user_data_dir);
  service_ = std::make_unique<OpenBrowserService>(user_data_dir);
}

void OpenBrowserMainExtraParts::PostBrowserStart() {
  if (service_) {
    service_->Start();
  }
}

void OpenBrowserMainExtraParts::PostMainMessageLoopRun() {
  if (service_) {
    service_->Shutdown();
  }
  service_.reset();
}

}  // namespace open_unified
