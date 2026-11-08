// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_service.h"

#include <algorithm>
#include <map>
#include <optional>
#include <string_view>
#include <utility>

#include "base/files/file_util.h"
#include "open/adblock/open_adblock_engine_registry.h"
#include "open/adblock/open_adblock_url_loader_factory.h"
#if !defined(OFFICIAL_BUILD)
#include "open/adblock/open_adblock_selftest.h"
#endif
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/timer/elapsed_timer.h"
#include "base/values.h"
#include "crypto/hash.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "partition_alloc/memory_reclaimer.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace open_engine {

namespace {

// Read caps. The Swift store caps a list at 64 MiB and a manifest at 4 MiB
// (docs/adblock-lists.md); the DAT cap is adblock-fork §6.3.2.
constexpr size_t kMaxPointerBytes = 64 * 1024;
constexpr size_t kMaxManifestBytes = 4 * 1024 * 1024;
constexpr size_t kMaxReceiptBytes = 4 * 1024 * 1024;
constexpr size_t kMaxListBytes = 64 * 1024 * 1024;
// All lists of one generation together (review 100-5; adblock-fork D-16).
constexpr size_t kMaxInputBytes = 128 * 1024 * 1024;
constexpr size_t kMaxDatBytes = 256 * 1024 * 1024;
// The resources file (§6.6 caps; the uBlock Origin set is about 1 MiB).
constexpr size_t kMaxResourcesBytes = 4 * 1024 * 1024;
constexpr char kResourcesListId[] = "_resources";
constexpr char kResourcesFile[] = "resources.json";

constexpr char kDatName[] = "engine.dat";
constexpr char kReceiptName[] = "engine-inputs.json";

std::string Sha256Hex(std::string_view data) {
  return base::HexEncodeLower(crypto::hash::Sha256(data));
}

bool IsSha256Hex(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), base::IsHexDigit<char>) &&
         base::ToLowerASCII(value) == value;
}

// A manifest file name: "<listID>.txt", no path parts, nothing hidden.
bool IsSafeListName(const std::string& name) {
  return name.size() > 4 && name.front() != '.' &&
         base::EndsWith(name, ".txt") &&
         name.find_first_of("/\\") == std::string::npos &&
         name.find("..") == std::string::npos;
}

// Reads a regular file (not a link) of at most |max_bytes|.
std::optional<std::string> ReadBounded(const base::FilePath& path,
                                       size_t max_bytes) {
  if (base::IsLink(path)) {
    return std::nullopt;
  }
  std::string data;
  if (!base::ReadFileToStringWithMaxSize(path, &data, max_bytes)) {
    return std::nullopt;
  }
  return data;
}

// The verified inputs of the live generation (adblock-fork §9.2).
struct Generation {
  int64_t number = 0;
  std::string manifest_sha256;
  base::FilePath dir;
  // File name -> SHA-256 of every verified file (lists and resources).
  std::map<std::string, std::string> file_hashes;
  // List IDs, their SHA-256 and texts, in file-name order (the build
  // order).
  std::vector<std::pair<std::string, std::string>> lists;
  std::vector<std::string> texts;
  // The verified resources.json (§9.3), or empty.
  std::string resources_json;
  std::string resources_sha256;
};

