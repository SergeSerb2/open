// Copyright 2026 The Open Authors. All rights reserved.
// OpenAdBlockProfileService implementation.

#include "open_unified/core/adblock/open_adblock_profile_service.h"

#include <algorithm>
#include <utility>

#include "base/base_paths.h"
#include "base/environment.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/values.h"
#include "build/build_config.h"
#include "components/keyed_service/content/browser_context_dependency_manager.h"
#include "components/web_cache/browser/web_cache_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "crypto/hash.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "open/adblock/open_adblock_cosmetics_host.h"
#include "open/adblock/open_adblock_tab_helper.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"
#include "url/url_constants.h"

#if BUILDFLAG(IS_MAC)
#include "base/apple/bundle_locations.h"
#endif

namespace open_unified {

namespace {

constexpr char kConfigFileName[] = "adblock-config.json";
constexpr char kExclusionsFileName[] = "exclusions.json";
constexpr char kCustomRulesFileName[] = "custom-rules.txt";
constexpr char kCurrentPointerName[] = "current.json";
constexpr char kManifestFileName[] = "manifest.json";
constexpr char kResourcesFileName[] = "resources.json";
constexpr char kCustomRulesListId[] = "CustomRules";
constexpr size_t kMaxConfigBytes = 4 * 1024 * 1024;
constexpr size_t kMaxCustomRulesBytes = 2 * 1024 * 1024;
constexpr size_t kMaxResourcesBytes = 4 * 1024 * 1024;
constexpr int64_t kMaxSourceBytes = 16 * 1024 * 1024;
constexpr size_t kMaxListBytes = 64 * 1024 * 1024;

constexpr net::NetworkTrafficAnnotationTag kOpenAdBlockListTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_adblock_list_updater", R"(
        semantics {
          sender: "Open AdBlock List Updater"
          description:
            "Downloads enabled AdBlock filter lists (such as EasyList and "
            "EasyPrivacy) from their configured HTTPS upstream sources."
          trigger:
            "User enables a non-bundled filter list or triggers a manual "
            "filter list update in open://settings."
          data:
            "No user data or cookies are sent. Standard conditional GET "
            "headers (If-None-Match / If-Modified-Since) may be included."
          destination: OTHER
          destination_other: "Configured public AdBlock filter list host"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Users can disable AdBlock or individual filter lists in "
            "open://settings."
          policy_exception_justification: "User-controlled content blocker."
        })");

base::FilePath& BundledDirOverrideForTesting() {
  static base::NoDestructor<base::FilePath> dir;
  return *dir;
}

std::string Sha256HexLower(std::string_view data) {
  return base::HexEncodeLower(crypto::hash::Sha256(data));
}

int64_t NowMs() {
  return base::Time::Now().InMillisecondsSinceUnixEpoch();
}

// Counts active filter rules (non-empty lines excluding comments/headers).
int CountFilterRules(std::string_view text) {
  int count = 0;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t end = text.find('\n', pos);
    if (end == std::string_view::npos) {
      end = text.size();
    }
    std::string_view line =
        base::TrimWhitespaceASCII(text.substr(pos, end - pos), base::TRIM_ALL);
    if (!line.empty() && line.front() != '!' && line.front() != '[') {
      ++count;
    }
    pos = end + 1;
  }
  return count;
}

bool LooksLikeHtmlErrorPage(std::string_view body) {
  std::string_view trimmed = base::TrimWhitespaceASCII(body, base::TRIM_LEADING);
  if (base::StartsWith(trimmed, "\xEF\xBB\xBF")) {
    trimmed.remove_prefix(3);
    trimmed = base::TrimWhitespaceASCII(trimmed, base::TRIM_LEADING);
  }
  return base::StartsWith(trimmed, "<!doctype html",
                          base::CompareCase::INSENSITIVE_ASCII) ||
         base::StartsWith(trimmed, "<html",
                          base::CompareCase::INSENSITIVE_ASCII);
}

std::string BundledFileNameForList(std::string_view list_id) {
  return base::ToLowerASCII(list_id) + ".txt";
}

bool HasBundledAdBlockPayloads(const base::FilePath& dir) {
  if (dir.empty()) {
    return false;
  }
  return base::PathExists(dir.AppendASCII("easylist.txt")) ||
         base::PathExists(dir.AppendASCII("easyprivacy.txt")) ||
         base::PathExists(dir.AppendASCII(kResourcesFileName));
}

base::DictValue ReceiptToDict(const AdBlockListReceipt& r) {
  base::DictValue d;
  d.Set("listId", r.list_id);
  d.Set("source", r.source);
  d.Set("lastUpdatedMs", static_cast<double>(r.last_updated_ms));
  d.Set("ruleCount", r.rule_count);
  d.Set("bytes", static_cast<double>(r.bytes));
  if (!r.sha256.empty()) d.Set("sha256", r.sha256);
  if (!r.etag.empty()) d.Set("etag", r.etag);
  if (!r.last_modified.empty()) d.Set("lastModified", r.last_modified);
  if (!r.last_error.empty()) d.Set("lastError", r.last_error);
  return d;
}

AdBlockListReceipt ReceiptFromDict(const std::string& fallback_id,
                                   const base::DictValue& d) {
  AdBlockListReceipt r;
  r.list_id = fallback_id;
  if (const std::string* s = d.FindString("listId"); s && !s->empty()) {
    r.list_id = *s;
  }
  if (const std::string* s = d.FindString("source")) r.source = *s;
  if (std::optional<double> v = d.FindDouble("lastUpdatedMs")) {
    r.last_updated_ms = static_cast<int64_t>(*v);
  }
  if (std::optional<int> v = d.FindInt("ruleCount")) r.rule_count = *v;
  if (std::optional<double> v = d.FindDouble("bytes")) {
    r.bytes = static_cast<int64_t>(*v);
  }
  if (const std::string* s = d.FindString("sha256")) r.sha256 = *s;
  if (const std::string* s = d.FindString("etag")) r.etag = *s;
  if (const std::string* s = d.FindString("lastModified")) r.last_modified = *s;
  if (const std::string* s = d.FindString("lastError")) r.last_error = *s;
  return r;
}

void WriteAtomicFileOnBlockingSequence(base::FilePath dir,
                                       std::string file_name,
                                       std::string contents) {
  if (!base::CreateDirectory(dir)) {
    return;
  }
  base::ImportantFileWriter::WriteFileAtomically(dir.AppendASCII(file_name),
                                                 contents);
}

bool WriteListCacheOnBlockingSequence(base::FilePath cache_dir,
                                      std::string list_id,
                                      std::string contents) {
  if (!base::CreateDirectory(cache_dir)) {
    return false;
  }
  return base::ImportantFileWriter::WriteFileAtomically(
      cache_dir.AppendASCII(list_id + ".txt"), contents);
}

std::optional<std::string> ReadAndDeleteTempFileOnBlockingSequence(
    base::FilePath temp_file) {
  if (temp_file.empty()) {
    return std::nullopt;
  }
  std::string body;
  bool ok = base::ReadFileToStringWithMaxSize(
      temp_file, &body, static_cast<size_t>(kMaxSourceBytes));
  base::DeleteFile(temp_file);
  if (!ok) {
    return std::nullopt;
  }
  return body;
}

bool HasCurrentGenerationOnBlockingSequence(base::FilePath lists_dir) {
  return base::PathExists(lists_dir.AppendASCII(kCurrentPointerName));
}

bool WriteGenerationOnBlockingSequence(
    base::FilePath lists_dir,
    std::vector<std::pair<std::string, std::string>> list_id_and_text,
    std::string resources_json) {
  int next_gen = 1;
  std::string current_raw;
  if (base::ReadFileToStringWithMaxSize(
          lists_dir.AppendASCII(kCurrentPointerName), &current_raw,
          64 * 1024)) {
    if (auto ptr =
            base::JSONReader::ReadDict(current_raw, base::JSON_PARSE_RFC)) {
      if (const auto* live = ptr->FindDict("live")) {
        next_gen = live->FindInt("generation").value_or(0) + 1;
      }
    }
  }

  base::FilePath gen_dir = lists_dir.AppendASCII("generations")
                               .AppendASCII(base::NumberToString(next_gen));
  if (!base::CreateDirectory(gen_dir)) {
    return false;
  }

  base::ListValue files_manifest;
  std::set<std::string> seen_ids;
  for (const auto& [list_id, text] : list_id_and_text) {
    if (list_id.empty() || !seen_ids.insert(list_id).second || text.empty()) {
      continue;
    }
    std::string file_name = list_id + ".txt";
    if (!base::ImportantFileWriter::WriteFileAtomically(
            gen_dir.AppendASCII(file_name), text)) {
      return false;
    }
    base::DictValue entry;
    entry.Set("file", file_name);
    entry.Set("listID", list_id);
    entry.Set("bytes", static_cast<int>(text.size()));
    entry.Set("sha256", Sha256HexLower(text));
    entry.Set("generation", next_gen);
    files_manifest.Append(std::move(entry));
  }

  if (!resources_json.empty()) {
    if (!base::ImportantFileWriter::WriteFileAtomically(
            gen_dir.AppendASCII(kResourcesFileName), resources_json)) {
      return false;
    }
    base::DictValue entry;
    entry.Set("file", kResourcesFileName);
    entry.Set("listID", "_resources");
    entry.Set("bytes", static_cast<int>(resources_json.size()));
    entry.Set("sha256", Sha256HexLower(resources_json));
    entry.Set("generation", next_gen);
    files_manifest.Append(std::move(entry));
  }

  base::DictValue manifest;
  manifest.Set("generation", next_gen);
  manifest.Set("files", std::move(files_manifest));
  std::string manifest_text;
  if (!base::JSONWriter::Write(manifest, &manifest_text)) {
    return false;
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(
          gen_dir.AppendASCII(kManifestFileName), manifest_text)) {
    return false;
  }

  base::DictValue live;
  live.Set("generation", next_gen);
  live.Set("manifestSHA256", Sha256HexLower(manifest_text));
  base::DictValue pointer;
  pointer.Set("schemaVersion", 1);
  pointer.Set("live", std::move(live));
  std::string pointer_text;
  if (!base::JSONWriter::Write(pointer, &pointer_text)) {
    return false;
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(
          lists_dir.AppendASCII(kCurrentPointerName), pointer_text)) {
    return false;
  }

  // Prune old generations/<k> directories where k < next_gen - 1 on this
  // background sequence after current.json has been atomically updated.
  base::FilePath generations_dir = lists_dir.AppendASCII("generations");
  base::FileEnumerator enumerator(generations_dir, /*recursive=*/false,
                                  base::FileEnumerator::DIRECTORIES);
  for (base::FilePath entry = enumerator.Next(); !entry.empty();
       entry = enumerator.Next()) {
    int gen_num = 0;
    if (base::StringToInt(entry.BaseName().AsUTF8Unsafe(), &gen_num) &&
        gen_num < next_gen - 1) {
      base::DeletePathRecursively(entry);
    }
  }
  return true;
}

std::vector<AdBlockListInfo> BuildBuiltinCatalog() {
  return {
      {"EasyList",
       "EasyList",
       "generic",
       "https://easylist.to/",
       {"https://easylist.to/easylist/easylist.txt"},
       true,
       true,
       std::nullopt},
      {"AdGuardAds",
       "AdGuard - Ads",
       "generic",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/2_without_easylist.txt"},
       false,
       false,
       std::nullopt},
      {"uBlock",
       "uBlock Origin filters",
       "generic",
       "https://github.com/uBlockOrigin/uAssets",
       {"https://ublockorigin.github.io/uAssets/filters/filters.txt",
        "https://ublockorigin.github.io/uAssets/filters/filters-2020.txt",
        "https://ublockorigin.github.io/uAssets/filters/filters-2021.txt",
        "https://ublockorigin.github.io/uAssets/filters/filters-2022.txt",
        "https://ublockorigin.github.io/uAssets/filters/filters-2023.txt",
        "https://ublockorigin.github.io/uAssets/filters/filters-2024.txt",
        "https://ublockorigin.github.io/uAssets/filters/ubo-link-shorteners.txt"},
       false,
       false,
       std::nullopt},
      {"CookieMonster",
       "CookieMonster by Fanboy",
       "cookies",
       "https://github.com/easylist/easylist#fanboy-lists",
       {"https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"},
       false,
       false,
       std::nullopt},
      {"AdGuardCookies",
       "AdGuard - Cookie Notices",
       "cookies",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/18.txt"},
       false,
       false,
       std::nullopt},
      {"EasyPrivacy",
       "EasyPrivacy",
       "privacy",
       "https://easylist.to/",
       {"https://easylist.to/easylist/easyprivacy.txt"},
       true,
       true,
       std::nullopt},
      {"AdGuardSpyware",
       "AdGuard Tracking Protection",
       "privacy",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/3.txt"},
       false,
       false,
       std::nullopt},
      {"EasyListSocial",
       "EasyList - Social Widgets",
       "privacy",
       "https://easylist.to/",
       {"https://ublockorigin.github.io/uAssets/thirdparties/easylist-social.txt"},
       false,
       false,
       std::nullopt},
      {"AdGuardSocial",
       "AdGuard - Social Widgets",
       "privacy",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/4.txt"},
       false,
       false,
       std::nullopt},
      {"FanBoyThirdParty",
       "Fanboy - Anti-Facebook",
       "privacy",
       "https://github.com/easylist/easylist#fanboy-lists",
       {"https://secure.fanboy.co.nz/fanboy-antifacebook.txt"},
       false,
       false,
       std::nullopt},
      {"pl",
       "EasyList - Polska lista",
       "regional",
       "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard",
       {"https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt",
        "https://raw.githubusercontent.com/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock_ublock.txt"},
       false,
       false,
       std::nullopt},
      {"ua",
       "RU AdList",
       "regional",
       "https://forums.lanik.us/viewtopic.php?f=102&t=22512",
       {"https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/adservers.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/first_level.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/general_block.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/general_hide.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/popup.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/specific_antisocial.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/specific_block.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/specific_hide.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/specific_special.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/thirdparty.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/advblock/whitelist.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/css-fixes-experimental.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/js-fixes-experimental.txt",
        "https://raw.githubusercontent.com/easylist/ruadlist/master/AWRL-non-sync.txt"},
       false,
       false,
       std::nullopt},
      {"al",
       "Adblock List for Albania",
       "regional",
       "https://github.com/AnXh3L0/blocklist",
       {"https://raw.githubusercontent.com/AnXh3L0/blocklist/master/albanian-easylist-addition/Albania.txt"},
       false,
       false,
       std::nullopt},
      {"bg",
       "Adblock List for Bulgaria",
       "regional",
       "https://stanev.org/abp/",
       {"https://stanev.org/abp/adblock_bg.txt"},
       false,
       false,
       std::nullopt},
      {"zn",
       "AdGuard Chinese",
       "regional",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/224.txt"},
       false,
       false,
       std::nullopt},
      {"cssk",
       "EasyList Czech and Slovak",
       "regional",
       "https://github.com/tomasko126/easylistczechandslovak",
       {"https://raw.githubusercontent.com/tomasko126/easylistczechandslovak/master/filters.txt",
        "https://raw.githubusercontent.com/tomasko126/easylistczechandslovak/master/filters_ublock.txt"},
       false,
       false,
       std::nullopt},
      {"de",
       "EasyList Germany",
       "regional",
       "https://forums.lanik.us/viewforum.php?f=90",
       {"https://easylist.to/easylistgermany/easylistgermany.txt"},
       false,
       false,
       std::nullopt},
      {"ee",
       "Eesti saitidele kohandatud filter (Estonian)",
       "regional",
       "https://adblock.ee/",
       {"https://adblock.ee/list.php"},
       false,
       false,
       std::nullopt},
      {"ar",
       "Liste AR",
       "regional",
       "https://forums.lanik.us/viewforum.php?f=98",
       {"https://easylist-downloads.adblockplus.org/Liste_AR.txt"},
       false,
       false,
       std::nullopt},
      {"espt",
       "AdGuard Spanish/Portuguese",
       "regional",
       "https://kb.adguard.com/en/general/adguard-ad-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/9.txt"},
       false,
       false,
       std::nullopt},
      {"es",
       "EasyList Spanish",
       "regional",
       "https://forums.lanik.us/viewforum.php?f=103",
       {"https://easylist-downloads.adblockplus.org/easylistspanish.txt"},
       false,
       false,
       std::nullopt},
      {"fi",
       "Adblock List for Finland",
       "regional",
       "https://github.com/finnish-easylist-addition/finnish-easylist-addition",
       {"https://raw.githubusercontent.com/finnish-easylist-addition/finnish-easylist-addition/gh-pages/Finland_adb.txt",
        "https://raw.githubusercontent.com/finnish-easylist-addition/finnish-easylist-addition/gh-pages/Finland_adb_uBO_extras.txt"},
       false,
       false,
       std::nullopt},
      {"fr",
       "AdGuard Francais",
       "regional",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/16.txt"},
       false,
       false,
       std::nullopt},
      {"gr",
       "Greek AdBlock Filter",
       "regional",
       "https://github.com/kargig/greek-adblockplus-filter",
       {"https://www.void.gr/kargig/void-gr-filters.txt"},
       false,
       false,
       std::nullopt},
      {"hr",
       "Dandelion Sprout's Serbo-Croatian filters",
       "regional",
       "https://github.com/DandelionSprout/adfilt#readme",
       {"https://raw.githubusercontent.com/DandelionSprout/adfilt/master/SerboCroatianList.txt"},
       false,
       false,
       std::nullopt},
      {"hu",
       "hufilter (Hungarian)",
       "regional",
       "https://github.com/hufilter/hufilter",
       {"https://cdn.jsdelivr.net/gh/hufilter/hufilter@gh-pages/hufilter-ublock.txt"},
       false,
       false,
       std::nullopt},
      {"ind",
       "ABPindo (Indonesia/Malaysia)",
       "regional",
       "https://github.com/ABPindo/indonesianadblockrules",
       {"https://raw.githubusercontent.com/ABPindo/indonesianadblockrules/master/subscriptions/abpindo.txt"},
       false,
       false,
       std::nullopt},
      {"il",
       "EasyList Hebrew",
       "regional",
       "https://github.com/easylist/EasyListHebrew",
       {"https://raw.githubusercontent.com/easylist/EasyListHebrew/master/EasyListHebrew.txt",
        "https://raw.githubusercontent.com/easylist/EasyListHebrew/master/EasyListHebrew-uBO.txt"},
       false,
       false,
       std::nullopt},
      {"in",
       "IndianList",
       "regional",
       "https://github.com/mediumkreation/IndianList",
       {"https://easylist-downloads.adblockplus.org/indianlist.txt"},
       false,
       false,
       std::nullopt},
      {"persian",
       "PersianBlocker",
       "regional",
       "https://github.com/MasterKia/PersianBlocker",
       {"https://raw.githubusercontent.com/MasterKia/PersianBlocker/main/PersianBlocker.txt"},
       false,
       false,
       std::nullopt},
      {"cold",
       "Icelandic ABP List",
       "regional",
       "https://github.com/brave/adblock-lists",
       {"https://raw.githubusercontent.com/brave/adblock-lists/master/custom/is.txt"},
       false,
       false,
       std::nullopt},
      {"it",
       "EasyList Italy",
       "regional",
       "https://forums.lanik.us/viewforum.php?f=96",
       {"https://easylist-downloads.adblockplus.org/easylistitaly.txt"},
       false,
       false,
       std::nullopt},
      {"jp",
       "AdGuard Japanese",
       "regional",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/7.txt"},
       false,
       false,
       std::nullopt},
      {"kr",
       "List-KR (Korean)",
       "regional",
       "https://github.com/List-KR/List-KR#readme",
       {"https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/3rd_domains.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/1st_domains.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/general_elemhide.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/general_url.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/specific_URL.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/specific_ELEMHIDE.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/removeparam.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/extended_css_ELEMHIDE.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/extended_css_INJECTION.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/specific_CSS.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-share/allowlist.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/specific_ELEMHIDE.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/specific_REDIRECT.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/extended_css_ELEMHIDE.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/scriptlets.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/antiadblock.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/allowlist.txt",
        "https://cdn.jsdelivr.net/gh/List-KR/List-KR@latest/filters-uBO/specific_CSS.txt"},
       false,
       false,
       std::nullopt},
      {"lt",
       "EasyList Lithuania",
       "regional",
       "https://github.com/EasyList-Lithuania/easylist_lithuania",
       {"https://raw.githubusercontent.com/EasyList-Lithuania/easylist_lithuania/master/easylistlithuania.txt"},
       false,
       false,
       std::nullopt},
      {"lv",
       "Latvian List",
       "regional",
       "https://github.com/Latvian-List/adblock-latvian",
       {"https://raw.githubusercontent.com/Latvian-List/adblock-latvian/master/lists/latvian-list.txt"},
       false,
       false,
       std::nullopt},
      {"mk",
       "Macedonian adBlock Filters",
       "regional",
       "https://github.com/DeepSpaceHarbor/Macedonian-adBlock-Filters",
       {"https://raw.githubusercontent.com/DeepSpaceHarbor/Macedonian-adBlock-Filters/master/Filters"},
       false,
       false,
       std::nullopt},
      {"dk",
       "AdGuard Dutch",
       "regional",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/8.txt"},
       false,
       false,
       std::nullopt},
      {"nodkice",
       "Dandelion Sprouts nordiske filtre (Norway/Denmark/Iceland)",
       "regional",
       "https://github.com/DandelionSprout/adfilt",
       {"https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianList.txt",
        "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianExperimentalList alternate versions/AntiAdblockEntries.txt",
        "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianExperimentalList alternate versions/NordicFilters-NotFirefox.txt",
        "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianExperimentalList alternate versions/NordicFilters-NotBrave.txt",
        "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/NorwegianExperimentalList alternate versions/AdditionalGenericEntriesForUBO.txt"},
       false,
       false,
       std::nullopt},
      {"ro",
       "Romanian Ad (ROad) Block List Light",
       "regional",
       "https://github.com/tcptomato/ROad-Block",
       {"https://raw.githubusercontent.com/tcptomato/ROad-Block/master/road-block-filters-light.txt",
        "https://raw.githubusercontent.com/tcptomato/ROad-Block/master/road-ubo.txt"},
       false,
       false,
       std::nullopt},
      {"se",
       "Frellwit's Swedish Filter",
       "regional",
       "https://github.com/lassekongo83/Frellwits-filter-lists",
       {"https://raw.githubusercontent.com/lassekongo83/Frellwits-filter-lists/master/Frellwits-Swedish-Filter.txt"},
       false,
       false,
       std::nullopt},
      {"slovenia",
       "Slovenian List",
       "regional",
       "https://github.com/betterwebleon/slovenian-list",
       {"https://raw.githubusercontent.com/betterwebleon/slovenian-list/master/filters.txt"},
       false,
       false,
       std::nullopt},
      {"th",
       "EasyList Thailand",
       "regional",
       "https://github.com/easylist-thailand/easylist-thailand",
       {"https://raw.githubusercontent.com/easylist-thailand/easylist-thailand/master/subscription/easylist-thailand.txt",
        "https://raw.githubusercontent.com/easylist-thailand/easylist-thailand/master/subscription/ublock.txt"},
       false,
       false,
       std::nullopt},
      {"tr",
       "AdGuard Turkish",
       "regional",
       "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
       {"https://filters.adtidy.org/extension/ublock/filters/13.txt"},
       false,
       false,
       std::nullopt},
      {"vn",
       "ABPVN List (Vietnamese)",
       "regional",
       "https://abpvn.com/",
       {"https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn_ublock.txt"},
       false,
       false,
       std::nullopt},
      {"BCNYBlocklists",
       "BCNY Blocklists",
       "bcny",
       "https://diabrowser.com",
       {},
       false,
       false,
       "No public upstream source. The reference lists are proprietary mirror-only additions."},
  };
}

}  // namespace

