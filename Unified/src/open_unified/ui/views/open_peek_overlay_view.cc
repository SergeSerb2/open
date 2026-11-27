// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_peek_overlay_view.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "open_unified/ui/design/open_motion.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/clipboard/clipboard_buffer.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/base/window_open_disposition.h"
#include "ui/compositor/layer.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/rounded_corners_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/controls/webview/unhandled_keyboard_event_handler.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/widget/widget.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::GlyphButton;
using secondary::PaintedButton;
namespace m = peek_metrics;

constexpr int kMenuCommandAddFavorite = 1;
constexpr int kMenuCommandSpaceBase = 100;

}  // namespace

// Internal WebContentsDelegate + WebContentsObserver installed on owned Peek
// entries so Shift+Click / target=_blank / window.open links inside Peek push
// onto the Peek stack, window.close() pops cleanly, and Back/Forward state
// stays synchronized.
class OpenPeekOverlayView::StackEntryDelegate
    : public content::WebContentsDelegate,
      public content::WebContentsObserver {
 public:
  StackEntryDelegate(OpenPeekOverlayView* owner,
                     content::WebContents* contents,
                     bool install_as_delegate)
      : owner_(owner), installed_delegate_(install_as_delegate) {
    Observe(contents);
    if (installed_delegate_ && contents) {
      contents->SetDelegate(this);
    }
  }

  ~StackEntryDelegate() override { Detach(); }

  void Detach() {
    if (installed_delegate_ && web_contents() &&
        web_contents()->GetDelegate() == this) {
      web_contents()->SetDelegate(nullptr);
    }
    installed_delegate_ = false;
    Observe(nullptr);
  }

  // content::WebContentsDelegate:
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override {
    if (!owner_ || !params.url.is_valid()) {
      return nullptr;
    }
    const bool push_new_peek =
        params.disposition == WindowOpenDisposition::NEW_WINDOW ||
        params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
        params.disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB ||
        params.disposition == WindowOpenDisposition::NEW_POPUP;
    return owner_->HandleChildOpenUrl(
        source, params, std::move(navigation_handle_callback), push_new_peek);
  }

  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override {
    if (was_blocked) {
      *was_blocked = false;
    }
    if (!owner_ || !new_contents) {
      return nullptr;
    }
    return owner_->HandleChildNewContents(std::move(new_contents));
  }

  void CloseContents(content::WebContents* source) override {
    if (owner_) {
      owner_->OnEntryClosed(source);
    }
  }

  bool HandleKeyboardEvent(
      content::WebContents* source,
      const input::NativeWebKeyboardEvent& event) override {
    if (!owner_) {
      return false;
    }
    const auto type = event.GetType();
    if (type == blink::WebInputEvent::Type::kRawKeyDown ||
        type == blink::WebInputEvent::Type::kKeyDown) {
      if (event.windows_key_code == ui::VKEY_ESCAPE) {
        owner_->PopStack(PeekDismissReason::kEscape);
        return true;
      }
      const bool primary =
          (event.GetModifiers() &
#if BUILDFLAG(IS_MAC)
           blink::WebInputEvent::kMetaKey
#else
           blink::WebInputEvent::kControlKey
#endif
           ) != 0;
      if (primary && event.windows_key_code == ui::VKEY_O) {
        owner_->PressButton(OpenPeekOverlayView::kExpandButton);
        return true;
      }
      if (primary && event.windows_key_code == ui::VKEY_OEM_4) {
        owner_->GoBack();
        return true;
      }
      if (primary && event.windows_key_code == ui::VKEY_OEM_6) {
        owner_->GoForward();
        return true;
      }
#if !BUILDFLAG(IS_MAC)
      const bool alt_only =
          (event.GetModifiers() & blink::WebInputEvent::kAltKey) != 0 &&
          (event.GetModifiers() & (blink::WebInputEvent::kControlKey |
                                   blink::WebInputEvent::kMetaKey |
                                   blink::WebInputEvent::kShiftKey)) == 0;
      if (alt_only && event.windows_key_code == ui::VKEY_LEFT) {
        owner_->GoBack();
        return true;
      }
      if (alt_only && event.windows_key_code == ui::VKEY_RIGHT) {
        owner_->GoForward();
        return true;
      }
#endif
    }
    if (views::FocusManager* focus_manager = owner_->GetFocusManager()) {
      return unhandled_keyboard_event_handler_.HandleKeyboardEvent(
          event, focus_manager);
    }
    return false;
  }

  // content::WebContentsObserver:
  void DidStartLoading() override {
    if (owner_) {
      owner_->OnEntryNavigated(web_contents());
    }
  }
  void DidStopLoading() override {
    if (owner_) {
      owner_->OnEntryNavigated(web_contents());
    }
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (owner_) {
      owner_->OnEntryNavigated(web_contents());
    }
  }
  void TitleWasSet(content::NavigationEntry* entry) override {
    if (owner_) {
      owner_->OnEntryNavigated(web_contents());
    }
  }
  void WebContentsDestroyed() override {
    content::WebContents* doomed = web_contents();
    installed_delegate_ = false;
    if (owner_) {
      owner_->OnEntryClosed(doomed);
    }
  }

 private:
  raw_ptr<OpenPeekOverlayView> owner_;
  bool installed_delegate_ = false;
  views::UnhandledKeyboardEventHandler unhandled_keyboard_event_handler_;
};

