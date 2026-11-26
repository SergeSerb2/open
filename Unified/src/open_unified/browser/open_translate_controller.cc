// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_translate_controller.h"

#include <algorithm>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/escape.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/translate/chrome_translate_client.h"
#include "components/language_detection/core/constants.h"
#include "components/prefs/pref_service.h"
#include "components/translate/content/browser/content_translate_driver.h"
#include "components/translate/core/browser/language_state.h"
#include "components/translate/core/browser/translate_driver.h"
#include "components/translate/core/browser/translate_manager.h"
#include "components/translate/core/browser/translate_pref_names.h"
#include "components/translate/core/browser/translate_prefs.h"
#include "components/translate/core/common/translate_errors.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "open_unified/ui/webui/open_settings_ui.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "ui/base/clipboard/clipboard_buffer.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr size_t kMaxSelectionResponseBytes = 256 * 1024;
constexpr base::TimeDelta kSelectionRequestTimeout = base::Seconds(10);

constexpr net::NetworkTrafficAnnotationTag kSelectionTranslateAnnotation =
    net::DefineNetworkTrafficAnnotation("open_translate_selection", R"(
        semantics {
          sender: "Open Selection Translate"
          description:
            "Translates text explicitly selected by the user from the web "
            "page context menu."
          trigger:
            "User invokes Translate Selection on highlighted text."
          data:
            "Selected text snippet and target language code."
          destination: GOOGLE_OWNED_SERVICE
          internal {
            contacts {
              email: "engineering@openbrowser.dev"
            }
          }
          user_data {
            type: USER_CONTENT
          }
          last_reviewed: "2026-11-26"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Controlled by Open Settings -> Offer to translate pages."
          policy_exception_justification:
            "Only invoked on explicit user action."
        })");

std::string TranslateErrorToString(translate::TranslateErrors error) {
  switch (error) {
    case translate::TranslateErrors::NONE:
      return std::string();
    case translate::TranslateErrors::NETWORK:
      return "Network error while translating.";
    case translate::TranslateErrors::UNKNOWN_LANGUAGE:
      return "Could not detect the page language.";
    case translate::TranslateErrors::UNSUPPORTED_LANGUAGE:
      return "This language is not supported.";
    case translate::TranslateErrors::IDENTICAL_LANGUAGES:
      return "The page is already in the target language.";
    case translate::TranslateErrors::TRANSLATION_TIMEOUT:
      return "Translation timed out.";
    default:
      return "Could not translate this page.";
  }
}

void WritePrefsAtomicOnIo(base::FilePath path, std::string json) {
  if (path.empty() || !base::CreateDirectory(path.DirName())) {
    return;
  }
  base::ImportantFileWriter::WriteFileAtomically(path, json);
}

// Parses Google Translate lightweight JSON array:
// [[[translated_chunk, original_chunk, ...], ...], null, "detected_src", ...]
bool ParseSelectionTranslateJson(const std::string& body,
                                 std::string* out_translated,
                                 std::string* out_source_lang) {
  auto parsed = base::JSONReader::Read(body, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_list()) {
    return false;
  }
  const base::ListValue& root = parsed->GetList();
  if (root.empty() || !root[0].is_list()) {
    return false;
  }
  std::string joined;
  for (const base::Value& segment : root[0].GetList()) {
    if (!segment.is_list() || segment.GetList().empty()) {
      continue;
    }
    if (const std::string* piece = segment.GetList()[0].GetIfString()) {
      joined.append(*piece);
    }
  }
  if (joined.empty()) {
    return false;
  }
  *out_translated = std::move(joined);
  if (root.size() >= 3 && root[2].is_string()) {
    *out_source_lang = root[2].GetString();
  }
  return true;
}

}  // namespace

// ===========================================================================
// Per-WebContents Translate Observer
// ===========================================================================