// Lightweight per-WebContents observer attached by EnsureTabHelper() that
// notifies OpenAdBlockProfileService observers whenever the tab's live
// blocked/redirected count changes (0% idle CPU, no polling timers).
class OpenAdBlockCountWatcher
    : public content::WebContentsUserData<OpenAdBlockCountWatcher>,
      public content::WebContentsObserver {
 public:
  static void EnsureForWebContents(content::WebContents* web_contents) {
    if (web_contents) {
      CreateForWebContents(web_contents);
    }
  }

  OpenAdBlockCountWatcher(const OpenAdBlockCountWatcher&) = delete;
  OpenAdBlockCountWatcher& operator=(const OpenAdBlockCountWatcher&) = delete;
  ~OpenAdBlockCountWatcher() override = default;

  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    if (navigation_handle && navigation_handle->IsInPrimaryMainFrame() &&
        navigation_handle->HasCommitted()) {
      MaybeNotify();
    }
  }

  void DidFinishLoad(content::RenderFrameHost* /*render_frame_host*/,
                     const GURL& /*validated_url*/) override {
    MaybeNotify();
  }

  void ResourceLoadComplete(
      content::RenderFrameHost* /*render_frame_host*/,
      const content::GlobalRequestID& /*request_id*/,
      const GURL& /*original_url*/,
      const blink::mojom::ResourceLoadInfo& /*resource_load_info*/) override {
    MaybeNotify();
  }

 private:
  explicit OpenAdBlockCountWatcher(content::WebContents* web_contents)
      : content::WebContentsUserData<OpenAdBlockCountWatcher>(*web_contents),
        content::WebContentsObserver(web_contents) {}
  friend class content::WebContentsUserData<OpenAdBlockCountWatcher>;

  void MaybeNotify() {
    content::WebContents* contents = web_contents();
    if (!contents) {
      return;
    }
    const int count = OpenAdBlockProfileService::GetTotalStoppedCount(contents);
    if (count != last_count_) {
      last_count_ = count;
      OpenAdBlockProfileService::NotifyTabBlockedCountChanged(contents, count);
    }
  }

  int last_count_ = 0;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(OpenAdBlockCountWatcher);