OpenPeekOverlayView::StackEntry::StackEntry() = default;
OpenPeekOverlayView::StackEntry::~StackEntry() {
  if (wc_delegate) {
    wc_delegate->Detach();
  }
}
OpenPeekOverlayView::StackEntry::StackEntry(StackEntry&&) noexcept = default;
OpenPeekOverlayView::StackEntry& OpenPeekOverlayView::StackEntry::operator=(
    StackEntry&&) noexcept = default;

OpenPeekOverlayView::OpenPeekOverlayView(PeekDelegate* delegate)
    : delegate_(delegate) {
  SetVisible(false);
  SetPaintToLayer();
  layer()->SetFillsBoundsOpaquely(false);
  GetViewAccessibility().SetRole(ax::mojom::Role::kDialog);
  GetViewAccessibility().SetName(u"Peek");

  web_view_ = AddChildView(std::make_unique<views::WebView>());

  struct Spec {
    Glyph glyph;
    const char* sf_symbol;
    const char16_t* name;
    float glyph_size;
  };
  // Floating vertical action rail outside the card's right edge:
  // Close, Expand to Tab, Open in Split View, Copy URL, Open in Favorite/Space.
  const std::array<Spec, kButtonCount> specs = {{
      {Glyph::kClose, "xmark", u"Close", 12.f},
      {Glyph::kExpand, "arrow.up.left.and.arrow.down.right", u"Open as Tab",
       14.f},
      {Glyph::kSplit, "square.split.2x1", u"Open in Split View", 15.f},
      {Glyph::kLink, "link", u"Copy URL", 13.f},
      {Glyph::kStar, "star", u"Open in Favorite or Space", 13.f},
  }};
  for (int i = 0; i < kButtonCount; ++i) {
    auto button = std::make_unique<GlyphButton>(
        base::BindRepeating(&OpenPeekOverlayView::PressButton,
                            base::Unretained(this), static_cast<Button>(i)),
        specs[i].glyph, specs[i].name);
    button->SetGlyphSize(specs[i].glyph_size);
    button->SetSystemSymbol(specs[i].sf_symbol, specs[i].glyph_size);
    buttons_[i] = AddChildView(std::move(button));
  }

  // Compact Back / Forward / Stack depth controls below the main rail.
  auto make_nav = [this](Glyph glyph, const char* symbol, const char16_t* name,
                         views::Button::PressedCallback cb) {
    auto button = std::make_unique<GlyphButton>(std::move(cb), glyph, name);
    button->SetGlyphSize(12.f);
    button->SetSystemSymbol(symbol, 12.f);
    button->SetVisible(false);
    return AddChildView(std::move(button));
  };
  back_button_ =
      make_nav(Glyph::kBack, "chevron.left", u"Go Back",
               base::BindRepeating(&OpenPeekOverlayView::GoBack,
                                   base::Unretained(this)));
  forward_button_ =
      make_nav(Glyph::kForward, "chevron.right", u"Go Forward",
               base::BindRepeating(&OpenPeekOverlayView::GoForward,
                                   base::Unretained(this)));
  stack_badge_button_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenPeekOverlayView* self) {
            self->PopStack(PeekDismissReason::kCloseButton);
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenPeekOverlayView::PaintStackBadge,
                          base::Unretained(this)),
      u"Peek Stack"));
  stack_badge_button_->SetVisible(false);

  SetAppearance(appearance_);

  // Esc is registered centrally by OpenWindowUi in overlay z-order (Command Bar
  // -> Peek -> Find Bar) so Peek never steals Esc from a Command Bar above it.
  AddAccelerator(ui::Accelerator(ui::VKEY_O, secondary::kPrimaryModifier));
  AddAccelerator(ui::Accelerator(ui::VKEY_OEM_4, secondary::kPrimaryModifier));
  AddAccelerator(ui::Accelerator(ui::VKEY_OEM_6, secondary::kPrimaryModifier));
