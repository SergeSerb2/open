// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_selftest.h"

#include <mach/mach.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/strings/string_number_conversions.h"
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
// type, and mutated DATs. Passing means no abort; the full-size runs are a
// pre-release follow-up (docs/followups.md).
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
  Line("status enabled=" + std::to_string(status.enabled) +
       " engine_loaded=" + std::to_string(status.engine_loaded) +
       " engine_from_dat=" + std::to_string(status.engine_from_dat) +
       " generation=" + std::to_string(status.generation) +
       " list_count=" + std::to_string(status.list_count) +
       " dat_size_bytes=" + std::to_string(status.dat_size_bytes) +
       " last_build_ms=" + std::to_string(status.last_build_ms) +
       " last_error=\"" + status.last_error + "\"" +
       " excluded=" + base::JoinString(status.excluded_domains, ","));

  ok &= Expect(status.engine_loaded && status.list_count > 0,
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

  // adblock-fork §13.4: mean cost of one page's cosmetic query. A real-time
  // budget on a shared machine: up to 3 attempts, each printed with the
  // load average (docs/review-checklist.md §4).
  constexpr int64_t kCosmeticBudgetUs = 100;
  size_t hide_count = 0;
  int64_t mean_us = 0;
  for (int attempt = 1; attempt <= 3; ++attempt) {
    base::ElapsedTimer timer;
    for (int i = 0; i < 100; ++i) {
      hide_count = service->CosmeticResources(GURL("https://www.nytimes.com/"))
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
  ok &= Expect(std::is_sorted(gamedev.hide_selectors.begin(),
                              gamedev.hide_selectors.end()),
               "hide selectors sorted");
  const AdBlockStatus counted = service->GetStatus();
  Line("status cosmetic_dropped procedural=" +
       std::to_string(counted.cosmetic_dropped_procedural) +
       " unsafe=" + std::to_string(counted.cosmetic_dropped_unsafe) +
       " style=" + std::to_string(counted.cosmetic_dropped_style) +
       " remove=" + std::to_string(counted.cosmetic_dropped_remove) +
       " scriptlet=" + std::to_string(counted.cosmetic_dropped_scriptlet) +
       " over_cap=" + std::to_string(counted.cosmetic_dropped_over_cap));
  ok &= Expect(counted.cosmetic_dropped_procedural >= gamedev.dropped_procedural &&
                   gamedev.dropped_procedural > 0,
               "the status sums the cosmetic counters");

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

}  // namespace open_engine
