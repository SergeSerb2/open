// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_selftest.h"

#include <mach/mach.h>
#include <sys/resource.h>
#include <time.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "base/strings/string_split.h"
#include "base/task/thread_pool.h"
#include "base/task/task_traits.h"
#include "base/threading/platform_thread.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/timer/elapsed_timer.h"
#include "base/values.h"
#include "crypto/hash.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/open_adblock_profile_proof.h"
#include "open/adblock/open_adblock_url_loader_factory.h"
#include "open/adblock/rust/src/lib.rs.h"
#include "partition_alloc/partition_root.h"
#include "partition_alloc/partition_stats.h"
#include "partition_alloc/shim/allocator_shim_default_dispatch_to_partition_alloc.h"
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
    const std::vector<std::string>& lines,
    std::string_view resources_json = {}) {
  rust::Vec<rust::String> texts;
  texts.push_back(rust::String::lossy(base::JoinString(lines, "\n")));
  return open_adblock::open_adblock_build(
      rust::Slice<const rust::String>(texts.data(), texts.size()),
      rust::Str(resources_json.data(), resources_json.size()));
}

bool Deserialize(const std::vector<uint8_t>& dat) {
  auto engine = open_adblock::open_adblock_create_empty();
  return open_adblock::open_adblock_deserialize(
      *engine, rust::Slice<const uint8_t>(dat.data(), dat.size()), rust::Str());
}

uint64_t ResidentBytes() {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info),
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return info.resident_size;
}

// The crate's DAT header (magic, version 0) followed by |body|.
std::vector<uint8_t> Dat(std::vector<uint8_t> body, uint8_t version = 0) {
  std::vector<uint8_t> dat = {0xd1, 0xd9, 0x3a, 0xaf, version};
  dat.insert(dat.end(), body.begin(), body.end());
  return dat;
}

// Review R2-1: crafted DATs whose MessagePack claims more than the DAT holds.
// The first is the reviewer's probe: 14 bytes, a str32 header that claims
// 512 MiB; before the shim's walk, rmp-serde allocated it (RSS 2,816 KiB to
// 527,184 KiB) and then failed. Each must be refused with resident memory
// flat and no abort.
bool CheckCraftedDats() {
  const std::vector<std::pair<std::string, std::vector<uint8_t>>> cases = {
      {"str32 claims 512 MiB (review probe)",
       Dat({0xdc, 0x00, 0x14, 0x81, 0xdb, 0x20, 0x00, 0x00, 0x00})},
      {"str32 claims 4 GiB", Dat({0xdc, 0x00, 0x14, 0x81, 0xdb, 0xff, 0xff,
                                  0xff, 0xff})},
      {"bin32 claims 512 MiB", Dat({0xdc, 0x00, 0x14, 0xc6, 0x20, 0x00, 0x00,
                                    0x00})},
      {"ext32 claims 4 GiB", Dat({0xc9, 0xff, 0xff, 0xff, 0xff, 0x01})},
      {"array32 claims 4G values", Dat({0xdd, 0xff, 0xff, 0xff, 0xff, 0xc0})},
      {"map32 claims 4G pairs", Dat({0xdf, 0xff, 0xff, 0xff, 0xff, 0xc0})},
      {"64 nested arrays", [] {
         std::vector<uint8_t> body(64, 0x91);
         body.push_back(0xc0);
         return Dat(body);
       }()},
      {"reserved marker 0xc1", Dat({0xc1})},
      {"version 1", Dat({0x90}, 1)},
      {"magic only (4 bytes, review 98-3)", {0xd1, 0xd9, 0x3a, 0xaf}},
      {"magic and version only", Dat({})},
      {"no magic", std::vector<uint8_t>(100, 0x90)},
  };
  bool ok = true;
  const uint64_t before = ResidentBytes();
  for (const auto& [name, dat] : cases) {
    ok &= Expect(!Deserialize(dat), "crafted DAT refused: " + name);
  }
  const int64_t grew_kib =
      (static_cast<int64_t>(ResidentBytes()) - static_cast<int64_t>(before)) /
      1024;
  Line("crafted DATs: resident memory grew " + std::to_string(grew_kib) +
       " KiB");
  ok &= Expect(grew_kib < 16 * 1024,
               "crafted DATs allocate nothing (resident memory flat)");
  return ok;
}

// Review R3-6: the walk at its limits. 32 levels and 2^24 values are
// accepted; 33 levels, 2^24 + 1 values (review R3-1) and a byte after the
// root value (review R3-5) are refused.
bool CheckDatBoundaries() {
  auto verdict = [](const std::vector<uint8_t>& dat) {
    return std::string(open_adblock::open_adblock_dat_check(
        rust::Slice<const uint8_t>(dat.data(), dat.size())));
  };
  auto nested = [](size_t levels) {
    std::vector<uint8_t> body(levels, 0x91);  // fixarray of one
    body.push_back(0xc0);
    return Dat(std::move(body));
  };
  // One array32 of n fixints: 1 + n values.
  auto fixints = [](uint32_t n) {
    std::vector<uint8_t> body = {0xdd, static_cast<uint8_t>(n >> 24),
                                 static_cast<uint8_t>(n >> 16),
                                 static_cast<uint8_t>(n >> 8),
                                 static_cast<uint8_t>(n)};
    body.resize(body.size() + n, 0x00);
    return Dat(std::move(body));
  };
  constexpr uint32_t kMaxValues = 1u << 24;
  const std::vector<uint8_t> at_limit = fixints(kMaxValues - 1);
  const std::vector<uint8_t> over_limit = fixints(kMaxValues);
  bool ok = true;
  ok &= Expect(verdict(nested(32)).empty() && verdict(nested(33)) == "depth",
               "DAT walk: 32 levels accepted, 33 refused");
  ok &= Expect(verdict(at_limit).empty() && verdict(over_limit) == "values",
               "DAT walk: 2^24 values accepted, 2^24 + 1 refused");
  ok &= Expect(!Deserialize(over_limit), "a DAT of 2^24 + 1 values is refused");
  ok &= Expect(verdict(Dat({0x90})).empty() &&
                   verdict(Dat({0x90, 0x00})) == "trailing",
               "DAT walk: a byte after the root value is refused");
  return ok;
}

// Review R3-2: a build over the per-build limits is refused before the crate
// parses anything, with resident memory flat; a build at the limits runs.
bool CheckBuildLimits() {
  auto texts_of = [](std::string text) {
    rust::Vec<rust::String> texts;
    texts.push_back(rust::String::lossy(text));
    return texts;
  };
  // Builds |texts| and returns the refusal ("" when it built), and the
  // resident memory growth during the build in KiB.
  auto build = [](const rust::Vec<rust::String>& texts) {
    const uint64_t before = ResidentBytes();
    auto engine = open_adblock::open_adblock_build(
        rust::Slice<const rust::String>(texts.data(), texts.size()),
        rust::Str());
    const int64_t grew_kib = (static_cast<int64_t>(ResidentBytes()) -
                              static_cast<int64_t>(before)) /
                             1024;
    return std::make_pair(
        std::string(open_adblock::open_adblock_build_report(*engine).refused),
        grew_kib);
  };
  bool ok = true;

  // The reviewer's 16 MiB list of 5,592,405 two-character rules (it aborted
  // the dev build at 2.68 GB).
  std::string many;
  many.reserve(5592405 * 3);
  for (int i = 0; i < 5592405; ++i) {
    many += "ab\n";
  }
  const auto [many_refused, many_grew] = build(texts_of(std::move(many)));
  Line("16 MiB two-character list: refused=\"" + many_refused +
       "\" resident_grew_kib=" + std::to_string(many_grew));
  ok &= Expect(!many_refused.empty() && many_grew < 16 * 1024,
               "a 5.59 million line list is refused, memory flat");

  // At the line limit: 2^21 comment lines build; one more is refused.
  std::string comments;
  for (int i = 0; i < (1 << 21); ++i) {
    comments += "!\n";
  }
  const std::string at_lines = build(texts_of(comments)).first;
  comments += "!\n";
  const std::string over_lines = build(texts_of(std::move(comments))).first;
  ok &= Expect(at_lines.empty() && !over_lines.empty(),
               "2^21 list lines build, 2^21 + 1 are refused");

  // The reviewer's cosmetic line: 10,000 hostnames, a 50,001-byte selector
  // (it cost 478 MiB of copies).
  std::string hosts;
  for (int i = 0; i < 10000; ++i) {
    hosts += (i ? ",h" : "h") + std::to_string(i) + ".com";
  }
  const auto [wide_refused, wide_grew] =
      build(texts_of(hosts + "##." + std::string(50000, 'a')));
  Line("10,000-hostname cosmetic line: refused=\"" + wide_refused +
       "\" resident_grew_kib=" + std::to_string(wide_grew));
  ok &= Expect(!wide_refused.empty() && wide_grew < 16 * 1024,
               "a 10,000-hostname cosmetic line is refused, memory flat");

  // At the copy limit: 1,024 hostnames × a 65,536-byte selector = 64 MiB
  // builds; 1,025 hostnames are refused.
  auto copies_line = [](int hostnames) {
    std::string line;
    for (int i = 0; i < hostnames; ++i) {
      line += (i ? ",c" : "c") + std::to_string(i) + ".com";
    }
    return line + "##." + std::string(65535, 'a');
  };
  const std::string at_copies = build(texts_of(copies_line(1024))).first;
  const std::string over_copies = build(texts_of(copies_line(1025))).first;
  ok &= Expect(at_copies.empty() && !over_copies.empty(),
               "64 MiB of selector copies build, one hostname more is "
               "refused");
  return ok;
}

struct Rng {
  uint64_t state;
  uint64_t Next() {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
  }
  size_t Below(size_t n) { return n ? static_cast<size_t>(Next() % n) : 0; }
};