#if !BUILDFLAG(IS_MAC)
  AddAccelerator(ui::Accelerator(ui::VKEY_LEFT, ui::EF_ALT_DOWN));
  AddAccelerator(ui::Accelerator(ui::VKEY_RIGHT, ui::EF_ALT_DOWN));
#endif
}

OpenPeekOverlayView::~OpenPeekOverlayView() {
  if (opacity_animator_) {
    opacity_animator_->Stop();
  }
  web_view_->SetWebContents(nullptr);
  stack_.clear();
}

// static
gfx::Rect OpenPeekOverlayView::ComputeCardBounds(
    const gfx::Rect& content_rect) {
  const int width =
      static_cast<int>(std::lround(content_rect.width() * m::kWidthFraction));
  return gfx::Rect(content_rect.x() + (content_rect.width() - width) / 2,
                   content_rect.y() + m::kVerticalInset, width,
                   std::max(0, content_rect.height() - 2 * m::kVerticalInset));
}

// static
GURL OpenPeekOverlayView::CurrentUrlFor(content::WebContents* contents,
                                        const GURL& fallback) {
  if (!contents) {
    return fallback;
  }
  const GURL& committed = contents->GetLastCommittedURL();
  if (committed.is_valid()) {
    return committed;
  }
  const GURL& visible = contents->GetVisibleURL();
  if (visible.is_valid()) {
    return visible;
  }
  return fallback;
}

void OpenPeekOverlayView::Show(content::WebContents* contents,
                               const gfx::Rect& content_rect) {
  content_rect_ = content_rect;
  showing_ = true;
  pending_dismiss_reason_.reset();

  // Keep stack in sync when called via legacy non-owning Show().
  if (!stack_.empty() && stack_.back().raw_contents == contents &&
      !stack_.back().owned_contents) {
    // Already top of stack.
  } else {
    web_view_->SetWebContents(nullptr);
    stack_.clear();
    if (contents) {
      StackEntry entry;
      entry.raw_contents = contents;
      entry.url = CurrentUrlFor(contents, GURL());
      entry.title = contents->GetTitle();
      // Observe navigation without stealing the caller's WebContentsDelegate.
      entry.wc_delegate = std::make_unique<StackEntryDelegate>(
          this, contents, /*install_as_delegate=*/false);
      stack_.push_back(std::move(entry));
    }
  }

  ShowTopEntry();
  StartOpacityAnimation(0.0, 1.0, motion::kPeekOpen, std::nullopt);
  if (delegate_) {
    delegate_->OnPeekStackChanged(stack_.size());
  }
}

void OpenPeekOverlayView::AdoptWebContents(
    std::unique_ptr<content::WebContents> wc,
    const gfx::Rect& content_rect) {
  content_rect_ = content_rect;
  AdoptWebContents(std::move(wc));
}

void OpenPeekOverlayView::AdoptWebContents(
    std::unique_ptr<content::WebContents> wc) {
  if (!wc) {
    Hide();
    return;
  }
  pending_dismiss_reason_.reset();
  web_view_->SetWebContents(nullptr);
  stack_.clear();
  PushWebContents(std::move(wc));
}

bool OpenPeekOverlayView::PushWebContents(
    std::unique_ptr<content::WebContents> wc) {
  if (!wc) {
    return false;
  }
  pending_dismiss_reason_.reset();
  // Cap at kMaxStackDepth by replacing the top entry when full.
  if (stack_.size() >= m::kMaxStackDepth) {
    web_view_->SetWebContents(nullptr);
    stack_.pop_back();
  }
  content::WebContents* raw = wc.get();
  StackEntry entry;
  entry.url = CurrentUrlFor(raw, GURL());
  entry.title = raw->GetTitle();
  entry.owned_contents = std::move(wc);
  entry.raw_contents = raw;
  entry.wc_delegate = std::make_unique<StackEntryDelegate>(
      this, raw, /*install_as_delegate=*/true);
  stack_.push_back(std::move(entry));

  const bool was_showing = showing_;
  showing_ = true;
  ShowTopEntry();
  if (!was_showing) {
    StartOpacityAnimation(0.0, 1.0, motion::kPeekOpen, std::nullopt);
  }
  if (delegate_) {
    delegate_->OnPeekStackChanged(stack_.size());
  }
  return true;
}