class OpenTranslateController::WebContentsTracker
    : public content::WebContentsObserver,
      public translate::ContentTranslateDriver::TranslationObserver,
      public translate::TranslateDriver::LanguageDetectionObserver {
 public:
  WebContentsTracker(OpenTranslateController* owner,
                     content::WebContents* web_contents)
      : content::WebContentsObserver(web_contents), owner_(owner) {
    AttachDriver();
  }

  ~WebContentsTracker() override { DetachDriver(); }

  const std::string& last_error() const { return last_error_; }
  void ClearError() { last_error_.clear(); }

  // content::WebContentsObserver:
  void WebContentsDestroyed() override {
    DetachDriver();
    content::WebContents* wc = web_contents();
    owner_->OnWebContentsDestroyed(wc);
  }

  // translate::ContentTranslateDriver::TranslationObserver:
  void OnIsPageTranslatedChanged(content::WebContents* source) override {
    owner_->OnWebContentsTranslateChanged(web_contents());
  }

  void OnTranslateEnabledChanged(content::WebContents* source) override {
    owner_->OnWebContentsTranslateChanged(web_contents());
  }

  void OnPageTranslated(std::string_view source_lang,
                        std::string_view translated_lang,
                        translate::TranslateErrors error_type) override {
    last_error_ = TranslateErrorToString(error_type);
    owner_->OnWebContentsTranslateChanged(web_contents());
  }

  // translate::TranslateDriver::LanguageDetectionObserver:
  void OnTranslateDriverDestroyed(translate::TranslateDriver* driver) override {
    DetachDriver();
  }

  void OnLanguageDetermined(
      const translate::LanguageDetectionDetails& details) override {
    last_error_.clear();
    owner_->OnWebContentsTranslateChanged(web_contents());
  }

 private:
  void AttachDriver() {
    if (!web_contents()) {
      return;
    }
    ChromeTranslateClient* client =
        ChromeTranslateClient::FromWebContents(web_contents());
    if (!client || !client->translate_driver()) {
      return;
    }
    driver_ = client->translate_driver();
    driver_->AddTranslationObserver(this);
    driver_->AddLanguageDetectionObserver(this);
  }

  void DetachDriver() {
    if (driver_) {
      driver_->RemoveTranslationObserver(this);
      driver_->RemoveLanguageDetectionObserver(this);
      driver_ = nullptr;
    }
  }

  raw_ptr<OpenTranslateController> owner_;
  raw_ptr<translate::ContentTranslateDriver> driver_ = nullptr;
  std::string last_error_;
};

// ===========================================================================
// Struct Boilerplate
// ===========================================================================

PageTranslateState::PageTranslateState() = default;
PageTranslateState::PageTranslateState(const PageTranslateState&) = default;
PageTranslateState::PageTranslateState(PageTranslateState&&) noexcept = default;
PageTranslateState& PageTranslateState::operator=(const PageTranslateState&) =
    default;
PageTranslateState& PageTranslateState::operator=(
    PageTranslateState&&) noexcept = default;
PageTranslateState::~PageTranslateState() = default;

SelectionTranslateResult::SelectionTranslateResult() = default;
SelectionTranslateResult::SelectionTranslateResult(
    const SelectionTranslateResult&) = default;
SelectionTranslateResult::SelectionTranslateResult(
    SelectionTranslateResult&&) noexcept = default;
SelectionTranslateResult& SelectionTranslateResult::operator=(
    const SelectionTranslateResult&) = default;
SelectionTranslateResult& SelectionTranslateResult::operator=(
    SelectionTranslateResult&&) noexcept = default;
SelectionTranslateResult::~SelectionTranslateResult() = default;

// ===========================================================================
// OpenTranslateController
// ===========================================================================

OpenTranslateController::OpenTranslateController(base::FilePath state_dir)
    : state_dir_(std::move(state_dir)) {
  LoadPersistedPrefs();
}

OpenTranslateController::~OpenTranslateController() {
  ClosePopover();
  selection_loader_.reset();
  trackers_.clear();
}

