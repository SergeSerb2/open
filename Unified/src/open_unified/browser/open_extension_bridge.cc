// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_extension_bridge.h"

#include <algorithm>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/strings/strcat.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_context_menu_model.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/extensions/accelerator_priority.h"
#include "chrome/browser/ui/extensions/extension_action_delegate.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/views/extensions/extension_keybinding_registry_views.h"
#include "chrome/browser/ui/views/extensions/extension_popup.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/top_container_view.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_icon_factory.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_host.h"
#include "extensions/browser/extension_host_observer.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/common/command.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/description_info.h"
#include "extensions/common/permissions/permissions_data.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_tab_bridge.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/image_model.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_anchor.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/context_menu_controller.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/view.h"
#include "ui/views/view_tracker.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/widget/widget_observer.h"

namespace open_unified {

namespace {

int TabIdFor(content::WebContents* contents) {
  return contents ? sessions::SessionTabHelper::IdForTab(contents).id() : -1;
}

int ActiveTabSessionId(OpenBrowserService* service) {
  OpenTabBridge* bridge = service->tab_bridge();
  return TabIdFor(bridge ? bridge->ActiveWebContents() : nullptr);
}

// The browser (or Little Open) window that hosts `widget`: bubbles such as
// the Site Control Center are top-level widgets with a parent window.
views::Widget* HostWindowWidget(views::Widget* widget) {
  while (widget && widget->parent()) {
    widget = widget->parent();
  }
  return widget ? widget->GetTopLevelWidget() : nullptr;
}

// A popup anchor that outlives the click: a button inside a bubble (a Site
// Control tile, a picker row) closes with that bubble when the popup takes
// focus, so the popup anchors to the bubble's own anchor instead.
views::View* StableAnchor(views::View* anchor) {
  while (anchor && anchor->GetWidget() && anchor->GetWidget()->parent()) {
    views::WidgetDelegate* delegate = anchor->GetWidget()->widget_delegate();
    views::BubbleDialogDelegate* bubble =
        delegate ? delegate->AsBubbleDialogDelegate() : nullptr;
    views::View* next = bubble ? bubble->GetAnchorView() : nullptr;
    if (!next || next == anchor) {
      break;
    }
    anchor = next;
  }
  return anchor;
}

bool IsUserManageable(const extensions::Extension& extension) {
  return extension.location() !=
             extensions::mojom::ManifestLocation::kComponent &&
         extension.location() !=
             extensions::mojom::ManifestLocation::kExternalComponent &&
         !extension.is_theme();
}

}  // namespace

// --- Structs -----------------------------------------------------------------

ExtensionActionInfo::ExtensionActionInfo() = default;
ExtensionActionInfo::ExtensionActionInfo(const ExtensionActionInfo&) = default;
ExtensionActionInfo& ExtensionActionInfo::operator=(
    const ExtensionActionInfo&) = default;
ExtensionActionInfo::ExtensionActionInfo(ExtensionActionInfo&&) noexcept =
    default;
ExtensionActionInfo& ExtensionActionInfo::operator=(
    ExtensionActionInfo&&) noexcept = default;
ExtensionActionInfo::~ExtensionActionInfo() = default;

ExtensionHostWindow::ExtensionHostWindow() = default;
ExtensionHostWindow::ExtensionHostWindow(const ExtensionHostWindow&) = default;
ExtensionHostWindow& ExtensionHostWindow::operator=(
    const ExtensionHostWindow&) = default;
ExtensionHostWindow::~ExtensionHostWindow() = default;

OpenExtensionBridge::PickerCallbacks::PickerCallbacks() = default;
OpenExtensionBridge::PickerCallbacks::PickerCallbacks(const PickerCallbacks&) =
    default;
OpenExtensionBridge::PickerCallbacks&
OpenExtensionBridge::PickerCallbacks::operator=(const PickerCallbacks&) =
    default;
OpenExtensionBridge::PickerCallbacks::~PickerCallbacks() = default;

// --- WindowState ---------------------------------------------------------------

// Per-window extension UI state: one ExtensionActionViewModel per action (the
// model ties the action to that window's Browser, active tab and focus
// manager), the keybinding registry for windows Chromium does not cover, the
// anchor of the next popup, and the context menu runner.
struct OpenExtensionBridge::WindowState : public views::WidgetObserver {
  WindowState(OpenExtensionBridge* bridge,
              const ExtensionHostWindow& host_window,
              views::Widget* top_level)
      : owner(bridge), window(host_window), widget(top_level) {
    widget_observation.Observe(widget.get());
    browser_closed = window.browser->RegisterBrowserDidClose(base::BindRepeating(
        [](base::WeakPtr<OpenExtensionBridge> bridge,
           BrowserWindowInterface* browser) {
          if (bridge) {
            bridge->DetachBrowser(browser);
          }
        },
        owner->weak_factory_.GetWeakPtr()));
  }
  ~WindowState() override;

  content::WebContents* ActiveContents() const {
    if (window.active_contents) {
      return window.active_contents.Run();
    }
    tabs::TabInterface* tab = window.browser->GetActiveTabInterface();
    return tab ? tab->GetContents() : nullptr;
  }

  views::View* FallbackAnchor() const {
    if (BrowserView* browser_view =
            BrowserView::GetBrowserViewForBrowser(window.browser.get());
        browser_view && browser_view->GetWidget() == widget.get()) {
      return browser_view->top_container();
    }
    return widget->GetRootView();
  }

  // views::WidgetObserver:
  void OnWidgetDestroying(views::Widget* destroying) override {
    owner->OnWidgetGone(destroying);  // Deletes this.
  }
  void OnWidgetActivationChanged(views::Widget* changed,
                                 bool active) override {
    if (keybindings) {
      keybindings->OnHostActivationChanged(active);
    }
  }