// --- Value types ---

AdBlockListReceipt::AdBlockListReceipt() = default;
AdBlockListReceipt::AdBlockListReceipt(const AdBlockListReceipt&) = default;
AdBlockListReceipt::AdBlockListReceipt(AdBlockListReceipt&&) noexcept = default;
AdBlockListReceipt& AdBlockListReceipt::operator=(const AdBlockListReceipt&) =
    default;
AdBlockListReceipt& AdBlockListReceipt::operator=(
    AdBlockListReceipt&&) noexcept = default;
AdBlockListReceipt::~AdBlockListReceipt() = default;

AdBlockProfileSnapshot::AdBlockProfileSnapshot() = default;
AdBlockProfileSnapshot::AdBlockProfileSnapshot(const AdBlockProfileSnapshot&) =
    default;
AdBlockProfileSnapshot::AdBlockProfileSnapshot(
    AdBlockProfileSnapshot&&) noexcept = default;
AdBlockProfileSnapshot& AdBlockProfileSnapshot::operator=(
    const AdBlockProfileSnapshot&) = default;
AdBlockProfileSnapshot& AdBlockProfileSnapshot::operator=(
    AdBlockProfileSnapshot&&) noexcept = default;
AdBlockProfileSnapshot::~AdBlockProfileSnapshot() = default;

struct OpenAdBlockProfileService::PendingListDownload {
  std::string list_id;
  std::vector<std::string> urls;
  size_t next_url_index = 0;
  std::vector<std::string> parts;
  std::string etag;
  std::string last_modified;
  bool any_not_modified = false;
  bool all_not_modified = true;
  std::string error;
};

struct OpenAdBlockProfileService::ListDownloadBatch {
  uint64_t batch_id = 0;
  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory;
  std::vector<PendingListDownload> items;
  size_t current_item_index = 0;
  std::unique_ptr<network::SimpleURLLoader> active_loader;
  bool any_succeeded = false;
  bool all_succeeded = true;
  std::string first_error;
  base::OnceCallback<void(bool)> done;
};

// static
const std::vector<AdBlockListInfo>& OpenAdBlockProfileService::GetCatalog() {
  static const base::NoDestructor<std::vector<AdBlockListInfo>> kCatalog(
      BuildBuiltinCatalog());
  return *kCatalog;
}

// static
const AdBlockListInfo* OpenAdBlockProfileService::FindCatalogList(
    std::string_view list_id) {
  for (const auto& item : GetCatalog()) {
    if (item.id == list_id) {
      return &item;
    }
  }
  return nullptr;
}

// static
base::FilePath OpenAdBlockProfileService::ResolveBundledResourcesDir() {
  if (!BundledDirOverrideForTesting().empty()) {
    return BundledDirOverrideForTesting();
  }

  if (auto env = base::Environment::Create()) {
    if (auto var = env->GetVar("OPEN_ADBLOCK_BUNDLED_DIR");
        var && !var->empty()) {
      base::FilePath env_dir = base::FilePath::FromUTF8Unsafe(*var);
      if (HasBundledAdBlockPayloads(env_dir)) {
        return env_dir;
      }
    }
  }

  std::vector<base::FilePath> candidates;

#if BUILDFLAG(IS_MAC)
  const base::FilePath outer_bundle = base::apple::OuterBundlePath();
  if (!outer_bundle.empty()) {
    candidates.push_back(outer_bundle.AppendASCII("Contents")
                             .AppendASCII("Resources")
                             .AppendASCII("adblock"));
    candidates.push_back(outer_bundle.AppendASCII("Contents")
                             .AppendASCII("Resources")
                             .AppendASCII("AdBlock"));
  }
  const base::FilePath framework_bundle = base::apple::FrameworkBundlePath();
  if (!framework_bundle.empty()) {
    candidates.push_back(
        framework_bundle.AppendASCII("Resources").AppendASCII("adblock"));
  }
#endif

  base::FilePath exe_dir;
  if (base::PathService::Get(base::DIR_EXE, &exe_dir) && !exe_dir.empty()) {
    candidates.push_back(exe_dir.AppendASCII("adblock_resources"));
    candidates.push_back(exe_dir.AppendASCII("adblock"));
    candidates.push_back(
        exe_dir.AppendASCII("resources").AppendASCII("adblock"));
#if BUILDFLAG(IS_MAC)
    candidates.push_back(
        exe_dir.DirName().AppendASCII("Resources").AppendASCII("adblock"));
    candidates.push_back(
        exe_dir.DirName().AppendASCII("Resources").AppendASCII("AdBlock"));
#endif
  }

  for (const base::FilePath& dir : candidates) {
    if (HasBundledAdBlockPayloads(dir)) {
      return dir;
    }
  }
  return base::FilePath();
}

// static
void OpenAdBlockProfileService::SetBundledResourcesDirForTesting(
    base::FilePath dir) {
  BundledDirOverrideForTesting() = std::move(dir);
}

// static
bool OpenAdBlockProfileService::IsPlausibleHost(std::string_view raw) {
  return NormalizeHost(raw).has_value();
}

// static
std::optional<std::string> OpenAdBlockProfileService::NormalizeExclusionDomain(
    std::string_view raw) {
  return NormalizeHost(raw);
}

// static
OpenAdBlockProfileService* OpenAdBlockProfileService::GetForBrowserContext(
    content::BrowserContext* context) {
  return OpenAdBlockProfileServiceFactory::GetForBrowserContext(context);
}

OpenAdBlockProfileService::DiskState::DiskState() = default;
OpenAdBlockProfileService::DiskState::DiskState(DiskState&&) noexcept = default;
OpenAdBlockProfileService::DiskState&
OpenAdBlockProfileService::DiskState::operator=(DiskState&&) noexcept = default;
OpenAdBlockProfileService::DiskState::~DiskState() = default;

OpenAdBlockProfileService::CompileInputs::CompileInputs() = default;
OpenAdBlockProfileService::CompileInputs::CompileInputs(
    CompileInputs&&) noexcept = default;
OpenAdBlockProfileService::CompileInputs&
OpenAdBlockProfileService::CompileInputs::operator=(
    CompileInputs&&) noexcept = default;
OpenAdBlockProfileService::CompileInputs::~CompileInputs() = default;

