// Copyright 2026 The Open Authors. All rights reserved.
// OpenAdBlockProfileService implementation.

#include "open_unified/core/adblock/open_adblock_profile_service.h"

#include <algorithm>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "components/keyed_service/content/browser_context_dependency_manager.h"
#include "components/web_cache/browser/web_cache_manager.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "crypto/hash.h"
#include "open/adblock/open_adblock_cosmetics_host.h"
#include "open/adblock/open_adblock_tab_helper.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr char kConfigFileName[] = "adblock-config.json";
constexpr char kExclusionsFileName[] = "exclusions.json";
constexpr char kCurrentPointerName[] = "current.json";
constexpr char kManifestFileName[] = "manifest.json";
constexpr size_t kMaxConfigBytes = 4 * 1024 * 1024;

std::string Sha256HexLower(std::string_view data) {
  return base::HexEncodeLower(crypto::hash::Sha256(data));
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
            gen_dir.AppendASCII("resources.json"), resources_json)) {
      return false;
    }
    base::DictValue entry;
    entry.Set("file", "resources.json");
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
  return base::ImportantFileWriter::WriteFileAtomically(
      lists_dir.AppendASCII(kCurrentPointerName), pointer_text);
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
OpenAdBlockProfileService* OpenAdBlockProfileService::GetForBrowserContext(
    content::BrowserContext* context) {
  return OpenAdBlockProfileServiceFactory::GetForBrowserContext(context);
}

OpenAdBlockProfileService::DiskState::DiskState() = default;
OpenAdBlockProfileService::DiskState::DiskState(DiskState&&) noexcept = default;
OpenAdBlockProfileService::DiskState&
OpenAdBlockProfileService::DiskState::operator=(DiskState&&) noexcept = default;
OpenAdBlockProfileService::DiskState::~DiskState() = default;

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
  service_ = std::make_unique<open_engine::OpenAdBlockService>(profile_path);
  service_->SetRendererCacheInvalidator(base::BindRepeating(
      &OpenAdBlockProfileService::ClearRendererCachesForService,
      weak_factory_.GetWeakPtr()));
  service_->SetStatusCallback(
      base::BindRepeating(&OpenAdBlockProfileService::OnEngineStatusChanged,
                          base::Unretained(this)));

  adblock_dir_ = profile_path.AppendASCII("AdBlock");
  lists_dir_ = adblock_dir_.AppendASCII("lists");
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
  if (service_) {
    service_->Shutdown();
    service_.reset();
  }
  browser_context_ = nullptr;
}

void OpenAdBlockProfileService::BindOffTheRecordParent(
    OpenAdBlockProfileService* parent) {
  if (parent) {
    InitializeFromParent(parent);
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
  enabled_ = parent->IsEnabled();
  auto parent_lists = parent->GetEnabledListIds();
  enabled_list_ids_.clear();
  enabled_list_ids_.insert(parent_lists.begin(), parent_lists.end());
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
                     adblock_dir_),
      base::BindOnce(&OpenAdBlockProfileService::OnDiskStateLoaded,
                     weak_factory_.GetWeakPtr()));
}

// static
OpenAdBlockProfileService::DiskState
OpenAdBlockProfileService::ReadDiskStateOnBlockingSequence(
    base::FilePath adblock_dir) {
  DiskState state;
  // Load adblock-config.json (enabled flag + enabled list IDs).
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
    }
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
        if (!item.is_string()) continue;
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
    service_->SetEnabled(enabled_);
    changed = true;
  }
  if (!exclusions_mutated_ && state.has_exclusions) {
    excluded_domains_ = std::move(state.excluded_domains);
    ApplyExclusionsToEngine();
    changed = true;
  }
  if (changed && status_observer_) {
    status_observer_.Run(GetSnapshot());
  }
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
  if (status_observer_) {
    status_observer_.Run(GetSnapshot());
  }
}

bool OpenAdBlockProfileService::IsEnabled() const {
  return enabled_ && service_ && service_->IsEnabled();
}

std::vector<std::string> OpenAdBlockProfileService::GetEnabledListIds() const {
  return std::vector<std::string>(enabled_list_ids_.begin(),
                                  enabled_list_ids_.end());
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
  if (status_observer_) {
    status_observer_.Run(GetSnapshot());
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
  if (status_observer_) {
    status_observer_.Run(GetSnapshot());
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
  if (service_) {
    snap.engine_status = service_->GetStatus();
  }
  snap.enabled_list_ids = GetEnabledListIds();
  snap.excluded_domains = GetExcludedDomains();
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
  if (status_observer_) {
    status_observer_.Run(GetSnapshot());
  }
}

// static
std::optional<std::string> OpenAdBlockProfileService::NormalizeHost(
    std::string_view raw) {
  std::string s = base::ToLowerASCII(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
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
  if (s.empty() || s.find(' ') != std::string::npos) {
    return std::nullopt;
  }
  if (s.find(':') != std::string::npos && s.front() != '[') {
    // Strip port for host:port, preserve IPv6.
    if (std::count(s.begin(), s.end(), ':') == 1) {
      s.erase(s.find(':'));
    } else {
      s = "[" + s + "]";
    }
  }
  GURL probe("http://" + s + "/");
  if (!probe.is_valid() || probe.host().empty()) {
    return std::nullopt;
  }
  return std::string(probe.host());
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
  return std::make_unique<OpenAdBlockProfileService>(context);
}

}  // namespace open_unified