std::vector<std::string> CodePoints(std::string_view text) {
  std::vector<std::string> out;
  for (size_t i = 0; i < text.size();) {
    const auto lead = static_cast<unsigned char>(text[i]);
    const size_t n = std::min<size_t>(
        lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4,
        text.size() - i);
    out.emplace_back(text.substr(i, n));
    i += n;
  }
  return out;
}

// The round 1 reviewer's fuzz (same xorshift seed and alphabet), cut to fit
// the self-test's 10 s: mutated list lines (build, cosmetic, hidden
// selectors, check, serialize, deserialize), mutated URLs with every request
// type, and mutated DATs. The opt-in full-size mode below has no watchdog.
bool Fuzz() {
  const char* const seeds[] = {
      "||ads.example.com^$third-party",
      "example.com##.ad",
      "##.banner-ad",
      "@@||example.com/ads.js$script,domain=example.org",
      "/banner/*/img^$image,1p",
      "/^https?:\\/\\/[a-z]{8,}\\.com\\/[0-9]{4}\\//$script",
      "example.com#@#.sponsored",
      "example.com##+js(set-constant, x, 1)",
      "example.com##.x:style(color: red)",
      "example.com##.y:remove()",
      "example.com##.promo:has-text(Sponsored)",
      "||tracker.example^$removeparam=utm_source",
      "||cdn.example/ad.js$redirect=noopjs",
      "||example.com^$csp=script-src 'none'",
      "*$ping,domain=example.com|~sub.example.com",
      "example.com,~news.example.com##div[id^=\"ad_\"]",
  };
  const std::vector<std::string> alphabet = {
      "$", "#", "@", "|", "^", "*", "/", "\\", ",", "=", "~", "!", ":", "(",
      ")", "[", "]", "{", "}", "+", ".", "-", "_", " ", std::string(1, '\0'),
      "\xc2\xa0", "\xc3\xa9", "\xf0\x9d\x94\x98", "\xe2\x80\x8b",
      "\xc4\xb1", "\xef\xbf\xbd", "\xc4\xb0", "\xc3\x9f", "%", "?", "&",
      ";", "'", "\"", "<", ">"};
  Rng rng{0x9e3779b97f4a7c15};
  auto mutate = [&](std::string_view base, size_t max_ops) {
    std::vector<std::string> chars = CodePoints(base);
    const size_t ops = 1 + rng.Below(max_ops);
    for (size_t op = 0; op < ops; ++op) {
      const size_t kind = rng.Below(4);
      const size_t pos = rng.Below(chars.size() + 1);
      const std::string& c = alphabet[rng.Below(alphabet.size())];
      if (kind == 0) {
        chars.insert(chars.begin() + pos, c);
      } else if (kind == 1 && pos < chars.size()) {
        chars.erase(chars.begin() + pos);
      } else if (kind == 2) {
        chars.resize(pos);
      } else if (pos < chars.size()) {
        chars[pos] = c;
      }
    }
    return base::JoinString(chars, "");
  };

  base::ElapsedTimer timer;
  rust::Vec<rust::String> classes;
  classes.push_back(rust::String("ad"));
  rust::Vec<rust::String> ids;
  ids.push_back(rust::String("banner"));
  const int kLines = 3000;
  for (int i = 0; i < kLines; ++i) {
    const std::string line = mutate(seeds[rng.Below(std::size(seeds))], 4);
    auto engine = BuildLines({line});
    open_adblock::open_adblock_cosmetic(*engine, "https://www.example.com/");
    open_adblock::open_adblock_hidden_selectors(
        *engine, rust::Slice<const rust::String>(classes.data(), classes.size()),
        rust::Slice<const rust::String>(ids.data(), ids.size()),
        rust::Slice<const rust::String>());
    open_adblock::open_adblock_check(
        *engine, "https://ads.example.com/x/ad.js?utm_source=1",
        "https://example.com/", OpenRequestType::Script,
        kOpenAdBlockMatchCapBytes);
    rust::Vec<uint8_t> dat = open_adblock::open_adblock_serialize(*engine);
    auto copy = open_adblock::open_adblock_create_empty();
    open_adblock::open_adblock_deserialize(
        *copy, rust::Slice<const uint8_t>(dat.data(), dat.size()), rust::Str());
  }

  std::vector<std::string> lines;
  for (const char* seed : seeds) {
    lines.push_back(seed);
  }
  auto engine = BuildLines(lines);
  const char* const url_seeds[] = {
      "https://www.google-analytics.com/analytics.js", "https://a.b/",
      "http://[::1]:80/x", "https://xn--e1afmkfd.xn--p1ai/", "ws://example.com/",
      "https://example.com:99999/", "https://1.2.3.4/a?b#c", "data:text/html,x",
      "https://ex%41mple.com/"};
  const int kUrls = 20000;
  for (int i = 0; i < kUrls; ++i) {
    std::vector<std::string> chars =
        CodePoints(url_seeds[rng.Below(std::size(url_seeds))]);
    for (size_t n = rng.Below(4); n > 0; --n) {
      chars.insert(chars.begin() + rng.Below(chars.size() + 1),
                   alphabet[rng.Below(alphabet.size())]);
    }
    const std::string url = base::JoinString(chars, "");
    const auto type = static_cast<OpenRequestType>(rng.Below(14));
    open_adblock::open_adblock_check(
        *engine, rust::String::lossy(url),
        url_seeds[rng.Below(std::size(url_seeds))], type,
        static_cast<uint32_t>(rng.Below(64)));
    open_adblock::open_adblock_cosmetic(*engine, rust::String::lossy(url));
  }

  rust::Vec<uint8_t> dat = open_adblock::open_adblock_serialize(*engine);
  const std::vector<uint8_t> valid(dat.begin(), dat.end());
  int accepted = 0;
  const int kDats = 3000;
  for (int i = 0; i < kDats && valid.size() > 6; ++i) {
    std::vector<uint8_t> d = valid;
    const size_t span = d.size() - 5;
    switch (rng.Below(3)) {
      case 0:
        d.resize(5 + rng.Below(span));
        break;
      case 1:
        for (int flip = 0; flip < 8; ++flip) {
          d[5 + rng.Below(span)] ^= static_cast<uint8_t>(1u << rng.Below(8));
        }
        break;
      default:
        d[5 + rng.Below(span)] = 0xdb;
        break;
    }
    accepted += Deserialize(d);
  }
  Line("fuzz lines=" + std::to_string(kLines) + " urls=" +
       std::to_string(kUrls) + " dats=" + std::to_string(kDats) +
       " (accepted " + std::to_string(accepted) + ") ms=" +
       std::to_string(timer.Elapsed().InMilliseconds()));
  return Expect(true, "fuzz: no abort");
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
  // Host rules: generic "##.class" rules go through HiddenSelectors(). One
  // scriptlet resource, so the crate resolves the ##+js() rule.
  const std::string resources =
      R"([{"name":"open-test.js","aliases":[],"kind":"template","content":")" +
      base::Base64Encode("window.__openTestScriptlet = 1;") + R"("}])";
  auto injected = BuildLines(
      {
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
          "example.com##.gone:remove()",
          "example.com##.attr-target:remove-attr(onclick)",
          "example.com##.class-target:remove-class(ad)",
          "example.com##+js(open-test.js)",
      },
      resources);
  open_adblock::OpenCosmeticResources cosmetic =
      open_adblock::open_adblock_cosmetic(*injected, "https://example.com/");
  bool clean = true;
  int plain = 0;
  for (const rust::String& selector : cosmetic.hide_selectors) {
    clean &= IsCleanSelector(std::string(selector));
    plain += std::string(selector) == ".plain-ad" ||
             std::string(selector) == "div[style^=\"z-index: 9;\"]";
  }
  Line("injection hide=" + std::to_string(cosmetic.hide_selectors.size()) +
       " dropped_procedural=" + std::to_string(cosmetic.dropped_procedural) +
       " dropped_unsafe=" + std::to_string(cosmetic.dropped_unsafe) +
       " dropped_style=" + std::to_string(cosmetic.dropped_style) +
       " dropped_remove=" + std::to_string(cosmetic.dropped_remove) +
       " dropped_scriptlet=" + std::to_string(cosmetic.dropped_scriptlet) +
       " dropped_over_cap=" + std::to_string(cosmetic.dropped_over_cap));
  ok &= Expect(clean && plain == 2 && cosmetic.hide_selectors.size() == 2,
               "no injected CSS crosses the bridge; plain and quoted-';' "
               "selectors kept");
  ok &= Expect(cosmetic.dropped_procedural == 1 && cosmetic.dropped_unsafe == 1,
               "procedural and unsafe selectors counted");
  // Lead ruling 6 (review R2-2): v1 applies hide selectors only.
  ok &= Expect(cosmetic.dropped_style == 3 && cosmetic.dropped_remove == 3 &&
                   cosmetic.dropped_scriptlet == 1,
               ":style(), :remove*() and scriptlet output discarded and "
               "counted");

  ok &= CheckCraftedDats();
  ok &= CheckDatBoundaries();
  ok &= CheckBuildLimits();

  // Review R3-3: every style rule counts, also next to :remove() rules on
  // the same or other selectors (the reviewer's 4-rule probe).
  auto styles = BuildLines({"example.com##.y:remove()",
                            "example.com##.z:style(color: red)",
                            "example.com##.z:remove()",
                            "example.com##.s:style(color: blue)"});
  const open_adblock::OpenCosmeticResources style_counts =
      open_adblock::open_adblock_cosmetic(*styles, "https://example.com/");
  ok &= Expect(style_counts.dropped_style == 2 &&
                   style_counts.dropped_remove == 2,
               "two :style() and two :remove() rules counted (R3-3)");

  // Review R3-4: generic selectors for a page's tokens are sanitized and the
  // drops counted.
  auto generic = BuildLines({"##.adx:has-text(Sponsored)", "##.ady"});
  rust::Vec<rust::String> tokens;
  tokens.push_back(rust::String("adx"));
  tokens.push_back(rust::String("ady"));
  const open_adblock::OpenHiddenSelectors hidden =
      open_adblock::open_adblock_hidden_selectors(
          *generic, rust::Slice<const rust::String>(tokens.data(), tokens.size()),
          rust::Slice<const rust::String>(), rust::Slice<const rust::String>());
  std::string kept;
  for (const rust::String& selector : hidden.selectors) {
    kept += std::string(selector) + " ";
  }
  Line("hidden selectors kept=" + kept + "dropped_procedural=" +
       std::to_string(hidden.dropped_procedural));
  ok &= Expect(hidden.selectors.size() == 1 && hidden.dropped_procedural == 1,
               "hidden selectors: the procedural one dropped and counted "
               "(R3-4)");

  auto lossy = BuildLines({"||example.com^$removeparam=test", "||ads.test^"});
  open_adblock::OpenBuildReport report =
      open_adblock::open_adblock_build_report(*lossy);
  ok &= Expect(!report.lossless && report.lossy_kinds.size() == 1 &&
                   std::string(report.lossy_kinds[0]) == "removeparam",
               "a $removeparam list is reported lossy (no DAT)");
  open_adblock::OpenBlockerResult rewritten = open_adblock::open_adblock_check(
      *lossy, "https://example.com/?q=1&test=2#blue", "https://example.com/",
      OpenRequestType::Document, kOpenAdBlockMatchCapBytes);
  ok &= Expect(
      std::string(rewritten.rewritten_url) == "https://example.com/?q=1#blue",
      "$removeparam rewrites; the fragment is not matched but kept (R2-3)");

  // §7.7 (review R2-4): the cap is the caller's max_input_bytes. Past it only
  // a prefix is matched and nothing is rewritten.
  const std::string url_9k =
      "https://example.com/?test=2&pad=" + std::string(9000, 'a');
  const std::string url_20k =
      "https://example.com/?test=2&pad=" + std::string(20000, 'a');
  auto check = [&](const std::string& url, uint32_t cap) {
    return open_adblock::open_adblock_check(*lossy, url, "https://example.com/",
                                            OpenRequestType::Document, cap);
  };
  const open_adblock::OpenBlockerResult whole = check(url_9k, 16 * 1024);
  const open_adblock::OpenBlockerResult cut_8k = check(url_9k, 8 * 1024);
  const open_adblock::OpenBlockerResult cut_16k = check(url_20k, 16 * 1024);
  ok &= Expect(!whole.truncated && !std::string(whole.rewritten_url).empty(),
               "a 9 KB URL is matched whole under the 16 KiB cap");
  ok &= Expect(cut_8k.truncated && std::string(cut_8k.rewritten_url).empty() &&
                   cut_16k.truncated &&
                   std::string(cut_16k.rewritten_url).empty(),
               "over the cap (8 KiB, 16 KiB) a URL is cut and never rewritten");
  std::string wide = "https://example.com/?q=";
  for (int i = 0; i < 5000; ++i) {
    wide += "\xc3\xa9";
  }
  ok &= Expect(check(wide, 8 * 1024).truncated,
               "a cut inside multi-byte text lands on a char boundary");
  Line("engine format " + std::string(open_adblock::open_adblock_engine_format()));
  ok &= Fuzz();
  return ok;
}