OpenAdBlockProfileService::OpenAdBlockProfileService(
    content::BrowserContext* browser_context)
    : browser_context_(browser_context),
      is_off_the_record_(browser_context && browser_context->IsOffTheRecord()),
      io_task_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN})) {
  // Default enabled lists match EasyList + EasyPrivacy.
  for (const auto& item : GetCatalog()) {
    if (item.default_enabled) {
      enabled_list_ids_.insert(item.id);
    }
  }

  base::FilePath profile_path =
      browser_context_ ? browser_context_->GetPath() : base::FilePath();
  if (!profile_path.empty()) {
    profile_id_ = profile_path.BaseName().AsUTF8Unsafe();
  }

  service_ = std::make_unique<open_engine::OpenAdBlockService>(profile_path);
  service_->SetRendererCacheInvalidator(base::BindRepeating(
      &OpenAdBlockProfileService::ClearRendererCachesForService,
      weak_factory_.GetWeakPtr()));
  service_->SetStatusCallback(
      base::BindRepeating(&OpenAdBlockProfileService::OnEngineStatusChanged,
                          base::Unretained(this)));

  adblock_dir_ = profile_path.AppendASCII("AdBlock");
  lists_dir_ = adblock_dir_.AppendASCII("lists");
  cache_dir_ = adblock_dir_.AppendASCII("cache");
  service_->SetEnabled(enabled_);
  ApplyExclusionsToEngine();
  if (!lists_dir_.empty()) {
    service_->SetListDirectory(lists_dir_);
  }
  InitializeFromDisk();
}

OpenAdBlockProfileService::~OpenAdBlockProfileService() {
  Shutdown();
}

void OpenAdBlockProfileService::Shutdown() {
  weak_factory_.InvalidateWeakPtrs();
  status_observer_.Reset();
  active_batch_.reset();
  is_updating_ = false;
  OpenAdBlockProfileServiceFactory::GetInstance()->UnregisterService(this);
  if (parent_service_) {
    parent_service_->RemoveOffTheRecordChild(this);
    parent_service_ = nullptr;
  }
  if (!otr_children_.empty()) {
    auto children = std::move(otr_children_);
    otr_children_.clear();
    for (OpenAdBlockProfileService* child : children) {
      if (child) {
        child->OnParentShutdown();
      }
    }
  }
  if (service_) {
    service_->Shutdown();
    service_.reset();
  }
  browser_context_ = nullptr;
}

void OpenAdBlockProfileService::SetProfileId(std::string profile_id) {
  profile_id_ = std::move(profile_id);
}

void OpenAdBlockProfileService::AddObserver(Observer* observer) {
  if (observer) {
    observers_.AddObserver(observer);
  }
}

void OpenAdBlockProfileService::RemoveObserver(Observer* observer) {
  if (observer) {
    observers_.RemoveObserver(observer);
  }
}

void OpenAdBlockProfileService::NotifyBlockedCountChanged(
    content::WebContents* web_contents,
    int count) {
  if (!web_contents) {
    return;
  }
  for (Observer& observer : observers_) {
    observer.OnAdBlockBlockedCountChanged(web_contents, count);
  }
}

// static
void OpenAdBlockProfileService::NotifyTabBlockedCountChanged(
    content::WebContents* web_contents,
    int count) {
  if (!web_contents) {
    return;
  }
  if (OpenAdBlockProfileService* service =
          GetForBrowserContext(web_contents->GetBrowserContext())) {
    service->NotifyBlockedCountChanged(web_contents, count);
  }
}

void OpenAdBlockProfileService::NotifyUpdated() {
  if (status_observer_) {
    status_observer_.Run(GetSnapshot());
  }
  for (Observer& observer : observers_) {
    observer.OnAdBlockStateChanged(profile_id_);
  }
}

void OpenAdBlockProfileService::BindOffTheRecordParent(
    OpenAdBlockProfileService* parent) {
  if (!parent || parent == this) {
    return;
  }
  if (parent_service_ && parent_service_ != parent) {
    parent_service_->RemoveOffTheRecordChild(this);
  }
  parent_service_ = parent;
  parent->AddOffTheRecordChild(this);
  InitializeFromParent(parent);
}

void OpenAdBlockProfileService::AddOffTheRecordChild(
    OpenAdBlockProfileService* child) {
  if (!child || child == this) {
    return;
  }
  if (std::find(otr_children_.begin(), otr_children_.end(), child) ==
      otr_children_.end()) {
    otr_children_.push_back(child);
  }
}

void OpenAdBlockProfileService::RemoveOffTheRecordChild(
    OpenAdBlockProfileService* child) {
  std::erase(otr_children_, child);
}

void OpenAdBlockProfileService::OnParentShutdown() {
  parent_service_ = nullptr;
}

void OpenAdBlockProfileService::OnParentEnabledChanged(bool enabled) {
  config_mutated_ = true;
  if (enabled_ == enabled) {
    return;
  }
  enabled_ = enabled;
  if (service_) {
    service_->SetEnabled(enabled_);
  }
  ResetURLLoaderFactories();
  NotifyUpdated();
}

void OpenAdBlockProfileService::OnParentEnabledListsChanged(
    const std::set<std::string>& enabled_lists) {
  config_mutated_ = true;
  if (enabled_list_ids_ == enabled_lists) {
    return;
  }
  enabled_list_ids_ = enabled_lists;
  NotifyUpdated();
}

void OpenAdBlockProfileService::OnParentExcludedDomainAdded(
    const std::string& domain) {
  exclusions_mutated_ = true;
  if (!excluded_domains_.insert(domain).second) {
    return;
  }
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  NotifyUpdated();
}

void OpenAdBlockProfileService::OnParentExcludedDomainRemoved(
    const std::string& domain) {
  exclusions_mutated_ = true;
  if (excluded_domains_.erase(domain) == 0) {
    return;
  }
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  NotifyUpdated();
}

void OpenAdBlockProfileService::OnParentExcludedDomainsReplaced(
    const std::set<std::string>& domains) {
  exclusions_mutated_ = true;
  excluded_domains_ = domains;
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  NotifyUpdated();
}

void OpenAdBlockProfileService::OnParentGenerationPublished() {
  if (service_ && !lists_dir_.empty()) {
    service_->LoadFromDirectory(lists_dir_, /*prefer_dat=*/true);
  }
}

void OpenAdBlockProfileService::InitializeFromParent(
    OpenAdBlockProfileService* parent) {
  // Share parent's list directory so OpenAdBlockEngineRegistry shares the
  // exact same immutable EngineHolder with zero extra memory or disk writes.
  bound_to_parent_ = true;
  config_mutated_ = true;
  exclusions_mutated_ = true;
  adblock_dir_ = parent->adblock_dir();
  lists_dir_ = parent->lists_dir();
  cache_dir_ = parent->cache_dir();
  enabled_ = parent->IsEnabled();
  auto parent_lists = parent->GetEnabledListIds();
  enabled_list_ids_.clear();
  enabled_list_ids_.insert(parent_lists.begin(), parent_lists.end());
  list_receipts_ = parent->GetListReceipts();
  auto parent_exclusions = parent->GetExcludedDomains();
  excluded_domains_.clear();
  excluded_domains_.insert(parent_exclusions.begin(), parent_exclusions.end());

  if (service_) {
    service_->SetEnabled(enabled_);
    ApplyExclusionsToEngine();
    if (!lists_dir_.empty()) {
      service_->SetListDirectory(lists_dir_);
    }
  }
}

void OpenAdBlockProfileService::InitializeFromDisk() {
  if (is_off_the_record_ || adblock_dir_.empty() || !io_task_runner_) {
    return;
  }
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&OpenAdBlockProfileService::ReadDiskStateOnBlockingSequence,
                     adblock_dir_, lists_dir_),
      base::BindOnce(&OpenAdBlockProfileService::OnDiskStateLoaded,
                     weak_factory_.GetWeakPtr()));
}

// static
OpenAdBlockProfileService::DiskState
OpenAdBlockProfileService::ReadDiskStateOnBlockingSequence(
    base::FilePath adblock_dir,
    base::FilePath lists_dir) {
  DiskState state;
  state.has_current_generation =
      !lists_dir.empty() &&
      base::PathExists(lists_dir.AppendASCII(kCurrentPointerName));

  // Load adblock-config.json (enabled flag, enabled list IDs, receipts).
  std::string raw_cfg;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII(kConfigFileName), &raw_cfg,
          kMaxConfigBytes)) {
    if (auto dict =
            base::JSONReader::ReadDict(raw_cfg, base::JSON_PARSE_RFC)) {
      state.has_config = true;
      state.enabled = dict->FindBool("enabled").value_or(true);
      if (const auto* lists = dict->FindList("enabledListIDs")) {
        state.has_enabled_lists = true;
        for (const auto& v : *lists) {
          if (v.is_string() && FindCatalogList(v.GetString())) {
            state.enabled_list_ids.insert(v.GetString());
          }
        }
      }
      if (const auto* receipts = dict->FindDict("receipts")) {
        for (const auto [key, value] : *receipts) {
          if (const auto* rd = value.GetIfDict()) {
            state.list_receipts[key] = ReceiptFromDict(key, *rd);
          }
        }
      }
    }
  }

  // Load optional custom-rules.txt.
  std::string raw_custom;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII(kCustomRulesFileName), &raw_custom,
          kMaxCustomRulesBytes)) {
    state.custom_rules = std::move(raw_custom);
  }

  // Load exclusions.json (JSON array of domain strings).
  std::string raw_excl;
  if (base::ReadFileToStringWithMaxSize(
          adblock_dir.AppendASCII(kExclusionsFileName), &raw_excl,
          kMaxConfigBytes)) {
    if (auto val = base::JSONReader::Read(raw_excl, base::JSON_PARSE_RFC);
        val && val->is_list()) {
      state.has_exclusions = true;
      for (const auto& item : val->GetList()) {
        if (!item.is_string()) {
          continue;
        }
        if (auto norm = NormalizeHost(item.GetString())) {
          state.excluded_domains.insert(*norm);
        }
      }
    }
  }
  return state;
}

void OpenAdBlockProfileService::OnDiskStateLoaded(DiskState state) {
  if (bound_to_parent_ || !service_) {
    return;
  }
  bool changed = false;
  if (!config_mutated_ && state.has_config) {
    enabled_ = state.enabled;
    if (state.has_enabled_lists) {
      enabled_list_ids_ = std::move(state.enabled_list_ids);
    }
    if (!state.list_receipts.empty()) {
      list_receipts_ = std::move(state.list_receipts);
    }
    service_->SetEnabled(enabled_);
    for (OpenAdBlockProfileService* child : otr_children_) {
      child->OnParentEnabledChanged(enabled_);
      child->OnParentEnabledListsChanged(enabled_list_ids_);
    }
    changed = true;
  }
  if (custom_rules_.empty() && !state.custom_rules.empty()) {
    custom_rules_ = std::move(state.custom_rules);
  }
  if (!exclusions_mutated_ && state.has_exclusions) {
    excluded_domains_ = std::move(state.excluded_domains);
    ApplyExclusionsToEngine();
    for (OpenAdBlockProfileService* child : otr_children_) {
      child->OnParentExcludedDomainsReplaced(excluded_domains_);
    }
    changed = true;
  }
  if (changed) {
    NotifyUpdated();
  }

  // Fresh install / missing generation: seed bundled filter lists (EasyList,
  // EasyPrivacy, resources.json) into the profile cache, compile off-thread,
  // and publish generation 1 automatically so real ads are blocked out of the
  // box without requiring any manual Settings action.
  if (!state.has_current_generation && !is_off_the_record_ &&
      compile_seq_ == 0) {
    RecompileEnabledLists(/*force_reseed_bundled=*/false,
                          /*wipe_cache_first=*/false,
                          /*auto_download_missing=*/true);
  }
}

