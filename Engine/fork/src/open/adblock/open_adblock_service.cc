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
  // File name -> SHA-256, and the texts in file-name order.
  std::map<std::string, std::string> file_hashes;
  std::vector<std::string> texts;
};

// current.json -> generations/<n>/manifest.json -> every listed file, each
// checked for size and SHA-256. Never enumerates the directory.
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
    int bytes;
    std::string sha256;
  };
  std::vector<Entry> entries;
  for (const base::Value& value : *files) {
    const base::DictValue* file = value.GetIfDict();
    const std::string* name = file ? file->FindString("file") : nullptr;
    const std::string* list_id = file ? file->FindString("listID") : nullptr;
    const std::string* sha = file ? file->FindString("sha256") : nullptr;
    std::optional<int> bytes = file ? file->FindInt("bytes") : std::nullopt;
    if (!name || !list_id || !sha || !bytes || *bytes <= 0 ||
        static_cast<size_t>(*bytes) > kMaxListBytes ||
        *name != *list_id + ".txt" || !IsSafeListName(*name) ||
        !IsSha256Hex(*sha) || file->FindInt("generation") != *number ||
        generation.file_hashes.contains(*name)) {
      *error = "read manifest.json: invalid file entry";
      return std::nullopt;
    }
    generation.file_hashes[*name] = *sha;
    entries.push_back({*name, *bytes, *sha});
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
    generation.texts.push_back(std::move(*text));
  }
  return generation;
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
  return open_adblock::open_adblock_build(
      rust::Slice<const rust::String>(texts.data(), texts.size()),
      rust::Str());
}

// Runs on the build runner; touches no service state.
OpenAdBlockService::BuildResult BuildOnBackground(base::FilePath root,
                                                  bool prefer_dat) {
  base::ElapsedTimer timer;
  OpenAdBlockService::BuildResult result;
  std::string error;
  std::optional<Generation> generation = ReadGeneration(root, &error);
  if (!generation) {
    result.error = error;
    result.build_ms = timer.Elapsed().InMilliseconds();
    return result;
  }
  result.generation = generation->number;
  result.list_count = static_cast<uint32_t>(generation->texts.size());

  if (prefer_dat) {
    if (std::optional<std::string> dat = ReadMatchingDat(*generation)) {
      auto engine = open_adblock::open_adblock_create_empty();
      // No resources before Step 7.
      if (open_adblock::open_adblock_deserialize(
              *engine,
              rust::Slice<const uint8_t>(
                  reinterpret_cast<const uint8_t*>(dat->data()), dat->size()),
              rust::Str())) {
        result.engine = std::make_unique<OpenAdBlockService::EngineHolder>(
            std::move(engine));
        result.from_dat = true;
        result.dat_size_bytes = dat->size();
      }
    }
  }
  if (!result.engine) {
    auto engine = BuildFromText(*generation);
    // The texts are no longer needed: free them before serializing.
    generation->texts = {};
    result.lossless = open_adblock::open_adblock_build_report(*engine).lossless;
    if (!result.lossless) {
      // A DAT would drop rules (F-31): no cache, and an old DAT of this
      // generation is never read (its receipt would not match).
      result.engine =
          std::make_unique<OpenAdBlockService::EngineHolder>(std::move(engine));
      result.build_ms = timer.Elapsed().InMilliseconds();
      return result;
    }
    rust::Vec<uint8_t> serialized = open_adblock::open_adblock_serialize(*engine);
    result.engine =
        std::make_unique<OpenAdBlockService::EngineHolder>(std::move(engine));
    if (serialized.empty()) {
      result.error = "write engine.dat: serialization failed";
    } else {
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
  result.build_ms = timer.Elapsed().InMilliseconds();
  return result;
}

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

OpenAdBlockService::EngineHolder::EngineHolder(
    rust::Box<open_adblock::OpenAdblockEngine> engine)
    : engine(std::move(engine)) {}
OpenAdBlockService::EngineHolder::~EngineHolder() = default;

OpenAdBlockService::BuildResult::BuildResult() = default;
OpenAdBlockService::BuildResult::BuildResult(BuildResult&&) = default;
OpenAdBlockService::BuildResult& OpenAdBlockService::BuildResult::operator=(
    BuildResult&&) = default;
OpenAdBlockService::BuildResult::~BuildResult() = default;

OpenAdBlockService::OpenAdBlockService(base::FilePath profile_dir)
    : profile_dir_(std::move(profile_dir)),
      build_runner_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN})) {}

OpenAdBlockService::~OpenAdBlockService() {
  Shutdown();
}