void OpenTranslateController::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenTranslateController::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

void OpenTranslateController::ObserveWebContents(
    content::WebContents* web_contents) {
  if (!web_contents || trackers_.contains(web_contents)) {
    return;
  }
  trackers_.emplace(web_contents,
                    std::make_unique<WebContentsTracker>(this, web_contents));
}

// static
std::string OpenTranslateController::NormalizeHost(
    const std::string& raw_host) {
  std::string h = base::ToLowerASCII(base::TrimWhitespaceASCII(
      raw_host, base::TRIM_ALL));
  if (h.empty() || h.size() > kMaxHostLength) {
    return std::string();
  }
  if (h.starts_with("www.")) {
    h.erase(0, 4);
  }
  return h;
}

PageTranslateState OpenTranslateController::GetPageTranslateState(
    content::WebContents* web_contents) const {
  PageTranslateState state;
  if (!web_contents) {
    return state;
  }

  const GURL url = web_contents->GetLastCommittedURL();
  state.host = NormalizeHost(url.host());
  const bool off_the_record =
      web_contents->GetBrowserContext() &&
      web_contents->GetBrowserContext()->IsOffTheRecord();
  state.is_never_translate_host =
      IsNeverTranslateHost(state.host, /*include_incognito=*/off_the_record);

  ChromeTranslateClient* client =
      ChromeTranslateClient::FromWebContents(web_contents);
  if (!client) {
    state.target_lang = "en";
    state.source_lang = "auto";
    return state;
  }

  std::string source_lang;
  std::string target_lang;
  client->GetTranslateLanguages(web_contents, &source_lang, &target_lang,
                                /*for_display=*/true);
  if (source_lang.empty() ||
      source_lang == language_detection::kUnknownLanguageCode) {
    source_lang = "auto";
  }
  if (target_lang.empty()) {
    target_lang = "en";
  }
  state.source_lang = source_lang;
  state.target_lang = target_lang;

  if (auto prefs = client->GetTranslatePrefs()) {
    if (!state.host.empty() && prefs->IsSiteOnNeverPromptList(state.host)) {
      state.is_never_translate_host = true;
    }
    if (state.source_lang != "auto") {
      state.is_always_translate_source =
          prefs->IsLanguagePairOnAlwaysTranslateList(state.source_lang,
                                                     state.target_lang);
    }
  }

  const translate::LanguageState& lang_state = client->GetLanguageState();
  state.is_translated = lang_state.IsPageTranslated();
  state.can_translate =
      url.SchemeIsHTTPOrHTTPS() && client->IsTranslatableURL(url);

  if (auto it = trackers_.find(web_contents); it != trackers_.end()) {
    state.error_message = it->second->last_error();
  }

  if (!state.can_translate) {
    state.status = PageTranslateState::Status::kUnavailable;
  } else if (lang_state.translation_pending()) {
    state.status = PageTranslateState::Status::kTranslating;
  } else if (lang_state.IsPageTranslated()) {
    state.status = PageTranslateState::Status::kTranslated;
  } else if (lang_state.translation_error() || !state.error_message.empty()) {
    state.status = PageTranslateState::Status::kError;
  } else if (IsOfferTranslateEnabled(web_contents) &&
             !state.is_never_translate_host &&
             state.source_lang != "auto" &&
             base::ToLowerASCII(state.source_lang) !=
                 base::ToLowerASCII(state.target_lang)) {
    state.status = PageTranslateState::Status::kOffered;
  } else {
    state.status = PageTranslateState::Status::kReady;
  }

  return state;
}