  raw_ptr<OpenExtensionBridge> owner;
  ExtensionHostWindow window;
  raw_ptr<views::Widget> widget;
  // Whether this window's action delegates own the "_execute_action"
  // accelerators. False for regular browser windows: Chromium's (hidden)
  // toolbar container already registers them on the same FocusManager, and
  // AcceleratorManager allows a single high-priority handler.
  bool registers_action_commands = false;
  std::map<std::string, std::unique_ptr<ActionEntry>> entries;
  std::unique_ptr<ExtensionKeybindingRegistryViews> keybindings;
  views::ViewTracker next_anchor;
  base::OnceCallback<void(bool)> pending_done;
  std::unique_ptr<views::MenuRunner> menu_runner;
  base::CallbackListSubscription browser_closed;
  base::ScopedObservation<views::Widget, views::WidgetObserver>
      widget_observation{this};
};

// --- ActionDelegate ------------------------------------------------------------

// Open's ExtensionActionDelegate: shows the popup anchored to the button the
// user clicked in this window, owns the "_execute_action" accelerator where
// Chromium does not, and reports popup visibility to the bridge.
class OpenExtensionBridge::ActionDelegate
    : public ExtensionActionDelegate,
      public ui::AcceleratorTarget,
      public extensions::ExtensionHostObserver {
 public:
  ActionDelegate(OpenExtensionBridge* bridge,
                 WindowState* window,
                 std::string extension_id)
      : bridge_(bridge),
        window_(window),
        extension_id_(std::move(extension_id)) {}
  ~ActionDelegate() override {
    UnregisterCommand();
    if (popup_host_ && has_opened_popup_) {
      popup_host_->Close();
    }
  }

  bool popup_requested() const { return popup_requested_; }
  void reset_popup_requested() { popup_requested_ = false; }

  // ExtensionActionDelegate:
  void AttachToModel(ExtensionActionViewModel* model) override {
    CHECK(model);
    model_ = model;
  }
  void DetachFromModel() override { model_ = nullptr; }

  void RegisterCommand() override {
    if (action_keybinding_ || !model_ ||
        !window_->registers_action_commands) {
      return;
    }
    views::FocusManager* focus_manager = window_->widget->GetFocusManager();
    extensions::Command command;
    if (!focus_manager || !model_->GetExtensionCommand(&command)) {
      return;
    }
    action_keybinding_ =
        std::make_unique<ui::Accelerator>(command.accelerator());
    focus_manager->RegisterAccelerator(
        *action_keybinding_,
        focus_manager->HasPriorityHandler(*action_keybinding_)
            ? ui::AcceleratorManager::kNormalPriority
            : kExtensionAcceleratorPriority,
        this);
  }

  void UnregisterCommand() override {
    if (!action_keybinding_) {
      return;
    }
    if (views::FocusManager* focus_manager =
            window_->widget->GetFocusManager()) {
      focus_manager->UnregisterAccelerator(*action_keybinding_, this);
    }
    action_keybinding_.reset();
  }

  bool IsShowingPopup() const override { return popup_host_ != nullptr; }

  void HidePopup() override {
    if (!popup_host_) {
      return;
    }
    if (has_opened_popup_) {
      popup_host_->Close();
    }
    if (popup_host_) {
      OnPopupClosed();
    }
  }

  gfx::NativeView GetPopupNativeView() override {
    if (!popup_host_ || !popup_host_->view()) {
      return gfx::NativeView();
    }
    return popup_host_->view()->GetNativeView();
  }

  void TriggerPopup(std::unique_ptr<extensions::ExtensionViewHost> host,
                    PopupShowAction show_action,
                    bool by_user,
                    ShowPopupCallback callback) override {
    popup_requested_ = true;
    // Only one popup at a time (ExtensionsContainer::HideActivePopup).
    bridge_->HidePopups(nullptr);
    popup_host_ = host.get();
    popup_host_observation_.Observe(popup_host_.get());
    views::View* anchor = window_->next_anchor.view();
    if (!anchor) {
      anchor = window_->FallbackAnchor();
    }
    has_opened_popup_ = true;
    base::OnceCallback<void(bool)> done = std::move(window_->pending_done);
    // The sidebar URL pill and the Site Control grid sit at the window's
    // left: the popup opens below the button and grows to the right.
    ExtensionPopup::ShowPopup(
        window_->window.browser, std::move(host), views::BubbleAnchor(anchor),
        views::BubbleBorder::TOP_LEFT, show_action,
        base::BindOnce(
            [](ShowPopupCallback callback,
               base::OnceCallback<void(bool)> done,
               extensions::ExtensionHost* popup_host) {
              if (done) {
                std::move(done).Run(popup_host != nullptr);
              }
              if (callback) {
                std::move(callback).Run(popup_host);
              }
            },
            std::move(callback), std::move(done)));
    bridge_->OnPopupVisibility(extension_id_, true);
  }

  void ShowContextMenuAsFallback() override {
    views::View* anchor = window_->next_anchor.view();
    if (!anchor) {
      anchor = window_->FallbackAnchor();
    }
    bridge_->ShowContextMenu(window_->window, extension_id_, anchor,
                             anchor->GetBoundsInScreen().CenterPoint(),
                             ui::mojom::MenuSourceType::kMouse);
  }

  void CloseExtensionsMenuIfOpen() override {
    bridge_->CloseExtensionsPicker();
  }

  content::WebContents* GetActiveWebContents() const override {
    return window_->ActiveContents();
  }

  // ui::AcceleratorTarget:
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override {
    return model_ && model_->TryHandleAcceleratorPress();
  }
  bool CanHandleAccelerators() const override {
    return model_ && model_->CanHandleAccelerators();
  }

  // extensions::ExtensionHostObserver:
  void OnExtensionHostDestroyed(extensions::ExtensionHost* host) override {
    OnPopupClosed();
  }

 private:
  void OnPopupClosed() {
    popup_host_observation_.Reset();
    popup_host_ = nullptr;
    has_opened_popup_ = false;
    bridge_->OnPopupVisibility(extension_id_, false);
  }

  raw_ptr<OpenExtensionBridge> bridge_;
  raw_ptr<WindowState> window_;
  const std::string extension_id_;
  raw_ptr<ExtensionActionViewModel> model_ = nullptr;
  raw_ptr<extensions::ExtensionViewHost> popup_host_ = nullptr;
  bool has_opened_popup_ = false;
  bool popup_requested_ = false;
  std::unique_ptr<ui::Accelerator> action_keybinding_;
  base::ScopedObservation<extensions::ExtensionHost,
                          extensions::ExtensionHostObserver>
      popup_host_observation_{this};
};

// --- ActionEntry ---------------------------------------------------------------

// One action in one window: Chromium's view model (execute, popup, context
// menu, composed icon) plus a plain icon factory for Open's own badge
// drawing. Both report icon changes to the bridge.
class OpenExtensionBridge::ActionEntry
    : public extensions::ExtensionActionIconFactory::Observer {
 public:
  ActionEntry(OpenExtensionBridge* bridge,
              WindowState* window,
              const extensions::Extension* extension,
              extensions::ExtensionAction* action)
      : bridge_(bridge),
        extension_id_(extension->id()),
        extension_(extension),
        icon_factory_(extension, action, this) {
    auto delegate =
        std::make_unique<ActionDelegate>(bridge, window, extension->id());
    delegate_ = delegate.get();
    model_ = ExtensionActionViewModel::Create(extension->id(), window->window.browser,
                                              std::move(delegate));
    icon_subscription_ = model_->RegisterIconUpdateObserver(base::BindRepeating(
        &ActionEntry::OnIconUpdated, base::Unretained(this)));
    model_->RegisterCommand();
  }
  ~ActionEntry() override {
    icon_subscription_ = {};
    if (model_) {
      model_->UnregisterCommand();
    }
    delegate_ = nullptr;
    model_.reset();
  }

  ExtensionActionViewModel* model() { return model_.get(); }
  ActionDelegate* delegate() { return delegate_; }

  gfx::ImageSkia PlainIcon(int tab_id) {
    gfx::Image image = icon_factory_.GetIcon(tab_id);
    return image.IsEmpty() ? gfx::ImageSkia() : *image.ToImageSkia();
  }

  // extensions::ExtensionActionIconFactory::Observer:
  void OnIconUpdated() override { bridge_->OnEntryIconUpdated(extension_id_); }

 private:
  raw_ptr<OpenExtensionBridge> bridge_;
  const std::string extension_id_;
  scoped_refptr<const extensions::Extension> extension_;
  extensions::ExtensionActionIconFactory icon_factory_;
  std::unique_ptr<ExtensionActionViewModel> model_;
  raw_ptr<ActionDelegate> delegate_ = nullptr;
  base::CallbackListSubscription icon_subscription_;
};

OpenExtensionBridge::WindowState::~WindowState() {
  menu_runner.reset();
  // View models (and their delegates) before the keybinding registry.
  entries.clear();
  keybindings.reset();
  if (pending_done) {
    std::move(pending_done).Run(false);
  }
}

// --- PickerView ----------------------------------------------------------------

// The Extensions Picker popover. Geometry is Open's (guess): the Site
// Control panel width and padding, 32 pt rows with a 16 pt icon at x 18,
// the name at x 44, the pin toggle at the trailing edge, and a footer with
// "Manage Extensions" and "Add Extension".
class OpenExtensionBridge::PickerView : public views::View,
                                        public views::ContextMenuController {
 public:
  static constexpr int kWidth = 236;
  static constexpr int kPadding = 10;
  static constexpr int kRowHeight = 32;
  static constexpr int kFooterRow = 28;

  PickerView(OpenExtensionBridge* bridge,
             const ExtensionHostWindow& window,
             const PickerCallbacks& callbacks,
             bool dark)
      : bridge_(bridge), window_(window), callbacks_(callbacks), dark_(dark) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kMenu);
    GetViewAccessibility().SetName(u"Extensions");
    Reload();
  }

  void Reload() {
    rows_.clear();
    pins_.clear();
    manage_ = nullptr;
    add_ = nullptr;
    RemoveAllChildViews();
    actions_ = bridge_->GetAllToolbarActions(window_, /*include_unpinned=*/true);
    for (size_t i = 0; i < actions_.size(); ++i) {
      auto row = std::make_unique<secondary::PaintedButton>(
          base::BindRepeating(&PickerView::OnRowPressed,
                              base::Unretained(this), i),
          base::BindRepeating(&PickerView::PaintRow, base::Unretained(this),
                              i),
          base::UTF8ToUTF16(actions_[i].name));
      row->SetTooltipText(actions_[i].tooltip);
      row->set_context_menu_controller(this);
      rows_.push_back(AddChildView(std::move(row)));
      auto pin = std::make_unique<secondary::PaintedButton>(
          base::BindRepeating(&PickerView::OnPinPressed,
                              base::Unretained(this), i),
          base::BindRepeating(&PickerView::PaintPin, base::Unretained(this),
                              i),
          base::StrCat({actions_[i].pinned ? u"Unpin " : u"Pin ",
                        base::UTF8ToUTF16(actions_[i].name)}));
      pin->GetViewAccessibility().SetRole(ax::mojom::Role::kToggleButton);
      pin->SetEnabled(!actions_[i].force_pinned);
      pins_.push_back(AddChildView(std::move(pin)));
    }
    manage_ = AddChildView(std::make_unique<secondary::PaintedButton>(
        base::BindRepeating(&PickerView::OnFooter, base::Unretained(this),
                            true),
        base::BindRepeating(&PickerView::PaintFooter, base::Unretained(this),
                            std::u16string(u"Manage Extensions")),
        u"Manage Extensions"));
    add_ = AddChildView(std::make_unique<secondary::PaintedButton>(
        base::BindRepeating(&PickerView::OnFooter, base::Unretained(this),
                            false),
        base::BindRepeating(&PickerView::PaintFooter, base::Unretained(this),
                            std::u16string(u"Add Extension")),
        u"Add Extension"));
    manage_->SetEnabled(!callbacks_.on_manage_extensions.is_null());
    add_->SetEnabled(!callbacks_.on_add_extension.is_null());
    PreferredSizeChanged();
    InvalidateLayout();
    SchedulePaint();
  }

  views::View* AnchorFor(const std::string& extension_id) {
    for (size_t i = 0; i < actions_.size() && i < rows_.size(); ++i) {
      if (actions_[i].id == extension_id) {
        return rows_[i];
      }
    }
    return nullptr;
  }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    const int list = actions_.empty()
                         ? kRowHeight
                         : static_cast<int>(actions_.size()) * kRowHeight;
    return gfx::Size(kWidth, kPadding + list + 11 + 2 * kFooterRow + kPadding);
  }

  void Layout(PassKey) override {
    int y = kPadding;
    for (size_t i = 0; i < rows_.size(); ++i) {
      rows_[i]->SetBoundsRect(gfx::Rect(0, y, kWidth - 40, kRowHeight));
      pins_[i]->SetBoundsRect(
          gfx::Rect(kWidth - kPadding - 28, y + 2, 28, 28));
      y += kRowHeight;
    }
    if (rows_.empty()) {
      y += kRowHeight;
    }
    separator_y_ = y + 5;
    y += 11;
    manage_->SetBoundsRect(gfx::Rect(0, y, kWidth, kFooterRow));
    y += kFooterRow;
    add_->SetBoundsRect(gfx::Rect(0, y, kWidth, kFooterRow));
  }

  void OnPaint(gfx::Canvas* canvas) override {
    canvas->DrawColor(PanelColor());
    if (rows_.empty()) {
      secondary::DrawText(canvas, u"No extensions installed",
                          secondary::FontOfSize(13), SubtleInk(),
                          gfx::Rect(kPadding + 8, kPadding,
                                    kWidth - 2 * kPadding - 8, kRowHeight));
    }
    canvas->FillRect(
        gfx::Rect(kPadding, separator_y_, kWidth - 2 * kPadding, 1),
        secondary::WithAlpha(dark_ ? SK_ColorWHITE : SK_ColorBLACK, 0.10f));
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    for (size_t i = 0; i < rows_.size(); ++i) {
      if (rows_[i] == source) {
        bridge_->ShowContextMenu(window_, actions_[i].id, source, point,
                                 source_type);
        return;
      }
    }
  }

  SkColor PanelColor() const {
    return dark_ ? SkColorSetRGB(0x2C, 0x2C, 0x33)
                 : SkColorSetRGB(0xF4, 0xF3, 0xEC);
  }

 private:
  SkColor Ink() const {
    return dark_ ? SkColorSetRGB(0xDF, 0xDF, 0xE2)
                 : SkColorSetRGB(0x26, 0x24, 0x1C);
  }
  SkColor SubtleInk() const {
    return dark_ ? SkColorSetRGB(0x9F, 0x9E, 0xA9)
                 : secondary::WithAlpha(SkColorSetRGB(0x26, 0x24, 0x1C), 0.6f);
  }
  SkColor HoverFill() const {
    return secondary::WithAlpha(dark_ ? SK_ColorWHITE : SK_ColorBLACK, 0.06f);
  }

  void OnRowPressed(size_t index) {
    if (index >= actions_.size()) {
      return;
    }
    // Anchored to the row; Chromium closes the picker once the action runs
    // (ExtensionActionDelegate::CloseExtensionsMenuIfOpen).
    bridge_->ExecuteAction(window_, actions_[index].id, rows_[index],
                           std::nullopt, base::DoNothing());
  }

  void OnPinPressed(size_t index) {
    if (index >= actions_.size()) {
      return;
    }
    const std::string id = actions_[index].id;
    const bool pinned = !actions_[index].pinned;
    // Deferred: the pin change rebuilds the rows (this button included).
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<OpenExtensionBridge> bridge,
                          std::string extension_id, bool pin) {
                         if (bridge) {
                           bridge->SetActionPinned(extension_id, pin);
                         }
                       },
                       bridge_->weak_factory_.GetWeakPtr(), id, pinned));
  }

  void OnFooter(bool manage) {
    const base::RepeatingClosure callback =
        manage ? callbacks_.on_manage_extensions : callbacks_.on_add_extension;
    OpenExtensionBridge* bridge = bridge_;
    if (callback) {
      callback.Run();
    }
    bridge->CloseExtensionsPicker();  // Deletes this.
  }

  void PaintRow(size_t index,
                gfx::Canvas* canvas,
                const gfx::Rect& bounds,
                bool hovered) {
    if (index >= actions_.size()) {
      return;
    }
    const ExtensionActionInfo& info = actions_[index];
    if (hovered) {
      secondary::FillRoundRect(
          canvas,
          gfx::RectF(bounds.x() + kPadding - 4, bounds.y(),
                     kWidth - 2 * kPadding + 8, bounds.height()),
          6.f, HoverFill());
    }
    const gfx::Rect icon(bounds.x() + kPadding + 8,
                         bounds.CenterPoint().y() - 8, 16, 16);
    const gfx::ImageSkia& image =
        info.icon_with_badge.isNull() ? info.icon : info.icon_with_badge;
    if (image.isNull()) {
      secondary::PaintGlyph(canvas, secondary::Glyph::kPuzzle,
                            gfx::RectF(icon), Ink());
    } else {
      canvas->SaveLayerAlpha(info.runnable ? 255 : 110);
      secondary::DrawImageInRect(canvas, image, icon);
      canvas->Restore();
    }
    const int text_x = icon.right() + 10;
    secondary::DrawText(
        canvas, base::UTF8ToUTF16(info.name),
        secondary::FontOfSize(14, gfx::Font::Weight::MEDIUM),
        info.runnable ? Ink() : SubtleInk(),
        gfx::Rect(text_x, bounds.y(), bounds.right() - text_x - 4,
                  bounds.height()));
  }

  void PaintPin(size_t index,
                gfx::Canvas* canvas,
                const gfx::Rect& bounds,
                bool hovered) {
    if (index >= actions_.size()) {
      return;
    }
    const bool pinned = actions_[index].pinned;
    if (hovered) {
      secondary::FillRoundRect(canvas, gfx::RectF(bounds), 6.f, HoverFill());
    }
    const SkColor ink = pinned ? Ink() : SubtleInk();
    const gfx::RectF box(bounds.CenterPoint().x() - 7.f,
                         bounds.CenterPoint().y() - 7.f, 14.f, 14.f);
    if (glyphs::DrawSystemSymbol(canvas, pinned ? "pin.fill" : "pin", 13.f,
                                 glyphs::SymbolWeight::kMedium, box, ink)) {
      return;
    }
    // Open's pin: a round head on a needle.
    cc::PaintFlags flags;
    flags.setAntiAlias(true);
    flags.setColor(ink);
    flags.setStyle(pinned ? cc::PaintFlags::kFill_Style
                          : cc::PaintFlags::kStroke_Style);
    flags.setStrokeWidth(1.4f);
    canvas->DrawCircle(gfx::PointF(box.CenterPoint().x(), box.y() + 4.5f),
                       3.8f, flags);
    cc::PaintFlags needle;
    needle.setAntiAlias(true);
    needle.setColor(ink);
    needle.setStyle(cc::PaintFlags::kStroke_Style);
    needle.setStrokeWidth(1.4f);
    needle.setStrokeCap(cc::PaintFlags::kRound_Cap);
    SkPathBuilder b;
    b.moveTo(box.CenterPoint().x(), box.y() + 8.5f);
    b.lineTo(box.CenterPoint().x(), box.bottom());
    canvas->DrawPath(b.detach(), needle);
  }

  void PaintFooter(const std::u16string& text,
                   gfx::Canvas* canvas,
                   const gfx::Rect& bounds,
                   bool hovered) {
    if (hovered) {
      secondary::FillRoundRect(
          canvas,
          gfx::RectF(bounds.x() + kPadding - 4, bounds.y(),
                     kWidth - 2 * kPadding + 8, bounds.height()),
          6.f, HoverFill());
    }
    secondary::DrawText(
        canvas, text, secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD),
        Ink(),
        gfx::Rect(bounds.x() + kPadding + 8, bounds.y(),
                  kWidth - 2 * kPadding - 8, bounds.height()));
  }

  raw_ptr<OpenExtensionBridge> bridge_;
  ExtensionHostWindow window_;
  PickerCallbacks callbacks_;
  bool dark_ = false;
  std::vector<ExtensionActionInfo> actions_;
  std::vector<raw_ptr<secondary::PaintedButton>> rows_;
  std::vector<raw_ptr<secondary::PaintedButton>> pins_;
  raw_ptr<secondary::PaintedButton> manage_ = nullptr;
  raw_ptr<secondary::PaintedButton> add_ = nullptr;
  int separator_y_ = 0;
};

