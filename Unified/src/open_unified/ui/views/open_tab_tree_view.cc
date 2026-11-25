// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_tab_tree_view.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/pickle.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "cc/paint/paint_filter.h"
#include "cc/paint/paint_flags.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "open_unified/ui/design/open_metrics.h"
#include "open_unified/ui/design/open_motion.h"
#include "open_unified/ui/design/open_theme_shader.h"
#include "open_unified/ui/design/open_typography.h"
#include "open_unified/ui/views/open_browser_view.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/clipboard/clipboard_format_type.h"
#include "ui/base/clipboard/clipboard_url_info.h"
#include "ui/base/dragdrop/drag_drop_types.h"
#include "ui/base/dragdrop/drop_target_event.h"
#include "ui/base/dragdrop/mojom/drag_drop_types.mojom.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/compositor/compositor.h"
#include "ui/compositor/layer_tree_owner.h"
#include "ui/compositor/paint_recorder.h"
#include "ui/events/event.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/animation/animation_delegate.h"
#include "ui/gfx/animation/slide_animation.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_conversions.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/context_menu_controller.h"
#include "ui/views/controls/scroll_view.h"
#include "ui/views/controls/scrollbar/overlay_scroll_bar.h"
#include "ui/views/controls/textfield/textfield.h"
#include "ui/views/controls/textfield/textfield_controller.h"
#include "ui/views/drag_controller.h"
#include "ui/views/paint_info.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

namespace open_unified {

namespace sl = metrics::space_list;
using theme::Rgba;
using typography::OpenFont;

namespace {

constexpr char kSpacerKey[] = "#spacer";
constexpr char kDividerKey[] = "#divider";
constexpr char kNewTabKey[] = "#newtab";

SkColor Sk(const Rgba& c, float alpha = 1.0f) {
  return theme::ToSkColor(c.WithAlpha(c.a * alpha));
}

float RowHeight(OpenTabTreeView::RowKind kind) {
  switch (kind) {
    case OpenTabTreeView::RowKind::kSpacer:
      return sl::kSpacerRowHeight;
    case OpenTabTreeView::RowKind::kDivider:
      return sl::kDividerRowHeight;
    case OpenTabTreeView::RowKind::kNode:
    case OpenTabTreeView::RowKind::kNewTab:
      return sl::kRowHeight;
  }
  return sl::kRowHeight;
}

gfx::RectF ToRectF(const metrics::Frame& f) {
  return gfx::RectF(f.x, f.y, f.w, f.h);
}

std::u16string HostLabel(const std::string& url) {
  const GURL gurl(url);
  std::string host(gurl.host());
  if (host.rfind("www.", 0) == 0) {
    host = host.substr(4);
  }
  return base::UTF8ToUTF16(host.empty() ? url : host);
}

void FillRoundRect(gfx::Canvas* canvas,
                   const gfx::RectF& rect,
                   float radius,
                   SkColor color) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  canvas->DrawRoundRect(rect, radius, flags);
}

// Selected plate shadow on light content (tabShadowSelected black 0.20).
// guess: blur sigma 1, 0.5 pt down.
void DrawPlateShadow(gfx::Canvas* canvas,
                     const gfx::RectF& rect,
                     float radius,
                     float alpha) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SkColorSetA(SK_ColorBLACK,
                             static_cast<U8CPU>(std::lround(0.20f * alpha * 255))));
  flags.setImageFilter(sk_make_sp<cc::BlurPaintFilter>(
      1.0f, 1.0f, SkTileMode::kDecal, nullptr));
  gfx::RectF shadow = rect;
  shadow.Offset(0, 0.5f);
  canvas->DrawRoundRect(shadow, radius, flags);
}

bool LeftPinnedUrl(const Tab& tab) {
  if (!tab.pinned_url.has_value() || tab.pinned_url->empty()) {
    return false;
  }
  const GURL pinned(*tab.pinned_url), current(tab.url);
  if (!pinned.is_valid() || !current.is_valid()) {
    return false;
  }
  return pinned.host() != current.host() || pinned.path() != current.path();
}

bool AnyChildLoaded(const Folder& folder) {
  for (const SidebarNode& child : folder.children) {
    if (const Tab* t = child.as_tab()) {
      if (t->live_state.has_web_content) {
        return true;
      }
    } else if (const Folder* f = child.as_folder()) {
      if (AnyChildLoaded(*f)) {
        return true;
      }
    } else if (const Split* s = child.as_split()) {
      for (const Tab& p : s->panes) {
        if (p.live_state.has_web_content) {
          return true;
        }
      }
    }
  }
  return false;
}

// Sleeping and frozen tabs draw dimmer. guess: not measured in Arc.
float SleepOpacity(const Tab& tab) {
  switch (tab.live_state.sleep_phase) {
    case SleepPhase::kSleeping:
      return 0.55f;
    case SleepPhase::kFrozen:
      return 0.8f;
    case SleepPhase::kPlaceholder:
    case SleepPhase::kLive:
      return 1.0f;
  }
  return 1.0f;
}

float DeviceScale(const views::View* view) {
  const views::Widget* widget = view->GetWidget();
  if (widget && widget->GetCompositor()) {
    return widget->GetCompositor()->device_scale_factor();
  }
  return 1.0f;
}

// Inline rename field: commits on Enter or focus loss, cancels on Escape.
class RenameField : public views::Textfield,
                    public views::TextfieldController {
  METADATA_HEADER(RenameField, views::Textfield)

 public:
  using CommitCallback = base::OnceCallback<void(std::optional<std::u16string>)>;

  explicit RenameField(CommitCallback callback)
      : callback_(std::move(callback)) {
    set_controller(this);
    SetBorder(nullptr);
    SetBackgroundEnabled(false);
  }

  void Finish(bool commit) {
    if (!callback_) {
      return;
    }
    std::optional<std::u16string> result;
    if (commit) {
      result = std::u16string(GetText());
    }
    std::move(callback_).Run(std::move(result));
  }

  // views::Textfield:
  void OnBlur() override {
    views::Textfield::OnBlur();
    Finish(true);
  }

  // views::TextfieldController:
  bool HandleKeyEvent(views::Textfield* sender,
                      const ui::KeyEvent& event) override {
    if (event.type() != ui::EventType::kKeyPressed) {
      return false;
    }
    if (event.key_code() == ui::VKEY_RETURN) {
      Finish(true);
      return true;
    }
    if (event.key_code() == ui::VKEY_ESCAPE) {
      Finish(false);
      return true;
    }
    return false;
  }

 private:
  CommitCallback callback_;
};

BEGIN_METADATA(RenameField)
END_METADATA

}  // namespace

// ---------------------------------------------------------------------------
// Drag payload

namespace sidebar_dnd {

const ui::ClipboardFormatType& NodeFormat() {
#if BUILDFLAG(IS_MAC)
  static const base::NoDestructor<ui::ClipboardFormatType> format(
      ui::ClipboardFormatType::CustomPlatformType("org.open.sidebar.node"));
#else
  static const base::NoDestructor<ui::ClipboardFormatType> format(
      ui::ClipboardFormatType::CustomPlatformType(
          "application/x-open-sidebar-node"));
#endif
  return *format;
}

void WriteNode(ui::OSExchangeData* data,
               const ItemID& node_id,
               const std::string& url,
               const std::u16string& title) {
  base::Pickle pickle;
  pickle.WriteString(node_id);
  data->SetPickledData(NodeFormat(), pickle);
  const GURL gurl(url);
  if (gurl.is_valid()) {
    data->SetURL(gurl, title);
  }
}

std::optional<ItemID> ReadNode(const ui::OSExchangeData& data) {
  if (!data.HasCustomFormat(NodeFormat())) {
    return std::nullopt;
  }
  std::optional<base::Pickle> pickle = data.GetPickledData(NodeFormat());
  if (!pickle) {
    return std::nullopt;
  }
  base::PickleIterator it(*pickle);
  std::string id;
  if (!it.ReadString(&id) || id.empty()) {
    return std::nullopt;
  }
  return id;
}

}  // namespace sidebar_dnd

// ---------------------------------------------------------------------------
// HeaderView: Space icon, title, hover fill, Pinned chevron and "..." button.

