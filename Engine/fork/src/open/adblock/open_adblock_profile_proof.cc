// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "open/adblock/open_adblock_profile_proof.h"
#include <cstdio>
#include <utility>
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "cef/include/cef_open_profile.h"
#include "cef/libcef/browser/browser_context.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "open/adblock/open_adblock_matcher.h"
#include "open/adblock/open_adblock_service.h"
#if !defined(OFFICIAL_BUILD)
namespace open_engine {
namespace {

Profile* LiveProfile(CefRefPtr<CefRequestContext> context) {
  if (!context) return nullptr;
  auto* native = static_cast<CefRequestContextImpl*>(context.get())
                     ->GetInitializedBrowserContext();
  return native ? native->AsProfile() : nullptr;
}

// Real CEF Profile/OTR lifecycle exercise; no pages, isolated user-data root.
// A handler may be called inside native teardown, so it only records there.
class AdBlockProfileProof final : public CefRequestContextHandler,
                                 public CefOpenProfileHandler,
                                 public CefOpenProfileDeletionHandler {
 public:
  AdBlockProfileProof(base::FilePath root, base::OnceCallback<void(bool)> done)
      : root_(std::move(root)), done_(std::move(done)) {}

  void Start() {
    auto* manager = g_browser_process->profile_manager();
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) =
        manager->user_data_dir().Append("OpenAdBlockProof").value();
    parent_ = CefRequestContext::CreateContext(settings, this);
    if (!parent_) {
      Row(false, "parent creation");
      Finish();
    }
  }

  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    // The CEF callback can be on the creation stack. Do not drop handles there.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&AdBlockProfileProof::LoadParent,
                                 CefRefPtr<AdBlockProfileProof>(this)));
  }

  void OnContextClosed() override { ++closed_; }

  void OnReadyToRelease() override { parent_ = nullptr; }

  void OnComplete(const CefString& error) override {
    Row(error.empty(), "parent native deletion completed");
    Row(!parent_service_, "parent service weak lifetime ended");
    AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(
            [](scoped_refptr<OpenAdBlockMatcher> parent,
               scoped_refptr<OpenAdBlockMatcher> otr) {
              return !parent->IsEnabled() && !parent->HasEngine() &&
                     !otr->IsEnabled() && !otr->HasEngine();
            }, parent_matcher_, otr_matcher_),
        base::BindOnce(&AdBlockProfileProof::DeletedMatchers,
                      CefRefPtr<AdBlockProfileProof>(this)));
  }

 private:
  ~AdBlockProfileProof() override = default;

  void Row(bool passed, const char* name) {
    ok_ &= passed;
    fprintf(stderr, "OpenAdBlockProfileProof: %s %s\n",
            passed ? "PASS" : "FAIL", name);
  }

  void LoadParent() {
    auto* context = static_cast<CefRequestContextImpl*>(parent_.get())
                        ->GetInitializedBrowserContext();
    auto* service = context ? context->open_adblock_service() : nullptr;
    if (!service) {
      Row(false, "parent service created");
      Finish();
      return;
    }
    parent_service_ = service->GetWeakPtr();
    parent_matcher_ = service->matcher();
    service->SetEnabled(true);
    service->LoadFromDirectory(root_, false,
        base::BindOnce(&AdBlockProfileProof::ParentLoaded,
                      CefRefPtr<AdBlockProfileProof>(this)));
  }

  void ParentLoaded(AdBlockLoadResult result) {
    Row(result == AdBlockLoadResult::kLoaded, "parent engine loaded");
    otr_ = CefCreateIncognitoContext(parent_, nullptr);
    Profile* parent_profile = LiveProfile(parent_);
    Profile* otr_profile = LiveProfile(otr_);
    Row(parent_profile && otr_profile && otr_profile->IsOffTheRecord() &&
            otr_profile->GetOriginalProfile() == parent_profile,
        "OTR belongs to requested parent");
    if (!otr_profile) {
      Finish();
      return;
    }
    otr_context_ = static_cast<CefRequestContextImpl*>(otr_.get())
                       ->GetInitializedBrowserContext();
    auto* service = otr_context_ ? otr_context_->open_adblock_service() : nullptr;
    if (!service) {
      Row(false, "OTR service created");
      Finish();
      return;
    }
    otr_service_ = service->GetWeakPtr();
    otr_matcher_ = service->matcher();
    Row(service != parent_service_.get(), "per-context services are distinct");
    CefSetOpenProfileHandler(otr_, this);
    service->SetEnabled(true);
    service->LoadFromDirectory(root_, true,
        base::BindOnce(&AdBlockProfileProof::OtrLoaded,
                      CefRefPtr<AdBlockProfileProof>(this)));
  }

  void OtrLoaded(AdBlockLoadResult result) {
    Row(result == AdBlockLoadResult::kLoaded &&
            otr_service_->GetStatus().engine_shared,
        "OTR engine_shared=1 for same lists");
    AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(
            [](scoped_refptr<OpenAdBlockMatcher> parent,
               scoped_refptr<OpenAdBlockMatcher> otr) {
              return parent->SharesEngineWithForDiagnostics(*otr) &&
                     parent->IsEnabled() && otr->IsEnabled();
            }, parent_matcher_, otr_matcher_),
        base::BindOnce(&AdBlockProfileProof::Shared,
                      CefRefPtr<AdBlockProfileProof>(this)));
  }

  void Shared(bool shared) {
    Row(shared, "matcher holder identity shared");
    // Queue a real load and destroy the native OTR before its UI reply.
    // The wrapper remains retained, as the public 0701 contract allows.
    otr_service_->LoadFromDirectory(root_, false,
        base::BindOnce(&AdBlockProfileProof::PendingCancelled,
                      CefRefPtr<AdBlockProfileProof>(this)));
    Profile* parent_profile = LiveProfile(parent_);
    Profile* otr_profile = LiveProfile(otr_);
    if (!parent_profile || !otr_profile) {
      Row(false, "profiles live before OTR close");
      Finish();
      return;
    }
    parent_profile->DestroyOffTheRecordProfile(otr_profile);
    Row(!CefIsOpenProfileContextLive(otr_) && closed_ == 1,
        "retained OTR wrapper closed once");
    Row(!otr_service_ && otr_context_->open_adblock_service() == nullptr,
        "OTR service destroyed and cannot be recreated");
    // Idempotence: repeated owner shutdown does not recreate or free twice.
    otr_context_->ShutdownOpenAdBlockService();
    Row(otr_context_->open_adblock_service() == nullptr,
        "OTR repeated shutdown remains closed");
  }

  void PendingCancelled(AdBlockLoadResult result) {
    Row(result == AdBlockLoadResult::kCancelled,
        "pending OTR load callback cancelled exactly once");
    AdBlockMatcherTaskRunner()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(
            [](scoped_refptr<OpenAdBlockMatcher> parent,
               scoped_refptr<OpenAdBlockMatcher> otr) {
              return parent->IsEnabled() && parent->HasEngine() &&
                     !otr->IsEnabled() && !otr->HasEngine();
            }, parent_matcher_, otr_matcher_),
        base::BindOnce(&AdBlockProfileProof::OtrClosed,
                      CefRefPtr<AdBlockProfileProof>(this)));
  }

  void OtrClosed(bool isolated) {
    Row(isolated && parent_service_ && CefIsOpenProfileContextLive(parent_),
        "OTR matcher disabled while parent remains active");
    otr_context_ = nullptr;
    otr_ = nullptr;
    Row(CefDeleteOpenProfile(parent_, this), "parent ordered deletion accepted");
  }

  void DeletedMatchers(bool disabled) {
    Row(disabled, "parent and OTR matchers disabled after parent shutdown");
    Finish();
  }

  void Finish() {
    if (done_) {
      auto done = std::move(done_);
      // Leave callback stacks before the caller can stop CEF.
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(std::move(done), ok_));
    }
  }

  base::FilePath root_;
  base::OnceCallback<void(bool)> done_;
  CefRefPtr<CefRequestContext> parent_;
  CefRefPtr<CefRequestContext> otr_;
  raw_ptr<CefBrowserContext> otr_context_ = nullptr;
  base::WeakPtr<OpenAdBlockService> parent_service_;
  base::WeakPtr<OpenAdBlockService> otr_service_;
  scoped_refptr<OpenAdBlockMatcher> parent_matcher_;
  scoped_refptr<OpenAdBlockMatcher> otr_matcher_;
  bool ok_ = true;
  int closed_ = 0;
  IMPLEMENT_REFCOUNTING(AdBlockProfileProof);
};
}  // namespace

void RunOpenAdBlockProfileProof(base::FilePath root,
                               base::OnceCallback<void(bool)> done) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("open-adblock-api-proof")) {
    RunOpenAdBlockApiProof(std::move(root), std::move(done));
    return;
  }
  CefRefPtr<AdBlockProfileProof> proof =
      new AdBlockProfileProof(std::move(root), std::move(done));
  proof->Start();
}
}  // namespace open_engine
#endif  // !defined(OFFICIAL_BUILD)