// Review R2-5: what each extra load's |done| received.
// Opt-in browser-process parser corpus. This uses the production CXX shim,
// not a separate parser or a mock. The ordinary smoke corpus stays bounded.
constexpr uint64_t kFullFuzzSeed = 0x9e3779b97f4a7c15;

std::string FullFuzzLoad() {
  double loads[3] = {};
  if (getloadavg(loads, 3) != 3) {
    return "unavailable";
  }
  return std::to_string(loads[0]) + "/" + std::to_string(loads[1]) + "/" +
         std::to_string(loads[2]);
}

struct FullFuzzCounts {
  uint64_t accepted = 0;
  uint64_t rejected = 0;
  void Record(bool accept) {
    if (accept) {
      ++accepted;
    } else {
      ++rejected;
    }
  }
  void Print(std::string_view kind) const {
    Line("fuzz-full kind=" + std::string(kind) +
         " accepted=" + std::to_string(accepted) +
         " rejected=" + std::to_string(rejected) +
         " total=" + std::to_string(accepted + rejected) +
         " load=" + FullFuzzLoad());
  }
};

class FullFuzzInput {
 public:
  explicit FullFuzzInput(base::FilePath directory)
      : directory_(std::move(directory)) {}

  bool Save(std::string_view kind,
            uint64_t index,
            uint64_t state,
            std::string_view input,
            std::string_view context = {}) const {
    // Close both files before entering a parser. A process panic leaves the
    // exact active bytes and replay coordinates, not the following input.
    const std::string metadata =
        "seed=0x9e3779b97f4a7c15\nkind=" + std::string(kind) +
        "\nindex=" + std::to_string(index) +
        "\nrng_state=" + std::to_string(state) +
        "\nbytes=" + std::to_string(input.size()) +
        "\nsha256=" + base::HexEncodeLower(crypto::hash::Sha256(input)) +
        "\n" + std::string(context) + "\n";
    if (!base::WriteFile(directory_.AppendASCII("current.input"), input) ||
        !base::WriteFile(directory_.AppendASCII("current.meta"), metadata)) {
      Line("FAIL fuzz-full cannot preserve active input");
      return false;
    }
    return true;
  }

 private:
  const base::FilePath directory_;
};

std::string FullFuzzMutate(std::string_view input, Rng& rng) {
  static const std::vector<std::string> alphabet = {
      "$", "#", "@", "|", "^", "*", "/", "\\", ",", "=", "~", "!", ":", "(",
      ")", "[", "]", "{", "}", "+", ".", "-", "_", " ", std::string(1, '\0'),
      "\xc2\xa0", "\xc3\xa9", "\xf0\x9d\x94\x98", "\xe2\x80\x8b",
      "\xc4\xb1", "\xef\xbf\xbd", "\xc4\xb0", "\xc3\x9f", "%", "?", "&",
      ";", "'", "\"", "<", ">"};
  // With an 8-MiB seed cap and eight insertions, capacity is at most
  // 16 Mi elements: at most 512 MiB, below PartitionAlloc's 2-GiB ceiling.
  // Actual pinned lines/resources are much smaller. No unbounded expansion.
  static_assert(sizeof(std::string) <= 32);
  std::vector<std::string> chars = CodePoints(input);
  const size_t operations = 1 + rng.Below(8);
  for (size_t operation = 0; operation < operations; ++operation) {
    const size_t kind = rng.Below(4);
    const size_t at = rng.Below(chars.size() + 1);
    const auto& inserted = alphabet[rng.Below(alphabet.size())];
    if (kind == 0) {
      chars.insert(chars.begin() + at, inserted);
    } else if (kind == 1 && at < chars.size()) {
      chars.erase(chars.begin() + at);
    } else if (kind == 2) {
      chars.resize(at);
    } else if (at < chars.size()) {
      chars[at] = inserted;
    }
  }
  return base::JoinString(chars, "");
}

