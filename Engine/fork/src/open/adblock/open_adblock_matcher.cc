// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_matcher.h"

#include <algorithm>
#include <list>
#include <utility>

#include "base/functional/bind.h"
#include "base/logging.h"
#if !defined(OFFICIAL_BUILD)
#include "base/command_line.h"
#include "open/adblock/open_adblock_selftest.h"
#endif
#include "base/no_destructor.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/elapsed_timer.h"
#include "base/timer/timer.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "partition_alloc/memory_reclaimer.h"
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

class IdleReclaimer;
IdleReclaimer*& ActiveIdleReclaimer() {
  static IdleReclaimer* reclaimer = nullptr;
  return reclaimer;
}

// Process-wide because all Profiles share the matcher sequence and allocator.
// This owns no Profile/engine reference. A pending task is skipped at shutdown.
class IdleReclaimer {
 public:
  void Activity(base::TimeTicks now) {
    DCHECK(MatcherRunner()->RunsTasksInCurrentSequence());
    last_activity_ = now;
    if (pending_) {
      return;
    }
    pending_ = true;
    Schedule(std::max(base::Seconds(5), next_allowed_ - now));
  }

  uint64_t count() const { return count_; }

 private:
  void Schedule(base::TimeDelta delay) {
    MatcherRunner()->PostDelayedTask(
        FROM_HERE, base::BindOnce(&IdleReclaimer::OnIdle,
                                 base::Unretained(this)), delay);
  }

  void OnIdle() {
    DCHECK(MatcherRunner()->RunsTasksInCurrentSequence());
    const auto now = base::TimeTicks::Now();
    const auto deadline = std::max(last_activity_ + base::Seconds(5),
                                   next_allowed_);
    if (now < deadline) {
      // Only activity since scheduling can move this deadline. No periodic
      // poll remains once idle: the first purge consumes the pending task.
      Schedule(deadline - now);
      return;
    }
    pending_ = false;
    next_allowed_ = now + base::Minutes(1);
#if !defined(OFFICIAL_BUILD)
    RecordOpenAdBlockMemoryPhase("before-idle-reclaim");
    const auto cpu_start = base::ThreadTicks::Now();
#endif
    base::ElapsedTimer timer;
    partition_alloc::MemoryReclaimer::Instance()->ReclaimAll();
    ++count_;
    VLOG(1) << "OpenAdBlock: idle reclaim runs=" << count_
            << " elapsed_us=" << timer.Elapsed().InMicroseconds()
            << " idle_ms=" << (now - last_activity_).InMilliseconds();
#if !defined(OFFICIAL_BUILD)
    VLOG(1) << "OpenAdBlock: idle reclaim cpu_us="
            << (base::ThreadTicks::Now() - cpu_start).InMicroseconds();
    RecordOpenAdBlockMemoryPhase("after-idle-reclaim");
#endif
  }

  base::TimeTicks last_activity_;
  base::TimeTicks next_allowed_;
  bool pending_ = false;
  uint64_t count_ = 0;
};

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

// One queue and one deadline timer for the whole process, on the matcher
// sequence. Pending callbacks retain their matcher, never the UI service.
// Once a request leaves the queue, no delayed task retains its request data.
class OpenAdBlockMatcher::ColdHoldQueue {
 public:
  void Add(scoped_refptr<OpenAdBlockMatcher> matcher,
           std::string top_host,
           base::TimeTicks start,
           base::OnceCallback<void(bool)> resume) {
    DCHECK(AdBlockMatcherTaskRunner()->RunsTasksInCurrentSequence());
    const auto now = base::TimeTicks::Now();
    if (pending_.size() >= kOpenAdBlockMaxColdHolds ||
        now >= start + kOpenAdBlockColdHoldLimit) {
      VLOG(1) << "OpenAdBlock: cold_hold_skipped="
              << (pending_.size() >= kOpenAdBlockMaxColdHolds ? "queue_full"
                                                            : "deadline");
      std::move(resume).Run(true);
      return;
    }
    matcher->counters_.cold_holds.fetch_add(1, std::memory_order_relaxed);
    pending_.push_back({std::move(matcher), std::move(top_host), start,
                        start + kOpenAdBlockColdHoldLimit, std::move(resume)});
    VLOG(1) << "OpenAdBlock: cold_hold_queued pending=" << pending_.size()
            << " limit=" << kOpenAdBlockMaxColdHolds;
    ScheduleNext();
  }

  void FinishReady(OpenAdBlockMatcher* changed) {
    DCHECK(AdBlockMatcherTaskRunner()->RunsTasksInCurrentSequence());
    const auto now = base::TimeTicks::Now();
    std::list<Pending> completed;
    for (auto it = pending_.begin(); it != pending_.end();) {
      auto current = it++;
      if (now >= current->deadline ||
          (changed && current->matcher.get() == changed &&
           !changed->NeedsFirstEngineHold(current->top_host))) {
        completed.splice(completed.end(), pending_, current);
      }
    }
    // Erase and re-arm before callbacks: one can release a factory or cause
    // another state update. No iterator into pending_ survives a callback.
    ScheduleNext();
    for (auto& request : completed) {
      const auto released = base::TimeTicks::Now();
      const auto elapsed = released - request.start;
      const bool fail_open = released >= request.deadline;
      auto& maximum = request.matcher->counters_.cold_hold_max_ms;
      maximum.store(std::max(maximum.load(std::memory_order_relaxed),
                             static_cast<uint64_t>(elapsed.InMilliseconds())),
                    std::memory_order_relaxed);
      VLOG(1) << "OpenAdBlock: cold_hold_ms=" << elapsed.InMillisecondsF()
              << " deadline_ms=" << kOpenAdBlockColdHoldLimit.InMilliseconds()
              << " deadline_expired=" << fail_open
              << " engine_loaded=" << request.matcher->HasEngine();
      std::move(request.resume).Run(fail_open);
    }
  }

