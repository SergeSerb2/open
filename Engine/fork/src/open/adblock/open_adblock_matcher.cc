// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_matcher.h"

#include <algorithm>
#include <utility>

#include "base/logging.h"
#include "base/command_line.h"
#include "base/strings/string_number_conversions.h"
#if !defined(OFFICIAL_BUILD)
#include "open/adblock/open_adblock_selftest.h"
#endif
#include "base/no_destructor.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"
#include "url/url_util.h"

namespace open_engine {

namespace {

scoped_refptr<base::SequencedTaskRunner>& MatcherRunner() {
  // Function-local statics are initialized once, thread-safely.
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> runner(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::TaskPriority::USER_BLOCKING,
           base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN}));
  return *runner;
}

void RecordCheck(AdBlockMatcherCounters& counters,
                 base::TimeDelta elapsed,
                 size_t url_length,
                 bool truncated) {
  constexpr auto kRelaxed = std::memory_order_relaxed;
  counters.checks.fetch_add(1, kRelaxed);
  if (truncated) {
    counters.checks_truncated.fetch_add(1, kRelaxed);
  }
  const uint64_t us = static_cast<uint64_t>(elapsed.InMicroseconds());
  uint64_t max = counters.max_check_us.load(kRelaxed);
  while (us > max &&
         !counters.max_check_us.compare_exchange_weak(max, us, kRelaxed)) {
  }
  if (us > 1000) {
    // G-6 (§7.8): length and duration only, never the URL (§6.4).
    counters.checks_over_1ms.fetch_add(1, kRelaxed);
    VLOG(1) << "OpenAdBlock: slow check " << us << " us, URL length "
            << url_length;
  }
}

}  // namespace

scoped_refptr<base::SequencedTaskRunner> AdBlockMatcherTaskRunner() {
  return MatcherRunner();
}

scoped_refptr<base::SequencedTaskRunner> AdBlockCosmeticsTaskRunner() {
  // §7.6 lane rule 2: the same runner until the priority lane exists.
  return MatcherRunner();
}

scoped_refptr<base::SequencedTaskRunner> AdBlockBuildTaskRunner() {
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> runner(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN}));
  return *runner;
}

EngineHolder::EngineHolder(rust::Box<open_adblock::OpenAdblockEngine> engine)
    : engine(std::move(engine)),
      warmed_regex_count([this] {
        DCHECK(AdBlockBuildTaskRunner()->RunsTasksInCurrentSequence());
#if !defined(OFFICIAL_BUILD)
        unsigned cache_capacity = 0;
        if (base::StringToUint(base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
                "open-adblock-regex-cache"), &cache_capacity) && cache_capacity <= (2u << 20)) {
          open_adblock::open_adblock_set_regex_cache_capacity(*this->engine, cache_capacity);
        }
        RecordOpenAdBlockMemoryPhase("rules-before-regex");
#endif
        const uint64_t count = open_adblock::open_adblock_warm_regexes(*this->engine);
#if !defined(OFFICIAL_BUILD)
        RecordOpenAdBlockMemoryPhase("programs-after-regex");
#endif
        return count;
      }()) {
  VLOG(1) << "OpenAdBlock: background regex compiles=" << warmed_regex_count;
}
EngineHolder::~EngineHolder() = default;

std::shared_ptr<const EngineHolder> MakeEngineHolder(
    rust::Box<open_adblock::OpenAdblockEngine> engine) {
  return std::shared_ptr<const EngineHolder>(
      new EngineHolder(std::move(engine)), [](const EngineHolder* holder) {
        // Best effort once ThreadPool shutdown has begun: then the engine
        // leaks at exit (§7.6 shutdown rule 3).
        AdBlockBuildTaskRunner()->DeleteSoon(FROM_HERE, holder);
      });
}

bool HostIsExcluded(const base::flat_set<std::string>& exclusions,
                    std::string_view host) {
  if (host.empty() || exclusions.empty()) {
    return false;
  }
  if (url::HostIsIPAddress(host)) {
    return exclusions.contains(host);
  }
  // The host and each parent domain, at label boundaries, down to the
  // registrable domain (or to the last label when there is none, so an
  // entry under a private suffix Chromium does not know still matches).
  const std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          host, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  std::string_view candidate = host;
  while (!candidate.empty()) {
    if (exclusions.contains(candidate)) {
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

OpenAdBlockMatcher::OpenAdBlockMatcher() {
  // Made on the UI thread; used on the matcher sequence.
  DETACH_FROM_SEQUENCE(sequence_checker_);
}

OpenAdBlockMatcher::~OpenAdBlockMatcher() = default;

void OpenAdBlockMatcher::SetEngine(std::shared_ptr<const EngineHolder> engine) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  engine_ = std::move(engine);
}

void OpenAdBlockMatcher::SetEnabled(bool enabled) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  enabled_ = enabled;
}

void OpenAdBlockMatcher::SetExclusions(
    base::flat_set<std::string> normalized_domains) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  exclusions_ = std::move(normalized_domains);
}

bool OpenAdBlockMatcher::IsActiveFor(std::string_view top_host) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return enabled_ && engine_ && !HostIsExcluded(exclusions_, top_host);
}

bool OpenAdBlockMatcher::IsEnabled() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return enabled_;
}