class OpenTabTreeView::HeaderView : public views::View,
                                    public views::ContextMenuController {
  METADATA_HEADER(HeaderView, views::View)

 public:
  explicit HeaderView(OpenTabTreeView* tree) : tree_(tree) {
    set_context_menu_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kHeading);
  }

  void Refresh() {
    const Space* space = tree_->space();
    GetViewAccessibility().SetName(
        space && space->title ? base::UTF8ToUTF16(*space->title)
                              : std::u16string(u"Space"));
    SchedulePaint();
  }

  void BeginRename() {
    const Space* space = tree_->space();
    if (!space || rename_) {
      return;
    }
    auto field = std::make_unique<RenameField>(base::BindOnce(
        &HeaderView::OnRenameFinished, weak_factory_.GetWeakPtr()));
    field->SetFontList(typography::Get(OpenFont::kSpaceTitle));
    field->SetColor(Sk(tree_->theme_state().roles.title));
    field->SetText(base::UTF8ToUTF16(space->title.value_or(std::string())));
    rename_ = AddChildView(std::move(field));
    LayoutRename();
    rename_->RequestFocus();
    rename_->SelectAll(false);
    SchedulePaint();
  }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    return gfx::Size(0, static_cast<int>(sl::kHeaderHeight));
  }

  void Layout(PassKey) override { LayoutRename(); }

  void OnPaint(gfx::Canvas* canvas) override {
    const Space* space = tree_->space();
    if (!space) {
      return;
    }
    const auto& state = tree_->theme_state();
    const float w = width();
    if (hovered_ && !rename_) {
      FillRoundRect(canvas,
                    gfx::RectF(sl::kHeaderFillInsetX, 0,
                               w - 2 * sl::kHeaderFillInsetX, sl::kHeaderHeight),
                    sl::kRowFillCornerRadius, Sk(state.roles.row_hover));
    }
    const std::u16string title =
        base::UTF8ToUTF16(space->title.value_or(std::string()));
    glyphs::DrawSpaceIcon(
        canvas, space->icon ? &*space->icon : nullptr, title,
        ToRectF(sl::kHeaderIconFrame), typography::Get(OpenFont::kHeaderEmoji),
        Sk(state.roles.space_title), 1.0f);
    if (rename_) {
      return;
    }
    const gfx::FontList& font = typography::Get(OpenFont::kSpaceTitle);
    const float right = hovered_ ? w - sl::kHeaderMoreTrailing -
                                       sl::kHeaderMoreSize - 2
                                 : w - 17;
    const int text_x = static_cast<int>(sl::kHeaderTitleX + sl::kHeaderTextInset);
    const int text_w = std::max(0, static_cast<int>(right) - text_x);
    const int top = typography::TextTopForBaseline(
        font, sl::kHeaderTitleY + sl::kHeaderTitleBaselineOffset);
    const gfx::Rect text_rect(text_x, top, text_w, font.GetHeight());
    canvas->DrawStringRect(title, font, Sk(state.roles.space_title), text_rect);
    if (hovered_) {
      // Pinned collapse chevron after the title (12 Bold), "..." at the end.
      const int title_w = std::min(
          text_w, gfx::Canvas::GetStringWidth(title, font));
      chevron_rect_ = gfx::RectF(text_x + title_w + 2, 5, 22, 26);
      glyphs::Draw(canvas,
                   space->is_pinned_collapsed ? glyphs::Glyph::kChevronRight
                                              : glyphs::Glyph::kChevronDown,
                   chevron_rect_, Sk(state.roles.space_title));
      more_rect_ = gfx::RectF(w - sl::kHeaderMoreTrailing - sl::kHeaderMoreSize,
                              5, sl::kHeaderMoreSize, sl::kHeaderMoreSize);
      if (more_hovered_) {
        FillRoundRect(canvas, more_rect_, metrics::chrome::kButtonPlateRadius,
                      Sk(state.roles.row_hover));
      }
      glyphs::Draw(canvas, glyphs::Glyph::kMore, more_rect_,
                   Sk(state.roles.space_title));
    }
  }

  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    SchedulePaint();
  }
  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    more_hovered_ = false;
    SchedulePaint();
  }
  void OnMouseMoved(const ui::MouseEvent& event) override {
    const bool more = more_rect_.Contains(gfx::PointF(event.location()));
    if (more != more_hovered_) {
      more_hovered_ = more;
      SchedulePaint();
    }
  }
  bool OnMousePressed(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton()) {
      return false;
    }
    if (event.GetClickCount() == 2 && !more_rect_.Contains(gfx::PointF(event.location()))) {
      BeginRename();
      return true;
    }
    return true;
  }
  void OnMouseReleased(const ui::MouseEvent& event) override {
    if (!event.IsOnlyLeftMouseButton() || !HitTestPoint(event.location())) {
      return;
    }
    const gfx::PointF p(event.location());
    if (more_rect_.Contains(p)) {
      ShowMenu(gfx::ToRoundedPoint(more_rect_.bottom_left()),
               ui::mojom::MenuSourceType::kMouse);
      return;
    }
    if (chevron_rect_.Contains(p)) {
      const Space* space = tree_->space();
      if (!space) {
        return;
      }
      OpenIntent intent = OpenIntent::ForSpace(OpenIntentKind::kSetPinnedCollapsed,
                                               tree_->space_id());
      intent.flag = !space->is_pinned_collapsed;
      tree_->context_->Send(intent);
    }
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kSpace;
    target.space_id = tree_->space_id();
    tree_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

 private:
  void ShowMenu(gfx::Point local, ui::mojom::MenuSourceType source_type) {
    views::View::ConvertPointToScreen(this, &local);
    ShowContextMenuForViewImpl(this, local, source_type);
  }

  void LayoutRename() {
    if (!rename_) {
      return;
    }
    rename_->SetBounds(static_cast<int>(sl::kHeaderTitleX), 7,
                       std::max(0, width() - static_cast<int>(sl::kHeaderTitleX) - 13),
                       22);
  }

  void OnRenameFinished(std::optional<std::u16string> text) {
    if (!rename_) {
      return;
    }
    views::View* field = rename_;
    rename_ = nullptr;
    if (text.has_value()) {
      OpenIntent intent =
          OpenIntent::ForSpace(OpenIntentKind::kRenameSpace, tree_->space_id());
      intent.text = base::UTF16ToUTF8(*text);
      tree_->context_->Send(intent);
    }
    // The field is inside its own key/blur handler: delete it later.
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, RemoveChildViewT(field));
    SchedulePaint();
  }

  raw_ptr<OpenTabTreeView> tree_;
  raw_ptr<RenameField> rename_ = nullptr;
  bool hovered_ = false;
  bool more_hovered_ = false;
  mutable gfx::RectF chevron_rect_;
  mutable gfx::RectF more_rect_;
  base::WeakPtrFactory<HeaderView> weak_factory_{this};
};

BEGIN_METADATA(OpenTabTreeView, HeaderView)
END_METADATA

// ---------------------------------------------------------------------------
// RowView: one row of any kind. Paints everything itself (no child views
// except the on-demand rename field) so a 1,000-row tree stays cheap.