// Owns the picker's bubble delegate and widget; the view is the contents.
class OpenExtensionBridge::PickerBubble {
 public:
  PickerBubble(views::View* anchor,
               std::unique_ptr<views::View> contents,
               SkColor background,
               base::OnceClosure on_closed)
      : on_closed_(std::move(on_closed)) {
    delegate_ = std::make_unique<views::BubbleDialogDelegate>(
        anchor, views::BubbleBorder::TOP_LEFT,
        views::BubbleBorder::DIALOG_SHADOW, /*autosize=*/true);
    delegate_->set_margins(gfx::Insets());
    delegate_->set_fixed_width(PickerView::kWidth);
    delegate_->set_corner_radius(16);
    delegate_->SetButtons(static_cast<int>(ui::mojom::DialogButton::kNone));
    delegate_->SetShowCloseButton(false);
    delegate_->SetShowTitle(false);
    delegate_->set_close_on_deactivate(true);
    delegate_->SetContentsView(std::move(contents));
    delegate_->SetBackgroundColor(background);
    widget_ = views::BubbleDialogDelegate::CreateBubble(
        delegate_.get(), base::BindOnce(&PickerBubble::OnClosed,
                                        weak_factory_.GetWeakPtr()));
    widget_->Show();
  }
  ~PickerBubble() {
    weak_factory_.InvalidateWeakPtrs();
    if (widget_ && !closed_) {
      widget_->CloseNow();
    }
    widget_.reset();  // Before its delegate.
    delegate_.reset();
  }