bool RunFullFuzz(base::FilePath input_root, base::FilePath output) {
  if (output.empty() || !base::CreateDirectory(output)) {
    Line("FAIL fuzz-full needs --open-adblock-fuzz-output=<private directory>");
    return false;
  }
  base::ElapsedTimer duration;
  Rng rng{kFullFuzzSeed};
  FullFuzzInput active(output);
  Line("fuzz-full seed=0x9e3779b97f4a7c15 watchdog=none load=" + FullFuzzLoad() +
       " active_input=" + output.AppendASCII("current.input").value());
  Line("fuzz-full counts: list=shim admission (per-rule parse failures are "
       "not exposed); URL=crate Request parse; DAT=deserialize; "
       "resources=nonempty typed JSON parse; CSS=sanitized output");

  std::string easylist, easyprivacy, resources, urls;
  const auto read = [&](const char* name, std::string& text) {
    // These are trusted pinned seeds, still bounded before allocation.
    // Largest seed string allocation: 8 MiB. Mutations add at most 32 bytes.
    const bool ok = base::ReadFileToStringWithMaxSize(
        input_root.AppendASCII(name), &text, 8 * 1024 * 1024);
    if (ok) {
      Line("fuzz-full input=" + std::string(name) +
           " bytes=" + std::to_string(text.size()) +
           " sha256=" + base::HexEncodeLower(crypto::hash::Sha256(text)));
    }
    return ok;
  };
  if (!read("easylist.txt", easylist) ||
      !read("easyprivacy.txt", easyprivacy) ||
      !read("resources.json", resources) || !read("corpus.txt", urls)) {
    Line("FAIL fuzz-full cannot read pinned seeds");
    return false;
  }
  auto line_seeds = base::SplitStringPiece(
      easylist, "\n", base::KEEP_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  const auto privacy_seeds = base::SplitStringPiece(
      easyprivacy, "\n", base::KEEP_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  line_seeds.insert(line_seeds.end(), privacy_seeds.begin(), privacy_seeds.end());
  auto url_seeds = base::SplitStringPiece(
      urls, "\n", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  for (std::string_view seed : {"http://[::1]:80/x", "https://a.b/",
                                "https://example.com:99999/", "data:text/html,x",
                                "https://xn--e1afmkfd.xn--p1ai/", "ws://a.b/"}) {
    url_seeds.push_back(seed);
  }
  if (line_seeds.empty() || url_seeds.empty()) {
    Line("FAIL fuzz-full empty seed corpus");
    return false;
  }

  uint64_t builds = 0;
  double slowest_build_ms = 0;
  std::string slowest_kind;
  uint64_t slowest_index = 0;
  const auto build = [&](const std::vector<std::string>& lists,
                         std::string_view json,
                         std::string_view kind, uint64_t index) {
    rust::Vec<rust::String> texts;
    for (const auto& text : lists) {
      texts.push_back(rust::String::lossy(text));
    }
    base::ElapsedTimer timer;
    auto engine = open_adblock::open_adblock_build(
        rust::Slice<const rust::String>(texts.data(), texts.size()),
        rust::Str(json.data(), json.size()));
    const double ms = timer.Elapsed().InMillisecondsF();
    ++builds;
    if (ms > slowest_build_ms) {
      slowest_build_ms = ms;
      slowest_kind = kind;
      slowest_index = index;
    }
    return engine;
  };
  const auto progress = [](std::string_view kind, uint64_t count) {
    Line("fuzz-full progress=" + std::string(kind) +
         " count=" + std::to_string(count) + " load=" + FullFuzzLoad());
  };

  FullFuzzCounts lines;
  for (uint64_t i = 0; i < 150000; ++i) {
    const std::string text = FullFuzzMutate(line_seeds[rng.Below(line_seeds.size())], rng);
    if (!active.Save("list", i, rng.state, text)) {
      return false;
    }
    auto engine = build({text}, {}, "list", i);
    lines.Record(open_adblock::open_adblock_build_report(*engine).refused.empty());
    if ((i + 1) % 5000 == 0) progress("list", i + 1);
  }
  lines.Print("list");

  // Keep the real two-list engine for URL checks and serialize that engine,
  // rather than mutating the tiny synthetic DAT used by the smoke corpus.
  const std::string joined = easylist + easyprivacy;
  if (!active.Save("real-list-build", 0, rng.state, joined,
                   "easylist_bytes=" + std::to_string(easylist.size()) +
                       "\nresources=resources.json (pinned seed above)")) {
    return false;
  }
  auto real = build({easylist, easyprivacy}, resources, "real-list-build", 0);
  const auto report = open_adblock::open_adblock_build_report(*real);
  if (!report.refused.empty() || report.list_count != 2 ||
      !report.resources_error.empty() || report.resources_loaded == 0) {
    Line("FAIL fuzz-full pinned engine build");
    return false;
  }
  rust::Vec<uint8_t> serialized = open_adblock::open_adblock_serialize(*real);
  const std::vector<uint8_t> valid(serialized.begin(), serialized.end());
  if (valid.size() <= 5 || valid.size() > 64 * 1024 * 1024) {
    Line("FAIL fuzz-full real DAT outside 6-byte to 64-MiB seed bound");
    return false;
  }
  if (!base::WriteFile(output.AppendASCII("real.dat"),
                       std::string_view(reinterpret_cast<const char*>(valid.data()), valid.size()))) {
    Line("FAIL fuzz-full cannot retain real DAT");
    return false;
  }
  Line("fuzz-full real_dat_bytes=" + std::to_string(valid.size()) +
       " lossless=" + std::to_string(report.lossless));
  if (!active.Save("DAT-control", 0, rng.state,
                   std::string_view(reinterpret_cast<const char*>(valid.data()), valid.size())) ||
      !Deserialize(valid)) {
    Line("FAIL fuzz-full real DAT control");
    return false;
  }

  FullFuzzCounts requests;
  uint64_t matched = 0;
  for (uint64_t i = 0; i < 100000; ++i) {
    const std::string url = FullFuzzMutate(url_seeds[rng.Below(url_seeds.size())], rng);
    const auto type = static_cast<OpenRequestType>(rng.Below(14));
    if (!active.Save("URL", i, rng.state, url,
                     "source=https://example.com/\ntype=" +
                         std::to_string(static_cast<int>(type)) +
                         "\ncap=" + std::to_string(kOpenAdBlockMatchCapBytes))) {
      return false;
    }
    const auto result = open_adblock::open_adblock_check(
        *real, rust::String::lossy(url), "https://example.com/", type,
        kOpenAdBlockMatchCapBytes);
    requests.Record(result.request_valid);
    matched += result.matched;
    if ((i + 1) % 10000 == 0) progress("URL", i + 1);
  }
  requests.Print("URL");
  Line("fuzz-full URL matched=" + std::to_string(matched));

  FullFuzzCounts four_byte;
  const std::vector<uint8_t> magic = {0xd1, 0xd9, 0x3a, 0xaf};
  if (!active.Save("DAT-4-byte", 0, rng.state,
                   std::string_view(reinterpret_cast<const char*>(magic.data()), magic.size()))) {
    return false;
  }
  four_byte.Record(Deserialize(magic));
  four_byte.Print("DAT-4-byte");
  if (four_byte.accepted) {
    Line("FAIL fuzz-full four-byte DAT accepted");
    return false;
  }
  FullFuzzCounts dats;
  for (uint64_t i = 0; i < 3000; ++i) {
    std::vector<uint8_t> dat = valid;
    switch (rng.Below(5)) {
      case 0:
        dat.resize(rng.Below(dat.size()));
        break;
      case 1:
        for (size_t n = 1 + rng.Below(8); n; --n) {
          dat[rng.Below(dat.size())] ^= static_cast<uint8_t>(1u << rng.Below(8));
        }
        break;
      case 2:
        dat[5 + rng.Below(dat.size() - 5)] = 0xdb;
        break;
      case 3: {
        const size_t at = rng.Below(dat.size());
        const size_t count = 1 + rng.Below(16);
        const uint8_t value = static_cast<uint8_t>(rng.Next());
        dat.insert(dat.begin() + at, count, value);
        break;
      }
      default:
        dat.push_back(static_cast<uint8_t>(rng.Next()));
        break;
    }
    if (!active.Save("DAT-mutation", i, rng.state,
                     std::string_view(reinterpret_cast<const char*>(dat.data()), dat.size()))) {
      return false;
    }
    dats.Record(Deserialize(dat));
    if ((i + 1) % 100 == 0) progress("DAT-mutation", i + 1);
  }
  dats.Print("DAT-mutation");

  FullFuzzCounts resource_inputs;
  for (uint64_t i = 0; i < 3000; ++i) {
    std::string json = FullFuzzMutate(resources, rng);
    if (json.empty()) json = "[";  // Exercise serde_json, not the no-file path.
    if (!active.Save("resources", i, rng.state, json)) {
      return false;
    }
    auto engine = build({}, json, "resources", i);
    const auto parsed = open_adblock::open_adblock_build_report(*engine);
    resource_inputs.Record(parsed.resources_error.empty() && parsed.resources_loaded > 0);
    if ((i + 1) % 100 == 0) progress("resources", i + 1);
  }
  resource_inputs.Print("resources");

  // Exact review 98-2 injection lines, with two positive selector controls.
  const std::vector<std::string> css = {
      "example.com##x{} input[type=password][value^=\"a\"]{background:url(https://evil.test/a)} y",
      "example.com##.banner:style(background: url(https://evil.test/p.gif) !important)",
      "example.com##.box:style(color: red } body { background: url(https://evil.test/q) )",
      "example.com##.plain-ad", "example.com##div[style^=\"z-index: 9;\"]"};
  if (!active.Save("CSS-review", 0, rng.state, base::JoinString(css, "\n"))) {
    return false;
  }
  auto injected = build(css, {}, "CSS-review", 0);
  const auto cosmetic = open_adblock::open_adblock_cosmetic(*injected, "https://example.com/");
  FullFuzzCounts css_output;
  css_output.accepted = cosmetic.hide_selectors.size();
  css_output.rejected = cosmetic.dropped_unsafe + cosmetic.dropped_style;
  css_output.Print("CSS-review");
  bool clean = true;
  for (const auto& selector : cosmetic.hide_selectors) {
    clean &= IsCleanSelector(std::string(selector));
  }
  if (!clean || css_output.accepted != 2 || cosmetic.dropped_unsafe != 1 ||
      cosmetic.dropped_style != 2) {
    Line("FAIL fuzz-full CSS injection crossed the bridge");
    return false;
  }

  task_vm_info_data_t memory{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&memory),
                &count) != KERN_SUCCESS || count < TASK_VM_INFO_REV3_COUNT ||
      memory.ledger_phys_footprint_peak <= 0) {
    Line("FAIL fuzz-full peak phys_footprint unavailable");
    return false;
  }
  Line("fuzz-full summary PASS seed=0x9e3779b97f4a7c15 lines=150000 urls=100000 "
       "dat_mutations=3000 resources=3000 dat_4_byte_rejected=1 css_rejected=3 "
       "css_controls=2 builds=" + std::to_string(builds) +
       " slowest_build_ms=" + std::to_string(slowest_build_ms) +
       " slowest_kind=" + slowest_kind +
       " slowest_index=" + std::to_string(slowest_index) +
       " duration_ms=" + std::to_string(duration.Elapsed().InMilliseconds()) +
       " phys_footprint=" + std::to_string(memory.phys_footprint) +
       " peak_phys_footprint=" + std::to_string(memory.ledger_phys_footprint_peak) +
       " load=" + FullFuzzLoad());
  return true;
}

struct LoadResults {
  std::optional<AdBlockLoadResult> destroyed;
  std::optional<AdBlockLoadResult> after_shutdown;
  std::optional<AdBlockLoadResult> stale;
};

enum class Slot { kAfterShutdown, kStale };

void Record(std::shared_ptr<LoadResults> results,
            Slot slot,
            AdBlockLoadResult result) {
  (slot == Slot::kStale ? results->stale : results->after_shutdown) = result;
}

// Matcher sequence: every engine call of the self-test runs here (G-1).
bool MatcherChecks(scoped_refptr<OpenAdBlockMatcher> matcher) {
  Line("matcher thread=" + std::string(base::PlatformThread::GetName()));
  const uint32_t cap = kOpenAdBlockMatchCapBytes;
  bool ok = Expect(
      matcher
          ->Check(GURL("https://www.google-analytics.com/analytics.js"),
                  GURL("https://example.com/"), OpenRequestType::Script, cap)
          .matched,
      "third-party analytics script blocked");
  ok &= Expect(!matcher
                    ->Check(GURL("https://example.com/main.css"),
                            GURL("https://example.com/"),
                            OpenRequestType::Stylesheet, cap)
                    .matched,
               "first-party stylesheet allowed");
  ok &= Expect(!matcher->Check(GURL("not a url"), GURL(),
                               OpenRequestType::Script, cap)
                    .matched,
               "invalid URL allowed");
  // The matcher's copy of the exclusions follows the same rule as the UI
  // mirror (review 100-4).
  ok &= Expect(!matcher->IsActiveFor("www.example.com") &&
                   !matcher->IsActiveFor("a.news.example.org") &&
                   matcher->IsActiveFor("example.org") &&
                   matcher->IsActiveFor("notexample.com"),
               "matcher: excluded top sites are inactive, others active");
  ok &= Expect(!matcher->HiddenSelectors({"ad--300x250"}, {}, {}).empty(),
               "generic class selector found");

  // adblock-fork §13.4: mean cost of one page's cosmetic query. A real-time
  // budget on a shared machine: up to 3 attempts, each printed with the
  // load average (docs/review-checklist.md §4).
  constexpr int64_t kCosmeticBudgetUs = 100;
  size_t hide_count = 0;
  int64_t mean_us = 0;
  for (int attempt = 1; attempt <= 3; ++attempt) {
    base::ElapsedTimer timer;
    for (int i = 0; i < 100; ++i) {
      hide_count = matcher->Cosmetic(GURL("https://www.nytimes.com/"))
                       .hide_selectors.size();
    }
    mean_us = timer.Elapsed().InMicroseconds() / 100;
    double load[1] = {0};
    getloadavg(load, 1);
    Line("cosmetic attempt=" + std::to_string(attempt) +
         " mean_us=" + std::to_string(mean_us) + " budget_us=" +
         std::to_string(kCosmeticBudgetUs) + " over_us=" +
         std::to_string(std::max<int64_t>(0, mean_us - kCosmeticBudgetUs)) +
         " load=" + base::NumberToString(load[0]) +
         " hide_selectors=" + std::to_string(hide_count));
    if (mean_us <= kCosmeticBudgetUs) {
      break;
    }
  }
  ok &= Expect(hide_count > 0 && mean_us <= kCosmeticBudgetUs,
               "cosmetic query within 100 us per page");

  // A page whose lists have procedural rules still gets its plain hiding,
  // and no procedural or unsafe selector (review 98-1).
  open_adblock::OpenCosmeticResources gamedev =
      matcher->Cosmetic(GURL("https://www.gamedev.net/"));
  bool clean = true;
  for (const rust::String& selector : gamedev.hide_selectors) {
    clean &= IsCleanSelector(std::string(selector));
  }
  Line("gamedev.net hide_selectors=" +
       std::to_string(gamedev.hide_selectors.size()) +
       " dropped_procedural=" + std::to_string(gamedev.dropped_procedural) +
       " dropped_unsafe=" + std::to_string(gamedev.dropped_unsafe));
  ok &= Expect(clean && gamedev.hide_selectors.size() > 100 &&
                   gamedev.dropped_procedural > 0,
               "gamedev.net: plain selectors kept, procedural ones dropped");
  ok &= Expect(std::is_sorted(gamedev.hide_selectors.begin(),
                              gamedev.hide_selectors.end()),
               "hide selectors sorted");

  // Network check cost on the six realistic URL shapes of review C-2 (58 to
  // 2,040 characters). Information only; G-2 uses the corpus bench.
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
    matcher->Check(url, source, type, cap);
    base::ElapsedTimer shape_timer;
    for (int i = 0; i < 500; ++i) {
      matcher->Check(url, source, type, cap);
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
  return ok;
}

// --- Bench (adblock-fork §7.8 G-1..G-3, §13.1) ---------------------------

struct BenchItem {
  GURL url;
  GURL source;
  OpenRequestType type = OpenRequestType::Other;
};

// §7.8 capture step 6: the as= of a 103 preload, or a request type name.
OpenRequestType BenchTypeOf(std::string_view name) {
  if (name == "script") return OpenRequestType::Script;
  if (name == "style" || name == "stylesheet") return OpenRequestType::Stylesheet;
  if (name == "image") return OpenRequestType::Image;
  if (name == "font") return OpenRequestType::Font;
  if (name == "fetch" || name == "xmlhttprequest") {
    return OpenRequestType::Xmlhttprequest;
  }
  if (name == "media") return OpenRequestType::Media;
  if (name == "ping") return OpenRequestType::Ping;
  if (name == "subdocument") return OpenRequestType::Subdocument;
  return OpenRequestType::Other;
}

// Build runner (file I/O): one URL per line, with optional
// "<type> <source-origin>" columns.
std::vector<BenchItem> ReadBenchFile(base::FilePath path) {
  std::string text;
  std::vector<BenchItem> items;
  if (!base::ReadFileToString(path, &text)) {
    return items;
  }
  for (std::string_view line : base::SplitStringPiece(
           text, "\n", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    std::vector<std::string_view> columns = base::SplitStringPiece(
        line, " \t", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    BenchItem item;
    item.url = GURL(columns[0]);
    if (columns.size() >= 3) {
      item.type = BenchTypeOf(columns[1]);
      item.source = GURL(columns[2]);
    }
    if (!item.source.is_valid()) {
      item.source = item.url;
    }
    if (item.url.is_valid()) {
      items.push_back(std::move(item));
    }
  }
  return items;
}

// Non-official C-G2 harness: the off Profile still has a loaded engine.
// Pace on UI, but enqueue exactly one task per check on the normal matcher
// runner. Neither synthetic checks nor a file read execute on UI.
struct BenchLoadState {
  std::vector<BenchItem> items;
  double rate = 0;
  base::TimeTicks start;
  base::TimeTicks last_log;
  uint64_t posted = 0;  // UI only.
  std::atomic<uint64_t> checks{0};
  std::atomic<uint32_t> pending{0};
};

std::atomic<uint64_t> g_bench_load_checks{0};
std::atomic<bool> g_bench_load_started{false};

void PumpBenchLoad(base::WeakPtr<OpenAdBlockService> service,
                   std::shared_ptr<BenchLoadState> state) {
  if (!service) {
    fprintf(stderr, "OpenAdBlockBenchLoad: stopped checks=%llu\n",
            static_cast<unsigned long long>(state->checks.load()));
    return;
  }
  const auto now = base::TimeTicks::Now();
  const uint64_t due =
      static_cast<uint64_t>((now - state->start).InSecondsF() * state->rate);
  while (state->posted < due && state->pending.load() < 1000) {
    const size_t index = state->posted++ % state->items.size();
    state->pending.fetch_add(1);
    AdBlockMatcherTaskRunner()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](scoped_refptr<OpenAdBlockMatcher> matcher,
                          std::shared_ptr<BenchLoadState> state, size_t index) {
                         const auto& item = state->items[index];
                         matcher->Check(item.url, item.source, item.type,
                                        kOpenAdBlockMatchCapBytes);
                         state->checks.fetch_add(1);
                         g_bench_load_checks.fetch_add(1);
                         state->pending.fetch_sub(1);
                       },
                       service->matcher(), state, index));
  }
  if (now - state->last_log >= base::Seconds(1)) {
    fprintf(stderr,
            "OpenAdBlockBenchLoad: rate=%.3f elapsed_s=%.3f checks=%llu "
            "posted=%llu pending=%u\n",
            state->rate, (now - state->start).InSecondsF(),
            static_cast<unsigned long long>(state->checks.load()),
            static_cast<unsigned long long>(state->posted),
            state->pending.load());
    state->last_log = now;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&PumpBenchLoad, service, std::move(state)),
      base::Milliseconds(1));
}