// static
OpenAdBlockProfileService::CompileInputs
OpenAdBlockProfileService::PrepareCompileInputsOnBlockingSequence(
    base::FilePath cache_dir,
    base::FilePath bundled_dir,
    std::vector<std::string> enabled_list_ids,
    std::map<std::string, AdBlockListReceipt> existing_receipts,
    std::string custom_rules,
    bool force_reseed_bundled,
    bool wipe_cache_first) {
  CompileInputs out;
  if (wipe_cache_first && !cache_dir.empty()) {
    base::DeletePathRecursively(cache_dir);
  }
  if (!cache_dir.empty()) {
    base::CreateDirectory(cache_dir);
  }

  // Seed / read resources.json (uBlock Origin redirect stubs).
  const base::FilePath cached_resources =
      cache_dir.AppendASCII(kResourcesFileName);
  const base::FilePath bundled_resources =
      bundled_dir.empty() ? base::FilePath()
                          : bundled_dir.AppendASCII(kResourcesFileName);
  if ((force_reseed_bundled || !base::PathExists(cached_resources)) &&
      !bundled_resources.empty() && base::PathExists(bundled_resources)) {
    std::string res_bytes;
    if (base::ReadFileToStringWithMaxSize(bundled_resources, &res_bytes,
                                          kMaxResourcesBytes) &&
        !res_bytes.empty()) {
      base::ImportantFileWriter::WriteFileAtomically(cached_resources,
                                                     res_bytes);
      out.resources_json = std::move(res_bytes);
    }
  }
  if (out.resources_json.empty() && base::PathExists(cached_resources)) {
    base::ReadFileToStringWithMaxSize(cached_resources, &out.resources_json,
                                      kMaxResourcesBytes);
  }
  if (out.resources_json.empty() && !bundled_resources.empty() &&
      base::PathExists(bundled_resources)) {
    base::ReadFileToStringWithMaxSize(bundled_resources, &out.resources_json,
                                      kMaxResourcesBytes);
  }

  const int64_t now_ms = NowMs();

  for (const std::string& list_id : enabled_list_ids) {
    const AdBlockListInfo* info = FindCatalogList(list_id);
    if (!info || info->unavailable_reason.has_value()) {
      continue;
    }

    const base::FilePath cached_path = cache_dir.AppendASCII(list_id + ".txt");
    std::string text;
    bool seeded_from_bundle = false;

    const bool can_use_cache =
        !force_reseed_bundled && base::PathExists(cached_path);
    if (can_use_cache) {
      base::ReadFileToStringWithMaxSize(cached_path, &text, kMaxListBytes);
    }

    if (text.empty() && info->bundled && !bundled_dir.empty()) {
      const base::FilePath bundled_path =
          bundled_dir.AppendASCII(BundledFileNameForList(list_id));
      if (base::PathExists(bundled_path) &&
          base::ReadFileToStringWithMaxSize(bundled_path, &text,
                                            kMaxListBytes) &&
          !text.empty()) {
        seeded_from_bundle = true;
        if (!cache_dir.empty()) {
          base::ImportantFileWriter::WriteFileAtomically(cached_path, text);
        }
      }
    }

    if (text.empty()) {
      out.missing_list_ids.push_back(list_id);
      continue;
    }

    AdBlockListReceipt receipt;
    auto existing_it = existing_receipts.find(list_id);
    if (!seeded_from_bundle && existing_it != existing_receipts.end()) {
      receipt = existing_it->second;
      receipt.list_id = list_id;
      if (receipt.source.empty()) {
        receipt.source = info->bundled ? "bundled" : "downloaded";
      }
      if (receipt.rule_count <= 0) {
        receipt.rule_count = CountFilterRules(text);
      }
      if (receipt.bytes <= 0) {
        receipt.bytes = static_cast<int64_t>(text.size());
      }
      if (receipt.sha256.empty()) {
        receipt.sha256 = Sha256HexLower(text);
      }
      if (receipt.last_updated_ms <= 0) {
        receipt.last_updated_ms = now_ms;
      }
    } else {
      receipt.list_id = list_id;
      receipt.source = seeded_from_bundle ? "bundled" : "downloaded";
      receipt.last_updated_ms = now_ms;
      receipt.rule_count = CountFilterRules(text);
      receipt.bytes = static_cast<int64_t>(text.size());
      receipt.sha256 = Sha256HexLower(text);
      receipt.last_error.clear();
    }
    out.updated_receipts[list_id] = std::move(receipt);
    out.list_id_and_text.emplace_back(list_id, std::move(text));
  }

  std::string trimmed_custom =
      std::string(base::TrimWhitespaceASCII(custom_rules, base::TRIM_ALL));
  if (!trimmed_custom.empty()) {
    out.list_id_and_text.emplace_back(kCustomRulesListId,
                                      std::move(trimmed_custom));
  }

  return out;
}

void OpenAdBlockProfileService::RecompileEnabledLists(
    bool force_reseed_bundled,
    bool wipe_cache_first,
    bool auto_download_missing,
    base::OnceCallback<void(bool)> done) {
  if (is_off_the_record_ || lists_dir_.empty() || !io_task_runner_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  const uint64_t seq = ++compile_seq_;
  std::vector<std::string> enabled_ids(enabled_list_ids_.begin(),
                                       enabled_list_ids_.end());
  const base::FilePath bundled_dir = ResolveBundledResourcesDir();
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          &OpenAdBlockProfileService::PrepareCompileInputsOnBlockingSequence,
          cache_dir_, bundled_dir, std::move(enabled_ids), list_receipts_,
          custom_rules_, force_reseed_bundled, wipe_cache_first),
      base::BindOnce(&OpenAdBlockProfileService::OnCompileInputsPrepared,
                     weak_factory_.GetWeakPtr(), seq, auto_download_missing,
                     std::move(done)));
}

void OpenAdBlockProfileService::OnCompileInputsPrepared(
    uint64_t compile_seq,
    bool auto_download_missing,
    base::OnceCallback<void(bool)> done,
    CompileInputs inputs) {
  if (compile_seq != compile_seq_ || !service_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }

  for (auto& [id, receipt] : inputs.updated_receipts) {
    list_receipts_[id] = std::move(receipt);
  }
  SaveConfigToDisk();

  // If any newly enabled non-bundled list isn't in cache yet, kick off an
  // automatic background download (if a URLLoaderFactory is available) while
  // still publishing everything we already have locally right now.
  std::vector<std::string> to_download;
  if (auto_download_missing && !inputs.missing_list_ids.empty()) {
    for (const std::string& missing_id : inputs.missing_list_ids) {
      if (const AdBlockListInfo* info = FindCatalogList(missing_id);
          info && !info->urls.empty() && !info->unavailable_reason.has_value()) {
        to_download.push_back(missing_id);
      }
    }
  }

  // Publish the compiled generation (including verified empty generation when
  // all lists are disabled) unless we have zero local inputs and are about to
  // download them.
  const bool have_anything_to_publish =
      !inputs.list_id_and_text.empty() || enabled_list_ids_.empty();
  if (have_anything_to_publish) {
    PublishGeneration(inputs.list_id_and_text, inputs.resources_json,
                      to_download.empty() ? std::move(done)
                                          : base::OnceCallback<void(bool)>());
  }

  if (!to_download.empty()) {
    if (auto factory = GetDefaultURLLoaderFactory()) {
      DownloadSpecificLists(std::move(to_download), std::move(factory),
                            std::move(done));
      return;
    }
  }

  if (!have_anything_to_publish) {
    NotifyUpdated();
    if (done) {
      std::move(done).Run(false);
    }
  }
}

scoped_refptr<network::SharedURLLoaderFactory>
OpenAdBlockProfileService::GetDefaultURLLoaderFactory() const {
  if (!browser_context_ || browser_context_->ShutdownStarted()) {
    return nullptr;
  }
  content::StoragePartition* partition =
      browser_context_->GetDefaultStoragePartition();
  return partition ? partition->GetURLLoaderFactoryForBrowserProcess()
                   : nullptr;
}