bool OpenTranslateController::TranslatePage(content::WebContents* web_contents,
                                            const std::string& source_lang,
                                            const std::string& target_lang) {
  if (!web_contents) {
    return false;
  }
  ObserveWebContents(web_contents);
  if (auto it = trackers_.find(web_contents); it != trackers_.end()) {
    it->second->ClearError();
  }

  ChromeTranslateClient* client =
      ChromeTranslateClient::FromWebContents(web_contents);
  if (!client) {
    return false;
  }
  translate::TranslateManager* manager = client->GetTranslateManager();
  if (!manager) {
    return false;
  }

  const std::string effective_source =
      (source_lang.empty() || source_lang == "auto")
          ? std::string(language_detection::kUnknownLanguageCode)
          : source_lang;
  const std::string effective_target =
      target_lang.empty() ? "en" : target_lang;

  if (auto prefs = client->GetTranslatePrefs()) {
    prefs->SetRecentTargetLanguage(effective_target);
  }
  manager->TranslatePage(effective_source, effective_target,
                         /*triggered_from_menu=*/true);
  OnWebContentsTranslateChanged(web_contents);
  return true;
}

bool OpenTranslateController::RevertTranslation(
    content::WebContents* web_contents) {
  if (!web_contents) {
    return false;
  }
  translate::TranslateManager* manager =
      ChromeTranslateClient::GetManagerFromWebContents(web_contents);
  if (!manager) {
    return false;
  }
  manager->RevertTranslation();
  OnWebContentsTranslateChanged(web_contents);
  return true;
}

void OpenTranslateController::SetAlwaysTranslateLanguage(
    content::WebContents* web_contents,
    const std::string& source_lang,
    const std::string& target_lang,
    bool always) {
  if (!web_contents || source_lang.empty() || source_lang == "auto" ||
      source_lang == language_detection::kUnknownLanguageCode) {
    return;
  }
  ChromeTranslateClient* client =
      ChromeTranslateClient::FromWebContents(web_contents);
  if (!client) {
    return;
  }
  if (auto prefs = client->GetTranslatePrefs()) {
    if (always) {
      prefs->AddLanguagePairToAlwaysTranslateList(
          source_lang, target_lang.empty() ? "en" : target_lang);
    } else {
      prefs->RemoveLanguagePairFromAlwaysTranslateList(source_lang);
    }
  }
  OnWebContentsTranslateChanged(web_contents);
}

void OpenTranslateController::SetNeverTranslateHost(
    content::WebContents* web_contents,
    const std::string& host,
    bool never) {
  const std::string normalized = NormalizeHost(host);
  if (normalized.empty()) {
    return;
  }

  const bool off_the_record =
      web_contents && web_contents->GetBrowserContext() &&
      web_contents->GetBrowserContext()->IsOffTheRecord();

  if (off_the_record) {
    if (never) {
      incognito_never_translate_hosts_.insert(normalized);
    } else {
      incognito_never_translate_hosts_.erase(normalized);
    }
  } else {
    std::erase(never_translate_hosts_, normalized);
    if (never) {
      never_translate_hosts_.push_back(normalized);
      if (never_translate_hosts_.size() > kMaxNeverTranslateHosts) {
        never_translate_hosts_.erase(
            never_translate_hosts_.begin(),
            never_translate_hosts_.begin() +
                static_cast<ptrdiff_t>(never_translate_hosts_.size() -
                                       kMaxNeverTranslateHosts));
      }
    }
    SavePersistedPrefs();

    if (web_contents) {
      if (ChromeTranslateClient* client =
              ChromeTranslateClient::FromWebContents(web_contents)) {
        if (auto prefs = client->GetTranslatePrefs()) {
          if (never) {
            prefs->AddSiteToNeverPromptList(normalized);
          } else {
            prefs->RemoveSiteFromNeverPromptList(normalized);
          }
        }
      }
    }
  }

  if (never && web_contents) {
    const PageTranslateState st = GetPageTranslateState(web_contents);
    if (st.is_translated) {
      RevertTranslation(web_contents);
    }
  }
  if (web_contents) {
    OnWebContentsTranslateChanged(web_contents);
  }
}