bool OpenPeekOverlayView::PopStack(PeekDismissReason reason) {
  if (stack_.empty()) {
    if (showing_) {
      Dismiss(reason);
    }
    return false;
  }
  StackEntry popped = std::move(stack_.back());
  stack_.pop_back();

  const GURL dismissed = CurrentUrlFor(popped.raw_contents, popped.url);
  if (dismissed.is_valid()) {
    last_dismissed_url_ = dismissed;
  }
  if (web_view_->web_contents() == popped.raw_contents) {
    web_view_->SetWebContents(nullptr);
  }
  if (popped.wc_delegate) {
    popped.wc_delegate->Detach();
  }
  // The WebContents may be closing us from inside its own CloseContents()
  // call stack, so destroy it asynchronously after detaching from the
  // WebView and clearing its delegate.
  if (popped.owned_contents) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(popped.owned_contents));
  }

  if (!stack_.empty()) {
    ShowTopEntry();
    if (delegate_) {
      delegate_->OnPeekStackChanged(stack_.size());
    }
    return true;
  }

  showing_ = false;
  SetVisible(false);
  if (delegate_) {
    delegate_->OnPeekStackChanged(0);
    if (last_dismissed_url_.is_valid()) {
      delegate_->OnPeekDismissedWithUndo(reason, last_dismissed_url_);
    }
    delegate_->OnPeekDismissed(reason);
  }
  return true;
}

void OpenPeekOverlayView::Hide() {
  if (opacity_animator_) {
    opacity_animator_->Stop();
  }
  pending_dismiss_reason_.reset();
  if (!stack_.empty()) {
    const GURL top_url =
        CurrentUrlFor(stack_.back().raw_contents, stack_.back().url);
    if (top_url.is_valid()) {
      last_dismissed_url_ = top_url;
    }
  }
  showing_ = false;
  SetVisible(false);
  web_view_->SetWebContents(nullptr);
  stack_.clear();
  if (layer()) {
    layer()->SetOpacity(1.f);
  }
}

void OpenPeekOverlayView::SetContentRect(const gfx::Rect& content_rect) {
  if (content_rect_ == content_rect) {
    return;
  }
  content_rect_ = content_rect;
  InvalidateLayout();
  SchedulePaint();
}

void OpenPeekOverlayView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  for (auto& button : buttons_) {
    button->SetPlate(GlyphButton::Plate::kCircle, SK_ColorTRANSPARENT,
                     m::kButtonDiameter / 2.f);
    button->SetGlyphColor(appearance_.peek_glyph);
    button->SetHoverFill(secondary::WithAlpha(SK_ColorWHITE, 0.14f));
  }
  for (GlyphButton* nav : {back_button_.get(), forward_button_.get()}) {
    nav->SetPlate(GlyphButton::Plate::kCircle, SK_ColorTRANSPARENT,
                  m::kButtonDiameter / 2.f);
    nav->SetGlyphColor(appearance_.peek_glyph);
    nav->SetHoverFill(secondary::WithAlpha(SK_ColorWHITE, 0.14f));
  }
  SchedulePaint();
}

void OpenPeekOverlayView::SetSpaceChoices(std::vector<PeekSpaceChoice> spaces) {
  space_choices_ = std::move(spaces);
}

std::unique_ptr<content::WebContents>
OpenPeekOverlayView::ReleaseWebContents() {
  if (stack_.empty()) {
    web_view_->SetWebContents(nullptr);
    Hide();
    return nullptr;
  }

  StackEntry top = std::move(stack_.back());
  stack_.pop_back();

  if (web_view_->web_contents() == top.raw_contents) {
    web_view_->SetWebContents(nullptr);
  }
  if (top.wc_delegate) {
    top.wc_delegate->Detach();
  }
  std::unique_ptr<content::WebContents> released =
      std::move(top.owned_contents);

  if (!stack_.empty()) {
    ShowTopEntry();
  } else {
    showing_ = false;
    SetVisible(false);
  }
  if (delegate_) {
    delegate_->OnPeekStackChanged(stack_.size());
  }
  return released;
}

content::WebContents* OpenPeekOverlayView::DetachWebContents() {
  content::WebContents* contents = active_web_contents();
  if (!stack_.empty()) {
    if (stack_.back().wc_delegate) {
      stack_.back().wc_delegate->Detach();
    }
    stack_.pop_back();
  }
  web_view_->SetWebContents(nullptr);
  if (!stack_.empty()) {
    ShowTopEntry();
  } else {
    showing_ = false;
    SetVisible(false);
  }
  if (delegate_) {
    delegate_->OnPeekStackChanged(stack_.size());
  }
  return contents;
}