void OpenAdBlockProfileService::SetCustomRules(
    std::string rules,
    base::OnceCallback<void(bool)> done) {
  if (is_off_the_record_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  if (rules.size() > kMaxCustomRulesBytes) {
    rules.resize(kMaxCustomRulesBytes);
  }
  custom_rules_ = std::move(rules);
  if (!adblock_dir_.empty() && io_task_runner_) {
    io_task_runner_->PostTask(
        FROM_HERE,
        base::BindOnce(&WriteAtomicFileOnBlockingSequence, adblock_dir_,
                       std::string(kCustomRulesFileName), custom_rules_));
  }
  RecompileEnabledLists(/*force_reseed_bundled=*/false,
                        /*wipe_cache_first=*/false,
                        /*auto_download_missing=*/false, std::move(done));
}

void OpenAdBlockProfileService::UpdateListsNow(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
    base::OnceCallback<void(bool)> done) {
  if (is_off_the_record_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  if (!url_loader_factory) {
    url_loader_factory = GetDefaultURLLoaderFactory();
  }
  if (!url_loader_factory) {
    last_error_ = "No network loader factory available for list update.";
    NotifyUpdated();
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }

  std::vector<std::string> targets;
  for (const std::string& id : enabled_list_ids_) {
    const AdBlockListInfo* info = FindCatalogList(id);
    if (info && !info->urls.empty() && !info->unavailable_reason.has_value()) {
      targets.push_back(id);
    }
  }
  if (targets.empty()) {
    RecompileEnabledLists(/*force_reseed_bundled=*/false,
                          /*wipe_cache_first=*/false,
                          /*auto_download_missing=*/false, std::move(done));
    return;
  }
  DownloadSpecificLists(std::move(targets), std::move(url_loader_factory),
                        std::move(done));
}

void OpenAdBlockProfileService::DownloadSpecificLists(
    std::vector<std::string> list_ids,
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory,
    base::OnceCallback<void(bool)> done) {
  if (!url_loader_factory || list_ids.empty() || is_off_the_record_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }

  // Supersede any previous in-flight batch cleanly.
  if (active_batch_ && active_batch_->done) {
    std::move(active_batch_->done).Run(false);
  }
  active_batch_.reset();

  auto batch = std::make_unique<ListDownloadBatch>();
  batch->batch_id = ++active_batch_id_;
  batch->url_loader_factory = std::move(url_loader_factory);
  batch->done = std::move(done);

  for (const std::string& list_id : list_ids) {
    const AdBlockListInfo* info = FindCatalogList(list_id);
    if (!info || info->urls.empty() || info->unavailable_reason.has_value()) {
      continue;
    }
    PendingListDownload item;
    item.list_id = info->id;
    item.urls = info->urls;
    item.parts.resize(info->urls.size());
    if (auto it = list_receipts_.find(info->id);
        it != list_receipts_.end() && info->urls.size() == 1) {
      item.etag = it->second.etag;
      item.last_modified = it->second.last_modified;
    }
    batch->items.push_back(std::move(item));
  }

  if (batch->items.empty()) {
    if (batch->done) {
      std::move(batch->done).Run(false);
    }
    return;
  }

  const uint64_t batch_id = batch->batch_id;
  active_batch_ = std::move(batch);
  is_updating_ = true;
  last_error_.clear();
  NotifyUpdated();
  StartNextUrlInBatch(batch_id);
}

void OpenAdBlockProfileService::StartNextUrlInBatch(uint64_t batch_id) {
  if (!active_batch_ || active_batch_->batch_id != batch_id) {
    return;
  }

  while (active_batch_->current_item_index < active_batch_->items.size()) {
    PendingListDownload& item =
        active_batch_->items[active_batch_->current_item_index];
    if (!item.error.empty() || item.next_url_index >= item.urls.size()) {
      FinalizeListDownloadInBatch(batch_id, item.list_id);
      return;
    }

    const size_t url_idx = item.next_url_index;
    const GURL url(item.urls[url_idx]);
    if (!url.is_valid() || !url.SchemeIs(url::kHttpsScheme)) {
      item.error = "Refused non-HTTPS filter list URL";
      FinalizeListDownloadInBatch(batch_id, item.list_id);
      return;
    }

    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url;
    request->method = "GET";
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->headers.SetHeader("User-Agent", "Open/1 AdBlock");
    if (item.urls.size() == 1) {
      if (!item.etag.empty()) {
        request->headers.SetHeader("If-None-Match", item.etag);
      } else if (!item.last_modified.empty()) {
        request->headers.SetHeader("If-Modified-Since", item.last_modified);
      }
    }

    auto loader = network::SimpleURLLoader::Create(
        std::move(request), kOpenAdBlockListTrafficAnnotation);
    loader->SetAllowHttpErrorResults(true);
    loader->SetTimeoutDuration(base::Seconds(30));
    loader->SetRetryOptions(
        2, network::SimpleURLLoader::RETRY_ON_5XX |
               network::SimpleURLLoader::RETRY_ON_NETWORK_CHANGE);

    network::SimpleURLLoader* raw_loader = loader.get();
    active_batch_->active_loader = std::move(loader);
    raw_loader->DownloadToTempFile(
        active_batch_->url_loader_factory.get(),
        base::BindOnce(&OpenAdBlockProfileService::OnSingleUrlDownloaded,
                       weak_factory_.GetWeakPtr(), batch_id, item.list_id,
                       url_idx),
        kMaxSourceBytes);
    return;
  }

  FinishDownloadBatch(batch_id);
}

void OpenAdBlockProfileService::OnSingleUrlDownloaded(uint64_t batch_id,
                                                      std::string list_id,
                                                      size_t url_index,
                                                      base::FilePath temp_file) {
  if (!active_batch_ || active_batch_->batch_id != batch_id) {
    if (!temp_file.empty() && io_task_runner_) {
      io_task_runner_->PostTask(
          FROM_HERE, base::BindOnce(base::IgnoreResult(&base::DeleteFile),
                                    std::move(temp_file)));
    }
    return;
  }

  std::unique_ptr<network::SimpleURLLoader> loader =
      std::move(active_batch_->active_loader);
  const int net_error = loader ? loader->NetError() : net::ERR_FAILED;
  int status_code = 0;
  std::string etag;
  std::string last_modified;
  if (loader && loader->ResponseInfo() && loader->ResponseInfo()->headers) {
    const auto& headers = loader->ResponseInfo()->headers;
    status_code = headers->response_code();
    if (auto v = headers->GetNormalizedHeader("ETag")) {
      etag = *v;
    }
    if (auto v = headers->GetNormalizedHeader("Last-Modified")) {
      last_modified = *v;
    }
  }

  if (status_code == 304) {
    if (!temp_file.empty() && io_task_runner_) {
      io_task_runner_->PostTask(
          FROM_HERE, base::BindOnce(base::IgnoreResult(&base::DeleteFile),
                                    std::move(temp_file)));
    }
    OnDownloadedPartProcessed(batch_id, std::move(list_id), url_index,
                              std::nullopt, std::move(etag),
                              std::move(last_modified), /*not_modified=*/true,
                              /*error=*/std::string());
    return;
  }

  if (net_error != net::OK || status_code != 200 || temp_file.empty()) {
    if (!temp_file.empty() && io_task_runner_) {
      io_task_runner_->PostTask(
          FROM_HERE, base::BindOnce(base::IgnoreResult(&base::DeleteFile),
                                    std::move(temp_file)));
    }
    std::string err = status_code > 0
                          ? "HTTP " + base::NumberToString(status_code)
                          : "Network error (" +
                                base::NumberToString(net_error) + ")";
    OnDownloadedPartProcessed(batch_id, std::move(list_id), url_index,
                              std::nullopt, std::string(), std::string(),
                              /*not_modified=*/false, std::move(err));
    return;
  }

  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ReadAndDeleteTempFileOnBlockingSequence,
                     std::move(temp_file)),
      base::BindOnce(
          [](base::WeakPtr<OpenAdBlockProfileService> self, uint64_t batch_id,
             std::string list_id, size_t url_index, std::string etag,
             std::string last_modified, std::optional<std::string> body) {
            if (!self) {
              return;
            }
            if (!body || body->empty()) {
              self->OnDownloadedPartProcessed(
                  batch_id, std::move(list_id), url_index, std::nullopt,
                  std::string(), std::string(), /*not_modified=*/false,
                  "Downloaded filter list was empty or exceeded 16 MiB");
              return;
            }
            if (LooksLikeHtmlErrorPage(*body)) {
              self->OnDownloadedPartProcessed(
                  batch_id, std::move(list_id), url_index, std::nullopt,
                  std::string(), std::string(), /*not_modified=*/false,
                  "Upstream returned HTML instead of filter rules");
              return;
            }
            self->OnDownloadedPartProcessed(
                batch_id, std::move(list_id), url_index, std::move(body),
                std::move(etag), std::move(last_modified),
                /*not_modified=*/false, std::string());
          },
          weak_factory_.GetWeakPtr(), batch_id, std::move(list_id), url_index,
          std::move(etag), std::move(last_modified)));
}

void OpenAdBlockProfileService::OnDownloadedPartProcessed(
    uint64_t batch_id,
    std::string list_id,
    size_t url_index,
    std::optional<std::string> body,
    std::string etag,
    std::string last_modified,
    bool not_modified,
    std::string error) {
  if (!active_batch_ || active_batch_->batch_id != batch_id ||
      active_batch_->current_item_index >= active_batch_->items.size()) {
    return;
  }

  PendingListDownload& item =
      active_batch_->items[active_batch_->current_item_index];
  if (item.list_id != list_id || url_index >= item.parts.size()) {
    return;
  }

  if (!error.empty()) {
    item.error = std::move(error);
    FinalizeListDownloadInBatch(batch_id, list_id);
    return;
  }

  if (not_modified) {
    item.any_not_modified = true;
    if (!etag.empty()) item.etag = std::move(etag);
    if (!last_modified.empty()) item.last_modified = std::move(last_modified);
  } else {
    item.all_not_modified = false;
    item.parts[url_index] = std::move(*body);
    if (item.urls.size() == 1) {
      item.etag = std::move(etag);
      item.last_modified = std::move(last_modified);
    }
  }
  item.next_url_index = url_index + 1;
  StartNextUrlInBatch(batch_id);
}

void OpenAdBlockProfileService::FinalizeListDownloadInBatch(
    uint64_t batch_id,
    const std::string& list_id) {
  if (!active_batch_ || active_batch_->batch_id != batch_id ||
      active_batch_->current_item_index >= active_batch_->items.size()) {
    return;
  }

  PendingListDownload& item =
      active_batch_->items[active_batch_->current_item_index];
  if (!item.error.empty()) {
    active_batch_->all_succeeded = false;
    if (active_batch_->first_error.empty()) {
      active_batch_->first_error = list_id + ": " + item.error;
    }
    AdBlockListReceipt& receipt = list_receipts_[list_id];
    receipt.list_id = list_id;
    receipt.last_error = item.error;
    ++active_batch_->current_item_index;
    StartNextUrlInBatch(batch_id);
    return;
  }

  if (item.all_not_modified && item.any_not_modified) {
    active_batch_->any_succeeded = true;
    AdBlockListReceipt& receipt = list_receipts_[list_id];
    receipt.list_id = list_id;
    if (receipt.source.empty()) {
      receipt.source = "downloaded";
    }
    receipt.last_updated_ms = NowMs();
    if (!item.etag.empty()) receipt.etag = item.etag;
    if (!item.last_modified.empty()) receipt.last_modified = item.last_modified;
    receipt.last_error.clear();
    ++active_batch_->current_item_index;
    StartNextUrlInBatch(batch_id);
    return;
  }

  std::string combined;
  for (size_t i = 0; i < item.parts.size(); ++i) {
    if (i > 0 && !combined.empty() && !item.parts[i].empty()) {
      combined.push_back('\n');
    }
    if (combined.size() + item.parts[i].size() > kMaxListBytes) {
      item.error = "Combined filter list exceeded 64 MiB";
      FinalizeListDownloadInBatch(batch_id, list_id);
      return;
    }
    combined.append(item.parts[i]);
  }

  AdBlockListReceipt receipt;
  receipt.list_id = list_id;
  receipt.source = "downloaded";
  receipt.last_updated_ms = NowMs();
  receipt.rule_count = CountFilterRules(combined);
  receipt.bytes = static_cast<int64_t>(combined.size());
  receipt.sha256 = Sha256HexLower(combined);
  receipt.etag = item.etag;
  receipt.last_modified = item.last_modified;
  receipt.last_error.clear();

  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&WriteListCacheOnBlockingSequence, cache_dir_, list_id,
                     std::move(combined)),
      base::BindOnce(&OpenAdBlockProfileService::OnListCacheWritten,
                     weak_factory_.GetWeakPtr(), batch_id, list_id,
                     std::move(receipt)));
}