  views::Widget* widget() { return widget_.get(); }

  void Hide() {
    if (widget_ && !closed_) {
      widget_->Hide();
    }
  }

 private:
  void OnClosed(views::Widget::ClosedReason reason) {
    closed_ = true;
    if (on_closed_) {
      // Posted: the bridge deletes this object.
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, std::move(on_closed_));
    }
  }

  std::unique_ptr<views::BubbleDialogDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  base::OnceClosure on_closed_;
  bool closed_ = false;
  base::WeakPtrFactory<PickerBubble> weak_factory_{this};
};

// --- OpenExtensionBridge -------------------------------------------------------

OpenExtensionBridge::OpenExtensionBridge(OpenBrowserService* service,
                                         ::Profile* profile)
    : service_(service),
      profile_(profile),
      toolbar_model_(ToolbarActionsModel::Get(profile)) {
  if (toolbar_model_) {
    toolbar_observation_.Observe(toolbar_model_.get());
  }
  registry_observation_.Observe(extensions::ExtensionRegistry::Get(profile));
  if (extensions::ExtensionActionDispatcher* dispatcher =
          extensions::ExtensionActionDispatcher::Get(profile)) {
    dispatcher_observation_.Observe(dispatcher);
  }
}

OpenExtensionBridge::~OpenExtensionBridge() {
  picker_view_ = nullptr;
  picker_bubble_.reset();
  windows_.clear();
}