content::WebContents* OpenPeekOverlayView::active_web_contents() const {
  if (!stack_.empty()) {
    return stack_.back().raw_contents.get();
  }
  return web_view_ ? web_view_->web_contents() : nullptr;
}

bool OpenPeekOverlayView::CanGoBack() const {
  content::WebContents* wc = active_web_contents();
  return wc && wc->GetController().CanGoBack();
}

bool OpenPeekOverlayView::CanGoForward() const {
  content::WebContents* wc = active_web_contents();
  return wc && wc->GetController().CanGoForward();
}

void OpenPeekOverlayView::GoBack() {
  if (content::WebContents* wc = active_web_contents();
      wc && wc->GetController().CanGoBack()) {
    wc->GetController().GoBack();
    SyncNavButtons();
  }
}

void OpenPeekOverlayView::GoForward() {
  if (content::WebContents* wc = active_web_contents();
      wc && wc->GetController().CanGoForward()) {
    wc->GetController().GoForward();
    SyncNavButtons();
  }
}

std::optional<GURL> OpenPeekOverlayView::TakeLastDismissedUrl() {
  if (!last_dismissed_url_.is_valid()) {
    return std::nullopt;
  }
  GURL out = std::move(last_dismissed_url_);
  last_dismissed_url_ = GURL();
  return out;
}

void OpenPeekOverlayView::DismissSmooth(PeekDismissReason reason) {
  if (!showing_) {
    return;
  }
  StartOpacityAnimation(layer() ? layer()->opacity() : 1.0, 0.0,
                        motion::kPeekDismiss, reason);
}

gfx::Rect OpenPeekOverlayView::GetButtonBounds(Button button) const {
  return buttons_[button]->bounds();
}

void OpenPeekOverlayView::ShowTopEntry() {
  content::WebContents* contents =
      stack_.empty() ? nullptr : stack_.back().raw_contents.get();
  if (web_view_->web_contents() != contents) {
    web_view_->SetWebContents(contents);
  }
  SetVisible(true);
  SyncNavButtons();
  InvalidateLayout();
  SchedulePaint();
  if (contents) {
    web_view_->RequestFocus();
  }
}

void OpenPeekOverlayView::SyncNavButtons() {
  const bool can_back = CanGoBack();
  const bool can_forward = CanGoForward();
  const bool stacked = stack_.size() > 1;
  const bool show_nav = showing_ && (can_back || can_forward || stacked);
  back_button_->SetVisible(show_nav);
  back_button_->SetEnabled(can_back);
  forward_button_->SetVisible(show_nav);
  forward_button_->SetEnabled(can_forward);
  stack_badge_button_->SetVisible(stacked);
  if (stacked) {
    stack_badge_button_->SetTooltipText(
        u"Back to previous Peek (" +
        base::NumberToString16(stack_.size()) + u"/" +
        base::NumberToString16(m::kMaxStackDepth) + u")");
    stack_badge_button_->SchedulePaint();
  }
  InvalidateLayout();
  SchedulePaint();
}

void OpenPeekOverlayView::Layout(PassKey) {
  card_ = ComputeCardBounds(content_rect_);
  web_view_->SetBoundsRect(card_);
  web_view_->holder()->SetNativeViewCornerRadii(
      gfx::RoundedCornersF(m::kCardCornerRadius));

  const int rail_x = card_.right() + m::kButtonGap;
  const int first_y = card_.y() + m::kButtonTop;
  for (int i = 0; i < kButtonCount; ++i) {
    buttons_[i]->SetBoundsRect(gfx::Rect(rail_x, first_y + i * m::kButtonPitch,
                                         m::kButtonHitWidth,
                                         m::kButtonDiameter));
  }
  const int rail_top = first_y - m::kRailPadding;
  const int rail_bottom = first_y + (kButtonCount - 1) * m::kButtonPitch +
                          m::kButtonDiameter + m::kRailPadding;
  rail_bounds_ =
      gfx::Rect(rail_x - m::kRailPadding, rail_top,
                m::kButtonHitWidth + 2 * m::kRailPadding, rail_bottom - rail_top);

  const bool show_nav =
      back_button_->GetVisible() || stack_badge_button_->GetVisible();
  if (show_nav) {
    int y = rail_bounds_.bottom() + m::kNavPillGap + m::kRailPadding;
    const int nav_top = y - m::kRailPadding;
    if (back_button_->GetVisible()) {
      back_button_->SetBoundsRect(
          gfx::Rect(rail_x, y, m::kButtonHitWidth, m::kButtonDiameter));
      y += m::kButtonPitch;
      forward_button_->SetBoundsRect(
          gfx::Rect(rail_x, y, m::kButtonHitWidth, m::kButtonDiameter));
      y += m::kButtonPitch;
    }
    if (stack_badge_button_->GetVisible()) {
      stack_badge_button_->SetBoundsRect(
          gfx::Rect(rail_x, y, m::kButtonHitWidth, m::kButtonDiameter));
      y += m::kButtonPitch;
    }
    const int nav_bottom =
        y - m::kButtonPitch + m::kButtonDiameter + m::kRailPadding;
    nav_pill_bounds_ = gfx::Rect(rail_x - m::kRailPadding, nav_top,
                                 m::kButtonHitWidth + 2 * m::kRailPadding,
                                 std::max(0, nav_bottom - nav_top));
  } else {
    nav_pill_bounds_ = gfx::Rect();
  }
}