void OpenAdBlockProfileService::OnListCacheWritten(uint64_t batch_id,
                                                   std::string list_id,
                                                   AdBlockListReceipt receipt,
                                                   bool ok) {
  if (!active_batch_ || active_batch_->batch_id != batch_id) {
    return;
  }
  if (ok) {
    active_batch_->any_succeeded = true;
    list_receipts_[list_id] = std::move(receipt);
  } else {
    active_batch_->all_succeeded = false;
    const std::string err = "Failed to write cached list file";
    if (active_batch_->first_error.empty()) {
      active_batch_->first_error = list_id + ": " + err;
    }
    AdBlockListReceipt& existing = list_receipts_[list_id];
    existing.list_id = list_id;
    existing.last_error = err;
  }
  ++active_batch_->current_item_index;
  StartNextUrlInBatch(batch_id);
}

void OpenAdBlockProfileService::FinishDownloadBatch(uint64_t batch_id) {
  if (!active_batch_ || active_batch_->batch_id != batch_id) {
    return;
  }
  std::unique_ptr<ListDownloadBatch> batch = std::move(active_batch_);
  is_updating_ = false;
  last_error_ = batch->all_succeeded ? std::string() : batch->first_error;
  SaveConfigToDisk();

  if (batch->any_succeeded) {
    RecompileEnabledLists(/*force_reseed_bundled=*/false,
                          /*wipe_cache_first=*/false,
                          /*auto_download_missing=*/false,
                          std::move(batch->done));
  } else {
    NotifyUpdated();
    if (batch->done) {
      std::move(batch->done).Run(false);
    }
  }
}

void OpenAdBlockProfileService::ResetLists(base::OnceCallback<void(bool)> done) {
  if (is_off_the_record_) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }

  if (active_batch_ && active_batch_->done) {
    std::move(active_batch_->done).Run(false);
  }
  active_batch_.reset();
  is_updating_ = false;
  last_error_.clear();

  config_mutated_ = true;
  enabled_list_ids_.clear();
  for (const auto& item : GetCatalog()) {
    if (item.default_enabled) {
      enabled_list_ids_.insert(item.id);
    }
  }
  list_receipts_.clear();
  custom_rules_.clear();
  if (!adblock_dir_.empty() && io_task_runner_) {
    io_task_runner_->PostTask(
        FROM_HERE,
        base::BindOnce(base::IgnoreResult(&base::DeleteFile),
                       adblock_dir_.AppendASCII(kCustomRulesFileName)));
  }

  SaveConfigToDisk();
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentEnabledListsChanged(enabled_list_ids_);
  }
  NotifyUpdated();

  RecompileEnabledLists(/*force_reseed_bundled=*/true,
                        /*wipe_cache_first=*/true,
                        /*auto_download_missing=*/false, std::move(done));
}

void OpenAdBlockProfileService::ExposeInterfacesToRenderer(
    service_manager::BinderRegistry* registry) {
  if (service_ && registry) {
    open_engine::ExposeAdBlockInterfacesToRenderer(registry, service_.get());
  }
}

void OpenAdBlockProfileService::SetEnabled(bool enabled) {
  config_mutated_ = true;
  if (enabled_ == enabled) {
    return;
  }
  enabled_ = enabled;
  if (!is_off_the_record_) {
    SaveConfigToDisk();
  }
  if (service_) {
    service_->SetEnabled(enabled_);
  }
  ResetURLLoaderFactories();
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentEnabledChanged(enabled_);
  }
  NotifyUpdated();
}

bool OpenAdBlockProfileService::IsEnabled() const {
  return enabled_ && service_ && service_->IsEnabled();
}

std::vector<std::string> OpenAdBlockProfileService::GetEnabledListIds() const {
  return std::vector<std::string>(enabled_list_ids_.begin(),
                                  enabled_list_ids_.end());
}

std::optional<AdBlockListReceipt> OpenAdBlockProfileService::GetListReceipt(
    std::string_view list_id) const {
  auto it = list_receipts_.find(std::string(list_id));
  if (it == list_receipts_.end()) {
    return std::nullopt;
  }
  return it->second;
}

bool OpenAdBlockProfileService::SetListEnabled(std::string_view list_id,
                                               bool enabled) {
  const AdBlockListInfo* info = FindCatalogList(list_id);
  if (!info || info->unavailable_reason.has_value()) {
    return false;
  }
  config_mutated_ = true;
  bool changed = false;
  if (enabled) {
    changed = enabled_list_ids_.insert(info->id).second;
  } else {
    changed = enabled_list_ids_.erase(info->id) > 0;
  }
  if (!changed) {
    return true;
  }
  if (!is_off_the_record_) {
    SaveConfigToDisk();
  }
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentEnabledListsChanged(enabled_list_ids_);
  }
  NotifyUpdated();
  if (!is_off_the_record_) {
    RecompileEnabledLists(/*force_reseed_bundled=*/false,
                          /*wipe_cache_first=*/false,
                          /*auto_download_missing=*/enabled);
  }
  return true;
}

void OpenAdBlockProfileService::SetEnabledListIds(
    std::vector<std::string> list_ids) {
  config_mutated_ = true;
  std::set<std::string> next;
  for (const auto& id : list_ids) {
    const AdBlockListInfo* info = FindCatalogList(id);
    if (info && !info->unavailable_reason.has_value()) {
      next.insert(info->id);
    }
  }
  if (next == enabled_list_ids_) {
    return;
  }
  enabled_list_ids_ = std::move(next);
  if (!is_off_the_record_) {
    SaveConfigToDisk();
  }
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentEnabledListsChanged(enabled_list_ids_);
  }
  NotifyUpdated();
  if (!is_off_the_record_) {
    RecompileEnabledLists(/*force_reseed_bundled=*/false,
                          /*wipe_cache_first=*/false,
                          /*auto_download_missing=*/true);
  }
}

std::vector<std::string> OpenAdBlockProfileService::GetExcludedDomains() const {
  return std::vector<std::string>(excluded_domains_.begin(),
                                  excluded_domains_.end());
}

bool OpenAdBlockProfileService::IsHostExcluded(std::string_view host) const {
  if (!service_) {
    return false;
  }
  auto norm = NormalizeHost(host);
  return norm ? service_->IsExcludedOnUi(*norm) : false;
}

bool OpenAdBlockProfileService::AddExcludedDomain(std::string_view domain) {
  auto norm = NormalizeHost(domain);
  if (!norm) {
    return false;
  }
  exclusions_mutated_ = true;
  if (!excluded_domains_.insert(*norm).second) {
    return true;
  }
  if (!is_off_the_record_) {
    SaveExclusionsToDisk();
  }
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentExcludedDomainAdded(*norm);
  }
  NotifyUpdated();
  return true;
}

bool OpenAdBlockProfileService::RemoveExcludedDomain(std::string_view domain) {
  auto norm = NormalizeHost(domain);
  if (!norm) {
    return false;
  }
  exclusions_mutated_ = true;
  if (excluded_domains_.erase(*norm) == 0) {
    return false;
  }
  if (!is_off_the_record_) {
    SaveExclusionsToDisk();
  }
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentExcludedDomainRemoved(*norm);
  }
  NotifyUpdated();
  return true;
}

void OpenAdBlockProfileService::SetExcludedDomains(
    std::vector<std::string> domains) {
  exclusions_mutated_ = true;
  std::set<std::string> next;
  for (const auto& d : domains) {
    if (auto norm = NormalizeHost(d)) {
      next.insert(*norm);
    }
  }
  excluded_domains_ = std::move(next);
  if (!is_off_the_record_) {
    SaveExclusionsToDisk();
  }
  ApplyExclusionsToEngine();
  ResetURLLoaderFactories();
  for (OpenAdBlockProfileService* child : otr_children_) {
    child->OnParentExcludedDomainsReplaced(excluded_domains_);
  }
  NotifyUpdated();
}

void OpenAdBlockProfileService::ReloadLists(
    base::OnceCallback<void(open_engine::AdBlockLoadResult)> done) {
  if (!service_ || lists_dir_.empty() || !io_task_runner_) {
    if (done) {
      std::move(done).Run(open_engine::AdBlockLoadResult::kCancelled);
    }
    return;
  }
  // Hop through the sequenced MayBlock runner so any pending PublishGeneration
  // write completes and current.json is checked off the UI thread before load.
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&HasCurrentGenerationOnBlockingSequence, lists_dir_),
      base::BindOnce(&OpenAdBlockProfileService::OnReloadListsReply,
                     weak_factory_.GetWeakPtr(), std::move(done)));
}

bool OpenAdBlockProfileService::PublishGeneration(
    const std::vector<std::pair<std::string, std::string>>& list_id_and_text,
    std::string_view resources_json,
    base::OnceCallback<void(bool)> done) {
  if (is_off_the_record_ || lists_dir_.empty() || !io_task_runner_) {
    if (done) {
      std::move(done).Run(false);
    }
    return false;
  }
  // Supersede any in-flight RecompileEnabledLists() so an older background
  // compile cannot later overwrite this newly published generation.
  ++compile_seq_;
  io_task_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&WriteGenerationOnBlockingSequence, lists_dir_,
                     list_id_and_text, std::string(resources_json)),
      base::BindOnce(&OpenAdBlockProfileService::OnGenerationPublishedReply,
                     weak_factory_.GetWeakPtr(), std::move(done)));
  return true;
}

// static
void OpenAdBlockProfileService::OnGenerationPublishedReply(
    base::WeakPtr<OpenAdBlockProfileService> self,
    base::OnceCallback<void(bool)> done,
    bool ok) {
  if (!self) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  if (ok && self->service_ && !self->lists_dir_.empty()) {
    self->service_->LoadFromDirectory(self->lists_dir_, /*prefer_dat=*/true);
    for (OpenAdBlockProfileService* child : self->otr_children_) {
      child->OnParentGenerationPublished();
    }
    self->NotifyUpdated();
  }
  if (done) {
    std::move(done).Run(ok);
  }
}

// static
void OpenAdBlockProfileService::OnReloadListsReply(
    base::WeakPtr<OpenAdBlockProfileService> self,
    base::OnceCallback<void(open_engine::AdBlockLoadResult)> done,
    bool /*has_current*/) {
  if (!self || !self->service_ || self->lists_dir_.empty()) {
    if (done) {
      std::move(done).Run(open_engine::AdBlockLoadResult::kCancelled);
    }
    return;
  }
  self->service_->LoadFromDirectory(self->lists_dir_, /*prefer_dat=*/true,
                                    std::move(done));
}

// static
int OpenAdBlockProfileService::ClearRendererCachesForService(
    base::WeakPtr<OpenAdBlockProfileService> self) {
  if (!self) {
    return 0;
  }
  return self->ClearRendererCachesOnNavigation();
}