bool OpenTranslateController::IsNeverTranslateHost(
    const std::string& host,
    bool include_incognito) const {
  const std::string normalized = NormalizeHost(host);
  if (normalized.empty()) {
    return false;
  }
  if (std::find(never_translate_hosts_.begin(), never_translate_hosts_.end(),
                normalized) != never_translate_hosts_.end()) {
    return true;
  }
  if (include_incognito &&
      incognito_never_translate_hosts_.contains(normalized)) {
    return true;
  }
  return false;
}

std::vector<std::string> OpenTranslateController::GetNeverTranslateHosts()
    const {
  return never_translate_hosts_;
}

void OpenTranslateController::ResetNeverTranslateHosts(
    content::WebContents* web_contents) {
  if (web_contents) {
    if (ChromeTranslateClient* client =
            ChromeTranslateClient::FromWebContents(web_contents)) {
      if (auto prefs = client->GetTranslatePrefs()) {
        for (const std::string& host : never_translate_hosts_) {
          prefs->RemoveSiteFromNeverPromptList(host);
        }
      }
    }
  }
  never_translate_hosts_.clear();
  incognito_never_translate_hosts_.clear();
  SavePersistedPrefs();
  if (web_contents) {
    OnWebContentsTranslateChanged(web_contents);
  }
}

bool OpenTranslateController::IsOfferTranslateEnabled(
    content::WebContents* web_contents) const {
  if (offer_translate_override_.has_value()) {
    return *offer_translate_override_;
  }
  // Honor OpenPreferences (supports both general.offerTranslate and
  // advanced.translateOffer).
  if (auto* open_prefs = webui::OpenPreferences::Get()) {
    const base::Value gen = open_prefs->GetValue("general.offerTranslate");
    if (gen.is_bool()) {
      return gen.GetBool();
    }
    const base::Value adv = open_prefs->GetValue("advanced.translateOffer");
    if (adv.is_bool() && !adv.GetBool()) {
      return false;
    }
  }
  if (web_contents) {
    if (ChromeTranslateClient* client =
            ChromeTranslateClient::FromWebContents(web_contents)) {
      if (auto prefs = client->GetTranslatePrefs()) {
        return prefs->IsOfferTranslateEnabled();
      }
    }
  }
  return true;
}

void OpenTranslateController::SetOfferTranslateEnabled(
    bool enabled,
    content::WebContents* web_contents) {
  offer_translate_override_ = enabled;
  if (web_contents) {
    if (ChromeTranslateClient* client =
            ChromeTranslateClient::FromWebContents(web_contents)) {
      if (PrefService* pref_service = client->GetPrefs()) {
        pref_service->SetBoolean(translate::prefs::kOfferTranslateEnabled,
                                 enabled);
      }
    }
  }
  SavePersistedPrefs();
  if (web_contents) {
    OnWebContentsTranslateChanged(web_contents);
  }
}