void OpenExtensionBridge::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenExtensionBridge::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

// --- Windows -------------------------------------------------------------------

views::Widget* OpenExtensionBridge::WidgetFor(
    const ExtensionHostWindow& window) const {
  if (window.widget) {
    return HostWindowWidget(window.widget);
  }
  if (!window.browser) {
    return nullptr;
  }
  BrowserView* browser_view =
      BrowserView::GetBrowserViewForBrowser(window.browser.get());
  return browser_view ? browser_view->GetWidget() : nullptr;
}

OpenExtensionBridge::WindowState* OpenExtensionBridge::EnsureWindow(
    const ExtensionHostWindow& window) {
  if (!window.browser || window.browser->IsDeleteScheduled() ||
      window.browser->GetProfile()->GetOriginalProfile() != profile_.get()) {
    return nullptr;
  }
  views::Widget* widget = WidgetFor(window);
  if (!widget) {
    return nullptr;
  }
  if (auto it = windows_.find(widget); it != windows_.end()) {
    // Keep the newest contents getter (a Little Open window can rebind).
    if (window.active_contents) {
      it->second->window.active_contents = window.active_contents;
    }
    return it->second.get();
  }
  auto state = std::make_unique<WindowState>(this, window, widget);
  BrowserView* browser_view =
      BrowserView::GetBrowserViewForBrowser(window.browser.get());
  const bool own_browser_window =
      browser_view && browser_view->GetWidget() == widget;
  // Regular browser windows: BrowserWindowFeatures already owns an
  // ExtensionKeybindingRegistryViews and the hidden toolbar container owns
  // "_execute_action". Other windows (Little Open) get both from here.
  state->registers_action_commands = !own_browser_window;
  if (!own_browser_window && widget->GetFocusManager()) {
    state->keybindings = std::make_unique<ExtensionKeybindingRegistryViews>(
        profile_.get(), /*tab_list_interface=*/nullptr,
        extensions::ExtensionKeybindingRegistry::ALL_EXTENSIONS,
        widget->GetFocusManager());
    state->keybindings->OnHostActivationChanged(widget->IsActive());
  }
  WindowState* raw = state.get();
  windows_[widget] = std::move(state);
  return raw;
}

void OpenExtensionBridge::AttachWindow(const ExtensionHostWindow& window) {
  if (WindowState* state = EnsureWindow(window)) {
    // Create the view models now so "_execute_action" works before the
    // first click.
    for (const std::string& id : OrderedActionIds(true)) {
      EnsureEntry(state, id);
    }
  }
}

void OpenExtensionBridge::DetachWindow(views::Widget* widget) {
  if (!widget) {
    return;
  }
  views::Widget* top = HostWindowWidget(widget);
  if (picker_bubble_ && picker_bubble_->widget() &&
      picker_bubble_->widget()->parent() &&
      picker_bubble_->widget()->parent()->GetTopLevelWidget() == top) {
    CloseExtensionsPicker();
  }
  windows_.erase(top);
}

void OpenExtensionBridge::DetachBrowser(BrowserWindowInterface* browser) {
  for (auto it = windows_.begin(); it != windows_.end();) {
    if (it->second->window.browser == browser) {
      it = windows_.erase(it);
    } else {
      ++it;
    }
  }
}

void OpenExtensionBridge::OnWidgetGone(views::Widget* widget) {
  windows_.erase(widget);
}

OpenExtensionBridge::WindowState* OpenExtensionBridge::FindWindow(
    views::Widget* widget) {
  auto it = windows_.find(widget);
  return it == windows_.end() ? nullptr : it->second.get();
}

OpenExtensionBridge::WindowState* OpenExtensionBridge::FindWindowForBrowser(
    BrowserWindowInterface* browser) {
  ExtensionHostWindow window;
  window.browser = browser;
  return EnsureWindow(window);
}

