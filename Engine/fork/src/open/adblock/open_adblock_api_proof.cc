// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Headless end-to-end control path in a real CEF Profile, not an isolated
// service test. Uses only the production API for settings and load requests.
#include "open/adblock/open_adblock_profile_proof.h"

#include <cstdio>
#include <iterator>
#include <utility>
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "cef/include/cef_open_adblock.h"
#include "cef/include/cef_open_profile.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "open/adblock/open_adblock_service.h"
#include "open/adblock/open_adblock_selftest.h"

#if !defined(OFFICIAL_BUILD)
namespace open_engine {
namespace {

class AdBlockApiProof final : public CefRequestContextHandler,
                              public CefOpenProfileDeletionHandler {
 public:
  AdBlockApiProof(base::FilePath root, base::OnceCallback<void(bool)> done)
      : root_(std::move(root)), done_(std::move(done)) {}

  void Start() {
    Row(!CefSetOpenAdBlockEnabled(nullptr, true) &&
        !CefSetOpenAdBlockListDirectory(nullptr, "") &&
        !CefSetOpenAdBlockExcludedDomains(nullptr, {}) &&
        !CefReloadOpenAdBlockLists(nullptr) &&
        !CefGetOpenAdBlockStatus(nullptr) &&
        CefGetOpenAdBlockBlockedCount(nullptr) == 0,
        "missing arguments reject without Default fallback");
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = g_browser_process->profile_manager()
        ->user_data_dir().Append("OpenAdBlockApiProof").value();
    context_ = CefRequestContext::CreateContext(settings, this);
    if (!context_) { Row(false, "context creation"); Finish(); }
  }

  void OnRequestContextInitialized(CefRefPtr<CefRequestContext>) override {
    empty_proof_ = base::PathExists(root_.Append("restored-current.json"));
    Post(&AdBlockApiProof::Configure, empty_proof_ ? base::Seconds(6) : base::TimeDelta());
  }

  void OnReadyToRelease() override { context_ = nullptr; }
  void OnComplete(const CefString& error) override {
    Row(error.empty(), "native Profile deletion completed");
    Finish();
  }

 private:
  ~AdBlockApiProof() override = default;
  void Row(bool passed, const char* name) {
    ok_ &= passed;
    fprintf(stderr, "OpenAdBlockApiProof: %s %s\n", passed ? "PASS" : "FAIL", name);
  }
  void Post(void (AdBlockApiProof::*method)(), base::TimeDelta delay = {}) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE, base::BindOnce(method, CefRefPtr<AdBlockApiProof>(this)), delay);
  }
  void Wait(int phase) {
    phase_ = phase;
    deadline_ = base::TimeTicks::Now() + base::Seconds(20);
    Post(&AdBlockApiProof::Poll, base::Milliseconds(10));
  }
  void Configure() {
    auto status = CefGetOpenAdBlockStatus(context_);
    static const char* keys[] = {"enabled", "engine_loaded", "engine_from_dat",
        "engine_shared", "dat_policy", "list_count", "resources_loaded",
        "last_build_ms", "last_error", "excluded_count", "load_generation"};
    bool schema = status && status->GetSize() == std::size(keys);
    for (auto* key : keys) schema &= status && status->HasKey(key);
    Row(schema, "status has exact privacy-safe keys");
    Row(status && !status->GetBool("enabled") && !status->GetBool("engine_loaded") &&
        status->GetDouble("load_generation") == 0, "context starts disabled and empty");
    if (empty_proof_) RecordOpenAdBlockMemoryPhase("api-no-engine");
    Row(CefSetOpenAdBlockExcludedDomains(context_, {"Example.COM.", "example.com"}) &&
        CefSetOpenAdBlockEnabled(context_, true) &&
        CefSetOpenAdBlockListDirectory(context_, root_.value()),
        "configure through production API");
    Wait(1);
  }
  void Poll() {
    auto status = CefGetOpenAdBlockStatus(phase_ == 4 ? otr_ : context_);
    const bool ready = status && (phase_ == 3
        ? !status->GetString("last_error").empty()
        : status->GetDouble("load_generation") ==
              (phase_ == 1 ? 1 : phase_ == 5 ? 3 : phase_ == 4 ? live_generation_ : 2) &&
          ((empty_proof_ && phase_ == 2) || status->GetBool("engine_loaded")));
    if (!ready) {
      if (base::TimeTicks::Now() < deadline_) {
        Post(&AdBlockApiProof::Poll, base::Milliseconds(10));
      } else { Row(false, "async API load deadline"); Finish(); }
      return;
    }
    if (phase_ == 1) {
      Row(status->GetBool("enabled") && status->GetInt("excluded_count") == 1 &&
          status->GetInt("list_count") > 0, "async load enabled with normalized exclusions");
      std::string next;
      if (!base::ReadFileToString(root_.Append("next-current.json"), &next) ||
          !base::WriteFile(root_.Append("current.json"), next)) {
        Row(false, "publish next fixture generation"); Finish(); return;
      }
      Row(CefSetOpenAdBlockListDirectory(context_, root_.value()), "same directory accepted");
      // Drain prior build work instead of guessing when an unwanted reload
      // would finish. The load reply is posted before this barrier's reply.
      AdBlockBuildTaskRunner()->PostTaskAndReply(
          FROM_HERE, base::BindOnce([] {}),
          base::BindOnce(&AdBlockApiProof::SameDirectory,
                         CefRefPtr<AdBlockApiProof>(this)));
    } else if (phase_ == 2) {
      Row(true, "explicit reload publishes generation 2");
      if (empty_proof_) {
        Row(!status->GetBool("engine_loaded") && !status->GetBool("engine_shared") &&
            !status->GetBool("engine_from_dat") && status->GetInt("list_count") == 0 &&
            status->GetInt("resources_loaded") == 0 && status->GetString("last_error").empty(),
            "all lists off publishes no engine or resources without error");
        Post(&AdBlockApiProof::RestoreLists, base::Seconds(6));
      } else {
        FailNextLoad();
      }
    } else if (phase_ == 5) {
      Row(status->GetBool("engine_loaded") && status->GetInt("list_count") > 0 &&
          status->GetDouble("load_generation") > 2 && status->GetString("last_error").empty(),
          "lists restored through production API advance generation");
      live_generation_ = 3;
      FailNextLoad();
    } else if (phase_ == 3) {
      const auto error = status->GetString("last_error").ToString();
      Row(status->GetBool("engine_loaded") && status->GetDouble("load_generation") == live_generation_ &&
          error.find('/') == std::string::npos && error.find(root_.value()) == std::string::npos,
          "failed load keeps engine and hides paths");
      Row(CefSetOpenAdBlockListDirectory(context_, ""), "empty directory unload accepted");
      status = CefGetOpenAdBlockStatus(context_);
      Row(status && !status->GetBool("engine_loaded") && status->GetBool("enabled") &&
          status->GetInt("excluded_count") == 1 && status->GetDouble("load_generation") == 0,
          "unload clears engine and preserves settings");
      Row(CefReloadOpenAdBlockLists(context_), "reload without directory is a no-op");
      // A real load followed by unload must not publish its late result.
      CefSetOpenAdBlockListDirectory(context_, root_.value());
      CefSetOpenAdBlockListDirectory(context_, "");
      AdBlockBuildTaskRunner()->PostTaskAndReply(FROM_HERE, base::BindOnce([] {}),
          base::BindOnce(&AdBlockApiProof::CancelledLoad, CefRefPtr<AdBlockApiProof>(this)));
    } else {
      Row(status->GetBool("engine_shared") && !status->GetBool("enabled") &&
          status->GetInt("excluded_count") == 0,
          "OTR shares engine with independent settings");
      auto parent = CefGetOpenAdBlockStatus(context_);
      Row(parent && parent->GetBool("enabled") && parent->GetInt("excluded_count") == 1,
          "OTR changes leave parent settings intact");
      CloseOtr();
    }
  }
  void RestoreLists() {
    RecordOpenAdBlockMemoryPhase("api-empty-after-reclaim");
    std::string restored;
    if (!base::ReadFileToString(root_.Append("restored-current.json"), &restored) ||
        !base::WriteFile(root_.Append("current.json"), restored)) {
      Row(false, "publish restored fixture generation"); Finish(); return;
    }
    Row(CefReloadOpenAdBlockLists(context_), "restore lists reload accepted");
    Wait(5);
  }
  void FailNextLoad() {
    Row(CefSetOpenAdBlockListDirectory(context_, root_.Append("missing").value()),
        "invalid directory load accepted asynchronously");
    Wait(3);
  }
  void SameDirectory() {
    auto status = CefGetOpenAdBlockStatus(context_);
    Row(status && status->GetDouble("load_generation") == 1,
        "same path does not reread current.json");
    Row(CefReloadOpenAdBlockLists(context_), "explicit reload accepted");
    Wait(2);
  }
  void CancelledLoad() {
    auto status = CefGetOpenAdBlockStatus(context_);
    Row(status && !status->GetBool("engine_loaded"), "pending load cannot republish after unload");
    Row(CefSetOpenAdBlockEnabled(context_, false) &&
        !CefGetOpenAdBlockStatus(context_)->GetBool("enabled") &&
        CefSetOpenAdBlockEnabled(context_, true), "global off/on without restart");
    // Restore parent and wait for it before loading OTR from the same registry.
    CefSetOpenAdBlockListDirectory(context_, root_.value());
    deadline_ = base::TimeTicks::Now() + base::Seconds(20);
    Post(&AdBlockApiProof::OpenOtr, base::Milliseconds(10));
  }
  void OpenOtr() {
    auto status = CefGetOpenAdBlockStatus(context_);
    if (!status || !status->GetBool("engine_loaded")) {
      if (base::TimeTicks::Now() < deadline_) Post(&AdBlockApiProof::OpenOtr, base::Milliseconds(10));
      else { Row(false, "parent restore deadline"); Finish(); }
      return;
    }
    otr_ = CefCreateIncognitoContext(context_, nullptr);
    if (!otr_) { Row(false, "OTR creation"); Finish(); return; }
    Row(CefSetOpenAdBlockListDirectory(otr_, root_.value()) &&
        CefSetOpenAdBlockExcludedDomains(otr_, {}) && CefSetOpenAdBlockEnabled(otr_, false),
        "OTR configured through production API");
    Wait(4);
  }
  void CloseOtr() {
    auto* native = static_cast<CefRequestContextImpl*>(context_.get())->GetInitializedBrowserContext();
    auto* private_native = static_cast<CefRequestContextImpl*>(otr_.get())->GetInitializedBrowserContext();
    if (!native || !private_native) { Row(false, "OTR native close precondition"); Finish(); return; }
    CefReloadOpenAdBlockLists(otr_);
    native->AsProfile()->DestroyOffTheRecordProfile(private_native->AsProfile());
    Row(!CefSetOpenAdBlockEnabled(otr_, true) && !CefSetOpenAdBlockListDirectory(otr_, root_.value()) &&
        !CefReloadOpenAdBlockLists(otr_) && !CefSetOpenAdBlockExcludedDomains(otr_, {}) &&
        !CefGetOpenAdBlockStatus(otr_), "closed retained OTR rejects every control API");
    otr_ = nullptr;
    if (!CefDeleteOpenProfile(context_, this)) { Row(false, "Profile deletion accepted"); Finish(); }
  }
  void Finish() {
    if (!done_) return;
    auto done = std::move(done_);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(done), ok_));
  }

  base::FilePath root_;
  base::OnceCallback<void(bool)> done_;
  CefRefPtr<CefRequestContext> context_, otr_;
  base::TimeTicks deadline_;
  int phase_ = 0;
  int live_generation_ = 2;
  bool empty_proof_ = false;
  bool ok_ = true;
  IMPLEMENT_REFCOUNTING(AdBlockApiProof);
};
}  // namespace
void RunOpenAdBlockApiProof(base::FilePath root, base::OnceCallback<void(bool)> done) {
  CefRefPtr<AdBlockApiProof> proof = new AdBlockApiProof(std::move(root), std::move(done));
  proof->Start();
}
}  // namespace open_engine
#endif