class OpenTabTreeView::RowView : public views::View,
                                 public gfx::AnimationDelegate,
                                 public views::ContextMenuController,
                                 public views::DragController {
  METADATA_HEADER(RowView, views::View)

 public:
  RowView(OpenTabTreeView* tree, const RowDescriptor& descriptor)
      : tree_(tree), descriptor_(descriptor) {
    hover_.SetSlideDuration(motion::Seconds(motion::kHoverFade));
    selection_.SetSlideDuration(motion::Seconds(motion::kSelectionFade));
    set_context_menu_controller(this);
    set_drag_controller(this);
    UpdateAccessibility();
  }

  const RowDescriptor& descriptor() const { return descriptor_; }
  void SetDescriptor(const RowDescriptor& d) {
    if (d == descriptor_) {
      return;
    }
    descriptor_ = d;
    UpdateAccessibility();
    SchedulePaint();
  }

  void SetSelected(bool selected, bool animate) {
    if (selected == selected_) {
      return;
    }
    selected_ = selected;
    if (animate) {
      selected ? selection_.Show() : selection_.Hide();
    } else {
      selection_.Reset(selected ? 1.0 : 0.0);
    }
    SchedulePaint();
  }

  void Refresh() {
    UpdateAccessibility();
    SchedulePaint();
  }

  void BeginRename() {
    if (descriptor_.kind != RowKind::kNode || rename_) {
      return;
    }
    const SidebarNode* node = tree_->context_->controller()->FindNode(descriptor_.node_id);
    if (!node) {
      return;
    }
    std::u16string text;
    bool folder = false;
    if (const Tab* tab = node->as_tab()) {
      text = base::UTF8ToUTF16(tab->display_title());
    } else if (const Folder* f = node->as_folder()) {
      text = base::UTF8ToUTF16(f->title);
      folder = true;
    } else if (const Split* s = node->as_split()) {
      text = base::UTF8ToUTF16(s->custom_title.value_or(std::string()));
    }
    auto field = std::make_unique<RenameField>(
        base::BindOnce(&RowView::OnRenameFinished, weak_factory_.GetWeakPtr()));
    field->SetFontList(typography::Get(folder ? OpenFont::kFolderTitle
                                              : OpenFont::kTabTitle));
    field->SetColor(Sk(tree_->theme_state().roles.title));
    field->SetText(text);
    rename_ = AddChildView(std::move(field));
    LayoutRename();
    rename_->RequestFocus();
    rename_->SelectAll(false);
    SchedulePaint();
  }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    return gfx::Size(0, static_cast<int>(RowHeight(descriptor_.kind)));
  }

  void Layout(PassKey) override { LayoutRename(); }

  void OnPaint(gfx::Canvas* canvas) override { PaintContent(canvas, false); }

  std::u16string GetRenderedTooltipText(const gfx::Point& p) const override {
    if (descriptor_.kind != RowKind::kNode) {
      return std::u16string();
    }
    const SidebarNode* node =
        tree_->context_->controller()->FindNode(descriptor_.node_id);
    if (const Tab* tab = node ? node->as_tab() : nullptr) {
      return base::UTF8ToUTF16(tab->display_title());
    }
    return std::u16string();
  }

  void OnMouseEntered(const ui::MouseEvent& event) override {
    hovered_ = true;
    hover_.Show();
    UpdateHoveredPart(event.location());
  }

  void OnMouseExited(const ui::MouseEvent& event) override {
    hovered_ = false;
    hover_.Hide();
    hovered_part_ = Part::kNone;
    SchedulePaint();
  }

  void OnMouseMoved(const ui::MouseEvent& event) override {
    UpdateHoveredPart(event.location());
  }

  bool OnMousePressed(const ui::MouseEvent& event) override {
    pressed_part_ = PartAt(event.location());
    if (event.IsOnlyLeftMouseButton() && event.GetClickCount() == 2 &&
        descriptor_.kind == RowKind::kNode && pressed_part_ == Part::kBody) {
      BeginRename();
      pressed_part_ = Part::kNone;
      return true;
    }
    return event.IsOnlyLeftMouseButton() || event.IsOnlyMiddleMouseButton();
  }

  void OnMouseReleased(const ui::MouseEvent& event) override {
    const Part part = PartAt(event.location());
    const Part pressed = pressed_part_;
    pressed_part_ = Part::kNone;
    if (!HitTestPoint(event.location()) || part != pressed ||
        pressed == Part::kNone) {
      return;
    }
    if (event.IsOnlyMiddleMouseButton()) {
      if (descriptor_.kind == RowKind::kNode &&
          descriptor_.node_kind != SidebarNode::Kind::kFolder) {
        Send(OpenIntent::ForNode(OpenIntentKind::kClose, descriptor_.node_id));
      }
      return;
    }
    Activate(part, event.location());
  }

  // gfx::AnimationDelegate:
  void AnimationProgressed(const gfx::Animation* animation) override {
    SchedulePaint();
  }
  void AnimationEnded(const gfx::Animation* animation) override {
    SchedulePaint();
  }

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.space_id = tree_->space_id();
    if (descriptor_.kind == RowKind::kNode) {
      target.kind = OpenMenuTarget::Kind::kNode;
      target.node_id = descriptor_.node_id;
    } else {
      target.kind = OpenMenuTarget::Kind::kSpace;
    }
    tree_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

  // views::DragController:
  void WriteDragDataForView(views::View* sender,
                            const gfx::Point& press_pt,
                            ui::OSExchangeData* data) override {
    std::string url;
    std::u16string title;
    if (const SidebarNode* node =
            tree_->context_->controller()->FindNode(descriptor_.node_id)) {
      if (const Tab* tab = node->as_tab()) {
        url = tab->url;
        title = base::UTF8ToUTF16(tab->display_title());
      } else if (const Folder* f = node->as_folder()) {
        title = base::UTF8ToUTF16(f->title);
      }
    }
    sidebar_dnd::WriteNode(data, descriptor_.node_id, url, title);
    // Drag image: the row as drawn, selected look.
    const float scale = DeviceScale(this);
    gfx::Canvas canvas(size(), scale, /*is_opaque=*/false);
    PaintContent(&canvas, /*for_drag=*/true);
    data->provider().SetDragImage(
        gfx::ImageSkia(gfx::ImageSkiaRep(canvas.GetBitmap(), scale)),
        press_pt.OffsetFromOrigin());
  }

  int GetDragOperationsForView(views::View* sender,
                               const gfx::Point& p) override {
    return ui::DragDropTypes::DRAG_MOVE | ui::DragDropTypes::DRAG_COPY |
           ui::DragDropTypes::DRAG_LINK;
  }

  bool CanStartDragForView(views::View* sender,
                           const gfx::Point& press_pt,
                           const gfx::Point& p) override {
    return descriptor_.kind == RowKind::kNode && !rename_ &&
           views::View::ExceededDragThreshold(p - press_pt);
  }

 private:
  enum class Part { kNone, kBody, kAccessory, kAudio, kClear, kSplitCell0,
                    kSplitCell1, kSplitCell2, kSplitCell3 };

  void Send(const OpenIntent& intent) { tree_->context_->Send(intent); }

  float indent() const { return descriptor_.depth * sl::kIndentPerLevel; }

  const SidebarNode* node() const {
    return descriptor_.kind == RowKind::kNode
               ? tree_->context_->controller()->FindNode(descriptor_.node_id)
               : nullptr;
  }

  bool HasAudio(const Tab& tab) const {
    return tab.live_state.is_audible || tab.is_muted;
  }

  // Close (Today) or unload (loaded pinned, folders with loaded children).
  bool ShowsAccessory() const {
    if (!hovered_ || rename_) {
      return false;
    }
    const SidebarNode* n = node();
    if (!n) {
      return false;
    }
    if (const Tab* tab = n->as_tab()) {
      return !descriptor_.in_pinned || tab->live_state.has_web_content;
    }
    if (const Folder* f = n->as_folder()) {
      return AnyChildLoaded(*f);
    }
    return !descriptor_.in_pinned;  // splits: close in Today
  }

  bool AccessoryIsUnload() const {
    const SidebarNode* n = node();
    return n && (descriptor_.in_pinned || n->as_folder());
  }

  gfx::RectF AccessoryRect() const {
    return ToRectF(sl::Accessory(width()));
  }

  gfx::RectF AudioRect() const {
    return gfx::RectF(metrics::row_media::kButtonX + indent(),
                      metrics::row_media::kButtonY,
                      metrics::row_media::kButtonSize,
                      metrics::row_media::kButtonSize);
  }

  gfx::RectF ClearRect() const {
    const float w = width();
    return gfx::RectF(w + sl::kClearArrowFrame.x - 2, 0,
                      -sl::kClearArrowFrame.x - 10, sl::kDividerRowHeight);
  }

  std::vector<gfx::RectF> SplitCells(size_t n) const {
    std::vector<gfx::RectF> cells;
    if (n == 0) {
      return cells;
    }
    const float w = width();
    const float pitch = (w - 2 * sl::kRowFillInsetX - indent() - sl::kSplitCellGap) /
                        static_cast<float>(n);
    const float x0 = sl::kRowFillInsetX + indent() + sl::kSplitCellInset;
    for (size_t i = 0; i < n; ++i) {
      cells.emplace_back(x0 + i * pitch, sl::kSplitCellTop,
                         pitch - sl::kSplitCellGap, sl::kSplitCellHeight);
    }
    return cells;
  }

  Part PartAt(const gfx::Point& point) const {
    const gfx::PointF p(point);
    switch (descriptor_.kind) {
      case RowKind::kSpacer:
        return Part::kNone;
      case RowKind::kDivider:
        return hovered_ && ClearRect().Contains(p) ? Part::kClear : Part::kNone;
      case RowKind::kNewTab:
        return Part::kBody;
      case RowKind::kNode:
        break;
    }
    if (ShowsAccessory() && AccessoryRect().Contains(p)) {
      return Part::kAccessory;
    }
    const SidebarNode* n = node();
    if (!n) {
      return Part::kBody;
    }
    if (const Tab* tab = n->as_tab()) {
      if (HasAudio(*tab) && AudioRect().Contains(p)) {
        return Part::kAudio;
      }
    }
    if (const Split* split = n->as_split()) {
      const auto cells = SplitCells(split->panes.size());
      for (size_t i = 0; i < cells.size() && i < 4; ++i) {
        if (cells[i].Contains(p)) {
          return static_cast<Part>(static_cast<int>(Part::kSplitCell0) + i);
        }
      }
    }
    return Part::kBody;
  }

  void UpdateHoveredPart(const gfx::Point& p) {
    const Part part = PartAt(p);
    if (part != hovered_part_) {
      hovered_part_ = part;
    }
    SchedulePaint();
  }

  void Activate(Part part, const gfx::Point& point) {
    const SpaceID& space_id = tree_->space_id();
    switch (descriptor_.kind) {
      case RowKind::kSpacer:
        return;
      case RowKind::kDivider:
        if (part == Part::kClear) {
          Send(OpenIntent::ForSpace(OpenIntentKind::kClearToday, space_id));
        }
        return;
      case RowKind::kNewTab: {
        gfx::Rect anchor = GetBoundsInScreen();
        Send(OpenIntent::CommandBar(CommandBarSource::kNewTabRow, anchor));
        return;
      }
      case RowKind::kNode:
        break;
    }
    const SidebarNode* n = node();
    if (!n) {
      return;
    }
    if (part == Part::kAccessory) {
      if (n->as_folder()) {
        Send(OpenIntent::ForNode(OpenIntentKind::kUnloadFolder,
                                 descriptor_.node_id));
      } else if (AccessoryIsUnload()) {
        Send(OpenIntent::ForNode(OpenIntentKind::kUnloadTab,
                                 descriptor_.node_id));
      } else {
        Send(OpenIntent::ForNode(OpenIntentKind::kClose, descriptor_.node_id));
      }
      return;
    }
    if (part == Part::kAudio) {
      Send(OpenIntent::ForNode(OpenIntentKind::kToggleMute, descriptor_.node_id));
      return;
    }
    if (const Folder* f = n->as_folder()) {
      OpenIntent intent = OpenIntent::ForNode(OpenIntentKind::kSetFolderExpanded,
                                              descriptor_.node_id);
      intent.flag = !f->is_expanded;
      Send(intent);
      return;
    }
    if (const Split* s = n->as_split()) {
      const int cell = static_cast<int>(part) - static_cast<int>(Part::kSplitCell0);
      ItemID pane;
      if (cell >= 0 && static_cast<size_t>(cell) < s->panes.size()) {
        pane = s->panes[static_cast<size_t>(cell)].id;
      }
      Send(OpenIntent::Select(descriptor_.node_id, space_id, pane));
      return;
    }
    Send(OpenIntent::Select(descriptor_.node_id, space_id));
  }

  void UpdateAccessibility() {
    auto& a11y = GetViewAccessibility();
    switch (descriptor_.kind) {
      case RowKind::kSpacer:
        a11y.SetIsIgnored(true);
        return;
      case RowKind::kDivider:
        a11y.SetRole(ax::mojom::Role::kSplitter);
        a11y.SetName(u"Pinned and Today divider");
        return;
      case RowKind::kNewTab:
        a11y.SetRole(ax::mojom::Role::kButton);
        a11y.SetName(u"New Tab");
        return;
      case RowKind::kNode:
        break;
    }
    a11y.SetRole(ax::mojom::Role::kTreeItem);
    const SidebarNode* n = node();
    if (!n) {
      return;
    }
    if (const Tab* tab = n->as_tab()) {
      a11y.SetName(base::UTF8ToUTF16(tab->display_title()));
    } else if (const Folder* f = n->as_folder()) {
      a11y.SetName(base::UTF8ToUTF16(f->title));
    } else if (const Split* s = n->as_split()) {
      a11y.SetName(base::UTF8ToUTF16(s->custom_title.value_or("Split View")));
    }
  }

  void LayoutRename() {
    if (!rename_) {
      return;
    }
    const int x = static_cast<int>(sl::kTitleX + indent());
    rename_->SetBounds(x, 9, std::max(0, width() - x - 13), 24);
  }

  void OnRenameFinished(std::optional<std::u16string> text) {
    if (!rename_) {
      return;
    }
    views::View* field = rename_;
    rename_ = nullptr;
    if (text.has_value()) {
      OpenIntent intent =
          OpenIntent::ForNode(OpenIntentKind::kRename, descriptor_.node_id);
      intent.text = base::UTF16ToUTF8(*text);
      Send(intent);
    }
    // The field is inside its own key/blur handler: delete it later.
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, RemoveChildViewT(field));
    SchedulePaint();
  }

  // --- Painting -----------------------------------------------------------------

  void PaintContent(gfx::Canvas* canvas, bool for_drag) {
    const auto& state = tree_->theme_state();
    const auto& roles = state.roles;
    switch (descriptor_.kind) {
      case RowKind::kSpacer:
        return;
      case RowKind::kDivider:
        PaintDivider(canvas, roles);
        return;
      case RowKind::kNewTab:
        PaintNewTab(canvas, roles);
        return;
      case RowKind::kNode:
        break;
    }
    const SidebarNode* n = node();
    if (!n) {
      return;
    }
    const float w = width();
    const gfx::RectF fill = ToRectF(sl::RowFill(w, indent()));
    const float sel = for_drag ? 1.0f : static_cast<float>(selection_.GetCurrentValue());
    const float hov = for_drag ? 0.0f : static_cast<float>(hover_.GetCurrentValue());
    const bool is_peek_source =
        tree_->peek_source_ && *tree_->peek_source_ == descriptor_.node_id;
    const Split* split = n->as_split();
    if (sel > 0 && !split) {
      if (roles.content == theme::ContentAppearance::kLight) {
        DrawPlateShadow(canvas, fill, sl::kRowFillCornerRadius, sel);
      }
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.active_plate, sel));
    }
    if (hov > 0 && sel < 1 && !split) {
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.row_hover, hov * (1 - sel)));
    }
    if (is_peek_source && sel <= 0) {
      // Lighter fill while the Peek shows (F0090). guess: half the plate.
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.active_plate, 0.5f));
    }

    float title_right = w - sl::kTitleTrailingInset;
    if (ShowsAccessory() && !for_drag) {
      const gfx::RectF acc = AccessoryRect();
      if (hovered_part_ == Part::kAccessory) {
        FillRoundRect(canvas, acc, metrics::chrome::kButtonPlateRadius,
                      Sk(roles.row_hover));
      }
      glyphs::Draw(canvas,
                   AccessoryIsUnload() ? glyphs::Glyph::kMinus
                                       : glyphs::Glyph::kClose,
                   acc, Sk(roles.title, 0.6f));
      title_right = acc.x();
    } else if (is_peek_source) {
      const gfx::RectF badge(w - sl::kPeekBadgeTrailingInset, sl::kPeekBadgeY,
                             sl::kPeekBadgeSize, sl::kPeekBadgeSize);
      FillRoundRect(canvas, badge, sl::kPeekBadgeCornerRadius,
                    Sk(roles.tile_fill));
      if (const Tab* peek = tree_->context_->controller()->GetActiveTab(
              tree_->context_->window_id())) {
        DrawFavicon(canvas, *peek,
                    gfx::RectF(badge.x() + 3, badge.y() + 3, 18, 18), roles, 1);
      }
      title_right = w - 39;
    }

    if (const Tab* tab = n->as_tab()) {
      PaintTab(canvas, *tab, roles, title_right, sel > 0.5f);
    } else if (const Folder* folder = n->as_folder()) {
      PaintFolder(canvas, *folder, state, title_right);
    } else if (split) {
      PaintSplit(canvas, *split, state, fill, sel, hov);
    }
  }

  void DrawFavicon(gfx::Canvas* canvas,
                   const Tab& tab,
                   const gfx::RectF& frame,
                   const theme::SidebarRoles& roles,
                   float opacity) {
    const float ink = sl::kFaviconInk;
    const gfx::RectF ink_rect(frame.x() + (frame.width() - ink) / 2,
                              frame.y() + (frame.height() - ink) / 2, ink, ink);
    const gfx::ImageSkia image = tree_->context_->FaviconFor(tab);
    if (!image.isNull()) {
      cc::PaintFlags flags;
      flags.setAlphaf(opacity);
      const gfx::Rect dst = gfx::ToEnclosingRect(ink_rect);
      canvas->DrawImageInt(image, 0, 0, image.width(), image.height(), dst.x(),
                           dst.y(), dst.width(), dst.height(), true, flags);
      return;
    }
    glyphs::DrawLetterTile(canvas, ink_rect, HostLabel(tab.url),
                           Sk(roles.title, 0.15f * opacity),
                           Sk(roles.title, opacity));
  }

  void PaintTab(gfx::Canvas* canvas,
                const Tab& tab,
                const theme::SidebarRoles& roles,
                float title_right,
                bool selected) {
    const float x0 = indent();
    const float opacity = SleepOpacity(tab);
    DrawFavicon(canvas, tab,
                gfx::RectF(sl::kFaviconX + x0, sl::kFaviconY, sl::kFaviconSize,
                           sl::kFaviconSize),
                roles, opacity);
    float title_x = sl::kTitleX + x0;
    if (HasAudio(tab)) {
      const gfx::RectF audio = AudioRect();
      if (hovered_part_ == Part::kAudio) {
        FillRoundRect(canvas, audio, metrics::chrome::kButtonPlateRadius,
                      Sk(roles.row_hover));
      }
      glyphs::Draw(canvas,
                   tab.is_muted ? glyphs::Glyph::kSpeakerMuted
                                : glyphs::Glyph::kSpeaker,
                   audio, Sk(roles.title, 0.75f));
      title_x += metrics::row_media::kTitleShift;
    }
    if (descriptor_.in_pinned && LeftPinnedUrl(tab)) {
      // "/" before the title once a pinned tab left its pinned URL.
      const float cx = title_x + sl::kPinnedSlashCenterX;
      const float cy = sl::kPinnedSlashCenterY;
      const float half = sl::kPinnedSlashSize.h / 2;
      const float dx = std::sin(sl::kPinnedSlashAngle) * half;
      cc::PaintFlags pen;
      pen.setAntiAlias(true);
      pen.setStyle(cc::PaintFlags::kStroke_Style);
      pen.setStrokeWidth(sl::kPinnedSlashSize.w);
      pen.setStrokeCap(cc::PaintFlags::kRound_Cap);
      pen.setColor(Sk(roles.title, 0.30f));
      canvas->DrawLine(gfx::PointF(cx + dx, cy - half),
                       gfx::PointF(cx - dx, cy + half), pen);
      title_x += sl::kPinnedSlashTitleShift;
    }
    if (tab.is_unread && !selected) {
      const float cx = width() - sl::kUnreadDotTrailingCenter;
      cc::PaintFlags dot;
      dot.setAntiAlias(true);
      dot.setColor(Sk(tree_->theme_state().contrast_accent));
      canvas->DrawCircle(gfx::PointF(cx, sl::kUnreadDotCenterY),
                         sl::kUnreadDotSize / 2, dot);
      title_right = std::min(title_right, cx - sl::kUnreadDotSize - 4);
    }
    if (rename_) {
      return;
    }
    const gfx::FontList& font = typography::Get(OpenFont::kTabTitle);
    DrawTitle(canvas, base::UTF8ToUTF16(tab.display_title()), font,
              Sk(roles.title, opacity), title_x, title_right);
  }

  void PaintFolder(gfx::Canvas* canvas,
                   const Folder& folder,
                   const OpenSpaceThemeState& state,
                   float title_right) {
    const float x0 = indent();
    const gfx::RectF icon(sl::kFaviconX + x0, sl::kFaviconY, sl::kFaviconSize,
                          sl::kFaviconSize);
    glyphs::Draw(canvas,
                 folder.is_expanded ? glyphs::Glyph::kFolderOpen
                                    : glyphs::Glyph::kFolderClosed,
                 icon, Sk(state.accent));
    if (!folder.is_expanded && folder.peeked_child_id.has_value()) {
      cc::PaintFlags dot;
      dot.setAntiAlias(true);
      dot.setColor(Sk(state.roles.title, 0.6f));
      for (int i = 0; i < 3; ++i) {
        canvas->DrawCircle(
            gfx::PointF(icon.x() + sl::kFolderPeekDotFirstX +
                            i * sl::kFolderPeekDotPitch,
                        icon.y() + sl::kFolderPeekDotY),
            sl::kFolderPeekDotDiameter / 2, dot);
      }
    }
    if (rename_) {
      return;
    }
    DrawTitle(canvas, base::UTF8ToUTF16(folder.title),
              typography::Get(OpenFont::kFolderTitle), Sk(state.roles.title),
              sl::kTitleX + x0, title_right);
  }

  void PaintSplit(gfx::Canvas* canvas,
                  const Split& split,
                  const OpenSpaceThemeState& state,
                  const gfx::RectF& fill,
                  float sel,
                  float hov) {
    const auto& roles = state.roles;
    const auto cells = SplitCells(split.panes.size());
    if (sel > 0) {
      // Selected split: the fill is a card, each pane its own cell (F0081).
      if (roles.content == theme::ContentAppearance::kLight) {
        DrawPlateShadow(canvas, fill, sl::kRowFillCornerRadius, sel);
      }
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.active_plate, sel));
      for (const gfx::RectF& cell : cells) {
        FillRoundRect(canvas, cell, sl::kSplitCellCornerRadius,
                      Sk(roles.row_hover, sel));
      }
    } else {
      if (hov > 0) {
        FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                      Sk(roles.row_hover, hov));
      }
      // Divider between unselected cells.
      for (size_t i = 1; i < cells.size(); ++i) {
        const float x = cells[i].x() - sl::kSplitCellGap / 2;
        canvas->FillRect(gfx::ToEnclosingRect(gfx::RectF(
                             x, 12, sl::kSplitDividerWidth, 17)),
                         Sk(roles.separator));
      }
    }
    const gfx::FontList& font = typography::Get(OpenFont::kSplitCellTitle);
    const SkColor text = Sk(state.style.SplitTitleColor(state.appearance));
    for (size_t i = 0; i < cells.size(); ++i) {
      const Tab& pane = split.panes[i];
      const gfx::RectF& cell = cells[i];
      const gfx::RectF icon(cell.x() + 5, cell.y() + (cell.height() - 18) / 2,
                            18, 18);
      DrawFavicon(canvas, pane, icon, roles, SleepOpacity(pane));
      const float tx = icon.right() + 6;
      const int top = static_cast<int>(
          cell.y() + (cell.height() - font.GetHeight()) / 2);
      canvas->DrawStringRect(
          base::UTF8ToUTF16(pane.display_title()), font, text,
          gfx::Rect(static_cast<int>(tx), top,
                    std::max(0, static_cast<int>(cell.right() - 4 - tx)),
                    font.GetHeight()));
    }
  }

  void DrawTitle(gfx::Canvas* canvas,
                 const std::u16string& title,
                 const gfx::FontList& font,
                 SkColor color,
                 float x,
                 float right) {
    const int text_x = static_cast<int>(std::lround(x + sl::kTextInset));
    const int text_w = std::max(
        0, static_cast<int>(right - sl::kTextTrailingInset) - text_x);
    const int top = typography::TextTopForBaseline(font, sl::kTitleBaselineOffset);
    canvas->DrawStringRect(title, font, color,
                           gfx::Rect(text_x, top, text_w, font.GetHeight()));
  }

  void PaintDivider(gfx::Canvas* canvas, const theme::SidebarRoles& roles) {
    const float w = width();
    const bool clear = hovered_;
    const float end = clear ? w + sl::kClearLineEnd : w - sl::kDividerLineInset;
    canvas->FillRect(
        gfx::ToEnclosingRect(gfx::RectF(sl::kDividerLineInset, sl::kDividerLineY,
                                        std::max(0.0f, end - sl::kDividerLineInset),
                                        1)),
        Sk(roles.separator));
    if (!clear) {
      return;
    }
    // "Clear" label and arrow: SidebarForeground (black 0.30 / white 0.45),
    // darker under the pointer (black 0.45 / white 0.45).
    const bool dark = roles.content == theme::ContentAppearance::kDark;
    const bool pressed_look = hovered_part_ == Part::kClear;
    const SkColor color = theme::ToSkColor(
        dark ? Rgba::White(0.45)
             : Rgba::Black(pressed_look ? 0.45 : 0.30));
    glyphs::Draw(canvas, glyphs::Glyph::kArrowDown,
                 gfx::RectF(w + sl::kClearArrowFrame.x, sl::kClearArrowFrame.y,
                            sl::kClearArrowFrame.w, sl::kClearArrowFrame.h),
                 color);
    const gfx::FontList& font = typography::Get(OpenFont::kClearLabel);
    const int top = typography::TextTopForBaseline(font, sl::kClearLabelBaseline);
    canvas->DrawStringRect(
        u"Clear", font, color,
        gfx::Rect(static_cast<int>(w + sl::kClearLabelX), top,
                  static_cast<int>(sl::kClearLabelWidth) + 4, font.GetHeight()));
  }

  void PaintNewTab(gfx::Canvas* canvas, const theme::SidebarRoles& roles) {
    const float w = width();
    const gfx::RectF fill = ToRectF(sl::RowFill(w));
    const bool open = tree_->new_tab_command_bar_open_;
    const float hov = static_cast<float>(hover_.GetCurrentValue());
    if (open) {
      if (roles.content == theme::ContentAppearance::kLight) {
        DrawPlateShadow(canvas, fill, sl::kRowFillCornerRadius, 1);
      }
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.active_plate));
    } else if (hov > 0) {
      FillRoundRect(canvas, fill, sl::kRowFillCornerRadius,
                    Sk(roles.row_hover, hov));
    }
    // Plus ink 11 x 11 at x 20...31, 1 left 1 down of center.
    glyphs::Draw(canvas, glyphs::Glyph::kPlus,
                 gfx::RectF(sl::kNewTabGlyphX, 0, sl::kNewTabGlyphInk,
                            sl::kRowHeight),
                 open ? Sk(roles.title) : Sk(roles.new_tab_glyph),
                 gfx::Vector2dF(-1, 1));
    DrawTitle(canvas, u"New Tab", typography::Get(OpenFont::kNewTab),
              open ? Sk(roles.title) : Sk(roles.new_tab_label), sl::kTitleX,
              w - sl::kTitleTrailingInset);
  }

  raw_ptr<OpenTabTreeView> tree_;
  RowDescriptor descriptor_;
  gfx::SlideAnimation hover_{this};
  gfx::SlideAnimation selection_{this};
  bool hovered_ = false;
  bool selected_ = false;
  Part hovered_part_ = Part::kNone;
  Part pressed_part_ = Part::kNone;
  raw_ptr<RenameField> rename_ = nullptr;
  base::WeakPtrFactory<RowView> weak_factory_{this};
};