OpenExtensionBridge::ActionEntry* OpenExtensionBridge::EnsureEntry(
    WindowState* window,
    const std::string& id) {
  if (!window) {
    return nullptr;
  }
  if (auto it = window->entries.find(id); it != window->entries.end()) {
    return it->second.get();
  }
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile_)->enabled_extensions().GetByID(
          id);
  if (!extension) {
    return nullptr;
  }
  extensions::ExtensionAction* action =
      extensions::ExtensionActionManager::Get(profile_)->GetExtensionAction(
          *extension);
  if (!action) {
    return nullptr;
  }
  auto entry = std::make_unique<ActionEntry>(this, window, extension, action);
  ActionEntry* raw = entry.get();
  window->entries[id] = std::move(entry);
  return raw;
}

void OpenExtensionBridge::DropEntry(const std::string& extension_id) {
  for (auto& [widget, state] : windows_) {
    state->entries.erase(extension_id);
  }
}

// --- Lists ---------------------------------------------------------------------

ExtensionActionInfo OpenExtensionBridge::InfoFor(
    const extensions::Extension& extension) const {
  OpenTabBridge* bridge = service_->tab_bridge();
  return InfoForTab(extension, bridge ? bridge->ActiveWebContents() : nullptr);
}

ExtensionActionInfo OpenExtensionBridge::InfoForTab(
    const extensions::Extension& extension,
    content::WebContents* contents) const {
  ExtensionActionInfo info;
  info.id = extension.id();
  info.name = extension.name();
  info.version = extension.VersionString();
  info.description = extensions::DescriptionInfo::GetDescription(extension);
  info.enabled = extensions::ExtensionRegistry::Get(profile_)
                     ->enabled_extensions()
                     .Contains(extension.id());
  if (toolbar_model_) {
    info.pinned = toolbar_model_->IsActionPinned(extension.id());
    info.force_pinned = toolbar_model_->IsActionForcePinned(extension.id());
  }
  for (const auto& permission :
       extension.permissions_data()->active_permissions().GetAPIsAsStrings()) {
    info.permissions.push_back(permission);
  }
  std::sort(info.permissions.begin(), info.permissions.end());

  const int tab_id = contents ? TabIdFor(contents) : ActiveTabSessionId(service_);
  if (extensions::ExtensionAction* action =
          extensions::ExtensionActionManager::Get(profile_)
              ->GetExtensionAction(extension)) {
    info.title = action->GetTitle(tab_id);
    info.badge_text = action->GetDisplayBadgeText(tab_id);
    info.badge_background_color = action->GetBadgeBackgroundColor(tab_id);
    info.badge_text_color = action->GetBadgeTextColor(tab_id);
    info.has_popup = action->HasPopup(tab_id);
    info.visible = action->GetIsVisible(tab_id);
  }
  if (info.title.empty()) {
    info.title = info.name;
  }
  info.tooltip = base::UTF8ToUTF16(info.title);
  return info;
}