int OpenAdBlockProfileService::ClearRendererCachesOnNavigation() const {
  if (!browser_context_ || browser_context_->ShutdownStarted()) {
    return 0;
  }
  auto* cache = web_cache::WebCacheManager::GetInstance();
  if (!cache) {
    return 0;
  }
  const base::FilePath owner_path = browser_context_->GetPath();
  int requested = 0;
  for (auto hosts = content::RenderProcessHost::AllHostsIterator();
       !hosts.IsAtEnd(); hosts.Advance()) {
    auto* process = hosts.GetCurrentValue();
    auto* candidate = process ? process->GetBrowserContext() : nullptr;
    if (!candidate || candidate->ShutdownStarted()) {
      continue;
    }
    bool matches = (candidate == browser_context_);
    if (!matches && !is_off_the_record_ && candidate->IsOffTheRecord() &&
        !owner_path.empty() && candidate->GetPath() == owner_path) {
      matches = true;
    }
    if (matches && cache->ClearCacheForProcessOnNavigation(process->GetID())) {
      ++requested;
    }
  }
  return requested;
}

void OpenAdBlockProfileService::ResetURLLoaderFactories() {
  if (!browser_context_) {
    return;
  }
  browser_context_->ForEachLoadedStoragePartition(
      [](content::StoragePartition* partition) {
        if (partition) {
          partition->ResetURLLoaderFactories();
        }
      });
}

// static
void OpenAdBlockProfileService::EnsureTabHelper(
    content::WebContents* web_contents) {
  if (web_contents) {
    open_engine::OpenAdBlockTabHelper::GetOrCreate(web_contents);
    OpenAdBlockCountWatcher::EnsureForWebContents(web_contents);
  }
}

// static
int OpenAdBlockProfileService::GetBlockedCount(
    content::WebContents* web_contents) {
  if (!web_contents) return 0;
  auto* helper =
      open_engine::OpenAdBlockTabHelper::FromWebContents(web_contents);
  return helper ? helper->blocked_count() : 0;
}

// static
int OpenAdBlockProfileService::GetRedirectedCount(
    content::WebContents* web_contents) {
  if (!web_contents) return 0;
  auto* helper =
      open_engine::OpenAdBlockTabHelper::FromWebContents(web_contents);
  return helper ? helper->redirected_count() : 0;
}

// static
int OpenAdBlockProfileService::GetTotalStoppedCount(
    content::WebContents* web_contents) {
  if (!web_contents) return 0;
  auto* helper =
      open_engine::OpenAdBlockTabHelper::FromWebContents(web_contents);
  return helper ? helper->total_count() : 0;
}

AdBlockProfileSnapshot OpenAdBlockProfileService::GetSnapshot() const {
  AdBlockProfileSnapshot snap;
  snap.enabled = enabled_;
  snap.is_off_the_record = is_off_the_record_;
  snap.is_updating = is_updating_;
  if (service_) {
    snap.engine_status = service_->GetStatus();
  }
  snap.enabled_list_ids = GetEnabledListIds();
  snap.excluded_domains = GetExcludedDomains();
  snap.list_receipts = list_receipts_;
  snap.last_error = !last_error_.empty() ? last_error_
                                         : snap.engine_status.last_error;
  return snap;
}

void OpenAdBlockProfileService::SetStatusObserver(StatusObserver observer) {
  status_observer_ = std::move(observer);
}

void OpenAdBlockProfileService::ApplyExclusionsToEngine() {
  if (!service_) {
    return;
  }
  std::vector<std::string> domains(excluded_domains_.begin(),
                                   excluded_domains_.end());
  service_->SetExcludedDomains(std::move(domains));
}

bool OpenAdBlockProfileService::SaveExclusionsToDisk() const {
  if (is_off_the_record_ || adblock_dir_.empty() || !io_task_runner_) {
    return false;
  }
  base::ListValue list;
  for (const auto& dom : excluded_domains_) {
    list.Append(dom);
  }
  std::string json;
  if (!base::JSONWriter::WriteWithOptions(
          list, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
    return false;
  }
  io_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&WriteAtomicFileOnBlockingSequence, adblock_dir_,
                     std::string(kExclusionsFileName), std::move(json)));
  return true;
}

bool OpenAdBlockProfileService::SaveConfigToDisk() const {
  if (is_off_the_record_ || adblock_dir_.empty() || !io_task_runner_) {
    return false;
  }
  base::DictValue dict;
  dict.Set("schemaVersion", 1);
  dict.Set("enabled", enabled_);
  base::ListValue lists;
  for (const auto& id : enabled_list_ids_) {
    lists.Append(id);
  }
  dict.Set("enabledListIDs", std::move(lists));
  if (!list_receipts_.empty()) {
    base::DictValue receipts;
    for (const auto& [id, receipt] : list_receipts_) {
      receipts.Set(id, ReceiptToDict(receipt));
    }
    dict.Set("receipts", std::move(receipts));
  }
  std::string json;
  if (!base::JSONWriter::WriteWithOptions(
          dict, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
    return false;
  }
  io_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&WriteAtomicFileOnBlockingSequence, adblock_dir_,
                     std::string(kConfigFileName), std::move(json)));
  return true;
}

void OpenAdBlockProfileService::OnEngineStatusChanged(
    const open_engine::AdBlockStatus& /*status*/) {
  NotifyUpdated();
}

// static
std::optional<std::string> OpenAdBlockProfileService::NormalizeHost(
    std::string_view raw) {
  std::string s =
      base::ToLowerASCII(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
  if (base::StartsWith(s, "*.")) {
    s.erase(0, 2);
  }
  if (size_t scheme = s.find("://"); scheme != std::string::npos) {
    s.erase(0, scheme + 3);
  }
  if (size_t slash = s.find_first_of("/?#"); slash != std::string::npos) {
    s.erase(slash);
  }
  while (!s.empty() && s.back() == '.') {
    s.pop_back();
  }
  if (s.empty() || s.size() > 253 ||
      s.find_first_of(" \t\r\n/\\?#@%") != std::string::npos) {
    return std::nullopt;
  }
  if (s.find(':') != std::string::npos && s.front() != '[') {
    // Strip port for host:port, preserve IPv6 literals by bracketing.
    if (std::count(s.begin(), s.end(), ':') == 1) {
      s.erase(s.find(':'));
    } else {
      s = "[" + s + "]";
    }
  }
  if (s.empty()) {
    return std::nullopt;
  }

  GURL probe("http://" + s + "/");
  if (!probe.is_valid() || probe.host().empty()) {
    return std::nullopt;
  }
  if (probe.HostIsIPAddress()) {
    return std::string(probe.host());
  }

  const std::string host(probe.host());
  if (host.size() > 253) {
    return std::nullopt;
  }
  // Validate DNS labels (no empty labels, <=63 chars, no leading/trailing '-').
  std::vector<std::string_view> labels = base::SplitStringPiece(
      host, ".", base::KEEP_WHITESPACE, base::SPLIT_WANT_ALL);
  if (labels.size() < 2) {
    return std::nullopt;
  }
  for (std::string_view label : labels) {
    if (label.empty() || label.size() > 63 || label.front() == '-' ||
        label.back() == '-') {
      return std::nullopt;
    }
    for (char c : label) {
      if (!base::IsAsciiAlphaNumeric(c) && c != '-') {
        return std::nullopt;
      }
    }
  }

  // Real Public Suffix List (PSL) registrable-domain validation including
  // private registries (matches OpenAdBlock SiteRules.swift and engine).
  std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          probe, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (registrable.empty()) {
    return std::nullopt;
  }
  return registrable;
}

// --- BrowserContextKeyedServiceFactory ---

// static
OpenAdBlockProfileService*
OpenAdBlockProfileServiceFactory::GetForBrowserContext(
    content::BrowserContext* context) {
  if (!context) {
    return nullptr;
  }
  return static_cast<OpenAdBlockProfileService*>(
      GetInstance()->GetServiceForBrowserContext(context, /*create=*/true));
}

// static
OpenAdBlockProfileServiceFactory*
OpenAdBlockProfileServiceFactory::GetInstance() {
  static base::NoDestructor<OpenAdBlockProfileServiceFactory> instance;
  return instance.get();
}

// static
void OpenAdBlockProfileServiceFactory::SetOriginalContextResolver(
    OriginalContextResolver resolver) {
  GetInstance()->original_context_resolver_ = std::move(resolver);
}

void OpenAdBlockProfileServiceFactory::UnregisterService(
    OpenAdBlockProfileService* service) {
  if (!service) {
    return;
  }
  for (auto it = regular_services_by_path_.begin();
       it != regular_services_by_path_.end();) {
    if (it->second == service) {
      it = regular_services_by_path_.erase(it);
    } else {
      ++it;
    }
  }
  for (auto it = unbound_otr_by_path_.begin();
       it != unbound_otr_by_path_.end();) {
    std::erase(it->second, service);
    if (it->second.empty()) {
      it = unbound_otr_by_path_.erase(it);
    } else {
      ++it;
    }
  }
}

OpenAdBlockProfileServiceFactory::OpenAdBlockProfileServiceFactory()
    : BrowserContextKeyedServiceFactory(
          "OpenAdBlockProfileService",
          BrowserContextDependencyManager::GetInstance()) {}

OpenAdBlockProfileServiceFactory::~OpenAdBlockProfileServiceFactory() = default;

content::BrowserContext*
OpenAdBlockProfileServiceFactory::GetBrowserContextToUse(
    content::BrowserContext* context) const {
  // Own instance per context (including OTR, which shares the parent profile's
  // immutable engine via OpenAdBlockEngineRegistry while keeping OTR exclusions
  // in-memory only).
  return context;
}

std::unique_ptr<KeyedService>
OpenAdBlockProfileServiceFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  auto service = std::make_unique<OpenAdBlockProfileService>(context);
  if (!context) {
    return service;
  }

  const base::FilePath path = context->GetPath();
  if (context->IsOffTheRecord()) {
    OpenAdBlockProfileService* parent = nullptr;
    if (original_context_resolver_) {
      content::BrowserContext* original =
          original_context_resolver_.Run(context);
      if (original && original != context && !original->IsOffTheRecord()) {
        parent = GetForBrowserContext(original);
      }
    }
    if (!parent && !path.empty()) {
      auto it = regular_services_by_path_.find(path);
      if (it != regular_services_by_path_.end()) {
        parent = it->second;
      }
    }
    if (parent) {
      service->BindOffTheRecordParent(parent);
    } else if (!path.empty()) {
      unbound_otr_by_path_[path].push_back(service.get());
    }
  } else if (!path.empty()) {
    regular_services_by_path_[path] = service.get();
    if (auto it = unbound_otr_by_path_.find(path);
        it != unbound_otr_by_path_.end()) {
      auto pending = std::move(it->second);
      unbound_otr_by_path_.erase(it);
      for (OpenAdBlockProfileService* otr : pending) {
        if (otr) {
          otr->BindOffTheRecordParent(service.get());
        }
      }
    }
  }
  return service;
}

}  // namespace open_unified