// current.json -> generations/<n>/manifest.json -> every listed file, each
// checked for size and SHA-256. Never enumerates the directory. One entry
// may be the resources file (listID "_resources", file "resources.json").
std::optional<Generation> ReadGeneration(const base::FilePath& root,
                                         std::string* error) {
  auto pointer_text = ReadBounded(root.Append("current.json"), kMaxPointerBytes);
  if (!pointer_text) {
    *error = "read current.json: missing or too large";
    return std::nullopt;
  }
  auto pointer = base::JSONReader::ReadDict(*pointer_text, base::JSON_PARSE_RFC);
  const base::DictValue* live = pointer ? pointer->FindDict("live") : nullptr;
  std::optional<int> number = live ? live->FindInt("generation") : std::nullopt;
  const std::string* manifest_sha =
      live ? live->FindString("manifestSHA256") : nullptr;
  if (!number || *number <= 0 || !manifest_sha || !IsSha256Hex(*manifest_sha)) {
    *error = "read current.json: invalid live generation";
    return std::nullopt;
  }

  Generation generation;
  generation.number = *number;
  generation.manifest_sha256 = *manifest_sha;
  generation.dir =
      root.Append("generations").Append(base::NumberToString(*number));
  if (base::IsLink(generation.dir) || !base::DirectoryExists(generation.dir)) {
    *error = "read generation: missing directory";
    return std::nullopt;
  }
  auto manifest_text =
      ReadBounded(generation.dir.Append("manifest.json"), kMaxManifestBytes);
  if (!manifest_text || Sha256Hex(*manifest_text) != *manifest_sha) {
    *error = "read manifest.json: missing or SHA-256 mismatch";
    return std::nullopt;
  }
  auto manifest = base::JSONReader::ReadDict(*manifest_text, base::JSON_PARSE_RFC);
  const base::ListValue* files =
      manifest ? manifest->FindList("files") : nullptr;
  if (!files || manifest->FindInt("generation") != *number || files->empty()) {
    *error = "read manifest.json: invalid";
    return std::nullopt;
  }

  struct Entry {
    std::string name;
    std::string list_id;
    int bytes;
    std::string sha256;
  };
  std::vector<Entry> entries;
  std::optional<Entry> resources;
  for (const base::Value& value : *files) {
    const base::DictValue* file = value.GetIfDict();
    const std::string* name = file ? file->FindString("file") : nullptr;
    const std::string* list_id = file ? file->FindString("listID") : nullptr;
    const std::string* sha = file ? file->FindString("sha256") : nullptr;
    std::optional<int> bytes = file ? file->FindInt("bytes") : std::nullopt;
    if (!name || !list_id || !sha || !bytes || *bytes <= 0 ||
        !IsSha256Hex(*sha) || file->FindInt("generation") != *number ||
        generation.file_hashes.contains(*name)) {
      *error = "read manifest.json: invalid file entry";
      return std::nullopt;
    }
    if (*list_id == kResourcesListId) {
      if (*name != kResourcesFile || resources ||
          static_cast<size_t>(*bytes) > kMaxResourcesBytes) {
        *error = "read manifest.json: invalid resources entry";
        return std::nullopt;
      }
      resources = Entry{*name, *list_id, *bytes, *sha};
    } else {
      if (static_cast<size_t>(*bytes) > kMaxListBytes ||
          *name != *list_id + ".txt" || !IsSafeListName(*name)) {
        *error = "read manifest.json: invalid file entry";
        return std::nullopt;
      }
      entries.push_back({*name, *list_id, *bytes, *sha});
    }
    generation.file_hashes[*name] = *sha;
  }
  if (entries.empty()) {
    *error = "read manifest.json: no lists";
    return std::nullopt;
  }
  size_t total_bytes = 0;
  for (const Entry& entry : entries) {
    total_bytes += static_cast<size_t>(entry.bytes);
  }
  if (total_bytes > kMaxInputBytes) {
    *error = "read manifest.json: lists over 128 MiB together";
    return std::nullopt;
  }
  std::sort(entries.begin(), entries.end(),
            [](const Entry& a, const Entry& b) { return a.name < b.name; });
  for (const Entry& entry : entries) {
    auto text = ReadBounded(generation.dir.Append(entry.name), kMaxListBytes);
    if (!text || text->size() != static_cast<size_t>(entry.bytes) ||
        Sha256Hex(*text) != entry.sha256) {
      *error = "read " + entry.name + ": size or SHA-256 mismatch";
      return std::nullopt;
    }
    generation.lists.emplace_back(entry.list_id, entry.sha256);
    generation.texts.push_back(std::move(*text));
  }
  if (resources) {
    auto text =
        ReadBounded(generation.dir.Append(resources->name), kMaxResourcesBytes);
    if (!text || text->size() != static_cast<size_t>(resources->bytes) ||
        Sha256Hex(*text) != resources->sha256) {
      *error = "read resources.json: size or SHA-256 mismatch";
      return std::nullopt;
    }
    generation.resources_json = std::move(*text);
    generation.resources_sha256 = resources->sha256;
  }
  return generation;
}