std::vector<std::string> OpenExtensionBridge::OrderedActionIds(
    bool include_unpinned) const {
  std::vector<std::string> ids;
  if (!toolbar_model_) {
    return ids;
  }
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  // Pinned actions in the user's order, then the rest by name (Arc's grid).
  for (const auto& id : toolbar_model_->pinned_action_ids()) {
    if (registry->enabled_extensions().GetByID(id)) {
      ids.push_back(id);
    }
  }
  if (!include_unpinned) {
    return ids;
  }
  std::vector<std::pair<std::string, std::string>> rest;
  for (const auto& id : toolbar_model_->action_ids()) {
    if (std::find(ids.begin(), ids.end(), id) != ids.end()) {
      continue;
    }
    if (const extensions::Extension* extension =
            registry->enabled_extensions().GetByID(id)) {
      rest.emplace_back(extension->name(), id);
    }
  }
  std::sort(rest.begin(), rest.end());
  for (auto& [name, id] : rest) {
    ids.push_back(std::move(id));
  }
  return ids;
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::ListActions() const {
  std::vector<ExtensionActionInfo> result;
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  for (const std::string& id : OrderedActionIds(/*include_unpinned=*/true)) {
    if (const extensions::Extension* extension =
            registry->enabled_extensions().GetByID(id)) {
      result.push_back(InfoFor(*extension));
    }
  }
  return result;
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::ListInstalled() const {
  std::vector<ExtensionActionInfo> result;
  const extensions::ExtensionSet installed =
      extensions::ExtensionRegistry::Get(profile_)
          ->GenerateInstalledExtensionsSet();
  for (const auto& extension : installed) {
    // Component and theme extensions are not user-manageable.
    if (!IsUserManageable(*extension)) {
      continue;
    }
    result.push_back(InfoFor(*extension));
  }
  std::sort(result.begin(), result.end(),
            [](const ExtensionActionInfo& a, const ExtensionActionInfo& b) {
              return a.name < b.name;
            });
  return result;
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::GetAllToolbarActions(
    BrowserWindowInterface* browser,
    bool include_unpinned,
    const gfx::Size& icon_size) {
  ExtensionHostWindow window;
  window.browser = browser;
  return GetAllToolbarActions(window, include_unpinned, icon_size);
}

std::vector<ExtensionActionInfo> OpenExtensionBridge::GetAllToolbarActions(
    const ExtensionHostWindow& window,
    bool include_unpinned,
    const gfx::Size& icon_size) {
  std::vector<ExtensionActionInfo> result;
  WindowState* state = EnsureWindow(window);
  content::WebContents* contents = state ? state->ActiveContents() : nullptr;
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  for (const std::string& id : OrderedActionIds(include_unpinned)) {
    const extensions::Extension* extension =
        registry->enabled_extensions().GetByID(id);
    if (!extension) {
      continue;
    }
    ExtensionActionInfo info = InfoForTab(*extension, contents);
    if (ActionEntry* entry = EnsureEntry(state, id)) {
      ExtensionActionViewModel* model = entry->model();
      info.icon = entry->PlainIcon(TabIdFor(contents));
      const ui::ImageModel composed = model->GetIcon(contents, icon_size);
      if (composed.IsImage()) {
        info.icon_with_badge = composed.GetImage().AsImageSkia();
      }
      info.tooltip = model->GetTooltip(contents);
      info.runnable = contents && model->IsEnabled(contents);
      info.popup_showing = model->IsShowingPopup();
      extensions::Command command;
      if (model->GetExtensionCommand(&command)) {
        info.shortcut = command.accelerator().GetShortcutText();
      }
    }
    result.push_back(std::move(info));
  }
  return result;
}

// --- Actions -------------------------------------------------------------------

void OpenExtensionBridge::ExecuteAction(
    const std::string& extension_id,
    views::View* anchor,
    base::OnceCallback<void(bool shown)> done) {
  OpenTabBridge* bridge = service_->tab_bridge();
  BrowserWindowInterface* browser = bridge ? bridge->MainBrowser() : nullptr;
  if (!browser) {
    std::move(done).Run(false);
    return;
  }
  ExtensionHostWindow window;
  window.browser = browser;
  // The main window's tab as OpenTabBridge sees it (the sidebar selection).
  window.active_contents = base::BindRepeating(
      [](base::WeakPtr<OpenExtensionBridge> self) -> content::WebContents* {
        if (!self) {
          return nullptr;
        }
        OpenTabBridge* tabs = self->service_->tab_bridge();
        return tabs ? tabs->ActiveWebContents() : nullptr;
      },
      weak_factory_.GetWeakPtr());
  if (anchor && anchor->GetWidget()) {
    window.widget = HostWindowWidget(anchor->GetWidget());
  }
  ExecuteAction(window, extension_id, anchor, std::nullopt, std::move(done));
}

void OpenExtensionBridge::ExecuteAction(
    BrowserWindowInterface* browser,
    const std::string& extension_id,
    views::View* anchor,
    std::optional<gfx::Rect> anchor_rect_in_screen,
    base::OnceCallback<void(bool shown)> done) {
  ExtensionHostWindow window;
  window.browser = browser;
  ExecuteAction(window, extension_id, anchor, anchor_rect_in_screen,
                std::move(done));
}

void OpenExtensionBridge::ExecuteAction(
    const ExtensionHostWindow& window,
    const std::string& extension_id,
    views::View* anchor,
    std::optional<gfx::Rect> anchor_rect_in_screen,
    base::OnceCallback<void(bool shown)> done) {
  WindowState* state = EnsureWindow(window);
  ActionEntry* entry = EnsureEntry(state, extension_id);
  if (!state || !entry || !state->ActiveContents()) {
    std::move(done).Run(false);
    return;
  }
  // The clicked button, or the view under the reported rect in this window.
  if (!anchor && anchor_rect_in_screen) {
    if (views::View* root = state->widget->GetRootView()) {
      gfx::Point point = anchor_rect_in_screen->CenterPoint();
      views::View::ConvertPointFromScreen(root, &point);
      if (root->HitTestPoint(point)) {
        anchor = root->GetEventHandlerForPoint(point);
      }
    }
  }
  anchor = StableAnchor(anchor);
  ExtensionActionViewModel* model = entry->model();
  if (model->IsShowingPopup()) {
    // A second click on the button closes its popup (toolbar behavior).
    model->HidePopup();
    std::move(done).Run(false);
    return;
  }
  if (anchor) {
    state->next_anchor.SetView(anchor);
  } else {
    state->next_anchor.SetView(nullptr);
  }
  if (state->pending_done) {
    std::move(state->pending_done).Run(false);
  }
  state->pending_done = std::move(done);
  ActionDelegate* delegate = entry->delegate();
  delegate->reset_popup_requested();
  views::Widget* const widget = state->widget;
  base::WeakPtr<OpenExtensionBridge> self = weak_factory_.GetWeakPtr();
  // Grants activeTab like a real click, runs chrome.action.onClicked when
  // there is no popup, and calls ActionDelegate::TriggerPopup when there is
  // one (or shows the context menu when the action cannot run here).
  model->ExecuteUserAction(
      ToolbarActionViewModel::InvocationSource::kToolbarButton);
  if (!self) {
    return;
  }
  if (WindowState* still = FindWindow(widget);
      still && still->pending_done) {
    // No popup: the click itself was the action (or it could not run).
    const bool ran = still->entries.contains(extension_id) &&
                     !still->entries[extension_id]->delegate()->popup_requested();
    std::move(still->pending_done).Run(ran);
  }
}

void OpenExtensionBridge::HidePopups(views::Widget* widget) {
  for (auto& [key, state] : windows_) {
    if (widget && key != HostWindowWidget(widget)) {
      continue;
    }
    for (auto& [id, entry] : state->entries) {
      if (entry->model()->IsShowingPopup()) {
        entry->model()->HidePopup();
      }
    }
  }
}

bool OpenExtensionBridge::IsPopupShowing(
    const std::string& extension_id) const {
  for (const auto& [key, state] : windows_) {
    auto it = state->entries.find(extension_id);
    if (it != state->entries.end() && it->second->model()->IsShowingPopup()) {
      return true;
    }
  }
  return false;
}

bool OpenExtensionBridge::ShowContextMenu(
    const ExtensionHostWindow& window,
    const std::string& extension_id,
    views::View* anchor,
    const gfx::Point& point_in_screen,
    ui::mojom::MenuSourceType source_type) {
  WindowState* state = EnsureWindow(window);
  ActionEntry* entry = EnsureEntry(state, extension_id);
  if (!state || !entry) {
    return false;
  }
  if (state->menu_runner && state->menu_runner->IsRunning()) {
    return true;
  }
  ui::MenuModel* menu = entry->model()->GetContextMenu(
      extensions::ExtensionContextMenuModel::ContextMenuSource::kToolbarAction);
  if (!menu) {
    return false;
  }
  // "Inspect Popup" anchors the popup to the same button.
  state->next_anchor.SetView(StableAnchor(anchor));
  state->menu_runner = std::make_unique<views::MenuRunner>(
      menu, views::MenuRunner::HAS_MNEMONICS | views::MenuRunner::CONTEXT_MENU);
  state->menu_runner->RunMenuAt(state->widget, nullptr,
                                gfx::Rect(point_in_screen, gfx::Size()),
                                views::MenuAnchorPosition::kTopLeft,
                                source_type);
  return true;
}

// --- Pinning -------------------------------------------------------------------

bool OpenExtensionBridge::IsActionPinned(
    const std::string& extension_id) const {
  return toolbar_model_ && toolbar_model_->IsActionPinned(extension_id);
}

bool OpenExtensionBridge::SetActionPinned(const std::string& extension_id,
                                          bool pinned) {
  if (!toolbar_model_ || profile_->IsOffTheRecord() ||
      !toolbar_model_->HasAction(extension_id) ||
      toolbar_model_->IsActionForcePinned(extension_id)) {
    return false;
  }
  if (toolbar_model_->IsActionPinned(extension_id) != pinned) {
    // Persists to the pinned-actions pref and notifies
    // OnToolbarPinnedActionsChanged.
    toolbar_model_->SetActionVisibility(extension_id, pinned);
  }
  return true;
}

bool OpenExtensionBridge::SetPinned(const std::string& extension_id,
                                    bool pinned) {
  return SetActionPinned(extension_id, pinned);
}

bool OpenExtensionBridge::SetEnabled(const std::string& extension_id,
                                     bool enabled) {
  auto* registry = extensions::ExtensionRegistry::Get(profile_);
  if (!registry->GetInstalledExtension(extension_id)) {
    return false;
  }
  auto* registrar = extensions::ExtensionRegistrar::Get(profile_);
  if (enabled) {
    registrar->EnableExtension(extension_id);
  } else {
    registrar->DisableExtension(
        extension_id, {extensions::disable_reason::DISABLE_USER_ACTION});
  }
  return true;
}

// --- Extensions Picker ---------------------------------------------------------

void OpenExtensionBridge::ShowExtensionsPicker(
    const ExtensionHostWindow& window,
    views::View* anchor,
    const PickerCallbacks& callbacks) {
  CloseExtensionsPicker();
  WindowState* state = EnsureWindow(window);
  if (!state) {
    return;
  }
  if (!anchor) {
    anchor = state->FallbackAnchor();
  }
  auto view = std::make_unique<PickerView>(this, state->window, callbacks,
                                           callbacks.dark);
  picker_view_ = view.get();
  const SkColor background = view->PanelColor();
  picker_bubble_ = std::make_unique<PickerBubble>(
      anchor, std::move(view), background,
      base::BindOnce(
          [](base::WeakPtr<OpenExtensionBridge> self,
             base::RepeatingClosure on_closed) {
            if (self) {
              self->CloseExtensionsPicker();
            }
            if (on_closed) {
              on_closed.Run();
            }
          },
          weak_factory_.GetWeakPtr(), callbacks.on_closed));
}

void OpenExtensionBridge::CloseExtensionsPicker() {
  picker_view_ = nullptr;
  if (picker_bubble_) {
    picker_bubble_->Hide();
    // Deleted on the next task: the call can come from the picker's own
    // button handler or from ExecuteUserAction's posted CloseMenuTask.
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(picker_bubble_));
  }
}

bool OpenExtensionBridge::IsExtensionsPickerShowing() const {
  return picker_bubble_ && picker_bubble_->widget() &&
         picker_bubble_->widget()->IsVisible();
}

// --- JSON ----------------------------------------------------------------------

// static
base::DictValue OpenExtensionBridge::ToValue(
    const ExtensionActionInfo& info) {
  base::ListValue permissions;
  for (const auto& permission : info.permissions) {
    permissions.Append(permission);
  }
  return base::DictValue()
      .Set("id", info.id)
      .Set("name", info.name)
      .Set("version", info.version)
      .Set("description", info.description)
      .Set("title", info.title)
      .Set("badge_text", info.badge_text)
      .Set("badge_background_color",
           static_cast<int>(info.badge_background_color))
      .Set("badge_text_color", static_cast<int>(info.badge_text_color))
      .Set("enabled", info.enabled)
      .Set("pinned", info.pinned)
      .Set("force_pinned", info.force_pinned)
      .Set("has_popup", info.has_popup)
      .Set("visible", info.visible)
      .Set("runnable", info.runnable)
      .Set("popup_showing", info.popup_showing)
      .Set("has_icon", !info.icon.isNull())
      .Set("shortcut", base::UTF16ToUTF8(info.shortcut))
      .Set("permissions", std::move(permissions));
}

// --- Notifications -------------------------------------------------------------

void OpenExtensionBridge::NotifyChanged() {
  change_pending_ = false;
  if (picker_view_) {
    picker_view_->Reload();
  }
  for (Observer& observer : observers_) {
    observer.OnExtensionActionsChanged();
  }
}

void OpenExtensionBridge::NotifyActionUpdated(
    const std::string& extension_id) {
  for (Observer& observer : observers_) {
    observer.OnExtensionActionUpdated(extension_id);
  }
}

void OpenExtensionBridge::NotifyChangedSoon() {
  if (change_pending_) {
    return;
  }
  change_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenExtensionBridge> self) {
                       if (self && self->change_pending_) {
                         self->NotifyChanged();
                       }
                     },
                     weak_factory_.GetWeakPtr()));
}