void StartBenchLoad(base::WeakPtr<OpenAdBlockService> service) {
  const auto* command_line = base::CommandLine::ForCurrentProcess();
  if (!command_line->HasSwitch("open-adblock-bench-load")) {
    return;
  }
  double rate = 0;
  if (!base::StringToDouble(
          command_line->GetSwitchValueASCII("open-adblock-bench-load-rate"),
          &rate) ||
      !std::isfinite(rate) || rate <= 0 || rate > 1000000) {
    fprintf(stderr, "OpenAdBlockBenchLoad: FAIL invalid rate\n");
    return;
  }
  AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ReadBenchFile, command_line->GetSwitchValuePath(
                                         "open-adblock-bench-load")),
      base::BindOnce(
          [](base::WeakPtr<OpenAdBlockService> service, double rate,
             std::vector<BenchItem> items) {
            if (!service || items.empty()) {
              fprintf(stderr, "OpenAdBlockBenchLoad: FAIL no live corpus\n");
              return;
            }
            auto state = std::make_shared<BenchLoadState>();
            state->items = std::move(items);
            state->rate = rate;
            state->start = state->last_log = base::TimeTicks::Now();
            g_bench_load_started.store(true);
            fprintf(stderr,
                    "OpenAdBlockBenchLoad: started rate=%.3f urls=%zu\n", rate,
                    state->items.size());
            PumpBenchLoad(service, std::move(state));
          },
          service, rate));
}