void OpenPeekOverlayView::OnPaint(gfx::Canvas* canvas) {
  if (!showing_) {
    return;
  }
  canvas->FillRect(GetLocalBounds(), appearance_.peek_scrim);
  // Card backing and shadow; the page paints over the backing.
  secondary::FillRoundRectWithShadow(
      canvas, gfx::RectF(card_), m::kCardCornerRadius, SK_ColorBLACK,
      secondary::WithAlpha(SK_ColorBLACK, m::kShadowAlpha), m::kShadowOffsetY,
      m::kShadowBlur);

  // Floating vertical pill rail outside the card's right edge.
  if (!rail_bounds_.IsEmpty()) {
    const float pill_radius = rail_bounds_.width() / 2.f;
    secondary::FillRoundRectWithShadow(
        canvas, gfx::RectF(rail_bounds_), pill_radius,
        appearance_.peek_controls,
        secondary::WithAlpha(SK_ColorBLACK, 0.28f), 3.f, 12.f);
    secondary::StrokeRoundRect(
        canvas, gfx::RectF(rail_bounds_), pill_radius,
        secondary::WithAlpha(SK_ColorWHITE, 0.12f), 1.f);
  }

  // Secondary Back/Forward/Stack floating pill when active.
  if (!nav_pill_bounds_.IsEmpty()) {
    const float pill_radius = nav_pill_bounds_.width() / 2.f;
    secondary::FillRoundRectWithShadow(
        canvas, gfx::RectF(nav_pill_bounds_), pill_radius,
        appearance_.peek_controls,
        secondary::WithAlpha(SK_ColorBLACK, 0.24f), 2.f, 10.f);
    secondary::StrokeRoundRect(
        canvas, gfx::RectF(nav_pill_bounds_), pill_radius,
        secondary::WithAlpha(SK_ColorWHITE, 0.12f), 1.f);
  }
}

void OpenPeekOverlayView::PaintStackBadge(gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  const float d = std::min(bounds.width(), bounds.height());
  const gfx::RectF circle(bounds.x() + (bounds.width() - d) / 2.f,
                          bounds.y() + (bounds.height() - d) / 2.f, d, d);
  if (hovered) {
    secondary::FillRoundRect(canvas, circle, d / 2.f,
                             secondary::WithAlpha(SK_ColorWHITE, 0.14f));
  }
  const std::u16string text = base::NumberToString16(stack_.size());
  secondary::DrawText(canvas, text,
                      secondary::FontOfSize(12, gfx::Font::Weight::SEMIBOLD),
                      appearance_.peek_glyph, bounds,
                      gfx::Canvas::TEXT_ALIGN_CENTER);
}

bool OpenPeekOverlayView::OnMousePressed(const ui::MouseEvent& event) {
  // Only the scrim reaches here: the page and buttons take their own clicks.
  if (showing_ && !card_.Contains(event.location()) &&
      !rail_bounds_.Contains(event.location()) &&
      !nav_pill_bounds_.Contains(event.location())) {
    Dismiss(PeekDismissReason::kScrimClick);
    return true;
  }
  return false;
}

bool OpenPeekOverlayView::OnKeyPressed(const ui::KeyEvent& event) {
  if (!showing_) {
    return false;
  }
  if (event.key_code() == ui::VKEY_ESCAPE) {
    Dismiss(PeekDismissReason::kEscape);
    return true;
  }
  return false;
}

