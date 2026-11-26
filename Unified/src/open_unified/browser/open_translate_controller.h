// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenTranslateController: wraps Chromium 156's ChromeTranslateClient &
// TranslateManager for full-page translation, tracks per-site never-translate
// hosts and offerTranslate preference, provides lightweight selection
// translation, and drives OpenTranslatePopover.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_TRANSLATE_CONTROLLER_H_
#define OPEN_UNIFIED_BROWSER_OPEN_TRANSLATE_CONTROLLER_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "open_unified/ui/views/open_translate_popover.h"
#include "ui/gfx/geometry/rect.h"

namespace content {
class WebContents;
}  // namespace content

namespace network {
class SimpleURLLoader;
}  // namespace network

namespace views {
class View;
class Widget;
}  // namespace views

namespace open_unified {

struct PageTranslateState {
  enum class Status {
    kUnavailable,
    kReady,
    kOffered,
    kTranslating,
    kTranslated,
    kError,
  };

  PageTranslateState();
  PageTranslateState(const PageTranslateState&);
  PageTranslateState(PageTranslateState&&) noexcept;
  PageTranslateState& operator=(const PageTranslateState&);
  PageTranslateState& operator=(PageTranslateState&&) noexcept;
  ~PageTranslateState();

  Status status = Status::kUnavailable;
  std::string source_lang;
  std::string target_lang;
  std::string host;
  std::string error_message;
  bool can_translate = false;
  bool is_translated = false;
  bool is_never_translate_host = false;
  bool is_always_translate_source = false;
};

struct SelectionTranslateResult {
  SelectionTranslateResult();
  SelectionTranslateResult(const SelectionTranslateResult&);
  SelectionTranslateResult(SelectionTranslateResult&&) noexcept;
  SelectionTranslateResult& operator=(const SelectionTranslateResult&);
  SelectionTranslateResult& operator=(SelectionTranslateResult&&) noexcept;
  ~SelectionTranslateResult();

  bool success = false;
  std::string source_lang;
  std::string target_lang;
  std::string translated_text;
  std::string error;
};

class OpenTranslateController : public TranslatePopoverDelegate {
 public:
  static constexpr size_t kMaxNeverTranslateHosts = 1000;
  static constexpr size_t kMaxHostLength = 253;
  static constexpr size_t kMaxSelectionChars = 5000;

  using SelectionTranslateCallback =
      base::OnceCallback<void(SelectionTranslateResult)>;

  class Observer : public base::CheckedObserver {
   public:
    virtual void OnTranslateStateChanged(content::WebContents* web_contents,
                                         const PageTranslateState& state) {}
  };

  explicit OpenTranslateController(base::FilePath state_dir);
  OpenTranslateController(const OpenTranslateController&) = delete;
  OpenTranslateController& operator=(const OpenTranslateController&) = delete;
  ~OpenTranslateController() override;

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Starts observing language detection and translation events on |wc|.
  void ObserveWebContents(content::WebContents* web_contents);

  // Queries Chromium's ChromeTranslateClient / TranslateManager for |wc|.
  PageTranslateState GetPageTranslateState(
      content::WebContents* web_contents) const;

  // Translates |web_contents| from |source_lang| (or "auto") to |target_lang|.
  bool TranslatePage(content::WebContents* web_contents,
                     const std::string& source_lang,
                     const std::string& target_lang);

  // Reverts an active translation back to the page's original language.
  bool RevertTranslation(content::WebContents* web_contents);

  // Sets or clears "Always translate <source_lang> -> <target_lang>" in
  // Chromium's TranslatePrefs.
  void SetAlwaysTranslateLanguage(content::WebContents* web_contents,
                                  const std::string& source_lang,
                                  const std::string& target_lang,
                                  bool always);

  // Persists & honors neverTranslateHosts (lowercase, leading "www." stripped).
  // Off-the-record tabs store choices in memory only.
  void SetNeverTranslateHost(content::WebContents* web_contents,
                             const std::string& host,
                             bool never);
  bool IsNeverTranslateHost(const std::string& host,
                            bool include_incognito = false) const;
  std::vector<std::string> GetNeverTranslateHosts() const;
  void ResetNeverTranslateHosts(content::WebContents* web_contents = nullptr);

  // Honors general.offerTranslate / advanced.translateOffer and Chromium's
  // translate.enabled pref.
  bool IsOfferTranslateEnabled(
      content::WebContents* web_contents = nullptr) const;
  void SetOfferTranslateEnabled(bool enabled,
                                content::WebContents* web_contents = nullptr);

  // Translates a selected text snippet into |target_lang| (defaults to the
  // page's/user's target language when empty).
  void TranslateSelection(content::WebContents* web_contents,
                          const std::string& text,
                          const std::string& target_lang,
                          SelectionTranslateCallback callback);

  // Shows the anchored native Views popover for Page or Selection translation.
  void ShowPagePopover(content::WebContents* web_contents,
                       views::View* anchor,
                       const secondary::Appearance& appearance);
  void ShowSelectionPopover(content::WebContents* web_contents,
                            const std::string& selected_text,
                            views::Widget* parent_widget,
                            const gfx::Rect& anchor_rect_in_screen,
                            const secondary::Appearance& appearance,
                            const std::string& target_lang = "");
  void ClosePopover();
  bool IsPopoverShowing() const;

  // Optional callback invoked when the user clicks "Language Settings...".
  void SetOpenLanguageSettingsCallback(base::RepeatingClosure callback) {
    open_language_settings_callback_ = std::move(callback);
  }

  static std::string NormalizeHost(const std::string& raw_host);

  // TranslatePopoverDelegate:
  void OnTranslateRequested(const std::string& source_lang,
                            const std::string& target_lang) override;
  void OnShowOriginalRequested() override;
  void OnAlwaysTranslateToggled(const std::string& source_lang,
                                const std::string& target_lang,
                                bool always) override;
  void OnNeverTranslateHostToggled(const std::string& host,
                                   bool never) override;
  void OnSelectionTargetLanguageChanged(
      const std::string& target_lang) override;
  void OnCopyTranslatedSelection(const std::u16string& text) override;
  void OnOpenLanguageSettings() override;
  void OnTranslatePopoverClosed() override;

 private:
  class WebContentsTracker;

  void LoadPersistedPrefs();
  void SavePersistedPrefs() const;
  base::FilePath PrefsFilePath() const;
  void OnWebContentsTranslateChanged(content::WebContents* web_contents);
  void OnWebContentsDestroyed(content::WebContents* web_contents);
  TranslatePopoverState BuildPagePopoverState(
      content::WebContents* web_contents) const;
  void OnSelectionLoaderComplete(
      uint64_t request_id,
      std::string target_lang,
      SelectionTranslateCallback callback,
      std::optional<std::string> response_body);
  void OnPopoverSelectionTranslated(uint64_t popover_generation,
                                    SelectionTranslateResult result);

  base::FilePath state_dir_;
  std::vector<std::string> never_translate_hosts_;
  std::set<std::string> incognito_never_translate_hosts_;
  std::optional<bool> offer_translate_override_;

  std::map<content::WebContents*, std::unique_ptr<WebContentsTracker>>
      trackers_;

  std::unique_ptr<OpenTranslatePopover> popover_;
  base::WeakPtr<content::WebContents> popover_web_contents_;
  std::string popover_selected_text_;
  uint64_t popover_generation_ = 0;
  base::RepeatingClosure open_language_settings_callback_;

  uint64_t selection_request_id_ = 0;
  std::unique_ptr<network::SimpleURLLoader> selection_loader_;

  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenTranslateController> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_OPEN_TRANSLATE_CONTROLLER_H_
