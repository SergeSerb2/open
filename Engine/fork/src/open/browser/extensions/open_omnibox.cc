// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "cef/include/cef_open_omnibox.h"
#include <limits>
#include <utility>
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/utf_string_conversions.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/request_context_impl.h"
#include "cef/libcef/browser/thread_util.h"
#include "chrome/browser/extensions/api/omnibox/omnibox_api.h"
#include "chrome/browser/omnibox/omnibox_suggestions_watcher_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/extensions/api/omnibox/omnibox_handler.h"
#include "components/omnibox/browser/omnibox_suggestions_watcher.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_util.h"

namespace {
// Chrome's KeywordExtensionsDelegateImpl uses positive ids. Keep a process-wide
// negative namespace for Open and refuse exhaustion instead of recycling ids.
int next_request = -1;
constexpr size_t kMaxText = 16384;
constexpr size_t kMaxRanges = 256;

CefRefPtr<CefDictionaryValue> Row(const std::string& content,
    const std::string& description, bool deletable,
    const ACMatchClassifications& styles) {
  if (content.size() > kMaxText * 4 || description.size() > kMaxText * 4) return nullptr;
  auto text = base::UTF8ToUTF16(description);
  if (base::UTF8ToUTF16(content).size() > kMaxText || text.size() > kMaxText ||
      styles.size() > kMaxRanges) return nullptr;
  auto row = CefDictionaryValue::Create();
  row->SetString("content", content);
  row->SetString("description", description);
  row->SetBool("deletable", deletable);
  for (const auto& [name, mask] : {std::pair{"match", ACMatchClassification::MATCH},
       {"dim", ACMatchClassification::DIM}, {"url", ACMatchClassification::URL}}) {
    auto ranges = CefListValue::Create();
    for (size_t i = 0; i < styles.size(); ++i) {
      size_t from = styles[i].offset;
      size_t to = i + 1 < styles.size() ? styles[i + 1].offset : text.size();
      if (from > to || to > text.size()) return nullptr;
      if (!(styles[i].style & mask) || from == to) continue;
      auto range = CefDictionaryValue::Create();
      range->SetInt("location", from); range->SetInt("length", to - from);
      ranges->SetDictionary(ranges->GetSize(), range);
    }
    row->SetList(name, ranges);
  }
  // Five rows x 16K UTF-16 strings and 256 ranges: under 1 MiB, including
  // dictionaries. The largest string allocation is 64 KiB of UTF-8.
  return row;
}

class Omnibox final : public CefOpenOmnibox,
                      public OmniboxSuggestionsWatcher::Observer,
                      public extensions::ExtensionRegistryObserver {
 public:
  Omnibox(CefRefPtr<CefRequestContextImpl> context,
          CefRefPtr<CefOpenOmniboxHandler> handler)
      : context_(context), handler_(handler),
        profile_(CefRequestContextImpl::GetProfile(context)) {
    suggestions_.Observe(OmniboxSuggestionsWatcherFactory::GetForBrowserContext(profile_->GetOriginalProfile()));
    registry_.Observe(extensions::ExtensionRegistry::Get(profile_));
  }
  void Close() override {
    CEF_REQUIRE_UIT_RETURN_VOID();
    Cancel(session_);
    suggestions_.Reset(); registry_.Reset(); handler_ = nullptr;
    weak_.InvalidateWeakPtrs();
  }
  void Start(const CefString& id) override {
    CEF_REQUIRE_UIT_RETURN_VOID();
    if (!Enabled(id) || session_ == id.ToString()) return;
    Cancel(session_); session_ = id;
    extensions::ExtensionOmniboxEventRouter::OnInputStarted(profile_, session_);
  }
  int InputChanged(const CefString& id, const CefString& text) override {
    CEF_REQUIRE_UIT_RETURN(0);
    request_ = 0; last_reply_ = 0;
    if (session_ != id.ToString() || !Enabled(id) || text.length() > kMaxText ||
        next_request == std::numeric_limits<int>::min()) return 0;
    request_ = next_request--;
    if (!extensions::ExtensionOmniboxEventRouter::OnInputChanged(profile_, id, text, request_)) request_ = 0;
    return request_;
  }
  CefRefPtr<CefDictionaryValue> GetDefault(const CefString& id) override {
    CEF_REQUIRE_UIT_RETURN(nullptr);
    if (!Enabled(id)) return nullptr;
    const auto* dict = extensions::ExtensionPrefs::Get(profile_)->ReadPrefAsDict(id, "omnibox_default_suggestion");
    if (!dict) return nullptr;
    const auto* description = dict->FindString("description");
    if (!description || description->size() > kMaxText * 4) return nullptr;
    const auto* content = dict->FindString("content");
    const auto* raw_styles = dict->FindList("descriptionStyles");
    if ((content && content->size() > kMaxText * 4) ||
        (raw_styles && raw_styles->size() > kMaxRanges)) return nullptr;
    auto value = extensions::api::omnibox::SuggestResult::FromValue(*dict);
    if (!value) return nullptr;
    const std::vector<extensions::api::omnibox::MatchClassification> empty;
    const auto& styles = value->description_styles ? *value->description_styles : empty;
    if (styles.size() > kMaxRanges || base::UTF8ToUTF16(value->description).size() > kMaxText) return nullptr;
    return Row(value->content, value->description, false,
        extensions::StyleTypesToACMatchClassifications(&styles, value->description));
  }
  void Enter(const CefString& id, const CefString& text,
             CefRefPtr<CefBrowser> browser, int disposition) override {
    CEF_REQUIRE_UIT_RETURN_VOID();
    auto host = CefBrowserHostBase::FromBrowser(browser);
    auto* contents = host ? host->GetWebContents() : nullptr;
    if (session_ != id.ToString() || !Enabled(id) || text.length() > kMaxText ||
        !contents || contents->GetBrowserContext() != profile_ || disposition < 0 || disposition > 2) return;
    session_.clear(); request_ = 0; last_reply_ = 0;
    extensions::ExtensionOmniboxEventRouter::OnInputEntered(contents, id, text,
        disposition == 1 ? WindowOpenDisposition::NEW_FOREGROUND_TAB :
        disposition == 2 ? WindowOpenDisposition::NEW_BACKGROUND_TAB : WindowOpenDisposition::CURRENT_TAB);
  }
  void Cancel(const CefString& id) override {
    CEF_REQUIRE_UIT_RETURN_VOID();
    if (session_.empty() || session_ != id.ToString()) return;
    auto old = std::exchange(session_, {}); request_ = 0; last_reply_ = 0;
    extensions::ExtensionOmniboxEventRouter::OnInputCancelled(profile_, old);
  }
  void DeleteSuggestion(const CefString& id, const CefString& content) override {
    CEF_REQUIRE_UIT_RETURN_VOID();
    if (session_ == id.ToString() && Enabled(id) && content.length() <= kMaxText)
      extensions::ExtensionOmniboxEventRouter::OnDeleteSuggestion(profile_, id, content);
  }
  void OnOmniboxSuggestionsReady(const std::vector<ExtensionSuggestion>& values,
      int request, const std::string& id) override {
    if (!request_ || request != request_ || id != session_ || !Enabled(id)) return;
    request_ = 0; // at most one answer, also when an extension calls suggest twice
    auto rows = CefListValue::Create();
    for (const auto& value : values) {
      if (rows->GetSize() == 4) break;
      if (auto row = Row(value.content, value.description, value.deletable, value.match_classifications))
        rows->SetDictionary(rows->GetSize(), row);
    }
    CEF_POST_TASK(CEF_UIT, base::BindOnce([](base::WeakPtr<Omnibox> self,
        int request, std::string id, CefRefPtr<CefListValue> rows) {
      if (self && self->handler_ && self->session_ == id && self->last_reply_ == request)
        self->handler_->OnSuggestions(request, rows);
    }, weak_.GetWeakPtr(), request, id, rows));
    last_reply_ = request;
  }
  void OnOmniboxDefaultSuggestionChanged() override {
    if (session_.empty()) return;
    CEF_POST_TASK(CEF_UIT, base::BindOnce([](base::WeakPtr<Omnibox> self, std::string id) {
      if (self && self->handler_ && self->session_ == id && self->Enabled(id)) self->handler_->OnDefaultChanged(id);
    }, weak_.GetWeakPtr(), session_));
  }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension* extension,
      extensions::UnloadedExtensionReason) override {
    if (session_ == extension->id()) Cancel(session_);
  }
  void OnShutdown(extensions::ExtensionRegistry*) override {
    session_.clear(); request_ = 0; last_reply_ = 0;
    suggestions_.Reset(); registry_.Reset(); handler_ = nullptr;
    weak_.InvalidateWeakPtrs();
  }
 private:
  ~Omnibox() override { Close(); }
  bool Enabled(const CefString& id) {
    if (!handler_ || !registry_.IsObserving()) return false;
    auto* extension = registry_.GetSource()->enabled_extensions().GetByID(id);
    return extension && !extensions::OmniboxInfo::GetKeyword(extension).empty() &&
        (!profile_->IsOffTheRecord() || extensions::util::IsIncognitoEnabled(id, profile_));
  }
  CefRefPtr<CefRequestContextImpl> context_;
  CefRefPtr<CefOpenOmniboxHandler> handler_;
  raw_ptr<Profile> profile_;
  std::string session_;
  int request_ = 0, last_reply_ = 0;
  base::ScopedObservation<OmniboxSuggestionsWatcher, OmniboxSuggestionsWatcher::Observer> suggestions_{this};
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver> registry_{this};
  IMPLEMENT_REFCOUNTING(Omnibox);
  base::WeakPtrFactory<Omnibox> weak_{this};
};
}  // namespace

CefRefPtr<CefOpenOmnibox> CefOpenOmnibox::Create(CefRefPtr<CefRequestContext> context,
    CefRefPtr<CefOpenOmniboxHandler> handler) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  if (!context || !handler) return nullptr;
  auto impl = CefRefPtr<CefRequestContextImpl>(static_cast<CefRequestContextImpl*>(context.get()));
  if (!impl->VerifyBrowserContext() || !CefRequestContextImpl::GetProfile(impl)) return nullptr;
  return new Omnibox(impl, handler);
}