BEGIN_METADATA(OpenTabTreeView, RowView)
END_METADATA

// ---------------------------------------------------------------------------
// ListView: lays rows out, animates structure, and is the drop target.

class OpenTabTreeView::ListView : public views::View,
                                  public views::ContextMenuController {
  METADATA_HEADER(ListView, views::View)

 public:
  explicit ListView(OpenTabTreeView* tree)
      : tree_(tree), bounds_animator_(this, /*use_transforms=*/false) {
    bounds_animator_.SetAnimationDuration(motion::Seconds(motion::kRowStructure));
    set_context_menu_controller(this);
    GetViewAccessibility().SetRole(ax::mojom::Role::kTree);
  }

  float TotalHeight() const {
    float h = 0;
    for (const auto& row : tree_->rows_) {
      h += RowHeight(row.kind);
    }
    return h;
  }

  // Positions rows in descriptor order. Rows that already had bounds slide
  // to their new place when `animate`.
  void LayoutRows(bool animate) {
    const int w = width();
    float y = 0;
    for (const auto& d : tree_->rows_) {
      auto it = tree_->row_views_.find(d.key);
      if (it == tree_->row_views_.end()) {
        continue;
      }
      RowView* row = it->second;
      const gfx::Rect target(0, static_cast<int>(std::lround(y)), w,
                             static_cast<int>(RowHeight(d.kind)));
      const bool had_bounds = !row->bounds().IsEmpty();
      if (animate && had_bounds && row->bounds() != target) {
        bounds_animator_.AnimateViewTo(row, target);
      } else if (!bounds_animator_.IsAnimating(row)) {
        row->SetBoundsRect(target);
      } else {
        bounds_animator_.SetTargetBounds(row, target);
      }
      y += RowHeight(d.kind);
    }
  }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override {
    return gfx::Size(0, static_cast<int>(std::ceil(TotalHeight())));
  }

  void Layout(PassKey) override { LayoutRows(/*animate=*/false); }

  // Rows first, then the drop indicator above them.
  void PaintChildren(const views::PaintInfo& info) override {
    views::View::PaintChildren(info);
    if (!drop_target_) {
      return;
    }
    ui::PaintRecorder recorder(info.context(), size());
    PaintDropIndicator(recorder.canvas());
  }

  void ForgetRow(RowView* row) { bounds_animator_.StopAnimatingView(row); }
  void NotifyPreferredSizeChanged() { PreferredSizeChanged(); }

 private:
  void PaintDropIndicator(gfx::Canvas* canvas) {
    if (!drop_target_) {
      return;
    }
    const auto& roles = tree_->theme_state().roles;
    const SkColor hint = theme::ToSkColor(
        roles.content == theme::ContentAppearance::kDark ? Rgba::White(0.50)
                                                         : Rgba::Black(0.50));
    if (drop_target_->into_folder) {
      if (RowView* row = tree_->FindRow(*drop_target_->into_folder)) {
        cc::PaintFlags flags;
        flags.setAntiAlias(true);
        flags.setStyle(cc::PaintFlags::kStroke_Style);
        flags.setStrokeWidth(2);
        flags.setColor(hint);
        gfx::RectF r(ToRectF(sl::RowFill(width())));
        r.Offset(0, row->y());
        r.Inset(1);
        canvas->DrawRoundRect(r, sl::kRowFillCornerRadius, flags);
      }
      return;
    }
    if (drop_target_->indicator_y >= 0) {
      cc::PaintFlags flags;
      flags.setAntiAlias(true);
      flags.setColor(hint);
      const float y = drop_target_->indicator_y;
      canvas->DrawRoundRect(
          gfx::RectF(sl::kRowFillInsetX + drop_indent_, y - 1,
                     width() - 2 * sl::kRowFillInsetX - drop_indent_, 2),
          1, flags);
    }
  }

 public:
  // Drop target.
  bool GetDropFormats(int* formats,
                      std::set<ui::ClipboardFormatType>* format_types) override {
    *formats = ui::OSExchangeData::URL;
    format_types->insert(sidebar_dnd::NodeFormat());
    return true;
  }

  bool CanDrop(const ui::OSExchangeData& data) override {
    return data.HasCustomFormat(sidebar_dnd::NodeFormat()) ||
           data.HasURL(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
  }

  void OnDragEntered(const ui::DropTargetEvent& event) override {}

  int OnDragUpdated(const ui::DropTargetEvent& event) override {
    dragged_ = sidebar_dnd::ReadNode(event.data());
    drop_target_ = tree_->ComputeDropTarget(event.location(), dragged_);
    drop_indent_ = 0;
    if (drop_target_ && drop_target_->parent.kind == NodeParentKind::kFolder) {
      for (const auto& row : tree_->rows_) {
        if (row.node_id == drop_target_->parent.owner_id) {
          drop_indent_ = (row.depth + 1) * sl::kIndentPerLevel;
          break;
        }
      }
    }
    SchedulePaint();
    if (!drop_target_) {
      return ui::DragDropTypes::DRAG_NONE;
    }
    return dragged_ ? ui::DragDropTypes::DRAG_MOVE
                    : ui::DragDropTypes::DRAG_COPY | ui::DragDropTypes::DRAG_LINK;
  }

  void OnDragExited() override {
    drop_target_.reset();
    dragged_.reset();
    SchedulePaint();
  }

  views::View::DropCallback GetDropCallback(
      const ui::DropTargetEvent& event) override {
    std::optional<DropTarget> target = drop_target_;
    std::optional<ItemID> dragged = dragged_;
    std::string url;
    if (!dragged) {
      const std::vector<ui::ClipboardUrlInfo> urls =
          event.data().GetURLs(ui::FilenameToURLPolicy::CONVERT_FILENAMES);
      if (!urls.empty()) {
        url = urls.front().url.spec();
      }
    }
    drop_target_.reset();
    dragged_.reset();
    SchedulePaint();
    if (!target) {
      return base::NullCallback();
    }
    return base::BindOnce(&ListView::PerformDrop, weak_factory_.GetWeakPtr(),
                          *target, dragged, url);
  }

  // views::ContextMenuController (empty list area -> Space menu).
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override {
    OpenMenuTarget target;
    target.kind = OpenMenuTarget::Kind::kSpace;
    target.space_id = tree_->space_id();
    tree_->context_->ShowSidebarMenu(target, this, point, source_type);
  }

 private:
  void PerformDrop(const DropTarget& target,
                   const std::optional<ItemID>& dragged,
                   const std::string& url,
                   const ui::DropTargetEvent& event,
                   ui::mojom::DragOperation& output_drag_op,
                   std::unique_ptr<ui::LayerTreeOwner> drag_image_layer_owner) {
    if (dragged) {
      tree_->context_->Send(OpenIntent::Move(*dragged, target.parent, target.index));
      output_drag_op = ui::mojom::DragOperation::kMove;
      return;
    }
    if (url.empty()) {
      output_drag_op = ui::mojom::DragOperation::kNone;
      return;
    }
    OpenIntent intent = OpenIntent::Of(OpenIntentKind::kOpenUrl);
    intent.text = url;
    intent.parent = target.parent;
    intent.index = target.index;
    intent.space_id = tree_->space_id();
    tree_->context_->Send(intent);
    output_drag_op = ui::mojom::DragOperation::kCopy;
  }

  raw_ptr<OpenTabTreeView> tree_;
  views::BoundsAnimator bounds_animator_;
  std::optional<DropTarget> drop_target_;
  std::optional<ItemID> dragged_;
  float drop_indent_ = 0;
  base::WeakPtrFactory<ListView> weak_factory_{this};
};

BEGIN_METADATA(OpenTabTreeView, ListView)
END_METADATA

// ---------------------------------------------------------------------------
// OpenTabTreeView

OpenTabTreeView::OpenTabTreeView(OpenSidebarContext* context,
                                 const SpaceID& space_id)
    : context_(context), space_id_(space_id) {
  header_ = AddChildView(std::make_unique<HeaderView>(this));
  auto scroll = std::make_unique<views::ScrollView>(
      views::ScrollView::ScrollWithLayers::kEnabled);
  scroll->SetBackgroundColor(std::nullopt);
  scroll->SetHorizontalScrollBarMode(
      views::ScrollView::ScrollBarMode::kDisabled);
  scroll->SetDrawOverflowIndicator(false);
  scroll->SetVerticalScrollBar(std::make_unique<views::OverlayScrollBar>(
      views::ScrollBar::Orientation::kVertical));
  scroll_view_ = AddChildView(std::move(scroll));
  list_ = scroll_view_->SetContents(std::make_unique<ListView>(this));
  Reload();
}

OpenTabTreeView::~OpenTabTreeView() = default;

const Space* OpenTabTreeView::space() const {
  return context_->controller()->GetSpace(space_id_);
}

const OpenSpaceThemeState& OpenTabTreeView::theme_state() const {
  return context_->ThemeStateFor(space_id_);
}

std::optional<ItemID> OpenTabTreeView::SelectedNodeId() const {
  const BrowserWindowState* state =
      context_->controller()->GetWindowState(context_->window_id());
  if (!state) {
    return std::nullopt;
  }
  auto it = state->selected_node_by_space.find(space_id_);
  if (it == state->selected_node_by_space.end()) {
    return std::nullopt;
  }
  return it->second;
}

std::vector<OpenTabTreeView::RowDescriptor> OpenTabTreeView::BuildDescriptors()
    const {
  std::vector<RowDescriptor> rows;
  const Space* s = space();
  if (!s) {
    return rows;
  }
  RowDescriptor spacer;
  spacer.kind = RowKind::kSpacer;
  spacer.key = kSpacerKey;
  rows.push_back(spacer);

  // Depth-first: folders list their children when expanded.
  auto add = [&](auto&& self, const SidebarNode& node, int depth,
                 const NodeParent& parent, size_t index, bool pinned) -> void {
    RowDescriptor d;
    d.kind = RowKind::kNode;
    d.key = node.id();
    d.node_id = node.id();
    d.node_kind = node.kind();
    d.depth = depth;
    d.parent = parent;
    d.index = index;
    d.in_pinned = pinned;
    rows.push_back(d);
    if (const Folder* f = node.as_folder(); f && f->is_expanded) {
      const NodeParent child_parent{NodeParentKind::kFolder, f->id};
      for (size_t i = 0; i < f->children.size(); ++i) {
        self(self, f->children[i], depth + 1, child_parent, i, pinned);
      }
    }
  };

  if (!s->is_pinned_collapsed) {
    const NodeParent pinned{NodeParentKind::kSpacePinned, s->id};
    for (size_t i = 0; i < s->pinned.size(); ++i) {
      add(add, s->pinned[i], 0, pinned, i, true);
    }
  }
  if (!s->today.empty()) {
    RowDescriptor divider;
    divider.kind = RowKind::kDivider;
    divider.key = kDividerKey;
    rows.push_back(divider);
  }
  RowDescriptor new_tab;
  new_tab.kind = RowKind::kNewTab;
  new_tab.key = kNewTabKey;
  rows.push_back(new_tab);
  const NodeParent today{NodeParentKind::kSpaceToday, s->id};
  for (size_t i = 0; i < s->today.size(); ++i) {
    add(add, s->today[i], 0, today, i, false);
  }
  return rows;
}

void OpenTabTreeView::Reconcile(bool animate) {
  std::vector<RowDescriptor> next = BuildDescriptors();
  std::map<std::string, raw_ptr<RowView>> next_views;
  // Reuse rows by key; create only new ones.
  for (const RowDescriptor& d : next) {
    auto it = row_views_.find(d.key);
    if (it != row_views_.end()) {
      it->second->SetDescriptor(d);
      next_views.emplace(d.key, it->second);
      row_views_.erase(it);
    } else {
      next_views.emplace(d.key, list_->AddChildView(std::make_unique<RowView>(this, d)));
    }
  }
  // Destroy rows that left the tree.
  for (auto& [key, view] : row_views_) {
    RowView* row = view;
    view = nullptr;
    list_->ForgetRow(row);
    list_->RemoveChildViewT(row);
  }
  rows_ = std::move(next);
  row_views_ = std::move(next_views);
  // Keep child order equal to row order (focus traversal, a11y).
  for (size_t i = 0; i < rows_.size(); ++i) {
    list_->ReorderChildView(row_views_[rows_[i].key], i);
  }
  OnSelectionChanged();
  list_->NotifyPreferredSizeChanged();
  list_->LayoutRows(animate && context_->AnimationsEnabled() &&
                    !motion::PrefersReducedMotion());
}

void OpenTabTreeView::Reload() {
  ++full_reload_count_;
  Reconcile(/*animate=*/false);
  header_->Refresh();
}

void OpenTabTreeView::ApplyTreeChange(const TreeChange& change) {
  switch (change.kind) {
    case TreeChange::Kind::kUpdate: {
      // A folder update may toggle its expansion: reconcile (cheap, keyed).
      const SidebarNode* node = context_->controller()->FindNode(change.node_id);
      if (node && node->as_folder()) {
        Reconcile(/*animate=*/true);
      } else if (RowView* row = FindRow(change.node_id)) {
        row->Refresh();
      }
      return;
    }
    case TreeChange::Kind::kInsert:
    case TreeChange::Kind::kRemove:
    case TreeChange::Kind::kMove:
      Reconcile(/*animate=*/true);
      return;
    case TreeChange::Kind::kReload:
      Reload();
      return;
    case TreeChange::Kind::kSpaceProfileChanged:
      header_->Refresh();
      return;
  }
}

void OpenTabTreeView::OnSpaceChanged() {
  header_->Refresh();
  // Pinned collapse changes the row set.
  Reconcile(/*animate=*/true);
}

void OpenTabTreeView::OnSpaceThemeChanged() {
  header_->SchedulePaint();
  for (auto& [key, row] : row_views_) {
    row->SchedulePaint();
  }
}

void OpenTabTreeView::OnSelectionChanged() {
  const std::optional<ItemID> selected =
      new_tab_command_bar_open_ ? std::nullopt : SelectedNodeId();
  // A selected pane selects its split row.
  std::optional<ItemID> row_id = selected;
  if (selected && !FindRow(*selected)) {
    for (const auto& d : rows_) {
      if (d.node_kind != SidebarNode::Kind::kSplit) {
        continue;
      }
      if (const SidebarNode* n = context_->controller()->FindNode(d.node_id)) {
        if (const Split* s = n->as_split()) {
          for (const Tab& pane : s->panes) {
            if (pane.id == *selected) {
              row_id = d.node_id;
            }
          }
        }
      }
    }
  }
  const bool animate = context_->AnimationsEnabled() && last_selected_.has_value();
  for (auto& [key, row] : row_views_) {
    row->SetSelected(row_id && row->descriptor().node_id == *row_id, animate);
  }
  last_selected_ = row_id;
}

void OpenTabTreeView::OnTabLiveStateChanged(const ItemID& tab_id) {
  if (RowView* row = FindRow(tab_id)) {
    row->SchedulePaint();
    return;
  }
  // Split panes repaint their split row.
  for (const auto& d : rows_) {
    if (d.node_kind != SidebarNode::Kind::kSplit) {
      continue;
    }
    if (const SidebarNode* n = context_->controller()->FindNode(d.node_id)) {
      if (const Split* s = n->as_split()) {
        for (const Tab& pane : s->panes) {
          if (pane.id == tab_id) {
            if (RowView* row = FindRow(d.node_id)) {
              row->SchedulePaint();
            }
            return;
          }
        }
      }
    }
  }
}

void OpenTabTreeView::OnWindowActivationChanged() {
  SchedulePaint();
}

void OpenTabTreeView::SetPeekSourceNode(std::optional<ItemID> node_id) {
  if (peek_source_ == node_id) {
    return;
  }
  std::optional<ItemID> old = peek_source_;
  peek_source_ = std::move(node_id);
  for (const auto& id : {old, peek_source_}) {
    if (id) {
      if (RowView* row = FindRow(*id)) {
        row->SchedulePaint();
      }
    }
  }
}

void OpenTabTreeView::SetNewTabCommandBarOpen(bool open) {
  if (open == new_tab_command_bar_open_) {
    return;
  }
  new_tab_command_bar_open_ = open;
  auto it = row_views_.find(kNewTabKey);
  if (it != row_views_.end()) {
    it->second->SchedulePaint();
  }
  // The selected tab loses its fill while the New Tab command bar shows.
  OnSelectionChanged();
}

void OpenTabTreeView::BeginRename(const ItemID& node_id) {
  ScrollToNode(node_id);
  if (RowView* row = FindRow(node_id)) {
    row->BeginRename();
  }
}

void OpenTabTreeView::ScrollToNode(const ItemID& node_id) {
  if (RowView* row = FindRow(node_id)) {
    row->ScrollViewToVisible();
  }
}

std::optional<gfx::Rect> OpenTabTreeView::GetRowBoundsInScreen(
    const ItemID& node_id) const {
  RowView* row = FindRow(node_id);
  if (!row) {
    return std::nullopt;
  }
  return row->GetBoundsInScreen();
}

OpenTabTreeView::RowView* OpenTabTreeView::FindRow(const ItemID& node_id) const {
  auto it = row_views_.find(node_id);
  return it == row_views_.end() ? nullptr : it->second.get();
}

void OpenTabTreeView::Layout(PassKey) {
  const int header_h = static_cast<int>(sl::kHeaderHeight);
  header_->SetBounds(0, 0, width(), header_h);
  scroll_view_->SetBounds(0, header_h, width(),
                          std::max(0, height() - header_h));
  scroll_view_->ClipHeightTo(0, std::max(0, height() - header_h));
}

void OpenTabTreeView::OnThemeChanged() {
  views::View::OnThemeChanged();
  OnSpaceThemeChanged();
}

std::optional<OpenTabTreeView::DropTarget> OpenTabTreeView::ComputeDropTarget(
    const gfx::Point& p,
    const std::optional<ItemID>& dragged) const {
  const Space* s = space();
  if (!s) {
    return std::nullopt;
  }
  const NodeParent pinned{NodeParentKind::kSpacePinned, s->id};
  const NodeParent today{NodeParentKind::kSpaceToday, s->id};

  // Is `folder_id` the dragged node or inside it?
  auto inside_dragged = [&](const ItemID& folder_id) {
    if (!dragged) {
      return false;
    }
    if (folder_id == *dragged) {
      return true;
    }
    // Walk descriptors: a row is inside the dragged node when it follows it
    // at a greater depth.
    bool in = false;
    int depth = 0;
    for (const auto& d : rows_) {
      if (d.node_id == *dragged) {
        in = true;
        depth = d.depth;
        continue;
      }
      if (in) {
        if (d.kind != RowKind::kNode || d.depth <= depth) {
          in = false;
        } else if (d.node_id == folder_id) {
          return true;
        }
      }
    }
    return false;
  };

  DropTarget target;
  float y = 0;
  const RowDescriptor* hit = nullptr;
  float hit_top = 0;
  for (const auto& d : rows_) {
    const float h = RowHeight(d.kind);
    if (p.y() >= y && p.y() < y + h) {
      hit = &d;
      hit_top = y;
      break;
    }
    y += h;
  }
  if (!hit) {
    target.parent = today;
    target.index = s->today.size();
    target.indicator_y = static_cast<int>(y);
  } else {
    switch (hit->kind) {
      case RowKind::kSpacer:
        target.parent = pinned;
        target.index = 0;
        target.indicator_y = static_cast<int>(hit_top + sl::kSpacerRowHeight);
        break;
      case RowKind::kDivider:
      case RowKind::kNewTab:
        // Between the divider and the first Today row.
        if (hit->kind == RowKind::kDivider && p.y() < hit_top + sl::kDividerRowHeight / 2) {
          target.parent = pinned;
          target.index = s->pinned.size();
          target.indicator_y = static_cast<int>(hit_top);
        } else {
          target.parent = today;
          target.index = 0;
          target.indicator_y = static_cast<int>(
              hit->kind == RowKind::kNewTab ? hit_top + sl::kRowHeight : hit_top + sl::kDividerRowHeight);
        }
        break;
      case RowKind::kNode: {
        const float local = p.y() - hit_top;
        const SidebarNode* node = context_->controller()->FindNode(hit->node_id);
        const Folder* folder = node ? node->as_folder() : nullptr;
        if (folder && local > sl::kRowHeight * 0.3f &&
            local < sl::kRowHeight * 0.7f && !inside_dragged(folder->id)) {
          // Onto a folder: append inside it.
          target.parent = {NodeParentKind::kFolder, folder->id};
          target.index = std::nullopt;
          target.into_folder = folder->id;
          target.indicator_y = -1;
        } else if (local < sl::kRowHeight / 2) {
          target.parent = hit->parent;
          target.index = hit->index;
          target.indicator_y = static_cast<int>(hit_top);
        } else if (folder && folder->is_expanded && !inside_dragged(folder->id)) {
          target.parent = {NodeParentKind::kFolder, folder->id};
          target.index = 0;
          target.indicator_y = static_cast<int>(hit_top + sl::kRowHeight);
        } else {
          target.parent = hit->parent;
          target.index = hit->index + 1;
          target.indicator_y = static_cast<int>(hit_top + sl::kRowHeight);
        }
        if (target.parent.kind == NodeParentKind::kFolder &&
            inside_dragged(target.parent.owner_id)) {
          return std::nullopt;
        }
        break;
      }
    }
  }
  // Same-parent downward move: the model counts after removal.
  if (dragged && target.index) {
    for (const auto& d : rows_) {
      if (d.node_id == *dragged) {
        if (d.parent == target.parent && d.index < *target.index) {
          target.index = *target.index - 1;
        }
        break;
      }
    }
  }
  return target;
}

BEGIN_METADATA(OpenTabTreeView)
END_METADATA

}  // namespace open_unified
