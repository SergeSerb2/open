// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_BROWSER_MAIN_EXTRA_PARTS_H_
#define OPEN_UNIFIED_BROWSER_OPEN_BROWSER_MAIN_EXTRA_PARTS_H_

#include <memory>

#include "chrome/browser/chrome_browser_main_extra_parts.h"

namespace open_unified {

class OpenBrowserService;

// Owns OpenBrowserService for the browser process lifetime. Added by hook
// 0009 at the end of ChromeBrowserMainParts::Create().
//
// - PreProfileInit(): registers Open's KeyedService factories (ad
//   blocking) before any Profile is created.
// - PreBrowserStart(): creates the service, which loads State/browser.json
//   synchronously (blocking is still allowed; Chromium's startup Browser is
//   created right after this, and OpenBrowserView::Install needs the model).
// - PostBrowserStart(): Start() (Profiles, windows, sleep, automation).
// - PostMainMessageLoopRun(): saves and destroys the service while Profiles
//   are still alive.
class OpenBrowserMainExtraParts : public ChromeBrowserMainExtraParts {
 public:
  OpenBrowserMainExtraParts();
  ~OpenBrowserMainExtraParts() override;

  OpenBrowserMainExtraParts(const OpenBrowserMainExtraParts&) = delete;
  OpenBrowserMainExtraParts& operator=(const OpenBrowserMainExtraParts&) =
      delete;

  // ChromeBrowserMainExtraParts:
  void PreProfileInit() override;
  void PreBrowserStart() override;
  void PostBrowserStart() override;
  void PostMainMessageLoopRun() override;

 private:
  std::unique_ptr<OpenBrowserService> service_;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_BROWSER_MAIN_EXTRA_PARTS_H_