bool OpenPeekOverlayView::AcceleratorPressed(
    const ui::Accelerator& accelerator) {
  if (!showing_) {
    return false;
  }
  if (accelerator.key_code() == ui::VKEY_ESCAPE) {
    Dismiss(PeekDismissReason::kEscape);
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_O) {
    PressButton(kExpandButton);
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_OEM_4) {
    GoBack();
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_OEM_6) {
    GoForward();
    return true;
  }
#if !BUILDFLAG(IS_MAC)
  if (accelerator.key_code() == ui::VKEY_LEFT && accelerator.IsAltDown()) {
    GoBack();
    return true;
  }
  if (accelerator.key_code() == ui::VKEY_RIGHT && accelerator.IsAltDown()) {
    GoForward();
    return true;
  }
#endif
  return false;
}

bool OpenPeekOverlayView::CanHandleAccelerators() const {
  return showing_ && views::View::CanHandleAccelerators();
}

void OpenPeekOverlayView::Dismiss(PeekDismissReason reason) {
  if (!showing_) {
    return;
  }
  if (stack_.size() > 1 && reason != PeekDismissReason::kProgrammatic) {
    PopStack(reason);
    return;
  }
  if (!stack_.empty()) {
    const GURL top_url =
        CurrentUrlFor(stack_.back().raw_contents, stack_.back().url);
    if (top_url.is_valid()) {
      last_dismissed_url_ = top_url;
    }
  }
  if (delegate_) {
    if (last_dismissed_url_.is_valid()) {
      delegate_->OnPeekDismissedWithUndo(reason, last_dismissed_url_);
    }
    delegate_->OnPeekDismissed(reason);
  }
}

void OpenPeekOverlayView::PressButton(Button button) {
  if (!showing_) {
    return;
  }
  switch (button) {
    case kCloseButton:
      Dismiss(PeekDismissReason::kCloseButton);
      break;
    case kExpandButton:
      if (delegate_) {
        delegate_->OnPeekExpandToTab();
      }
      break;
    case kSplitButton:
      if (delegate_) {
        delegate_->OnPeekOpenInSplit();
      }
      break;
    case kCopyUrlButton: {
      const GURL url = CurrentUrlFor(
          active_web_contents(),
          stack_.empty() ? GURL() : stack_.back().url);
      if (url.is_valid()) {
        const bool handled = delegate_ && delegate_->OnPeekCopyUrl(url);
        if (!handled) {
          ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
              .WriteText(base::UTF8ToUTF16(url.spec()));
        }
      }
      break;
    }
    case kFavoriteOrSpaceButton:
      if (!space_choices_.empty()) {
        ShowFavoriteOrSpaceMenu();
      } else if (delegate_) {
        delegate_->OnPeekOpenInFavorite();
      }
      break;
    case kButtonCount:
      break;
  }
}

void OpenPeekOverlayView::ShowFavoriteOrSpaceMenu() {
  if (space_menu_runner_ && space_menu_runner_->IsRunning()) {
    return;
  }
  space_menu_model_ = std::make_unique<ui::SimpleMenuModel>(this);
  space_menu_model_->AddItem(kMenuCommandAddFavorite, u"Add to Favorites");
  if (!space_choices_.empty()) {
    space_menu_model_->AddSeparator(ui::NORMAL_SEPARATOR);
    for (size_t i = 0; i < space_choices_.size(); ++i) {
      space_menu_model_->AddItem(kMenuCommandSpaceBase + static_cast<int>(i),
                                 u"Open in " + space_choices_[i].title);
    }
  }
  space_menu_runner_ = std::make_unique<views::MenuRunner>(
      space_menu_model_.get(), views::MenuRunner::HAS_MNEMONICS);
  space_menu_runner_->RunMenuAt(
      GetWidget(), nullptr,
      buttons_[kFavoriteOrSpaceButton]->GetBoundsInScreen(),
      views::MenuAnchorPosition::kTopRight, ui::mojom::MenuSourceType::kMouse);
}

void OpenPeekOverlayView::ExecuteCommand(int command_id, int event_flags) {
  if (!delegate_) {
    return;
  }
  if (command_id == kMenuCommandAddFavorite) {
    delegate_->OnPeekOpenInFavorite();
    return;
  }
  if (command_id >= kMenuCommandSpaceBase) {
    const size_t idx = static_cast<size_t>(command_id - kMenuCommandSpaceBase);
    if (idx < space_choices_.size()) {
      delegate_->OnPeekOpenInSpace(space_choices_[idx].id);
    }
  }
}

bool OpenPeekOverlayView::IsCommandIdEnabled(int command_id) const {
  return showing_;
}