void OpenTranslateController::TranslateSelection(
    content::WebContents* web_contents,
    const std::string& text,
    const std::string& target_lang,
    SelectionTranslateCallback callback) {
  std::string trimmed = std::string(
      base::TrimWhitespaceASCII(text, base::TRIM_ALL));
  if (trimmed.empty()) {
    SelectionTranslateResult res;
    res.error = "No text selected to translate.";
    std::move(callback).Run(std::move(res));
    return;
  }
  if (trimmed.size() > kMaxSelectionChars) {
    trimmed = std::string(
        base::TruncateUTF8ToByteSize(trimmed, kMaxSelectionChars));
  }

  std::string effective_target = target_lang;
  if (effective_target.empty() && web_contents) {
    effective_target = GetPageTranslateState(web_contents).target_lang;
  }
  if (effective_target.empty()) {
    effective_target = "en";
  }

  scoped_refptr<network::SharedURLLoaderFactory> factory;
  if (web_contents && web_contents->GetBrowserContext()) {
    if (auto* partition =
            web_contents->GetBrowserContext()->GetDefaultStoragePartition()) {
      factory = partition->GetURLLoaderFactoryForBrowserProcess();
    }
  }
  if (!factory) {
    SelectionTranslateResult res;
    res.target_lang = effective_target;
    res.error = "Translation network service is unavailable.";
    std::move(callback).Run(std::move(res));
    return;
  }

  const uint64_t request_id = ++selection_request_id_;
  selection_loader_.reset();

  const std::string url_str =
      "https://translate.googleapis.com/translate_a/single?client=gtx"
      "&sl=auto&tl=" +
      base::EscapeQueryParamValue(effective_target, /*use_plus=*/false) +
      "&dt=t&q=" + base::EscapeQueryParamValue(trimmed, /*use_plus=*/true);

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = GURL(url_str);
  request->method = "GET";
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;

  selection_loader_ =
      network::SimpleURLLoader::Create(std::move(request),
                                       kSelectionTranslateAnnotation);
  selection_loader_->SetTimeoutDuration(kSelectionRequestTimeout);
  selection_loader_->DownloadToString(
      factory.get(),
      base::BindOnce(&OpenTranslateController::OnSelectionLoaderComplete,
                     weak_factory_.GetWeakPtr(), request_id, effective_target,
                     std::move(callback)),
      kMaxSelectionResponseBytes);
}

void OpenTranslateController::ShowPagePopover(
    content::WebContents* web_contents,
    views::View* anchor,
    const secondary::Appearance& appearance) {
  if (!web_contents || !anchor) {
    return;
  }
  ObserveWebContents(web_contents);
  popover_web_contents_ = web_contents->GetWeakPtr();
  popover_selected_text_.clear();
  ++popover_generation_;

  if (!popover_) {
    popover_ = std::make_unique<OpenTranslatePopover>(this);
  }
  popover_->Show(anchor, BuildPagePopoverState(web_contents), appearance);
}

void OpenTranslateController::ShowSelectionPopover(
    content::WebContents* web_contents,
    const std::string& selected_text,
    views::Widget* parent_widget,
    const gfx::Rect& anchor_rect_in_screen,
    const secondary::Appearance& appearance,
    const std::string& target_lang) {
  if (!web_contents || !parent_widget) {
    return;
  }
  ObserveWebContents(web_contents);
  popover_web_contents_ = web_contents->GetWeakPtr();
  popover_selected_text_ = selected_text;
  const uint64_t gen = ++popover_generation_;

  const PageTranslateState page_state = GetPageTranslateState(web_contents);
  const std::string effective_target =
      target_lang.empty() ? page_state.target_lang : target_lang;

  TranslatePopoverState state;
  state.mode = TranslatePopoverMode::kSelection;
  state.source_lang = "auto";
  state.target_lang = effective_target.empty() ? "en" : effective_target;
  state.host = page_state.host;
  state.selected_text = base::UTF8ToUTF16(selected_text);
  state.selection_loading = true;

  if (!popover_) {
    popover_ = std::make_unique<OpenTranslatePopover>(this);
  }
  popover_->ShowAtRect(parent_widget, anchor_rect_in_screen, state, appearance);

  TranslateSelection(
      web_contents, selected_text, state.target_lang,
      base::BindOnce(&OpenTranslateController::OnPopoverSelectionTranslated,
                     weak_factory_.GetWeakPtr(), gen));
}

void OpenTranslateController::ClosePopover() {
  ++popover_generation_;
  popover_web_contents_.reset();
  popover_selected_text_.clear();
  if (popover_) {
    popover_->Close();
  }
}

bool OpenTranslateController::IsPopoverShowing() const {
  return popover_ && popover_->IsShowing();
}

void OpenTranslateController::OnTranslateRequested(
    const std::string& source_lang,
    const std::string& target_lang) {
  if (!popover_web_contents_) {
    return;
  }
  TranslatePage(popover_web_contents_.get(), source_lang, target_lang);
}