// The engine key of adblock-fork §6.6: content hashes only (no generation,
// path or manifest hash), so two Profiles with the same lists share one
// engine. Lists in build order.
std::string EngineKey(const Generation& generation) {
  std::string input(open_adblock::open_adblock_engine_format());
  input += "\n";
  for (const auto& [list_id, sha] : generation.lists) {
    input += list_id + "\n" + sha + "\n";
  }
  input += "resources\n" +
           (generation.resources_sha256.empty() ? std::string("none")
                                                : generation.resources_sha256) +
           "\n";
  return Sha256Hex(input);
}

// The DAT receipt binds engine.dat to one generation, its exact inputs, and
// the engine format that wrote it (adblock-fork §9.2, D-15). Only a lossless
// build writes a DAT, and its receipt says so.
base::DictValue MakeReceipt(const Generation& generation,
                            std::string_view dat) {
  base::DictValue files;
  for (const auto& [name, sha] : generation.file_hashes) {
    files.Set(name, sha);
  }
  base::DictValue receipt;
  receipt.Set("engineFormat",
              std::string(open_adblock::open_adblock_engine_format()));
  receipt.Set("lossless", true);
  receipt.Set("generation", static_cast<int>(generation.number));
  receipt.Set("manifestSHA256", generation.manifest_sha256);
  receipt.Set("files", std::move(files));
  if (generation.resources_sha256.empty()) {
    receipt.Set("resourcesSHA256", base::Value());
  } else {
    receipt.Set("resourcesSHA256", generation.resources_sha256);
  }
  receipt.Set("datBytes", base::NumberToString(dat.size()));
  receipt.Set("datSHA256", Sha256Hex(dat));
  return receipt;
}

// The generation's DAT, if its receipt matches the verified inputs.
std::optional<std::string> ReadMatchingDat(const Generation& generation) {
  auto receipt_text =
      ReadBounded(generation.dir.Append(kReceiptName), kMaxReceiptBytes);
  auto dat = ReadBounded(generation.dir.Append(kDatName), kMaxDatBytes);
  if (!receipt_text || !dat || dat->empty()) {
    return std::nullopt;
  }
  auto receipt = base::JSONReader::ReadDict(*receipt_text, base::JSON_PARSE_RFC);
  if (!receipt || *receipt != MakeReceipt(generation, *dat)) {
    return std::nullopt;
  }
  return dat;
}

rust::Box<open_adblock::OpenAdblockEngine> BuildFromText(
    const Generation& generation) {
  rust::Vec<rust::String> texts;
  for (const std::string& text : generation.texts) {
    // Lists are untrusted: invalid UTF-8 becomes U+FFFD instead of an abort.
    texts.push_back(rust::String::lossy(text));
  }
  // rust::Str needs UTF-8: a resources file that is not stays out.
  rust::String resources = rust::String::lossy(generation.resources_json);
  return open_adblock::open_adblock_build(
      rust::Slice<const rust::String>(texts.data(), texts.size()),
      rust::Str(resources));
}

void FillReport(const open_adblock::OpenAdblockEngine& engine,
                const Generation& generation,
                OpenAdBlockService::BuildResult& result) {
  const open_adblock::OpenBuildReport report =
      open_adblock::open_adblock_build_report(engine);
  result.lossless = report.lossless;
  result.lossy_kinds.clear();
  for (const rust::String& kind : report.lossy_kinds) {
    result.lossy_kinds.emplace_back(kind);
  }
  result.resources_loaded = report.resources_loaded;
  if (!generation.resources_sha256.empty()) {
    result.resources_version = generation.resources_sha256.substr(0, 12);
    if (!std::string(report.resources_error).empty()) {
      result.error = "read resources.json: " + std::string(report.resources_error);
    }
  }
}