void OpenPeekOverlayView::OnEntryNavigated(content::WebContents* contents) {
  for (StackEntry& entry : stack_) {
    if (entry.raw_contents == contents) {
      entry.url = CurrentUrlFor(contents, entry.url);
      if (contents) {
        entry.title = contents->GetTitle();
      }
      break;
    }
  }
  if (!stack_.empty() && stack_.back().raw_contents == contents) {
    SyncNavButtons();
  }
}

void OpenPeekOverlayView::OnEntryClosed(content::WebContents* contents) {
  for (size_t i = 0; i < stack_.size(); ++i) {
    if (stack_[i].raw_contents == contents) {
      if (i + 1 == stack_.size()) {
        PopStack(PeekDismissReason::kProgrammatic);
      } else {
        if (stack_[i].wc_delegate) {
          stack_[i].wc_delegate->Detach();
        }
        std::unique_ptr<content::WebContents> closed =
            std::move(stack_[i].owned_contents);
        stack_.erase(stack_.begin() + static_cast<ptrdiff_t>(i));
        if (closed) {
          base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
              FROM_HERE, std::move(closed));
        }
        SyncNavButtons();
        if (delegate_) {
          delegate_->OnPeekStackChanged(stack_.size());
        }
      }
      return;
    }
  }
}

content::WebContents* OpenPeekOverlayView::HandleChildOpenUrl(
    content::WebContents* source,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>
        navigation_handle_callback,
    bool open_in_new_peek) {
  if (!source || !params.url.is_valid()) {
    return nullptr;
  }
  content::NavigationController::LoadURLParams load_params(params.url);
  load_params.referrer = params.referrer;
  load_params.transition_type = params.transition;
  load_params.is_renderer_initiated = params.is_renderer_initiated;

  content::WebContents* target = source;
  if (open_in_new_peek) {
    content::WebContents::CreateParams create_params(
        source->GetBrowserContext());
    std::unique_ptr<content::WebContents> child =
        content::WebContents::Create(create_params);
    target = child.get();
    PushWebContents(std::move(child));
  }
  base::WeakPtr<content::NavigationHandle> handle =
      target->GetController().LoadURLWithParams(load_params);
  if (handle && navigation_handle_callback) {
    std::move(navigation_handle_callback).Run(*handle);
  }
  return target;
}

content::WebContents* OpenPeekOverlayView::HandleChildNewContents(
    std::unique_ptr<content::WebContents> new_contents) {
  if (!new_contents) {
    return nullptr;
  }
  content::WebContents* raw = new_contents.get();
  PushWebContents(std::move(new_contents));
  return raw;
}

void OpenPeekOverlayView::StartOpacityAnimation(
    double from,
    double to,
    double duration_sec,
    std::optional<PeekDismissReason> finish_dismiss) {
  pending_dismiss_reason_ = finish_dismiss;
  views::Widget* widget = GetWidget();
  ui::Compositor* compositor = widget ? widget->GetCompositor() : nullptr;
  if (!compositor || !layer() || motion::PrefersReducedMotion() ||
      duration_sec <= 0.0) {
    if (layer()) {
      layer()->SetOpacity(static_cast<float>(to));
    }
    if (pending_dismiss_reason_) {
      const PeekDismissReason reason = *pending_dismiss_reason_;
      pending_dismiss_reason_.reset();
      Dismiss(reason);
    }
    return;
  }
  if (!opacity_animator_) {
    opacity_animator_ = std::make_unique<motion::OpenSpringAnimator>(
        motion::kSidebarToggle,
        base::BindRepeating(&OpenPeekOverlayView::ApplyOpacityStep,
                            base::Unretained(this)),
        base::BindRepeating(&OpenPeekOverlayView::OnOpacityAnimationSettled,
                            base::Unretained(this)));
    opacity_animator_->set_epsilon(0.01);
  }
  opacity_animator_->SetCompositor(compositor);
  opacity_animator_->AnimateTimed(from, to, motion::Seconds(duration_sec),
                                  {0.25, 0.1, 0.25, 1.0});
}

void OpenPeekOverlayView::ApplyOpacityStep(double value) {
  if (layer()) {
    layer()->SetOpacity(static_cast<float>(std::clamp(value, 0.0, 1.0)));
  }
}

void OpenPeekOverlayView::OnOpacityAnimationSettled() {
  if (pending_dismiss_reason_) {
    const PeekDismissReason reason = *pending_dismiss_reason_;
    pending_dismiss_reason_.reset();
    Dismiss(reason);
  }
}

BEGIN_METADATA(OpenPeekOverlayView)
END_METADATA

}  // namespace open_unified