void OpenAdBlockService::Shutdown() {
  shut_down_ = true;
  ++load_id_;
  weak_ptr_factory_.InvalidateWeakPtrs();
  VLOG(1) << "OpenAdBlock: shutdown";
  std::shared_ptr<const EngineHolder> engine;
  {
    // Take the engine out under the lock; free it elsewhere, so a check that
    // waits for the lock does not wait for the free.
    std::unique_lock lock(engine_mutex_);
    engine_.swap(engine);
  }
  ReleaseOnBuildRunner(std::move(engine));
}

void OpenAdBlockService::ReleaseOnBuildRunner(
    std::shared_ptr<const EngineHolder> engine) {
  if (engine) {
    // A check on another thread may still hold the engine; then the last
    // reference frees it there.
    build_runner_->PostTask(
        FROM_HERE,
        base::BindOnce([](std::shared_ptr<const EngineHolder>) {},
                       std::move(engine)));
  }
}

void OpenAdBlockService::SetEnabled(bool enabled) {
  enabled_ = enabled;
  {
    std::lock_guard lock(status_mutex_);
    status_.enabled = enabled;
  }
  NotifyStatus();
}

bool OpenAdBlockService::IsEnabled() const {
  return enabled_ && !shut_down_;
}

void OpenAdBlockService::SetExcludedDomains(
    std::vector<std::string> registrable_domains) {
  std::set<std::string> domains;
  for (std::string& entry : registrable_domains) {
    if (std::optional<std::string> domain = NormalizeDomain(std::move(entry))) {
      domains.insert(std::move(*domain));
    } else {
      LOG(WARNING) << "OpenAdBlock: skipped an invalid excluded domain";
    }
  }
  {
    std::lock_guard lock(status_mutex_);
    status_.excluded_domains.assign(domains.begin(), domains.end());
  }
  {
    std::lock_guard lock(exclusions_mutex_);
    excluded_domains_ = std::move(domains);
  }
  NotifyStatus();
}

bool OpenAdBlockService::IsExcluded(const GURL& top_level_url) const {
  if (!top_level_url.is_valid() || !top_level_url.has_host()) {
    return false;
  }
  std::string host = base::ToLowerASCII(top_level_url.host());
  if (base::EndsWith(host, ".")) {
    host.pop_back();
  }
  std::lock_guard lock(exclusions_mutex_);
  if (top_level_url.HostIsIPAddress()) {
    return excluded_domains_.contains(host);
  }
  // The host and each parent domain, at label boundaries, down to the
  // registrable domain (or to the last label when there is none, so a
  // stored entry under a private suffix Chromium does not know still
  // matches; review 100-4).
  const std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          top_level_url,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  std::string_view candidate = host;
  while (!candidate.empty()) {
    if (excluded_domains_.contains(std::string(candidate))) {
      return true;
    }
    if (!registrable.empty() && candidate == registrable) {
      return false;
    }
    const size_t dot = candidate.find('.');
    if (dot == std::string_view::npos) {
      return false;
    }
    candidate.remove_prefix(dot + 1);
  }
  return false;
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
  const uint64_t load_id = ++load_id_;
  build_runner_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&BuildOnBackground, std::move(adblock_root), prefer_dat),
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
  // Shut down or destroyed: no build runner is left, so free the engine on
  // a pool thread, not here on the UI thread (review 100-2).
  if (result.engine) {
    base::ThreadPool::PostTask(
        FROM_HERE,
        {base::TaskPriority::BEST_EFFORT,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce([](std::unique_ptr<EngineHolder>) {},
                       std::move(result.engine)));
  }
  VLOG(1) << "OpenAdBlock: load " << load_id << " cancelled";
  if (done) {
    std::move(done).Run(AdBlockLoadResult::kCancelled);
  }
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
  // A newer load started: its result wins. The dropped engine is freed on
  // the build runner.
  if (shut_down_ || load_id != load_id_) {
    VLOG(1) << "OpenAdBlock: dropped the result of load " << load_id;
    ReleaseOnBuildRunner(std::move(result.engine));
    if (done) {
      std::move(done).Run(shut_down_ ? AdBlockLoadResult::kCancelled
                                     : AdBlockLoadResult::kStale);
    }
    return;
  }
  const bool loaded = !!result.engine;
  {
    std::lock_guard lock(status_mutex_);
    status_.last_build_ms = result.build_ms;
    status_.last_error = result.error;
    if (result.engine) {
      status_.engine_loaded = true;
      status_.engine_from_dat = result.from_dat;
      status_.generation = result.generation;
      status_.list_count = result.list_count;
      status_.dat_size_bytes = result.dat_size_bytes;
    }
  }
  if (result.engine) {
    std::shared_ptr<const EngineHolder> engine = std::move(result.engine);
    {
      std::unique_lock lock(engine_mutex_);
      engine_.swap(engine);
    }
    // `engine` is the old one now.
    ReleaseOnBuildRunner(std::move(engine));
  }
  VLOG(1) << "OpenAdBlock: loaded " << result.list_count << " lists, "
          << (result.from_dat ? "dat" : "text") << ", " << result.build_ms
          << " ms" << (result.error.empty() ? "" : ", " + result.error);
  NotifyStatus();
  if (done) {
    std::move(done).Run(loaded ? AdBlockLoadResult::kLoaded
                               : AdBlockLoadResult::kFailed);
  }
}