// Runs on the build runner; touches no service state. Stops at the two
// stale checks of §6.6 when a newer load of the same service started.
OpenAdBlockService::BuildResult BuildOnBackground(
    base::FilePath root,
    bool prefer_dat,
    uint64_t load_id,
    std::shared_ptr<std::atomic<uint64_t>> latest_load_id) {
  base::ElapsedTimer timer;
  OpenAdBlockService::BuildResult result;
  auto is_stale = [&] {
    if (latest_load_id->load(std::memory_order_acquire) == load_id) {
      return false;
    }
    result.stale = true;
    result.engine.reset();
    return true;
  };
  std::string error;
  std::optional<Generation> generation = ReadGeneration(root, &error);
  if (!generation) {
    result.error = error;
    result.build_ms = timer.Elapsed().InMilliseconds();
    return result;
  }
  result.generation = generation->number;
  result.list_count = static_cast<uint32_t>(generation->texts.size());

  // §6.6: another Profile's live engine with the same inputs.
  const std::string key = EngineKey(*generation);
  if (auto shared = OpenAdBlockEngineRegistry::Get().Find(key)) {
    result.engine = std::move(shared);
    result.shared = true;
    FillReport(*result.engine->engine, *generation, result);
    result.build_ms = timer.Elapsed().InMilliseconds();
    return result;
  }

  if (prefer_dat) {
    if (std::optional<std::string> dat = ReadMatchingDat(*generation)) {
      base::ElapsedTimer deserialize_timer;
      auto engine = open_adblock::open_adblock_create_empty();
      const rust::Slice<const uint8_t> bytes(
          reinterpret_cast<const uint8_t*>(dat->data()), dat->size());
      // A DAT carries no resources: they are applied after the load (F-31).
      rust::String resources = rust::String::lossy(generation->resources_json);
      if (open_adblock::open_adblock_deserialize(*engine, bytes,
                                                 rust::Str(resources))) {
        VLOG(1) << "OpenAdBlock: build phase=disk_deserialize elapsed_us="
                << deserialize_timer.Elapsed().InMicroseconds();
        FillReport(*engine, *generation, result);
        result.lossless = true;  // only a lossless build writes a DAT
        result.from_dat = true;
        result.dat_size_bytes = dat->size();
        // The crate owns decoded structures. Release all input buffers before
        // compiling regexes; no DAT or list-text copy stays with the engine.
        generation->texts = {};
        std::string().swap(generation->resources_json);
        resources = rust::String();
        dat.reset();
        result.engine = MakeEngineHolder(std::move(engine));
      } else {
        // A cache problem next to the text build below (review 98-5): the
        // walk's reason, or "decode" when the crate refused it.
        const std::string reason(open_adblock::open_adblock_dat_check(bytes));
        result.error =
            "engine.dat refused: " + (reason.empty() ? "decode" : reason);
      }
    }
  }
  if (!result.engine) {
    if (is_stale()) {
      return result;
    }
    base::ElapsedTimer parse_timer;
    auto engine = BuildFromText(*generation);
    VLOG(1) << "OpenAdBlock: build phase=text_parse elapsed_us="
            << parse_timer.Elapsed().InMicroseconds();
    // The lists have been consumed. Resources must remain until the in-memory
    // DAT round trip below reapplies them (DAT v0 does not contain resources).
    generation->texts = {};
    const open_adblock::OpenBuildReport report =
        open_adblock::open_adblock_build_report(*engine);
    if (!report.refused.empty()) {
      // Over the shim's per-build limits (review R3-2): nothing was parsed.
      // The load fails and the old engine stays.
      result.error = "lists refused: " + std::string(report.refused);
      result.build_ms = timer.Elapsed().InMilliseconds();
      return result;
    }
    FillReport(*engine, *generation, result);
    if (is_stale()) {
      // The engine is freed here, on the build runner.
      return result;
    }
    if (result.lossless) {
      base::ElapsedTimer serialize_timer;
      rust::Vec<uint8_t> serialized =
          open_adblock::open_adblock_serialize(*engine);
      VLOG(1) << "OpenAdBlock: build phase=serialize elapsed_us="
              << serialize_timer.Elapsed().InMicroseconds();
      if (is_stale()) {
        // A superseded build must not write a DAT after serialization (100-7).
        return result;
      }
      if (serialized.empty()) {
        result.error = "write engine.dat: serialization failed";
      } else {
#if !defined(OFFICIAL_BUILD)
        RecordOpenAdBlockMemoryPhase("text-before-roundtrip");
#endif
        // Serve the compact DAT representation after a text build too. Keep
        // the original until decode succeeds, then free it on this runner.
        // This uses the same checked decoder and resource reapplication as a
        // disk DAT load, including exact immutable rule re-sharing (N-19).
        base::ElapsedTimer deserialize_timer;
        auto compact = open_adblock::open_adblock_create_empty();
        rust::String resources =
            rust::String::lossy(generation->resources_json);
        const bool deserialized = open_adblock::open_adblock_deserialize(
            *compact,
            rust::Slice<const uint8_t>(serialized.data(), serialized.size()),
            rust::Str(resources));
        if (is_stale()) {
          return result;
        }
        if (deserialized) {
          engine = std::move(compact);
        } else {
          // An optional compaction failure must not lose the valid text
          // engine or alter its verdicts. Retain its original build report.
          result.error = "compact engine.dat: decode failed; kept text engine";
        }
        VLOG(1) << "OpenAdBlock: build phase=text_deserialize elapsed_us="
                << deserialize_timer.Elapsed().InMicroseconds()
                << " success=" << deserialized;
#if !defined(OFFICIAL_BUILD)
        RecordOpenAdBlockMemoryPhase("text-after-roundtrip");
#endif
        // Written from the Rust buffer, without a copy.
        std::string_view dat(reinterpret_cast<const char*>(serialized.data()),
                             serialized.size());
        result.dat_size_bytes = dat.size();
        // DAT first, then its receipt: a torn pair fails the receipt check
        // and is rebuilt from text. Failure keeps the in-memory engine.
        std::string receipt;
        if (!base::ImportantFileWriter::WriteFileAtomically(
                generation->dir.Append(kDatName), dat) ||
            !base::JSONWriter::Write(MakeReceipt(*generation, dat), &receipt) ||
            !base::ImportantFileWriter::WriteFileAtomically(
                generation->dir.Append(kReceiptName), receipt)) {
          result.error = "write engine.dat: failed";
        }
      }
    }
    // A lossy set writes no DAT (F-31), and an old DAT of this generation is
    // never read (its receipt would not match). It must retain the text
    // representation too: a round trip would drop rules such as removeparam.
    std::string().swap(generation->resources_json);
    result.engine = MakeEngineHolder(std::move(engine));
  }
  // All text/DAT/resource/serialization buffers and any replaced text engine
  // are gone. One explicit build-time reclaim releases freed pages; it never
  // runs on a request, the UI thread, or a repeating adblock timer. Chromium
  // uses this same API after backgrounding (partition_alloc_support.cc).
#if !defined(OFFICIAL_BUILD)
  RecordOpenAdBlockMemoryPhase("before-build-reclaim");
#endif
  base::ElapsedTimer reclaim_timer;
  partition_alloc::MemoryReclaimer::Instance()->ReclaimAll();
  VLOG(1) << "OpenAdBlock: build phase=reclaim elapsed_us="
          << reclaim_timer.Elapsed().InMicroseconds();
#if !defined(OFFICIAL_BUILD)
  RecordOpenAdBlockMemoryPhase("after-build-reclaim");
#endif
  OpenAdBlockEngineRegistry::Get().Insert(key, result.engine);
  result.build_ms = timer.Elapsed().InMilliseconds();
  return result;
}

