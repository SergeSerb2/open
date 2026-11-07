// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#include "open/browser/autofill/open_autofill_bubble_handler.h"

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/ui/autofill/autofill_bubble_base.h"
#include "chrome/browser/ui/autofill/address_bubbles_controller.h"
#include "chrome/browser/ui/autofill/autofill_ai/autofill_ai_import_data_controller.h"
#include "chrome/browser/ui/autofill/payments/filled_card_information_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/iban_bubble_controller.h"
#include "chrome/browser/ui/autofill/payments/mandatory_reauth_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/offer_notification_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/omnibox_autofill_bubble_controller.h"
#include "chrome/browser/ui/autofill/payments/payments_churned_users_bubble_controller.h"
#include "chrome/browser/ui/autofill/payments/save_card_bubble_controller_impl.h"
#include "components/autofill/core/browser/ui/payments/virtual_card_enroll_bubble_controller.h"
#include "chrome/browser/ui/autofill/payments/wallet_reminder_notice_bubble_controller.h"
#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/application_locale_storage/application_locale_storage.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/ui/addresses/autofill_address_util.h"
#include "open/browser/autofill/open_autofill_handler_registry.h"
#include "open/browser/autofill/open_save_prompt_impl.h"

namespace open_engine {
namespace {
using namespace autofill;

// Like a Views bubble, these objects own their lifetime. Close on a later
// turn so the caller can first install the required non-null view. Hide
// settles the old offer before its controller can install a replacement.
class NullAutofillBubble final : public AutofillBubbleBase {
 public:
  static AutofillBubbleBase* Create(base::OnceClosure close) {
    auto* bubble = new NullAutofillBubble(std::move(close));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&NullAutofillBubble::Close, bubble->weak_.GetWeakPtr()));
    return bubble;
  }
  void Hide() override { Close(); }
  bool IsMouseHovered() const override { return false; }
 private:
  explicit NullAutofillBubble(base::OnceClosure close) : close_(std::move(close)) {}
  void Close() {
    if (closed_) return;
    closed_ = true;
    weak_.InvalidateWeakPtrs();
    if (close_) std::move(close_).Run();
    // Hide can be called inside a controller destructor. Let its raw view
    // pointer clear before freeing the bubble.
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }
  bool closed_ = false;
  base::OnceClosure close_;
  base::WeakPtrFactory<NullAutofillBubble> weak_{this};
};

class PromptBubble final : public AutofillBubbleBase {
 public:
  base::WeakPtr<OpenSavePrompt> prompt;
  void Hide() override { if (prompt) prompt->Withdraw(); }
  bool IsMouseHovered() const override { return false; }
};

template<class Concrete, class Interface>
base::OnceClosure ClosePayment(Interface* controller) {
  auto weak = static_cast<Concrete*>(controller)->GetBubbleControllerBaseWeakPtr();
  return base::BindOnce([](base::WeakPtr<BubbleControllerBase> weak,
                           Interface* controller) {
    if (weak) controller->OnBubbleClosed(PaymentsUiClosedReason::kNotInteracted);
  }, weak, controller);
}

template<class Controller>
AutofillBubbleBase* AddressPrompt(content::WebContents* contents,
    std::unique_ptr<Controller> controller, const AutofillProfile& profile,
    std::u16string label, int kind, bool user_gesture) {
  auto bubble = std::make_unique<PromptBubble>();
  auto* result = bubble.get();
  CefRefPtr<OpenSavePrompt> prompt = new OpenSavePrompt(contents, kind, user_gesture,
      base::BindOnce([](std::unique_ptr<PromptBubble> bubble,
                       std::unique_ptr<Controller> controller,
                       AutofillProfile profile, int answer) {
        using Decision = AutofillClient::AddressPromptUserDecision;
        controller->OnUserDecision(answer == 0 ? Decision::kAccepted
                                    : answer == 2 ? Decision::kDeclined
                                                  : Decision::kIgnored,
                                   answer == 0 ? base::optional_ref<const AutofillProfile>(profile)
                                               : base::optional_ref<const AutofillProfile>());
        controller->OnBubbleClosed();
      }, std::move(bubble), std::move(controller), profile));
  prompt->SetLabels({}, {}, base::CollapseWhitespace(label, false));
  result->prompt = prompt->GetWeakPtr();
  ShowSavePrompt(prompt);
  return result;
}
}  // namespace

