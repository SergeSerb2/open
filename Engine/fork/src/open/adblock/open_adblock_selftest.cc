// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_selftest.h"

#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "base/strings/string_util.h"
#include "base/timer/elapsed_timer.h"
#include "open/adblock/open_adblock_service.h"
#include "url/gurl.h"

namespace open_engine {

namespace {

void Line(const std::string& text) {
  fprintf(stderr, "OpenAdBlockSelftest: %s\n", text.c_str());
}

bool Expect(bool ok, const std::string& what) {
  Line(std::string(ok ? "ok   " : "FAIL ") + what);
  return ok;
}

void OnLoaded(base::WeakPtr<OpenAdBlockService> service,
              base::OnceCallback<void(bool)> done) {
  if (!service) {
    Line("FAIL service gone");
    std::move(done).Run(false);
    return;
  }
  const AdBlockStatus status = service->GetStatus();
  Line("status enabled=" + std::to_string(status.enabled) +
       " engine_loaded=" + std::to_string(status.engine_loaded) +
       " engine_from_dat=" + std::to_string(status.engine_from_dat) +
       " generation=" + std::to_string(status.generation) +
       " list_count=" + std::to_string(status.list_count) +
       " dat_size_bytes=" + std::to_string(status.dat_size_bytes) +
       " last_build_ms=" + std::to_string(status.last_build_ms) +
       " last_error=\"" + status.last_error + "\"" +
       " excluded=" + base::JoinString(status.excluded_domains, ","));

  bool ok = Expect(status.engine_loaded && status.list_count > 0,
                   "engine loaded from the live generation");
  ok &= Expect(status.last_error.empty(), "no load or cache error");
  ok &= Expect(service
                   ->Check(GURL("https://www.google-analytics.com/analytics.js"),
                           GURL("https://example.com/"), "script")
                   .matched,
               "third-party analytics script blocked");
  ok &= Expect(!service
                    ->Check(GURL("https://example.com/main.css"),
                            GURL("https://example.com/"), "stylesheet")
                    .matched,
               "first-party stylesheet allowed");
  ok &= Expect(!service->Check(GURL("not a url"), GURL(), "script").matched,
               "invalid URL allowed");
  ok &= Expect(status.excluded_domains ==
                   std::vector<std::string>{"example.com", "news.example.org"},
               "excluded domains normalized; bare suffix, path, empty skipped");
  ok &= Expect(service->IsExcluded(GURL("https://www.example.com/a")) &&
                   !service->IsExcluded(GURL("https://example.org/")),
               "exclusion by registrable domain");
  ok &= Expect(!service->HiddenSelectors({"ad--300x250"}, {}, {}).empty(),
               "generic class selector found");

  // adblock-fork §13.4: mean cost of one page's cosmetic query.
  base::ElapsedTimer timer;
  size_t hide_bytes = 0;
  for (int i = 0; i < 100; ++i) {
    hide_bytes = service->CosmeticResources(GURL("https://www.nytimes.com/"))
                     .hide_css.size();
  }
  const int64_t mean_us = timer.Elapsed().InMicroseconds() / 100;
  Line("cosmetic mean_us=" + std::to_string(mean_us) +
       " hide_css_bytes=" + std::to_string(hide_bytes));
  ok &= Expect(hide_bytes > 0 && mean_us <= 100,
               "cosmetic query within 100 us per page");

  Line(ok ? "PASS" : "FAIL");
  std::move(done).Run(ok);
}

}  // namespace

void RunOpenAdBlockSelftest(OpenAdBlockService* service,
                            base::FilePath adblock_root,
                            base::OnceCallback<void(bool)> done) {
  Line("loading " + adblock_root.value());
  service->SetEnabled(true);
  service->SetExcludedDomains(
      {"Example.COM.", "*.news.example.org", "com", "bad/x", ""});
  service->LoadFromDirectory(
      std::move(adblock_root), /*prefer_dat=*/true,
      base::BindOnce(&OnLoaded, service->GetWeakPtr(), std::move(done)));
}

}  // namespace open_engine