 private:
  struct Pending {
    scoped_refptr<OpenAdBlockMatcher> matcher;
    std::string top_host;
    base::TimeTicks start;
    base::TimeTicks deadline;
    base::OnceCallback<void(bool)> resume;
  };

  void ScheduleNext() {
    timer_.Stop();
    if (pending_.empty()) {
      return;
    }
    const auto next = std::min_element(
        pending_.begin(), pending_.end(),
        [](const Pending& a, const Pending& b) { return a.deadline < b.deadline; });
    timer_.Start(FROM_HERE,
                 std::max(base::TimeDelta(),
                          next->deadline - base::TimeTicks::Now()),
                 base::BindOnce(&ColdHoldQueue::FinishReady,
                                base::Unretained(this), nullptr));
  }

  std::list<Pending> pending_;
  base::OneShotTimer timer_;
};

// static
OpenAdBlockMatcher::ColdHoldQueue& OpenAdBlockMatcher::ColdHolds() {
  static base::NoDestructor<ColdHoldQueue> queue;
  return *queue;
}

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

void NoteAdBlockEngineActivity(base::TimeTicks now) {
#if !defined(OFFICIAL_BUILD)
  // Same-binary diagnostic control. Production builds have no switch or
  // branch here; the enabled path still only records activity.
  static const bool disabled = base::CommandLine::ForCurrentProcess()->HasSwitch(
      "open-adblock-idle-purge-off");
  if (disabled) {
    return;
  }
#endif
  // Trivially destructible: storage remains valid through process shutdown.
  static IdleReclaimer reclaimer;
  ActiveIdleReclaimer() = &reclaimer;
  reclaimer.Activity(now);
}

void NoteAdBlockProxyActivity(base::TimeTicks now) {
  // Blocking-off/no-engine processes never arm an adblock idle purge.
  if (auto* reclaimer = ActiveIdleReclaimer()) {
    reclaimer->Activity(now);
  }
}

#if !defined(OFFICIAL_BUILD)
uint64_t AdBlockIdleReclaimCount() {
  DCHECK(MatcherRunner()->RunsTasksInCurrentSequence());
  auto* reclaimer = ActiveIdleReclaimer();
  return reclaimer ? reclaimer->count() : 0;
}
#endif

EngineHolder::EngineHolder(rust::Box<open_adblock::OpenAdblockEngine> engine)
    : engine(std::move(engine)),
      warmed_regex_count([this] {
        DCHECK(AdBlockBuildTaskRunner()->RunsTasksInCurrentSequence());
#if !defined(OFFICIAL_BUILD)
        RecordOpenAdBlockMemoryPhase("rules-before-regex");
#endif
        base::ElapsedTimer compile_timer;
        const uint64_t count = open_adblock::open_adblock_warm_regexes(*this->engine);
        VLOG(1) << "OpenAdBlock: build phase=regex_compile elapsed_us="
                << compile_timer.Elapsed().InMicroseconds();
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
  has_loaded_engine_ |= !!engine_;
  ColdHolds().FinishReady(this);
}

void OpenAdBlockMatcher::SetEnabled(bool enabled) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  enabled_ = enabled;
  if (!enabled) {
    ColdHolds().FinishReady(this);
  }
}

void OpenAdBlockMatcher::SetExclusions(
    base::flat_set<std::string> normalized_domains) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  exclusions_ = std::move(normalized_domains);
  ColdHolds().FinishReady(this);
}

void OpenAdBlockMatcher::SetFirstLoadPending(bool pending) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  first_load_pending_ = pending;
  if (!pending) {
    ColdHolds().FinishReady(this);
  }
}

bool OpenAdBlockMatcher::NeedsFirstEngineHold(std::string_view top_host) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return enabled_ && !has_loaded_engine_ && !engine_ && first_load_pending_ &&
         !HostIsExcluded(exclusions_, top_host);
}

void OpenAdBlockMatcher::HoldForFirstEngine(
    std::string top_host,
    base::TimeTicks request_start,
    base::OnceCallback<void(bool)> resume) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!NeedsFirstEngineHold(top_host)) {
    std::move(resume).Run(false);
    return;
  }
  ColdHolds().Add(base::WrapRefCounted(this), std::move(top_host), request_start,
                   std::move(resume));
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
         " regex_builder=default" +
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
  NoteAdBlockEngineActivity(start);
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
  NoteAdBlockEngineActivity(base::TimeTicks::Now());
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
  NoteAdBlockEngineActivity(base::TimeTicks::Now());
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