bool g_histogram_printed = false;

// adblock-fork §6.3.3: lowercase, no trailing dot, no leading "*.", and
// never a bare public suffix, a path, or an empty string. Swift stores IPv6
// addresses without brackets (docs/adblock-lists.md).
std::optional<std::string> NormalizeDomain(std::string domain) {
  domain = base::ToLowerASCII(base::TrimWhitespaceASCII(domain, base::TRIM_ALL));
  if (base::EndsWith(domain, ".")) {
    domain.pop_back();
  }
  if (base::StartsWith(domain, "*.")) {
    domain.erase(0, 2);
  }
  if (domain.empty() || domain.find_first_of("/\\ ") != std::string::npos) {
    return std::nullopt;
  }
  if (domain.find(':') != std::string::npos && domain.front() != '[') {
    domain = "[" + domain + "]";
  }
  const GURL url("http://" + domain + "/");
  if (!url.is_valid()) {
    return std::nullopt;
  }
  if (url.HostIsIPAddress()) {
    return std::string(url.host());
  }
  if (net::registry_controlled_domains::GetDomainAndRegistry(
          url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)
          .empty()) {
    return std::nullopt;
  }
  return std::string(url.host());
}

}  // namespace

AdBlockStatus::AdBlockStatus() = default;
AdBlockStatus::AdBlockStatus(const AdBlockStatus&) = default;
AdBlockStatus& AdBlockStatus::operator=(const AdBlockStatus&) = default;
AdBlockStatus::~AdBlockStatus() = default;