void OpenTranslateController::OnShowOriginalRequested() {
  if (!popover_web_contents_) {
    return;
  }
  RevertTranslation(popover_web_contents_.get());
}

void OpenTranslateController::OnAlwaysTranslateToggled(
    const std::string& source_lang,
    const std::string& target_lang,
    bool always) {
  if (!popover_web_contents_) {
    return;
  }
  SetAlwaysTranslateLanguage(popover_web_contents_.get(), source_lang,
                             target_lang, always);
}

void OpenTranslateController::OnNeverTranslateHostToggled(
    const std::string& host,
    bool never) {
  SetNeverTranslateHost(popover_web_contents_.get(), host, never);
  if (never) {
    ClosePopover();
  }
}

void OpenTranslateController::OnSelectionTargetLanguageChanged(
    const std::string& target_lang) {
  if (!popover_web_contents_ || popover_selected_text_.empty() ||
      !IsPopoverShowing()) {
    return;
  }
  const uint64_t gen = ++popover_generation_;
  if (popover_ && popover_->contents()) {
    TranslatePopoverState state = popover_->contents()->state();
    state.target_lang = target_lang;
    state.selection_loading = true;
    state.error.clear();
    popover_->UpdateState(state);
  }
  TranslateSelection(
      popover_web_contents_.get(), popover_selected_text_, target_lang,
      base::BindOnce(&OpenTranslateController::OnPopoverSelectionTranslated,
                     weak_factory_.GetWeakPtr(), gen));
}

void OpenTranslateController::OnCopyTranslatedSelection(
    const std::u16string& text) {
  if (text.empty()) {
    return;
  }
  ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
  writer.WriteText(text);
}

void OpenTranslateController::OnOpenLanguageSettings() {
  ClosePopover();
  if (open_language_settings_callback_) {
    open_language_settings_callback_.Run();
  }
}

void OpenTranslateController::OnTranslatePopoverClosed() {
  ++popover_generation_;
  popover_web_contents_.reset();
  popover_selected_text_.clear();
}

void OpenTranslateController::LoadPersistedPrefs() {
  const base::FilePath path = PrefsFilePath();
  if (path.empty() || !base::PathExists(path)) {
    return;
  }
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(path, &contents, 512 * 1024)) {
    return;
  }
  auto parsed = base::JSONReader::ReadDict(contents, base::JSON_PARSE_RFC);
  if (!parsed) {
    return;
  }
  if (const std::optional<bool> offer = parsed->FindBool("offerTranslate")) {
    offer_translate_override_ = *offer;
  }
  if (const base::ListValue* hosts = parsed->FindList("neverTranslateHosts")) {
    never_translate_hosts_.clear();
    for (const base::Value& entry : *hosts) {
      if (const std::string* raw = entry.GetIfString()) {
        std::string norm = NormalizeHost(*raw);
        if (!norm.empty() &&
            std::find(never_translate_hosts_.begin(),
                      never_translate_hosts_.end(),
                      norm) == never_translate_hosts_.end()) {
          never_translate_hosts_.push_back(std::move(norm));
          if (never_translate_hosts_.size() >= kMaxNeverTranslateHosts) {
            break;
          }
        }
      }
    }
  }
}

void OpenTranslateController::SavePersistedPrefs() const {
  const base::FilePath path = PrefsFilePath();
  if (path.empty()) {
    return;
  }
  base::DictValue root;
  if (offer_translate_override_.has_value()) {
    root.Set("offerTranslate", *offer_translate_override_);
  }
  base::ListValue hosts;
  for (const std::string& host : never_translate_hosts_) {
    hosts.Append(host);
  }
  root.Set("neverTranslateHosts", std::move(hosts));

  std::string json;
  if (base::JSONWriter::Write(root, &json)) {
    base::ThreadPool::PostTask(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
        base::BindOnce(&WritePrefsAtomicOnIo, path, std::move(json)));
  }
}