// Repetition 1 is warm-up (a first regex compile can take 6.78 ms, F-35):
// its max is printed apart; mean, p50, p99 and max cover repetitions 2-10.
void PrintTimings(const std::string& label,
                  std::vector<int64_t> warm_ns,
                  int64_t first_pass_max_ns) {
  if (warm_ns.empty()) {
    Line(label + " no samples");
    return;
  }
  std::sort(warm_ns.begin(), warm_ns.end());
  int64_t sum = 0;
  for (int64_t ns : warm_ns) {
    sum += ns;
  }
  auto at = [&](double fraction) {
    return warm_ns[static_cast<size_t>(fraction * (warm_ns.size() - 1))];
  };
  auto us = [](int64_t ns) {
    return base::NumberToString(static_cast<double>(ns) / 1000.0);
  };
  Line(label + " first_pass_max_us=" + us(first_pass_max_ns));
  Line(label + " checks=" + std::to_string(warm_ns.size()) +
       " mean_us=" + us(sum / static_cast<int64_t>(warm_ns.size())) +
       " p50_us=" + us(at(0.5)) + " p99_us=" + us(at(0.99)) +
       " max_us=" + us(warm_ns.back()));
}

int64_t NowNs() {
  return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}

// The bench thread's CPU time. Wall time also counts the time the thread
// waits for a core. The Section 13 G-2 max ruling reads thread CPU time;
// wall time is still reported, including the separate quiet-run ceiling.
int64_t ThreadCpuNs() {
  return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID));
}

// Matcher sequence: the corpus 10x, then the G-3 long URLs 10x each.
std::string RunBench(scoped_refptr<OpenAdBlockMatcher> matcher,
              std::vector<BenchItem> items,
              uint32_t cap) {
  Line("bench matcher thread=" + std::string(base::PlatformThread::GetName()) +
       " cap=" + std::to_string(cap) + " urls=" + std::to_string(items.size()));
  std::vector<int64_t> warm;
  std::vector<int64_t> warm_cpu;
  warm.reserve(items.size() * 9);
  warm_cpu.reserve(items.size() * 9);
  int64_t first_max = 0;
  int64_t first_max_cpu = 0;
  // The warm checks with the largest wall and CPU time: line and URL length.
  int64_t slowest_wall = -1, slowest_cpu = -1;
  size_t slowest_wall_line = 0, slowest_cpu_line = 0;
  size_t matched = 0;
  size_t truncated = 0;
  std::string verdicts;
  const bool dump = base::CommandLine::ForCurrentProcess()->HasSwitch(
      "open-adblock-verdict-dump");
  // §7.8 manifest third_party_share: registrable domains differ (the
  // crate's party rule, F-8, here with Chromium's copy of the PSL).
  size_t third_party = 0;
  std::map<std::string, int> matched_by_source;
  for (int rep = 1; rep <= 10; ++rep) {
    for (size_t line = 0; line < items.size(); ++line) {
      const BenchItem& item = items[line];
      const int64_t start_cpu = ThreadCpuNs();
      const int64_t start = NowNs();
      const open_adblock::OpenBlockerResult result =
          matcher->Check(item.url, item.source, item.type, cap);
      const int64_t ns = NowNs() - start;
      const int64_t cpu_ns = ThreadCpuNs() - start_cpu;
      if (rep == 1) {
        if (dump) {
          // Full results, in corpus order, never just the match count.
          // The opt-in file is private verification output, not a log.
          base::DictValue row;
          row.Set("line", static_cast<int>(line + 1));
          row.Set("matched", result.matched);
          row.Set("important", result.important);
          row.Set("has_redirect", result.has_redirect);
          row.Set("redirect_data_url", std::string(result.redirect_data_url));
          row.Set("rewritten_url", std::string(result.rewritten_url));
          row.Set("csp_directives", std::string(result.csp_directives));
          row.Set("truncated", result.truncated);
          std::string encoded;
          base::JSONWriter::Write(row, &encoded);
          verdicts += encoded + "\n";
        }
        first_max = std::max(first_max, ns);
        first_max_cpu = std::max(first_max_cpu, cpu_ns);
        matched += result.matched;
        truncated += result.truncated;
        third_party += !net::registry_controlled_domains::SameDomainOrHost(
            item.url, item.source,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
        if (result.matched) {
          ++matched_by_source[item.source.DeprecatedGetOriginAsURL().spec()];
        }
      } else {
        warm.push_back(ns);
        warm_cpu.push_back(cpu_ns);
        if (ns > slowest_wall) {
          slowest_wall = ns;
          slowest_wall_line = line + 1;
        }
        if (cpu_ns > slowest_cpu) {
          slowest_cpu = cpu_ns;
          slowest_cpu_line = line + 1;
        }
      }
    }
  }
  PrintTimings("bench corpus", std::move(warm), first_max);
  PrintTimings("bench corpus cpu", std::move(warm_cpu), first_max_cpu);
  if (!items.empty()) {
    Line("bench corpus slowest wall: line=" + std::to_string(slowest_wall_line) +
         " url_length=" +
         std::to_string(items[slowest_wall_line - 1].url.spec().size()) +
         "; slowest cpu: line=" + std::to_string(slowest_cpu_line) +
         " url_length=" +
         std::to_string(items[slowest_cpu_line - 1].url.spec().size()));
  }
  Line("bench corpus matched=" + std::to_string(matched) +
       " truncated=" + std::to_string(truncated) +
       " third_party=" + std::to_string(third_party));
  for (const auto& [source, count] : matched_by_source) {
    Line("bench matched_source " + source + " " + std::to_string(count));
  }

  // G-3: synthetic long URLs (a path of letters).
  for (size_t length : {size_t{8 * 1024}, size_t{16 * 1024},
                        size_t{100 * 1024}, size_t{2 * 1024 * 1024}}) {
    std::string path;
    path.reserve(length);
    for (size_t i = 0; path.size() < length; ++i) {
      path += static_cast<char>('a' + (i * 7) % 26);
    }
    const GURL url("https://ads.example-long.com/" + path);
    const GURL source("https://www.example-news.com/");
    std::vector<int64_t> long_warm;
    std::vector<int64_t> long_warm_cpu;
    int64_t long_first = 0;
    int64_t long_first_cpu = 0;
    for (int rep = 1; rep <= 10; ++rep) {
      const int64_t start_cpu = ThreadCpuNs();
      const int64_t start = NowNs();
      matcher->Check(url, source, OpenRequestType::Script, cap);
      const int64_t ns = NowNs() - start;
      const int64_t cpu_ns = ThreadCpuNs() - start_cpu;
      if (rep == 1) {
        long_first = ns;
        long_first_cpu = cpu_ns;
      } else {
        long_warm.push_back(ns);
        long_warm_cpu.push_back(cpu_ns);
      }
    }
    PrintTimings("bench long_" + std::to_string(length), std::move(long_warm),
                 long_first);
    PrintTimings("bench long_" + std::to_string(length) + " cpu",
                 std::move(long_warm_cpu), long_first_cpu);
  }
  Line(AdBlockLatencyHistogramText());
  Line(matcher->RegexCompileCountsText());
  return verdicts;
}

uint64_t ProcessCpuMicroseconds() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage)) {
    return 0;
  }
  return static_cast<uint64_t>(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) *
             1000000 +
         usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}

void FinishIdleProof(base::OnceCallback<void(bool)> done,
                     bool written,
                     uint64_t first,
                     uint64_t cpu,
                     unsigned seconds,
                     uint64_t last) {
  Line("idle proof seconds=" + std::to_string(seconds) +
       " first=" + std::to_string(first) + " last=" + std::to_string(last) +
       " extra=" + std::to_string(last - first) + " process_cpu_us=" +
       std::to_string(ProcessCpuMicroseconds() - cpu));
  const auto& command = *base::CommandLine::ForCurrentProcess();
  const bool disabled =
      command.HasSwitch("open-adblock-idle-purge-off") ||
      command.HasSwitch("open-adblock-idle-off-proof");
  const uint64_t expected = disabled ? 0 : 1;
  std::move(done).Run(written && first == expected && last == first);
}

void ReadIdleProofEnd(base::OnceCallback<void(bool)> done,
                      bool written,
                      uint64_t first,
                      uint64_t cpu,
                      unsigned seconds) {
  AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&AdBlockIdleReclaimCount),
      base::BindOnce(&FinishIdleProof, std::move(done), written, first, cpu,
                     seconds));
}

void ObserveIdleProof(base::OnceCallback<void(bool)> done,
                      bool written,
                      unsigned seconds,
                      uint64_t first) {
  RecordOpenAdBlockMemoryPhase("post-idle");
  Line("idle first_purges=" + std::to_string(first));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&ReadIdleProofEnd, std::move(done), written, first,
                     ProcessCpuMicroseconds(), seconds),
      base::Seconds(std::min(seconds, 120u)));
}

void ReadIdleProofStart(base::OnceCallback<void(bool)> done,
                        bool written,
                        unsigned seconds) {
  AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&AdBlockIdleReclaimCount),
      base::BindOnce(&ObserveIdleProof, std::move(done), written, seconds));
}

void FinishBenchAfterWrite(base::OnceCallback<void(bool)> done, bool written) {
  RecordOpenAdBlockMemoryPhase("post-checks");
  const auto& command = *base::CommandLine::ForCurrentProcess();
  if (!command.HasSwitch("open-adblock-idle-proof-seconds")) {
    std::move(done).Run(written);
    return;
  }
  unsigned seconds = 0;
  base::StringToUint(command.GetSwitchValueASCII("open-adblock-idle-proof-seconds"),
                    &seconds);
  // post-checks is 2s after the corpus. Allow the real 5s idle task to fire;
  // this observes production behavior and never invokes the purge directly.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&ReadIdleProofStart, std::move(done), written, seconds),
      base::Seconds(4));
}