bool OpenAdBlockMatcher::HasEngine() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return !!engine_;
}

#if !defined(OFFICIAL_BUILD)
bool OpenAdBlockMatcher::SharesEngineWithForDiagnostics(
    const OpenAdBlockMatcher& other) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DCHECK_CALLED_ON_VALID_SEQUENCE(other.sequence_checker_);
  return engine_ && engine_ == other.engine_;
}
#endif

std::string OpenAdBlockMatcher::RegexCompileCountsText() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!engine_) {
    return "G-6 regex no engine";
  }
  const uint64_t current =
      open_adblock::open_adblock_regex_compile_count(*engine_->engine);
  return "G-6 regex warm=" + std::to_string(engine_->warmed_regex_count) +
         " current=" + std::to_string(current) +
         " added=" + std::to_string(current - engine_->warmed_regex_count) +
         " program_limit_fallbacks=" + std::to_string(
             open_adblock::open_adblock_regex_program_limit_fallbacks(*engine_->engine)) +
         " program_bytes=" + std::to_string(
             open_adblock::open_adblock_regex_program_memory_usage(*engine_->engine)) +
         " user_regex_count=" + std::to_string(
             open_adblock::open_adblock_complete_regex_count(*engine_->engine)) +
         " user_regex_program_bytes=" + std::to_string(
             open_adblock::open_adblock_complete_regex_program_bytes(*engine_->engine)) +
         " dat_reshared=" + std::to_string(
             open_adblock::open_adblock_dat_reshared_count(*engine_->engine));
}

open_adblock::OpenBlockerResult OpenAdBlockMatcher::Check(
    const GURL& url,
    const GURL& source_url,
    open_adblock::OpenRequestType type,
    uint32_t max_input_bytes) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
#if !defined(OFFICIAL_BUILD)
  // G-1 (§7.8): no engine call on the UI or IO thread.
  CHECK(!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) &&
        !content::BrowserThread::CurrentlyOn(content::BrowserThread::IO));
#endif
  if (!engine_ || !url.is_valid()) {
    return {};
  }
  const GURL& source = source_url.is_valid() ? source_url : url;
  const base::TimeTicks start = base::TimeTicks::Now();
  open_adblock::OpenBlockerResult result = open_adblock::open_adblock_check(
      *engine_->engine, url.spec(), source.spec(), type, max_input_bytes);
  RecordCheck(counters_, base::TimeTicks::Now() - start, url.spec().size(),
              result.truncated);
  return result;
}

open_adblock::OpenCosmeticResources OpenAdBlockMatcher::Cosmetic(
    const GURL& document_url) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!engine_ || !document_url.is_valid()) {
    return {};
  }
  open_adblock::OpenCosmeticResources resources =
      open_adblock::open_adblock_cosmetic(*engine_->engine, document_url.spec());
  constexpr auto kRelaxed = std::memory_order_relaxed;
  counters_.cosmetic_dropped_procedural.fetch_add(resources.dropped_procedural,
                                                  kRelaxed);
  counters_.cosmetic_dropped_unsafe.fetch_add(resources.dropped_unsafe,
                                              kRelaxed);
  counters_.cosmetic_dropped_style.fetch_add(resources.dropped_style, kRelaxed);
  counters_.cosmetic_dropped_remove.fetch_add(resources.dropped_remove,
                                              kRelaxed);
  counters_.cosmetic_dropped_scriptlet.fetch_add(resources.dropped_scriptlet,
                                                 kRelaxed);
  counters_.cosmetic_dropped_over_cap.fetch_add(resources.dropped_over_cap,
                                                kRelaxed);
  return resources;
}

std::vector<std::string> OpenAdBlockMatcher::HiddenSelectors(
    const std::vector<std::string>& classes,
    const std::vector<std::string>& ids,
    const std::vector<std::string>& exceptions) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!engine_) {
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
  const rust::Vec<rust::String> rust_classes = to_rust(classes);
  const rust::Vec<rust::String> rust_ids = to_rust(ids);
  const rust::Vec<rust::String> rust_exceptions = to_rust(exceptions);
  open_adblock::OpenHiddenSelectors hidden =
      open_adblock::open_adblock_hidden_selectors(
          *engine_->engine,
          rust::Slice<const rust::String>(rust_classes.data(),
                                          rust_classes.size()),
          rust::Slice<const rust::String>(rust_ids.data(), rust_ids.size()),
          rust::Slice<const rust::String>(rust_exceptions.data(),
                                          rust_exceptions.size()));
  // The same counters as Cosmetic() (review R3-4).
  constexpr auto kRelaxed = std::memory_order_relaxed;
  counters_.cosmetic_dropped_procedural.fetch_add(hidden.dropped_procedural,
                                                  kRelaxed);
  counters_.cosmetic_dropped_unsafe.fetch_add(hidden.dropped_unsafe, kRelaxed);
  counters_.cosmetic_dropped_over_cap.fetch_add(hidden.dropped_over_cap,
                                                kRelaxed);
  std::vector<std::string> out;
  out.reserve(hidden.selectors.size());
  for (const rust::String& selector : hidden.selectors) {
    out.emplace_back(selector);
  }
  return out;
}

}  // namespace open_engine