void OpenExtensionBridge::OnPopupVisibility(const std::string& extension_id,
                                            bool showing) {
  for (Observer& observer : observers_) {
    observer.OnExtensionPopupVisibilityChanged(extension_id, showing);
  }
}

void OpenExtensionBridge::OnEntryIconUpdated(const std::string& extension_id) {
  NotifyActionUpdated(extension_id);
  NotifyChangedSoon();
}

void OpenExtensionBridge::OnToolbarActionAdded(
    const ToolbarActionsModel::ActionId& id) {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionRemoved(
    const ToolbarActionsModel::ActionId& id) {
  DropEntry(id);
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionUpdated(
    const ToolbarActionsModel::ActionId& id) {
  NotifyActionUpdated(id);
  NotifyChangedSoon();
}

void OpenExtensionBridge::OnToolbarModelInitialized() {
  for (auto& [widget, state] : windows_) {
    for (const std::string& id : OrderedActionIds(true)) {
      EnsureEntry(state.get(), id);
    }
  }
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarPinnedActionsChanged() {
  NotifyChanged();
}

void OpenExtensionBridge::OnToolbarActionsModelShutdown() {
  windows_.clear();
  toolbar_observation_.Reset();
  toolbar_model_ = nullptr;
}

void OpenExtensionBridge::OnExtensionLoaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  NotifyChanged();
}

void OpenExtensionBridge::OnExtensionUnloaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UnloadedExtensionReason reason) {
  // The view models hold the extension: drop them before it goes away.
  DropEntry(extension->id());
  NotifyChanged();
}

void OpenExtensionBridge::OnExtensionInstalled(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    bool is_update) {
  if (is_update) {
    // An update reloads the extension: its action, icon and popup URL can
    // change, so rebuild the per-window models on next use.
    DropEntry(extension->id());
  }
  NotifyChanged();
}

void OpenExtensionBridge::OnExtensionUninstalled(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UninstallReason reason) {
  DropEntry(extension->id());
  NotifyChanged();
}

void OpenExtensionBridge::OnExtensionActionUpdated(
    extensions::ExtensionAction* extension_action,
    content::WebContents* web_contents,
    content::BrowserContext* browser_context) {
  if (!extension_action ||
      ::Profile::FromBrowserContext(browser_context)->GetOriginalProfile() !=
          profile_.get()) {
    return;
  }
  // Badge text and color, title, icon or visibility for one tab.
  NotifyActionUpdated(extension_action->extension_id());
  NotifyChangedSoon();
}

void OpenExtensionBridge::OnShuttingDown() {
  dispatcher_observation_.Reset();
}

}  // namespace open_unified