void FinishResumeWrite(base::OnceCallback<void(bool)> done, bool written) {
  Line("resume-burst verdict_written=" + std::to_string(written));
  RecordOpenAdBlockMemoryPhase("after-resume");
  std::move(done).Run(written);
}

void WriteResumeVerdicts(base::OnceCallback<void(bool)> done,
                         std::string verdicts) {
  const auto path = base::CommandLine::ForCurrentProcess()->GetSwitchValuePath(
      "open-adblock-verdict-dump");
  if (path.empty()) {
    std::move(done).Run(false);
    return;
  }
  AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce([](base::FilePath path, std::string verdicts) {
        return !verdicts.empty() && base::WriteFile(path, verdicts);
      }, path.AddExtensionASCII("resumed"), std::move(verdicts)),
      base::BindOnce(&FinishResumeWrite, std::move(done)));
}

void RunResumeItems(scoped_refptr<OpenAdBlockMatcher> matcher,
                    uint32_t cap,
                    base::OnceCallback<void(bool)> done,
                    std::vector<BenchItem> items) {
  Line("resume-burst begin");
  AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&RunBench, matcher, std::move(items), cap),
      base::BindOnce(&WriteResumeVerdicts, std::move(done)));
}

void ResumeAfterIdle(scoped_refptr<OpenAdBlockMatcher> matcher,
                      uint32_t cap,
                      base::OnceCallback<void(bool)> done,
                      bool initial_ok) {
  if (!initial_ok) {
    std::move(done).Run(false);
    return;
  }
  // Read fresh request inputs only after post-idle memory/count observations.
  // The six-second memory point retains no corpus vector or verdict buffer.
  // Reading these inputs performs no matcher activity or regex matching.
  const auto path = base::CommandLine::ForCurrentProcess()->GetSwitchValuePath(
      "open-adblock-bench");
  AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&ReadBenchFile, path),
      base::BindOnce(&RunResumeItems, matcher, cap, std::move(done)));
}

// The matcher never does file IO. The final callback waits for the private
// verdict file on the build runner before it ends the real binary run.
void BenchAndWrite(scoped_refptr<OpenAdBlockMatcher> matcher,
                   std::vector<BenchItem> items,
                   uint32_t cap,
                   base::OnceCallback<void(bool)> done) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          "open-adblock-idle-resume-burst")) {
    done = base::BindOnce(&ResumeAfterIdle, matcher, cap, std::move(done));
  }
  AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&RunBench, matcher, std::move(items), cap),
      base::BindOnce(
          [](base::OnceCallback<void(bool)> done, std::string verdicts) {
            const base::FilePath path = base::CommandLine::ForCurrentProcess()
                                            ->GetSwitchValuePath(
                                                "open-adblock-verdict-dump");
            if (path.empty()) {
              std::move(done).Run(true);
              return;
            }
            AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
                FROM_HERE,
                base::BindOnce(
                    [](base::FilePath path, std::string verdicts) {
                      return !verdicts.empty() && base::WriteFile(path, verdicts);
                    },
                    path, std::move(verdicts)),
                base::BindOnce(
                    [](base::OnceCallback<void(bool)> done, bool written) {
                      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
                          FROM_HERE,
                          base::BindOnce(&FinishBenchAfterWrite,
                                         std::move(done), written), base::Seconds(2));
                    }, std::move(done)));
          },
          std::move(done)));
}

void Finish(base::WeakPtr<OpenAdBlockService> service,
            base::FilePath service_root,
            base::OnceCallback<void(bool)> done,
            bool ok) {
  Line(ok ? "PASS" : "FAIL");
  // Quit while a text build runs: Shutdown() drops the pending result, and
  // the process must still exit cleanly (review: harness honesty).
  if (service) {
    service->LoadFromDirectory(service_root, /*prefer_dat=*/false);
    Line("quitting with a text build in flight");
  }
  std::move(done).Run(ok);
}

void AfterMatcherChecks(base::WeakPtr<OpenAdBlockService> service,
                        base::FilePath service_root,
                        base::OnceCallback<void(bool)> done,
                        bool ok,
                        bool matcher_ok) {
  ok &= matcher_ok;
  if (!service) {
    Line("FAIL service gone");
    std::move(done).Run(false);
    return;
  }
  const AdBlockStatus counted = service->GetStatus();
  Line("status cosmetic_dropped procedural=" +
       std::to_string(counted.cosmetic_dropped_procedural) +
       " unsafe=" + std::to_string(counted.cosmetic_dropped_unsafe) +
       " style=" + std::to_string(counted.cosmetic_dropped_style) +
       " remove=" + std::to_string(counted.cosmetic_dropped_remove) +
       " scriptlet=" + std::to_string(counted.cosmetic_dropped_scriptlet) +
       " over_cap=" + std::to_string(counted.cosmetic_dropped_over_cap) +
       " checks=" + std::to_string(counted.checks) +
       " checks_truncated=" + std::to_string(counted.checks_truncated));
  ok &= Expect(counted.cosmetic_dropped_procedural > 0 && counted.checks > 0,
               "the status sums the matcher's counters");

  // The shim checks build their own engines: a pool thread, not the UI.
  auto finish = base::BindOnce(
      [](base::WeakPtr<OpenAdBlockService> service, base::FilePath root,
         base::OnceCallback<void(bool)> done, bool ok, bool shim_ok) {
        ok &= shim_ok;
        const base::CommandLine& command_line =
            *base::CommandLine::ForCurrentProcess();
        if (!service || !command_line.HasSwitch("open-adblock-bench")) {
          Finish(service, root, std::move(done), ok);
          return;
        }
        // §13.1 bench: read on the build runner, run on the matcher.
        uint32_t cap = kOpenAdBlockMatchCapBytes;
        if (command_line.HasSwitch("open-adblock-bench-cap")) {
          unsigned value = 0;
          if (base::StringToUint(command_line.GetSwitchValueASCII(
                                     "open-adblock-bench-cap"),
                                 &value) &&
              value > 0) {
            cap = value;
          }
        }
        scoped_refptr<OpenAdBlockMatcher> matcher = service->matcher();
        AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
            FROM_HERE,
            base::BindOnce(&ReadBenchFile,
                           command_line.GetSwitchValuePath("open-adblock-bench")),
            base::BindOnce(
                [](scoped_refptr<OpenAdBlockMatcher> matcher, uint32_t cap,
                   base::OnceCallback<void(bool)> after,
                   std::vector<BenchItem> items) {
                  BenchAndWrite(matcher, std::move(items), cap, std::move(after));
                },
                matcher, cap,
                base::BindOnce(
                    [](base::WeakPtr<OpenAdBlockService> service,
                       base::FilePath root, base::OnceCallback<void(bool)> done,
                       bool ok, bool written) {
                      Finish(service, root, std::move(done), ok && written);
                    },
                    service, root, std::move(done), ok)));
      },
      service, service_root, std::move(done), ok);
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&CheckShim), std::move(finish));
}

void OnLoaded(base::WeakPtr<OpenAdBlockService> service,
              base::FilePath service_root,
              std::shared_ptr<LoadResults> results,
              base::OnceCallback<void(bool)> done,
              AdBlockLoadResult load_result) {
  if (!service) {
    Line("FAIL service gone");
    std::move(done).Run(false);
    return;
  }
  bool ok = Expect(load_result == AdBlockLoadResult::kLoaded,
                   "the load's done reports kLoaded");
  ok &= Expect(results->destroyed == AdBlockLoadResult::kCancelled &&
                   results->after_shutdown == AdBlockLoadResult::kCancelled &&
                   results->stale == AdBlockLoadResult::kStale,
               "done runs for a destroyed service and after shutdown "
               "(kCancelled), and for a replaced load (kStale)");
  const AdBlockStatus status = service->GetStatus();
  Line("status " + AdBlockStatusText(status));

  ok &= Expect(status.engine_loaded && status.list_count > 0,
               "engine loaded from the live generation");
  ok &= Expect(status.last_error.empty(), "no load or cache error");
  ok &= Expect(status.excluded_domains ==
                   std::vector<std::string>{"[::1]", "example.com",
                                            "news.example.org"},
               "excluded domains normalized; bare suffix, path, empty skipped");
  // Behavior, not stored strings (review 100-4): an entry covers its domain
  // and subdomains at a label boundary.
  ok &= Expect(service->IsExcludedOnUi("www.example.com") &&
                   service->IsExcludedOnUi("example.com") &&
                   service->IsExcludedOnUi("a.news.example.org") &&
                   service->IsExcludedOnUi("news.example.org") &&
                   service->IsExcludedOnUi("[::1]") &&
                   !service->IsExcludedOnUi("example.org") &&
                   !service->IsExcludedOnUi("other.example.org") &&
                   !service->IsExcludedOnUi("notexample.com"),
               "exclusions match the domain and its subdomains only");

  // The engine reaches the matcher through a posted SetEngine; the matcher
  // checks run behind it on the same sequence.
  AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&MatcherChecks, service->matcher()),
      base::BindOnce(&AfterMatcherChecks, service, service_root,
                     std::move(done), ok));
}