std::shared_ptr<const OpenAdBlockService::EngineHolder>
OpenAdBlockService::CurrentEngine() const {
  std::shared_lock lock(engine_mutex_);
  return engine_;
}

open_adblock::OpenBlockerResult OpenAdBlockService::Check(
    const GURL& url,
    const GURL& source_url,
    open_adblock::OpenRequestType request_type) const {
  std::shared_ptr<const EngineHolder> holder = CurrentEngine();
  if (!holder || !url.is_valid()) {
    return {};
  }
  const GURL& source = source_url.is_valid() ? source_url : url;
  return open_adblock::open_adblock_check(*holder->engine, url.spec(),
                                          source.spec(), request_type,
                                          kOpenAdBlockMatchCapBytes);
}

open_adblock::OpenCosmeticResources OpenAdBlockService::CosmeticResources(
    const GURL& url) const {
  std::shared_ptr<const EngineHolder> holder = CurrentEngine();
  if (!holder || !url.is_valid()) {
    return {};
  }
  open_adblock::OpenCosmeticResources resources =
      open_adblock::open_adblock_cosmetic(*holder->engine, url.spec());
  constexpr auto kRelaxed = std::memory_order_relaxed;
  cosmetic_dropped_procedural_.fetch_add(resources.dropped_procedural, kRelaxed);
  cosmetic_dropped_unsafe_.fetch_add(resources.dropped_unsafe, kRelaxed);
  cosmetic_dropped_style_.fetch_add(resources.dropped_style, kRelaxed);
  cosmetic_dropped_remove_.fetch_add(resources.dropped_remove, kRelaxed);
  cosmetic_dropped_scriptlet_.fetch_add(resources.dropped_scriptlet, kRelaxed);
  cosmetic_dropped_over_cap_.fetch_add(resources.dropped_over_cap, kRelaxed);
  return resources;
}

std::vector<std::string> OpenAdBlockService::HiddenSelectors(
    const std::vector<std::string>& classes,
    const std::vector<std::string>& ids,
    const std::vector<std::string>& exceptions) const {
  std::shared_ptr<const EngineHolder> holder = CurrentEngine();
  if (!holder) {
    return {};
  }
  // Tokens come from pages: invalid UTF-8 becomes U+FFFD.
  auto to_rust = [](const std::vector<std::string>& values) {
    rust::Vec<rust::String> out;
    for (const std::string& value : values) {
      out.push_back(rust::String::lossy(value));
    }
    return out;
  };
  rust::Vec<rust::String> rust_classes = to_rust(classes);
  rust::Vec<rust::String> rust_ids = to_rust(ids);
  rust::Vec<rust::String> rust_exceptions = to_rust(exceptions);
  rust::Vec<rust::String> selectors = open_adblock::open_adblock_hidden_selectors(
      *holder->engine,
      rust::Slice<const rust::String>(rust_classes.data(), rust_classes.size()),
      rust::Slice<const rust::String>(rust_ids.data(), rust_ids.size()),
      rust::Slice<const rust::String>(rust_exceptions.data(),
                                      rust_exceptions.size()));
  std::vector<std::string> out;
  out.reserve(selectors.size());
  for (const rust::String& selector : selectors) {
    out.emplace_back(selector);
  }
  return out;
}

AdBlockStatus OpenAdBlockService::GetStatus() const {
  AdBlockStatus status;
  {
    std::lock_guard lock(status_mutex_);
    status = status_;
  }
  constexpr auto kRelaxed = std::memory_order_relaxed;
  status.cosmetic_dropped_procedural = cosmetic_dropped_procedural_.load(kRelaxed);
  status.cosmetic_dropped_unsafe = cosmetic_dropped_unsafe_.load(kRelaxed);
  status.cosmetic_dropped_style = cosmetic_dropped_style_.load(kRelaxed);
  status.cosmetic_dropped_remove = cosmetic_dropped_remove_.load(kRelaxed);
  status.cosmetic_dropped_scriptlet = cosmetic_dropped_scriptlet_.load(kRelaxed);
  status.cosmetic_dropped_over_cap = cosmetic_dropped_over_cap_.load(kRelaxed);
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