base::FilePath OpenTranslateController::PrefsFilePath() const {
  return state_dir_.empty() ? base::FilePath()
                            : state_dir_.AppendASCII("translate_prefs.json");
}

void OpenTranslateController::OnWebContentsTranslateChanged(
    content::WebContents* web_contents) {
  if (!web_contents) {
    return;
  }
  const PageTranslateState state = GetPageTranslateState(web_contents);
  for (Observer& obs : observers_) {
    obs.OnTranslateStateChanged(web_contents, state);
  }
  if (IsPopoverShowing() && popover_web_contents_.get() == web_contents &&
      popover_->contents() &&
      popover_->contents()->state().mode != TranslatePopoverMode::kSelection) {
    popover_->UpdateState(BuildPagePopoverState(web_contents));
  }
}

void OpenTranslateController::OnWebContentsDestroyed(
    content::WebContents* web_contents) {
  if (popover_web_contents_.get() == web_contents) {
    ClosePopover();
  }
  trackers_.erase(web_contents);
}

TranslatePopoverState OpenTranslateController::BuildPagePopoverState(
    content::WebContents* web_contents) const {
  const PageTranslateState page = GetPageTranslateState(web_contents);
  TranslatePopoverState out;
  out.source_lang = page.source_lang.empty() ? "auto" : page.source_lang;
  out.target_lang = page.target_lang.empty() ? "en" : page.target_lang;
  out.host = page.host;
  out.always_translate_source = page.is_always_translate_source;
  out.never_translate_host = page.is_never_translate_host;
  out.error = base::UTF8ToUTF16(page.error_message);
  switch (page.status) {
    case PageTranslateState::Status::kTranslating:
      out.mode = TranslatePopoverMode::kTranslating;
      break;
    case PageTranslateState::Status::kTranslated:
      out.mode = TranslatePopoverMode::kTranslated;
      break;
    default:
      out.mode = TranslatePopoverMode::kOffer;
      break;
  }
  return out;
}

void OpenTranslateController::OnSelectionLoaderComplete(
    uint64_t request_id,
    std::string target_lang,
    SelectionTranslateCallback callback,
    std::optional<std::string> response_body) {
  if (request_id != selection_request_id_) {
    return;
  }
  selection_loader_.reset();

  SelectionTranslateResult result;
  result.target_lang = std::move(target_lang);
  if (!response_body.has_value() || response_body->empty()) {
    result.error = "Could not reach translation service.";
    std::move(callback).Run(std::move(result));
    return;
  }

  std::string translated;
  std::string detected_source;
  if (!ParseSelectionTranslateJson(*response_body, &translated,
                                   &detected_source)) {
    result.error = "Could not parse translation response.";
    std::move(callback).Run(std::move(result));
    return;
  }

  result.success = true;
  result.source_lang = std::move(detected_source);
  result.translated_text = std::move(translated);
  std::move(callback).Run(std::move(result));
}

void OpenTranslateController::OnPopoverSelectionTranslated(
    uint64_t popover_generation,
    SelectionTranslateResult result) {
  if (popover_generation != popover_generation_ || !IsPopoverShowing() ||
      !popover_ || !popover_->contents()) {
    return;
  }
  TranslatePopoverState state = popover_->contents()->state();
  state.mode = TranslatePopoverMode::kSelection;
  state.selection_loading = false;
  if (!result.source_lang.empty()) {
    state.source_lang = result.source_lang;
  }
  if (!result.target_lang.empty()) {
    state.target_lang = result.target_lang;
  }
  if (result.success) {
    state.translated_selection = base::UTF8ToUTF16(result.translated_text);
    state.error.clear();
  } else {
    state.translated_selection.clear();
    state.error = base::UTF8ToUTF16(result.error);
  }
  popover_->UpdateState(state);
}

}  // namespace open_unified