uint64_t MemorySnapshot(const char* phase) {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  const bool measured = task_info(mach_task_self(), TASK_VM_INFO,
                                 reinterpret_cast<task_info_t>(&info),
                                 &count) == KERN_SUCCESS;
  Line(std::string("memory phase=") + phase + " phys_footprint=" +
       std::to_string(measured ? info.phys_footprint : 0));
  using allocator_shim::internal::PartitionAllocMalloc;
  for (size_t index = 0; index < allocator_shim::kNumPartitions; ++index) {
    for (auto* root : {PartitionAllocMalloc::Allocator(index),
                       PartitionAllocMalloc::OriginalAllocator(index)}) {
      if (!root) {
        continue;
      }
      partition_alloc::SimplePartitionStatsDumper dumper;
      root->DumpStats("malloc", /*is_light_dump=*/true,
                      /*populate_discardable_bytes=*/true, &dumper);
      const auto& stats = dumper.stats();
      Line(std::string("memory phase=") + phase + " partition=" +
           std::to_string(index) + " root=" +
           (root == PartitionAllocMalloc::Allocator(index) ? "current" :
                                                            "original") +
           " allocated=" +
           std::to_string(stats.total_allocated_bytes) + " active=" +
           std::to_string(stats.total_active_bytes) + " resident=" +
           std::to_string(stats.total_resident_bytes) + " committed=" +
           std::to_string(stats.total_committed_bytes) + " decommittable=" +
           std::to_string(stats.total_decommittable_bytes) + " discardable=" +
           std::to_string(stats.total_discardable_bytes));
    }
  }
  return measured ? info.phys_footprint : 0;
}

// Real service load and matcher interface, without the selftest's synthetic
// engines or safety fixtures contaminating the single-engine memory window.
void RunDiagnostic(base::WeakPtr<OpenAdBlockService> service,
                   base::FilePath root,
                   base::OnceCallback<void(bool)> done) {
  if (!service) {
    std::move(done).Run(false);
    return;
  }
  const uint64_t before = MemorySnapshot("before-load");
  const bool prefer_dat = !base::CommandLine::ForCurrentProcess()->HasSwitch(
      "open-adblock-text");
  service->SetEnabled(true);
  service->LoadFromDirectory(
      root, prefer_dat,
      base::BindOnce(
          [](base::WeakPtr<OpenAdBlockService> service, uint64_t before,
             base::OnceCallback<void(bool)> done, AdBlockLoadResult result) {
            if (!service || result != AdBlockLoadResult::kLoaded) {
              Line("FAIL diagnostic load");
              std::move(done).Run(false);
              return;
            }
            unsigned settle_seconds = 2;
            unsigned requested = 0;
            if (base::StringToUint(base::CommandLine::ForCurrentProcess()
                                   ->GetSwitchValueASCII(
                                       "open-adblock-settle-seconds"),
                                   &requested)) {
              settle_seconds = requested;
            }
            base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
                FROM_HERE,
                base::BindOnce(
                    [](base::WeakPtr<OpenAdBlockService> service,
                       uint64_t before, base::OnceCallback<void(bool)> done) {
                      if (!service) {
                        std::move(done).Run(false);
                        return;
                      }
                      const uint64_t after = MemorySnapshot("settled-load");
                      Line("memory delta_phys_footprint=" +
                           std::to_string(static_cast<int64_t>(after) -
                                          static_cast<int64_t>(before)));
                      Line("diagnostic status " +
                           AdBlockStatusText(service->GetStatus()));
                      const auto& command =
                          *base::CommandLine::ForCurrentProcess();
                      if (command.HasSwitch("open-adblock-measure-only")) {
                        std::move(done).Run(before && after);
                        return;
                      }
                      unsigned cap = kOpenAdBlockMatchCapBytes;
                      unsigned requested = 0;
                      if (base::StringToUint(command.GetSwitchValueASCII(
                                                 "open-adblock-bench-cap"),
                                             &requested) && requested > 0) {
                        cap = requested;
                      }
                      AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
                          FROM_HERE,
                          base::BindOnce(&ReadBenchFile,
                                         command.GetSwitchValuePath(
                                             "open-adblock-bench")),
                          base::BindOnce(
                              [](scoped_refptr<OpenAdBlockMatcher> matcher,
                                 uint32_t cap,
                                 base::OnceCallback<void(bool)> done,
                                 std::vector<BenchItem> items) {
                                if (items.empty()) {
                                  std::move(done).Run(false);
                                  return;
                                }
                                BenchAndWrite(matcher, std::move(items), cap,
                                              std::move(done));
                              },
                              service->matcher(), cap, std::move(done)));
                    },
                    service, before, std::move(done)),
                base::Seconds(std::min(settle_seconds, 60u)));
          },
          service, before, std::move(done)));
}

}  // namespace

void RunOpenAdBlockSelftest(OpenAdBlockService* service,
                            base::FilePath adblock_root,
                            base::OnceCallback<void(bool)> done) {
  const auto& command = *base::CommandLine::ForCurrentProcess();
  if (command.HasSwitch("open-adblock-fuzz-full")) {
    // Opt-in, headless, no watchdog. Do not load the service or consume its
    // shared matcher sequence. The process is also launched with nice(19).
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
        base::BindOnce(&RunFullFuzz, adblock_root,
                       command.GetSwitchValuePath("open-adblock-fuzz-output")),
        std::move(done));
    return;
  }
  if (command.HasSwitch("open-adblock-idle-off-proof")) {
    // Headless blocking-off control: do not load an engine or run checks.
    // Use the same process CPU/count observer as the post-corpus idle proof.
    service->SetEnabled(false);
    Line("idle off status " + AdBlockStatusText(service->GetStatus()));
    unsigned seconds = 60;
    base::StringToUint(command.GetSwitchValueASCII(
                          "open-adblock-idle-proof-seconds"), &seconds);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&ReadIdleProofStart, std::move(done), true, seconds),
        base::Seconds(6));
    return;
  }
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          "open-adblock-profile-proof")) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&RunOpenAdBlockProfileProof, adblock_root,
                                 std::move(done)), base::Seconds(1));
    return;
  }
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(
          "open-adblock-diagnostic")) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&RunDiagnostic, service->GetWeakPtr(), adblock_root,
                       std::move(done)),
        base::Seconds(1));
    return;
  }
  Line("loading " + adblock_root.value());
  service->SetEnabled(true);
  service->SetExcludedDomains(
      {"Example.COM.", "*.news.example.org", "com", "bad/x", "", "::1"});
  auto results = std::make_shared<LoadResults>();
  // Review R2-5. A service that shuts down first answers at once.
  OpenAdBlockService closed{base::FilePath()};
  closed.Shutdown();
  closed.LoadFromDirectory(
      adblock_root, /*prefer_dat=*/true,
      base::BindOnce(&Record, results, Slot::kAfterShutdown));
  // A service destroyed with its load in flight answers when the build ends;
  // then two loads on the real service, the first replaced by the second.
  auto start = base::BindOnce(
      [](base::WeakPtr<OpenAdBlockService> service, base::FilePath root,
         std::shared_ptr<LoadResults> results,
         base::OnceCallback<void(bool)> done, AdBlockLoadResult result) {
        results->destroyed = result;
        if (!service) {
          Line("FAIL service gone");
          std::move(done).Run(false);
          return;
        }
        service->LoadFromDirectory(
            root, /*prefer_dat=*/true,
            base::BindOnce(&Record, results, Slot::kStale));
        service->LoadFromDirectory(
            root, /*prefer_dat=*/true,
            base::BindOnce(&OnLoaded, service, root, results, std::move(done)));
      },
      service->GetWeakPtr(), adblock_root, results, std::move(done));
  auto doomed = std::make_unique<OpenAdBlockService>(base::FilePath());
  doomed->LoadFromDirectory(adblock_root, /*prefer_dat=*/true, std::move(start));
}

std::string AdBlockStatusText(const AdBlockStatus& status) {
  return "enabled=" + std::to_string(status.enabled) +
         " engine_loaded=" + std::to_string(status.engine_loaded) +
         " engine_from_dat=" + std::to_string(status.engine_from_dat) +
         " engine_shared=" + std::to_string(status.engine_shared) +
         " generation=" + std::to_string(status.generation) +
         " list_count=" + std::to_string(status.list_count) +
         " dat_size_bytes=" + std::to_string(status.dat_size_bytes) +
         " dat_policy=" + status.dat_policy +
         " resources_loaded=" + std::to_string(status.resources_loaded) +
         " match_cap_bytes=" + std::to_string(status.match_cap_bytes) +
         " checks=" + std::to_string(status.checks) +
         " checks_truncated=" + std::to_string(status.checks_truncated) +
         " last_build_ms=" + std::to_string(status.last_build_ms) +
         " last_error=\"" + status.last_error + "\"" +
         " excluded=" + base::JoinString(status.excluded_domains, ",");
}

void LoadOpenAdBlockForSmoke(OpenAdBlockService* service,
                             base::FilePath adblock_root) {
  service->LoadFromDirectory(
      adblock_root, /*prefer_dat=*/true,
      base::BindOnce(
          [](base::WeakPtr<OpenAdBlockService> service,
             AdBlockLoadResult result) {
            if (!service) {
              return;
            }
            static constexpr const char* kNames[] = {"loaded", "failed",
                                                     "stale", "cancelled"};
            fprintf(stderr, "OpenAdBlockSmoke: load result=%s %s\n",
                    kNames[static_cast<int>(result)],
                    AdBlockStatusText(service->GetStatus()).c_str());
            if (result == AdBlockLoadResult::kLoaded) {
              StartBenchLoad(service);
            }
          },
          service->GetWeakPtr()));
}

void RecordOpenAdBlockMemoryPhase(const char* phase) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("open-adblock-diagnostic")) {
    MemorySnapshot(phase);
  }
}

void PrintOpenAdBlockBenchLoadCount() {
  if (g_bench_load_started.load()) {
    fprintf(stderr, "OpenAdBlockBenchLoad: shutdown_checks=%llu\n",
            static_cast<unsigned long long>(g_bench_load_checks.load()));
  }
}

}  // namespace open_engine
