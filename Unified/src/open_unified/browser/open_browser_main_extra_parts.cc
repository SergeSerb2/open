// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_browser_main_extra_parts.h"

#include "base/base_paths.h"
#include "base/path_service.h"
#include "build/build_config.h"
#include "chrome/common/chrome_paths.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"

#if BUILDFLAG(IS_WIN)
#include <shobjidl.h>
#endif

namespace open_unified {

OpenBrowserMainExtraParts::OpenBrowserMainExtraParts() = default;

OpenBrowserMainExtraParts::~OpenBrowserMainExtraParts() = default;

void OpenBrowserMainExtraParts::PreProfileInit() {
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