OpenAutofillBubbleHandler::OpenAutofillBubbleHandler() = default;
OpenAutofillBubbleHandler::~OpenAutofillBubbleHandler() = default;
void OpenAutofillBubbleHandler::SetBrowser(BrowserWindowInterface* browser) {
  scoped_user_data_.reset();
  if (browser) scoped_user_data_ = std::make_unique<
      ui::ScopedUnownedUserData<autofill::AutofillBubbleHandler>>(
          browser->GetUnownedUserDataHost(), *this);
}

autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowSaveCreditCardBubble(
    content::WebContents* contents, autofill::SaveCardBubbleController* controller,
    bool user_gesture) {
  using namespace autofill;
  auto bubble = std::make_unique<PromptBubble>();
  auto* result = bubble.get();
  auto weak = static_cast<SaveCardBubbleControllerImpl*>(controller)
                  ->GetBubbleControllerBaseWeakPtr();
  auto close = controller->GetOnBubbleClosedCallback();
  CefRefPtr<OpenSavePrompt> prompt = new OpenSavePrompt(contents, 2, user_gesture,
      base::BindOnce([](std::unique_ptr<PromptBubble> bubble,
                       base::WeakPtr<BubbleControllerBase> weak,
                       SaveCardBubbleController* controller,
                       base::OnceCallback<void(PaymentsUiClosedReason)> close,
                       int answer) {
        if (weak && answer == 0) controller->OnSaveButton({});
        std::move(close).Run(answer == 0 ? PaymentsUiClosedReason::kAccepted
                            : answer == 2 ? PaymentsUiClosedReason::kCancelled
                                          : PaymentsUiClosedReason::kNotInteracted);
      }, std::move(bubble), weak, controller, std::move(close)));
  prompt->SetLabels({}, controller->GetCard().NetworkAndLastFourDigits(), {});
  result->prompt = prompt->GetWeakPtr();
  ShowSavePrompt(prompt);
  return result;
}

autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowSaveAddressProfileBubble(
    content::WebContents* contents,
    std::unique_ptr<autofill::SaveAddressBubbleController> controller, bool gesture) {
  auto profile = controller->GetAutofillProfile();
  auto label = controller->GetAddressSummary();
  return AddressPrompt(contents, std::move(controller), profile, label, 3, gesture);
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowUpdateAddressProfileBubble(
    content::WebContents* contents,
    std::unique_ptr<autofill::UpdateAddressBubbleController> controller, bool gesture) {
  auto profile = controller->GetProfileToSave();
  auto label = autofill::GetEnvelopeStyleAddress(profile,
      g_browser_process->GetFeatures()->application_locale_storage()->GetTag().tag_string(),
      /*include_recipient=*/true, /*include_country=*/true);
  return AddressPrompt(contents, std::move(controller), profile, label, 4, gesture);
}

autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowIbanBubble(
    content::WebContents*, autofill::IbanBubbleController* c, bool,
    autofill::IbanBubbleType) {
  return NullAutofillBubble::Create(base::BindOnce(c->GetOnBubbleClosedCallback(),
      autofill::PaymentsUiClosedReason::kNotInteracted));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowSaveIbanConfirmationBubble(
    content::WebContents*, autofill::IbanBubbleController* c) {
  return NullAutofillBubble::Create(base::BindOnce(c->GetOnBubbleClosedCallback(),
      autofill::PaymentsUiClosedReason::kNotInteracted));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowSaveCardConfirmationBubble(
    content::WebContents*, autofill::SaveCardBubbleController* c) {
  return NullAutofillBubble::Create(base::BindOnce(c->GetOnBubbleClosedCallback(),
      autofill::PaymentsUiClosedReason::kNotInteracted));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowOfferNotificationBubble(
    content::WebContents*, autofill::OfferNotificationBubbleController* c, bool) {
  return NullAutofillBubble::Create(ClosePayment<autofill::OfferNotificationBubbleControllerImpl>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowFilledCardInformationBubble(
    content::WebContents*, autofill::FilledCardInformationBubbleController* c, bool) {
  return NullAutofillBubble::Create(ClosePayment<autofill::FilledCardInformationBubbleControllerImpl>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowMandatoryReauthBubble(
    content::WebContents*, autofill::MandatoryReauthBubbleController* c, bool,
    autofill::MandatoryReauthBubbleType) {
  return NullAutofillBubble::Create(ClosePayment<autofill::MandatoryReauthBubbleControllerImpl>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowVirtualCardEnrollBubble(
    content::WebContents*, autofill::VirtualCardEnrollBubbleController* c, bool) {
  return NullAutofillBubble::Create(base::BindOnce(c->GetOnBubbleClosedCallback(),
      autofill::PaymentsUiClosedReason::kNotInteracted));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowVirtualCardEnrollConfirmationBubble(
    content::WebContents*, autofill::VirtualCardEnrollBubbleController* c) {
  return NullAutofillBubble::Create(base::BindOnce(c->GetOnBubbleClosedCallback(),
      autofill::PaymentsUiClosedReason::kNotInteracted));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowOmniboxAutofillBubble(
    content::WebContents*, autofill::OmniboxAutofillBubbleController* c) {
  return NullAutofillBubble::Create(ClosePayment<autofill::OmniboxAutofillBubbleController>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowPaymentsChurnedUsersBubble(
    content::WebContents*, autofill::PaymentsChurnedUsersBubbleController* c, bool) {
  return NullAutofillBubble::Create(ClosePayment<autofill::PaymentsChurnedUsersBubbleController>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowPaymentsChurnedUsersConfirmationBubble(
    content::WebContents*, autofill::PaymentsChurnedUsersBubbleController* c) {
  return NullAutofillBubble::Create(ClosePayment<autofill::PaymentsChurnedUsersBubbleController>(c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowWalletReminderNoticeBubble(
    content::WebContents*, autofill::WalletReminderNoticeBubbleController* c, bool) {
  return NullAutofillBubble::Create(base::BindOnce(
      [](base::WeakPtr<autofill::BubbleControllerBase> weak,
          autofill::WalletReminderNoticeBubbleController* c) {
        if (weak) c->OnBubbleClosed();
      }, c->GetBubbleControllerBaseWeakPtr(), c));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowSaveAutofillAiDataBubble(
    content::WebContents*, autofill::AutofillAiImportDataController* c) {
  return NullAutofillBubble::Create(base::BindOnce(
      [](base::WeakPtr<autofill::AutofillAiImportDataController> c) {
        if (c) c->OnBubbleClosed(autofill::AutofillClient::AutofillAiBubbleResult::kNotInteracted);
      }, c->GetWeakPtr()));
}
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowAutofillAiLocalSaveNotification(
    content::WebContents* contents, autofill::AutofillAiImportDataController* c) {
  return ShowSaveAutofillAiDataBubble(contents, c);
}
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
autofill::AutofillBubbleBase* OpenAutofillBubbleHandler::ShowAddressSignInPromo(
    content::WebContents* contents, const autofill::AutofillProfile&) {
  auto* controller = autofill::AddressBubblesController::FromWebContents(contents);
  return NullAutofillBubble::Create(base::BindOnce(
      [](base::WeakPtr<autofill::AddressBubbleControllerDelegate> c) {
        if (c) c->OnBubbleClosed();
      }, controller ? controller->GetWeakPtr()
                    : base::WeakPtr<autofill::AddressBubbleControllerDelegate>()));
}
#endif
}  // namespace open_engine