OpenAdBlockService::BuildResult::BuildResult() = default;
OpenAdBlockService::BuildResult::BuildResult(BuildResult&&) = default;
OpenAdBlockService::BuildResult& OpenAdBlockService::BuildResult::operator=(
    BuildResult&&) = default;
OpenAdBlockService::BuildResult::~BuildResult() = default;

OpenAdBlockService::OpenAdBlockService(base::FilePath profile_dir)
    : profile_dir_(std::move(profile_dir)),
      matcher_(base::MakeRefCounted<OpenAdBlockMatcher>()),
      latest_load_id_(std::make_shared<std::atomic<uint64_t>>(0)) {
  status_.match_cap_bytes = kOpenAdBlockMatchCapBytes;
}

OpenAdBlockService::~OpenAdBlockService() {
  Shutdown();
}

void OpenAdBlockService::Shutdown() {
  if (shut_down_) {
    return;
  }
  shut_down_ = true;
  latest_load_id_->fetch_add(1, std::memory_order_acq_rel);
  weak_ptr_factory_.InvalidateWeakPtrs();
  // G-3 and G-6 (§7.8): the matcher counters, read on this thread.
  const AdBlockMatcherCounters& counters = matcher_->counters();
  constexpr auto kRelaxed = std::memory_order_relaxed;
  VLOG(1) << "OpenAdBlock: shutdown checks=" << counters.checks.load(kRelaxed)
          << " checks_truncated=" << counters.checks_truncated.load(kRelaxed)
          << " checks_over_1ms=" << counters.checks_over_1ms.load(kRelaxed)
          << " max_check_us=" << counters.max_check_us.load(kRelaxed);
  // The matcher answers "off" from now on; its engine reference drops on
  // the matcher sequence and the deleter frees the engine on the build
  // runner (§6.6). Never a free under a lock or on this thread.
  AdBlockCosmeticsTaskRunner()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](scoped_refptr<OpenAdBlockMatcher> matcher) {
#if !defined(OFFICIAL_BUILD)
                       VLOG(1) << "OpenAdBlock: "
                               << matcher->RegexCompileCountsText();
#endif
                       matcher->SetEnabled(false);
                       matcher->SetEngine(nullptr);
                     },
                     matcher_));
  // G-4 (§7.8): printed here, on the UI thread, where a normal quit always
  // runs it; a matcher task could be dropped at shutdown.
  if (!g_histogram_printed) {
    g_histogram_printed = true;
    VLOG(1) << "OpenAdBlock: " << AdBlockLatencyHistogramText();
    VLOG(1) << "OpenAdBlock: " << AdBlockProxyProfileText();
  }
}

void OpenAdBlockService::PostToMatcher(
    base::OnceCallback<void(OpenAdBlockMatcher*)> update) {
  AdBlockCosmeticsTaskRunner()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](scoped_refptr<OpenAdBlockMatcher> matcher,
                        base::OnceCallback<void(OpenAdBlockMatcher*)> update) {
                       std::move(update).Run(matcher.get());
                     },
                     matcher_, std::move(update)));
}

void OpenAdBlockService::SetEnabled(bool enabled) {
  if (shut_down_) {
    return;
  }
  enabled_ = enabled;
  status_.enabled = enabled;
  PostToMatcher(base::BindOnce(
      [](bool enabled, OpenAdBlockMatcher* matcher) {
        matcher->SetEnabled(enabled);
      },
      enabled));
  NotifyStatus();
}

bool OpenAdBlockService::IsEnabled() const {
  return enabled_ && !shut_down_;
}

void OpenAdBlockService::SetExcludedDomains(
    std::vector<std::string> registrable_domains) {
  if (shut_down_) {
    return;
  }
  std::vector<std::string> domains;
  for (std::string& entry : registrable_domains) {
    if (std::optional<std::string> domain = NormalizeDomain(std::move(entry))) {
      domains.push_back(std::move(*domain));
    } else {
      LOG(WARNING) << "OpenAdBlock: skipped an invalid excluded domain";
    }
  }
  excluded_domains_ = base::flat_set<std::string>(std::move(domains));
  status_.excluded_domains.assign(excluded_domains_.begin(),
                                  excluded_domains_.end());
  PostToMatcher(base::BindOnce(
      [](base::flat_set<std::string> domains, OpenAdBlockMatcher* matcher) {
        matcher->SetExclusions(std::move(domains));
      },
      excluded_domains_));
  NotifyStatus();
}

bool OpenAdBlockService::IsExcludedOnUi(std::string_view host) const {
  return HostIsExcluded(excluded_domains_, host);
}

void OpenAdBlockService::LoadFromDirectory(
    base::FilePath adblock_root,
    bool prefer_dat,
    base::OnceCallback<void(AdBlockLoadResult)> done) {
  if (shut_down_) {
    if (done) {
      std::move(done).Run(AdBlockLoadResult::kCancelled);
    }
    return;
  }
  adblock_root_ = adblock_root;
  const uint64_t load_id =
      latest_load_id_->fetch_add(1, std::memory_order_acq_rel) + 1;
  AdBlockBuildTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&BuildOnBackground, std::move(adblock_root), prefer_dat,
                     load_id, latest_load_id_),
      base::BindOnce(&OpenAdBlockService::OnBuiltReply,
                     weak_ptr_factory_.GetWeakPtr(), load_id, std::move(done)));
}

// static
void OpenAdBlockService::OnBuiltReply(
    base::WeakPtr<OpenAdBlockService> service,
    uint64_t load_id,
    base::OnceCallback<void(AdBlockLoadResult)> done,
    BuildResult result) {
  if (service) {
    service->OnBuilt(load_id, std::move(done), std::move(result));
    return;
  }
  // Shut down or destroyed. Dropping the reference here is safe: the
  // engine's deleter frees it on the build runner (§6.6).
  result.engine.reset();
  VLOG(1) << "OpenAdBlock: load " << load_id << " cancelled";
  if (done) {
    std::move(done).Run(AdBlockLoadResult::kCancelled);
  }
}

void OpenAdBlockService::SetListDirectory(base::FilePath adblock_root) {
  if (shut_down_ || adblock_root == adblock_root_) {
    return;
  }
  if (!adblock_root.empty()) {
    LoadFromDirectory(std::move(adblock_root), /*prefer_dat=*/true);
    return;
  }
  adblock_root_.clear();
  latest_load_id_->fetch_add(1, std::memory_order_acq_rel);
  status_ = AdBlockStatus();
  status_.match_cap_bytes = kOpenAdBlockMatchCapBytes;
  status_.excluded_domains.assign(excluded_domains_.begin(),
                                  excluded_domains_.end());
  PostToMatcher(base::BindOnce([](OpenAdBlockMatcher* matcher) {
    matcher->SetEngine(nullptr);
  }));
  NotifyStatus();
}

void OpenAdBlockService::ReloadLists() {
  if (!adblock_root_.empty()) {
    LoadFromDirectory(adblock_root_, /*prefer_dat=*/true);
  }
}

void OpenAdBlockService::OnBuilt(
    uint64_t load_id,
    base::OnceCallback<void(AdBlockLoadResult)> done,
    BuildResult result) {
  // A newer load started: its result wins.
  if (shut_down_ || result.stale ||
      load_id != latest_load_id_->load(std::memory_order_acquire)) {
    VLOG(1) << "OpenAdBlock: dropped the result of load " << load_id;
    result.engine.reset();
    if (done) {
      std::move(done).Run(shut_down_ ? AdBlockLoadResult::kCancelled
                                     : AdBlockLoadResult::kStale);
    }
    return;
  }
  const bool loaded = !!result.engine;
  status_.last_build_ms = result.build_ms;
  status_.last_error = result.error;
  if (loaded) {
    status_.engine_loaded = true;
    status_.engine_from_dat = result.from_dat;
    status_.engine_shared = result.shared;
    status_.generation = result.generation;
    status_.list_count = result.list_count;
    status_.dat_size_bytes = result.dat_size_bytes;
    status_.dat_policy = result.lossless ? "dat" : "text-only";
    status_.lossy_kinds = result.lossy_kinds;
    status_.resources_loaded = result.resources_loaded;
    status_.resources_version = result.resources_version;
    PostToMatcher(base::BindOnce(
        [](std::shared_ptr<const EngineHolder> engine,
           OpenAdBlockMatcher* matcher) {
          matcher->SetEngine(std::move(engine));
        },
        std::move(result.engine)));
  }
  VLOG(1) << "OpenAdBlock: loaded " << result.list_count << " lists, "
          << (result.shared ? "shared" : result.from_dat ? "dat" : "text")
          << ", " << result.build_ms << " ms"
          << (result.error.empty() ? "" : ", " + result.error);
  NotifyStatus();
  if (done) {
    std::move(done).Run(loaded ? AdBlockLoadResult::kLoaded
                               : AdBlockLoadResult::kFailed);
  }
}

AdBlockStatus OpenAdBlockService::GetStatus() const {
  AdBlockStatus status = status_;
  status.enabled = IsEnabled();
  const AdBlockMatcherCounters& counters = matcher_->counters();
  constexpr auto kRelaxed = std::memory_order_relaxed;
  status.checks = counters.checks.load(kRelaxed);
  status.checks_truncated = counters.checks_truncated.load(kRelaxed);
  status.cosmetic_dropped_procedural =
      counters.cosmetic_dropped_procedural.load(kRelaxed);
  status.cosmetic_dropped_unsafe = counters.cosmetic_dropped_unsafe.load(kRelaxed);
  status.cosmetic_dropped_style = counters.cosmetic_dropped_style.load(kRelaxed);
  status.cosmetic_dropped_remove = counters.cosmetic_dropped_remove.load(kRelaxed);
  status.cosmetic_dropped_scriptlet =
      counters.cosmetic_dropped_scriptlet.load(kRelaxed);
  status.cosmetic_dropped_over_cap =
      counters.cosmetic_dropped_over_cap.load(kRelaxed);
  return status;
}

void OpenAdBlockService::SetStatusCallback(
    base::RepeatingCallback<void(const AdBlockStatus&)> callback) {
  status_callback_ = std::move(callback);
}

void OpenAdBlockService::NotifyStatus() {
  if (status_callback_) {
    status_callback_.Run(GetStatus());
  }
}

base::WeakPtr<OpenAdBlockService> OpenAdBlockService::GetWeakPtr() {
  return weak_ptr_factory_.GetWeakPtr();
}

}  // namespace open_engine
