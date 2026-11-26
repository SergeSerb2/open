// Copyright 2026 The Open Authors. All rights reserved.
// Open Account & Sync v1 Engine implementation.

#include "open_unified/core/sync/sync_engine.h"

#include <algorithm>
#include <cmath>
#include <tuple>
#include <utility>

#include "base/base64.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr char kSecretServiceName[] = "com.open.browser.sync";
constexpr char kSecretAccountPrefix[] = "sync-credentials-v1:";
constexpr int kMaxBackups = 3;
constexpr size_t kSyncMaxBlobsPerPass = 256;
constexpr size_t kSyncMaxTotalBlobBytesPerPass = 64 * 1024 * 1024;
constexpr double kPushDebounceSec = 2.0;
constexpr double kPushMaxCoalesceSec = 10.0;
constexpr double kWsMinBackoffSec = 1.0;
constexpr double kWsMaxBackoffSec = 60.0;
constexpr int kWsPingIntervalSec = 25;

void WipeDictString(base::DictValue& dict, std::string_view key) {
  if (base::Value* v = dict.Find(key); v && v->is_string()) {
    SyncCrypto::SecureZero(v->GetString());
  }
}

std::string TruncateUtf8Bytes(std::string_view input, size_t max_bytes) {
  return std::string(base::TruncateUTF8ToByteSize(input, max_bytes));
}

void WriteStateAtomicOnIo(base::FilePath path, std::string json) {
  if (!base::CreateDirectory(path.DirName())) {
    return;
  }
  base::ImportantFileWriter::WriteFileAtomically(path, json);
}

void DeleteStateOnIo(base::FilePath path) {
  base::DeleteFile(path);
}

std::set<std::string> ComputeDirtyKeys(
    const SyncLocalBundle& local,
    const std::map<std::string, SyncRecordMirror>& mirror,
    const std::set<SyncCollection>& enabled,
    const SyncVaultKeys& vault_keys) {
  std::set<std::string> dirty;
  std::set<std::string> local_keys;
  for (const auto& rec : local.records) {
    if (!enabled.contains(rec.collection) ||
        !IsValidSyncRecordId(rec.record_id)) {
      continue;
    }
    std::string key =
        SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
    local_keys.insert(key);
    std::string hash =
        SyncCrypto::ComputePayloadHash(rec.payload_json, vault_keys);
    auto it = mirror.find(key);
    if (it != mirror.end() && !it->second.deleted &&
        it->second.payload_hash == hash) {
      continue;
    }
    dirty.insert(std::move(key));
  }
  for (const auto& [key, known] : mirror) {
    if (known.deleted || local_keys.contains(key)) {
      continue;
    }
    auto parsed = SyncPersistedState::ParseMirrorKey(key);
    if (parsed && enabled.contains(parsed->first) &&
        local.complete_collections.contains(parsed->first)) {
      dirty.insert(key);
    }
  }
  return dirty;
}

SyncLocalBundle FilterLocalBundleExcluding(
    const SyncLocalBundle& local,
    const std::set<SyncCollection>& excluded) {
  if (excluded.empty()) {
    return local;
  }
  SyncLocalBundle out;
  out.blobs = local.blobs;
  out.warnings = local.warnings;
  for (const auto& rec : local.records) {
    if (!excluded.contains(rec.collection)) {
      out.records.push_back(rec);
    }
  }
  for (SyncCollection col : local.complete_collections) {
    if (!excluded.contains(col)) {
      out.complete_collections.insert(col);
    }
  }
  return out;
}

struct ChangePasswordDerivedKeys {
  std::optional<SyncDerivedPasswordKeys> current_keys;
  std::optional<SyncDerivedPasswordKeys> new_keys;
};

struct SignUpDerivedMaterial {
  std::optional<SyncKdfParams> kdf;
  std::optional<std::vector<uint8_t>> vault_key;
  std::optional<SyncGeneratedRecoveryKey> recovery;
  std::optional<SyncDerivedPasswordKeys> pw_keys;
  std::optional<SyncDerivedRecoveryKeys> rec_keys;

  ~SignUpDerivedMaterial() {
    if (vault_key) {
      SyncCrypto::SecureZero(*vault_key);
    }
  }
  SignUpDerivedMaterial() = default;
  SignUpDerivedMaterial(SignUpDerivedMaterial&&) noexcept = default;
  SignUpDerivedMaterial& operator=(SignUpDerivedMaterial&&) noexcept = default;
  SignUpDerivedMaterial(const SignUpDerivedMaterial&) = delete;
  SignUpDerivedMaterial& operator=(const SignUpDerivedMaterial&) = delete;
};

struct RecoverDerivedMaterial {
  std::optional<SyncKdfParams> new_kdf;
  std::optional<SyncGeneratedRecoveryKey> new_rec;
  std::optional<SyncDerivedPasswordKeys> new_pw_keys;
  std::optional<SyncDerivedRecoveryKeys> new_rec_keys;

  RecoverDerivedMaterial() = default;
  RecoverDerivedMaterial(RecoverDerivedMaterial&&) noexcept = default;
  RecoverDerivedMaterial& operator=(RecoverDerivedMaterial&&) noexcept = default;
  RecoverDerivedMaterial(const RecoverDerivedMaterial&) = delete;
  RecoverDerivedMaterial& operator=(const RecoverDerivedMaterial&) = delete;
};

// --- JSON helpers for open_types.h ---

base::DictValue EncodeRgba(const RGBAColor& c) {
  base::DictValue d;
  d.Set("r", c.r);
  d.Set("g", c.g);
  d.Set("b", c.b);
  d.Set("a", c.a);
  return d;
}

std::optional<RGBAColor> DecodeRgba(const base::DictValue* d) {
  if (!d) return std::nullopt;
  RGBAColor c;
  c.r = d->FindDouble("r").value_or(d->FindDouble("red").value_or(0.0));
  c.g = d->FindDouble("g").value_or(d->FindDouble("green").value_or(0.0));
  c.b = d->FindDouble("b").value_or(d->FindDouble("blue").value_or(0.0));
  c.a = d->FindDouble("a").value_or(d->FindDouble("alpha").value_or(1.0));
  return c;
}

base::DictValue EncodeSpaceIcon(const SpaceIcon& icon) {
  base::DictValue d;
  switch (icon.kind) {
    case SpaceIconKind::kEmoji:
      d.Set("kind", "emoji");
      break;
    case SpaceIconKind::kSymbol:
      d.Set("kind", "symbol");
      break;
    case SpaceIconKind::kNamed:
      d.Set("kind", "named");
      break;
  }
  d.Set("value", icon.value);
  return d;
}

std::optional<SpaceIcon> DecodeSpaceIcon(const base::DictValue* d) {
  if (!d) return std::nullopt;
  const std::string* kind = d->FindString("kind");
  const std::string* val = d->FindString("value");
  if (!kind || !val) return std::nullopt;
  SpaceIcon icon;
  if (*kind == "symbol") {
    icon.kind = SpaceIconKind::kSymbol;
  } else if (*kind == "named") {
    icon.kind = SpaceIconKind::kNamed;
  } else {
    icon.kind = SpaceIconKind::kEmoji;
  }
  icon.value = *val;
  return icon;
}

base::DictValue EncodeSpaceTheme(const SpaceTheme& theme) {
  base::DictValue d;
  if (theme.light_background) d.Set("lightBackground", EncodeRgba(*theme.light_background));
  if (theme.dark_background) d.Set("darkBackground", EncodeRgba(*theme.dark_background));
  if (theme.light_foreground) d.Set("lightForeground", EncodeRgba(*theme.light_foreground));
  if (theme.dark_foreground) d.Set("darkForeground", EncodeRgba(*theme.dark_foreground));
  if (theme.accent) d.Set("accent", EncodeRgba(*theme.accent));
  auto encode_stops = [](const std::vector<GradientStop>& stops) {
    base::ListValue list;
    for (const auto& s : stops) {
      base::DictValue sd;
      sd.Set("location", s.location);
      sd.Set("color", EncodeRgba(s.color));
      list.Append(std::move(sd));
    }
    return list;
  };
  if (!theme.gradient_stops_light.empty()) {
    d.Set("gradientStopsLight", encode_stops(theme.gradient_stops_light));
  }
  if (!theme.gradient_stops_dark.empty()) {
    d.Set("gradientStopsDark", encode_stops(theme.gradient_stops_dark));
  }
  if (theme.imported_arc_theme_json) {
    d.Set("importedArcThemeJSON", *theme.imported_arc_theme_json);
  }
  if (theme.style) {
    base::DictValue st;
    st.Set("mathVersion", theme.style->math_version);
    st.Set("keyColor", EncodeRgba(theme.style->key_color));
    st.Set("colorCount", theme.style->color_count);
    st.Set("wheel", theme.style->wheel == ThemeWheel::kComplementary
                        ? "complementary"
                        : "analogous");
    st.Set("appearance",
           theme.style->appearance == ThemeAppearance::kLight
               ? "light"
               : (theme.style->appearance == ThemeAppearance::kDark
                      ? "dark"
                      : "automatic"));
    st.Set("noiseFactor", theme.style->noise_factor);
    const char* tex = "grain";
    switch (theme.style->texture) {
      case ThemeTexture::kGrain: tex = "grain"; break;
      case ThemeTexture::kSand: tex = "sand"; break;
      case ThemeTexture::kDenim: tex = "denim"; break;
      case ThemeTexture::kTweed: tex = "tweed"; break;
    }
    st.Set("texture", tex);
    st.Set("intensityFactor", theme.style->intensity_factor);
    d.Set("style", std::move(st));
  }
  return d;
}

SpaceTheme DecodeSpaceTheme(const base::DictValue* d) {
  SpaceTheme theme;
  if (!d) return theme;
  theme.light_background = DecodeRgba(d->FindDict("lightBackground"));
  theme.dark_background = DecodeRgba(d->FindDict("darkBackground"));
  theme.light_foreground = DecodeRgba(d->FindDict("lightForeground"));
  theme.dark_foreground = DecodeRgba(d->FindDict("darkForeground"));
  theme.accent = DecodeRgba(d->FindDict("accent"));
  auto decode_stops = [](const base::ListValue* list) {
    std::vector<GradientStop> out;
    if (!list) return out;
    for (const auto& v : *list) {
      const auto* sd = v.GetIfDict();
      if (!sd) continue;
      GradientStop s;
      s.location = sd->FindDouble("location").value_or(0.0);
      if (auto col = DecodeRgba(sd->FindDict("color"))) s.color = *col;
      out.push_back(s);
    }
    return out;
  };
  theme.gradient_stops_light = decode_stops(d->FindList("gradientStopsLight"));
  theme.gradient_stops_dark = decode_stops(d->FindList("gradientStopsDark"));
  if (const auto* arc = d->FindString("importedArcThemeJSON")) {
    theme.imported_arc_theme_json = *arc;
  }
  if (const auto* st = d->FindDict("style")) {
    SpaceStyle style;
    style.math_version = st->FindInt("mathVersion").value_or(1);
    if (auto kc = DecodeRgba(st->FindDict("keyColor"))) style.key_color = *kc;
    style.color_count = st->FindInt("colorCount").value_or(2);
    if (const auto* w = st->FindString("wheel"); w && *w == "complementary") {
      style.wheel = ThemeWheel::kComplementary;
    }
    if (const auto* ap = st->FindString("appearance")) {
      if (*ap == "light") style.appearance = ThemeAppearance::kLight;
      else if (*ap == "dark") style.appearance = ThemeAppearance::kDark;
    }
    style.noise_factor = st->FindDouble("noiseFactor").value_or(0.0);
    if (const auto* tex = st->FindString("texture")) {
      if (*tex == "sand") style.texture = ThemeTexture::kSand;
      else if (*tex == "denim") style.texture = ThemeTexture::kDenim;
      else if (*tex == "tweed") style.texture = ThemeTexture::kTweed;
    }
    style.intensity_factor = st->FindDouble("intensityFactor").value_or(0.6);
    theme.style = style;
  }
  return theme;
}

base::DictValue EncodeTab(const Tab& tab) {
  base::DictValue d;
  d.Set("type", "tab");
  d.Set("id", tab.id);
  d.Set("url", tab.url);
  d.Set("title", tab.title);
  if (tab.custom_title) d.Set("customTitle", *tab.custom_title);
  if (tab.pinned_url) d.Set("pinnedURL", *tab.pinned_url);
  if (tab.custom_icon) d.Set("customIcon", *tab.custom_icon);
  if (tab.icon_override) d.Set("iconOverride", EncodeSpaceIcon(*tab.icon_override));
  d.Set("createdAt", tab.created_at);
  d.Set("lastActiveAt", tab.last_active_at);
  d.Set("isMuted", tab.is_muted);
  if (tab.opener_id) d.Set("openerID", *tab.opener_id);
  d.Set("isUnread", tab.is_unread);
  if (tab.live_item_url) d.Set("liveItemURL", *tab.live_item_url);
  if (tab.live_item) {
    base::DictValue li;
    li.Set("sourceKind", tab.live_item->source_kind);
    li.Set("subtitle", tab.live_item->subtitle);
    li.Set("statusBadge", tab.live_item->status_badge);
    li.Set("updatedAt", tab.live_item->updated_at);
    d.Set("liveItem", std::move(li));
  }
  return d;
}

std::optional<Tab> DecodeTab(const base::DictValue* d) {
  if (!d) return std::nullopt;
  const std::string* id = d->FindString("id");
  const std::string* url = d->FindString("url");
  if (!id || id->empty() || !url) return std::nullopt;
  Tab t;
  t.id = *id;
  t.url = *url;
  t.title = d->FindString("title") ? *d->FindString("title") : "";
  if (const auto* s = d->FindString("customTitle")) t.custom_title = *s;
  if (const auto* s = d->FindString("pinnedURL")) t.pinned_url = *s;
  if (const auto* s = d->FindString("customIcon")) t.custom_icon = *s;
  t.icon_override = DecodeSpaceIcon(d->FindDict("iconOverride"));
  t.created_at = d->FindDouble("createdAt").value_or(0.0);
  t.last_active_at = d->FindDouble("lastActiveAt").value_or(0.0);
  t.is_muted = d->FindBool("isMuted").value_or(false);
  if (const auto* s = d->FindString("openerID")) t.opener_id = *s;
  t.is_unread = d->FindBool("isUnread").value_or(false);
  if (const auto* s = d->FindString("liveItemURL")) t.live_item_url = *s;
  if (const auto* li = d->FindDict("liveItem")) {
    LiveItemInfo info;
    if (const auto* s = li->FindString("sourceKind")) info.source_kind = *s;
    if (const auto* s = li->FindString("subtitle")) info.subtitle = *s;
    if (const auto* s = li->FindString("statusBadge")) info.status_badge = *s;
    info.updated_at = li->FindDouble("updatedAt").value_or(0.0);
    t.live_item = std::move(info);
  }
  return t;
}

base::DictValue EncodeNode(const SidebarNode& node, int depth = 0) {
  if (const Tab* t = node.as_tab()) {
    return EncodeTab(*t);
  }
  if (const Folder* f = node.as_folder()) {
    base::DictValue d;
    d.Set("type", "folder");
    d.Set("id", f->id);
    d.Set("title", f->title);
    d.Set("isExpanded", f->is_expanded);
    if (f->peeked_child_id) d.Set("peekedChildID", *f->peeked_child_id);
    if (f->custom_icon) d.Set("customIcon", *f->custom_icon);
    if (f->icon_override) d.Set("iconOverride", EncodeSpaceIcon(*f->icon_override));
    base::ListValue children;
    if (depth < 32) {
      for (const auto& c : f->children) {
        children.Append(EncodeNode(c, depth + 1));
      }
    }
    d.Set("children", std::move(children));
    if (f->live) {
      base::DictValue lv;
      lv.Set("provider", f->live->provider);
      lv.Set("query", f->live->query);
      lv.Set("refreshIntervalSec", f->live->refresh_interval_sec);
      lv.Set("enabled", f->live->enabled);
      d.Set("live", std::move(lv));
    }
    return d;
  }
  const Split& s = *node.as_split();
  base::DictValue d;
  d.Set("type", "split");
  d.Set("id", s.id);
  d.Set("orientation", s.orientation == SplitOrientation::kVertical
                           ? "vertical"
                           : "horizontal");
  base::ListValue fracs;
  for (double f : s.fractions) fracs.Append(f);
  d.Set("fractions", std::move(fracs));
  base::ListValue panes;
  for (const auto& p : s.panes) panes.Append(EncodeTab(p));
  d.Set("panes", std::move(panes));
  if (s.focused_pane_id) d.Set("focusedPaneID", *s.focused_pane_id);
  if (s.custom_title) d.Set("customTitle", *s.custom_title);
  if (s.icon_override) d.Set("iconOverride", EncodeSpaceIcon(*s.icon_override));
  return d;
}

std::optional<SidebarNode> DecodeNode(const base::DictValue* d, int depth = 0) {
  if (!d || depth > 32) return std::nullopt;
  const std::string* type = d->FindString("type");
  if (!type) return std::nullopt;
  if (*type == "tab") {
    auto t = DecodeTab(d);
    if (!t) return std::nullopt;
    return SidebarNode(std::move(*t));
  }
  if (*type == "folder") {
    const std::string* id = d->FindString("id");
    if (!id || id->empty()) return std::nullopt;
    Folder f;
    f.id = *id;
    f.title = d->FindString("title") ? *d->FindString("title") : "";
    f.is_expanded = d->FindBool("isExpanded").value_or(false);
    if (const auto* p = d->FindString("peekedChildID")) f.peeked_child_id = *p;
    if (const auto* ci = d->FindString("customIcon")) f.custom_icon = *ci;
    f.icon_override = DecodeSpaceIcon(d->FindDict("iconOverride"));
    if (const auto* kids = d->FindList("children")) {
      for (const auto& k : *kids) {
        if (auto n = DecodeNode(k.GetIfDict(), depth + 1)) {
          f.children.push_back(std::move(*n));
        }
      }
    }
    if (const auto* lv = d->FindDict("live")) {
      LiveFolderConfig cfg;
      if (const auto* s = lv->FindString("provider")) cfg.provider = *s;
      if (const auto* s = lv->FindString("query")) cfg.query = *s;
      cfg.refresh_interval_sec = lv->FindInt("refreshIntervalSec").value_or(300);
      cfg.enabled = lv->FindBool("enabled").value_or(true);
      f.live = std::move(cfg);
    }
    return SidebarNode(std::move(f));
  }
  if (*type == "split") {
    const std::string* id = d->FindString("id");
    if (!id || id->empty()) return std::nullopt;
    Split s;
    s.id = *id;
    if (const auto* o = d->FindString("orientation"); o && *o == "vertical") {
      s.orientation = SplitOrientation::kVertical;
    }
    if (const auto* fracs = d->FindList("fractions")) {
      for (const auto& v : *fracs) {
        if (auto num = v.GetIfDouble(); num && std::isfinite(*num) && *num > 0) {
          s.fractions.push_back(*num);
        }
      }
    }
    if (const auto* panes = d->FindList("panes")) {
      for (const auto& p : *panes) {
        if (auto t = DecodeTab(p.GetIfDict())) {
          s.panes.push_back(std::move(*t));
        }
      }
    }
    if (s.panes.empty()) return std::nullopt;
    if (const auto* fp = d->FindString("focusedPaneID")) s.focused_pane_id = *fp;
    if (const auto* ct = d->FindString("customTitle")) s.custom_title = *ct;
    s.icon_override = DecodeSpaceIcon(d->FindDict("iconOverride"));
    return SidebarNode(std::move(s));
  }
  return std::nullopt;
}

const char* AutoArchiveToString(AutoArchiveInterval v) {
  switch (v) {
    case AutoArchiveInterval::kNever: return "never";
    case AutoArchiveInterval::kOneHour: return "1h";
    case AutoArchiveInterval::kSixHours: return "6h";
    case AutoArchiveInterval::kTwelveHours: return "12h";
    case AutoArchiveInterval::kTwentyFourHours: return "24h";
    case AutoArchiveInterval::kSevenDays: return "7d";
    case AutoArchiveInterval::kThirtyDays: return "30d";
  }
  return "12h";
}

AutoArchiveInterval AutoArchiveFromString(std::string_view s) {
  if (s == "never") return AutoArchiveInterval::kNever;
  if (s == "1h") return AutoArchiveInterval::kOneHour;
  if (s == "6h") return AutoArchiveInterval::kSixHours;
  if (s == "24h") return AutoArchiveInterval::kTwentyFourHours;
  if (s == "7d") return AutoArchiveInterval::kSevenDays;
  if (s == "30d") return AutoArchiveInterval::kThirtyDays;
  return AutoArchiveInterval::kTwelveHours;
}

const char* SleepModeToString(SleepMode m) {
  switch (m) {
    case SleepMode::kOff: return "off";
    case SleepMode::kConservative: return "conservative";
    case SleepMode::kBalanced: return "balanced";
    case SleepMode::kAggressive: return "aggressive";
  }
  return "balanced";
}

SleepMode SleepModeFromString(std::string_view s) {
  if (s == "off") return SleepMode::kOff;
  if (s == "conservative") return SleepMode::kConservative;
  if (s == "aggressive") return SleepMode::kAggressive;
  return SleepMode::kBalanced;
}

base::DictValue EncodeRoutingDestination(const RoutingDestination& dest) {
  base::DictValue d;
  switch (dest.kind) {
    case RoutingDestinationKind::kSpace:
      d.Set("kind", "space");
      break;
    case RoutingDestinationKind::kLittleOpen:
      d.Set("kind", "littleOpen");
      break;
    case RoutingDestinationKind::kMostRecentSpace:
      d.Set("kind", "mostRecentSpace");
      break;
  }
  if (dest.space_id) d.Set("spaceID", *dest.space_id);
  if (dest.profile_id) d.Set("profileID", *dest.profile_id);
  return d;
}

RoutingDestination DecodeRoutingDestination(const base::DictValue* d) {
  RoutingDestination dest;
  if (!d) return dest;
  if (const auto* k = d->FindString("kind")) {
    if (*k == "space") dest.kind = RoutingDestinationKind::kSpace;
    else if (*k == "littleOpen") dest.kind = RoutingDestinationKind::kLittleOpen;
    else dest.kind = RoutingDestinationKind::kMostRecentSpace;
  }
  if (const auto* s = d->FindString("spaceID")) dest.space_id = *s;
  if (const auto* p = d->FindString("profileID")) dest.profile_id = *p;
  return dest;
}

base::DictValue EncodeAssetRef(const SyncedAssetRef& a) {
  base::DictValue d;
  d.Set("filename", a.filename);
  d.Set("blobId", a.blob_id);
  d.Set("sha256", a.sha256);
  d.Set("byteLength", static_cast<int>(a.byte_length));
  return d;
}

std::optional<SyncedAssetRef> DecodeAssetRef(const base::DictValue* d) {
  if (!d) return std::nullopt;
  const auto* fn = d->FindString("filename");
  const auto* bid = d->FindString("blobId");
  const auto* sha = d->FindString("sha256");
  if (!fn || !bid || !sha) return std::nullopt;
  SyncedAssetRef ref;
  ref.filename = *fn;
  ref.blob_id = *bid;
  ref.sha256 = *sha;
  ref.byte_length = d->FindInt("byteLength").value_or(0);
  return ref;
}

std::string MakeWsUrlFromHttp(const std::string& base_url) {
  std::string ws = base_url;
  if (base::StartsWith(ws, "https://", base::CompareCase::INSENSITIVE_ASCII)) {
    ws.replace(0, 8, "wss://");
  } else if (base::StartsWith(ws, "http://",
                              base::CompareCase::INSENSITIVE_ASCII)) {
    ws.replace(0, 7, "ws://");
  }
  return ws + "/v1/sync/ws";
}

// --- Default SimpleURLLoader transport ---

constexpr net::NetworkTrafficAnnotationTag kOpenSyncTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_sync_v1_client", R"(
        semantics {
          sender: "Open Sync v1 Client"
          description:
            "Communicates with the user-configured self-hosted Open Sync "
            "Server using zero-knowledge end-to-end encrypted payloads."
          trigger:
            "User explicitly signs in to Open Sync or modifies synced browser "
            "data."
          data:
            "Opaque AES-256-GCM ciphertexts, device metadata, and auth tokens."
          destination: OTHER
          destination_other: "User-configured Open Sync Server"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Optional feature; disabled unless the user configures Open Sync "
            "in open://settings."
          policy_exception_justification: "User-configured opt-in sync."
        })");

class SimpleURLLoaderSyncTransport final : public SyncHttpTransport {
 public:
  explicit SimpleURLLoaderSyncTransport(
      scoped_refptr<network::SharedURLLoaderFactory> factory)
      : url_loader_factory_(std::move(factory)) {}

  ~SimpleURLLoaderSyncTransport() override = default;

  void Send(SyncHttpRequest request, Callback callback) override {
    if (!url_loader_factory_) {
      SyncHttpResponse resp;
      resp.error_message = "No URLLoaderFactory available.";
      std::move(callback).Run(std::move(resp));
      return;
    }

    auto resource_request = std::make_unique<network::ResourceRequest>();
    resource_request->url = GURL(request.url);
    resource_request->method = request.method;
    resource_request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    for (const auto& [k, v] : request.headers) {
      resource_request->headers.SetHeader(k, v);
    }

    auto loader = network::SimpleURLLoader::Create(
        std::move(resource_request), kOpenSyncTrafficAnnotation);
    loader->SetAllowHttpErrorResults(true);
    loader->SetTimeoutDuration(base::Seconds(30));
    if (!request.body.empty()) {
      std::string body_str(reinterpret_cast<const char*>(request.body.data()),
                           request.body.size());
      loader->AttachStringForUpload(
          body_str, request.content_type.empty() ? "application/json"
                                                 : request.content_type);
    }

    network::SimpleURLLoader* raw_loader = loader.get();
    uint64_t id = next_id_++;
    active_loaders_[id] = std::move(loader);

    raw_loader->DownloadToString(
        url_loader_factory_.get(),
        base::BindOnce(&SimpleURLLoaderSyncTransport::OnComplete,
                       weak_factory_.GetWeakPtr(), id, std::move(callback)),
        request.max_response_bytes);
  }

 private:
  void OnComplete(uint64_t id,
                  Callback callback,
                  std::optional<std::string> body) {
    auto it = active_loaders_.find(id);
    if (it == active_loaders_.end()) {
      return;
    }
    auto loader = std::move(it->second);
    active_loaders_.erase(it);

    SyncHttpResponse resp;
    resp.net_error = loader->NetError();
    if (loader->ResponseInfo() && loader->ResponseInfo()->headers) {
      resp.status_code = loader->ResponseInfo()->headers->response_code();
    }
    if (body) {
      resp.body.assign(body->begin(), body->end());
    } else if (resp.status_code == 0) {
      resp.error_message =
          "Network error " + base::NumberToString(resp.net_error);
    }
    std::move(callback).Run(std::move(resp));
  }

  scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory_;
  uint64_t next_id_ = 1;
  std::map<uint64_t, std::unique_ptr<network::SimpleURLLoader>> active_loaders_;
  base::WeakPtrFactory<SimpleURLLoaderSyncTransport> weak_factory_{this};
};

}  // namespace

std::unique_ptr<SyncHttpTransport> CreateSimpleURLLoaderSyncTransport(
    scoped_refptr<network::SharedURLLoaderFactory> url_loader_factory) {
  return std::make_unique<SimpleURLLoaderSyncTransport>(
      std::move(url_loader_factory));
}

// --- Collections & Categories ---

std::string_view SyncCollectionToString(SyncCollection collection) {
  switch (collection) {
    case SyncCollection::kWorkspaceMeta: return "workspace.meta";
    case SyncCollection::kWorkspaceProfile: return "workspace.profile";
    case SyncCollection::kWorkspaceSpace: return "workspace.space";
    case SyncCollection::kWorkspaceToday: return "workspace.today";
    case SyncCollection::kWorkspaceWindowLayout: return "workspace.windowLayout";
    case SyncCollection::kArchiveProfile: return "archive.profile";
    case SyncCollection::kSettingsPreferences: return "settings.preferences";
    case SyncCollection::kSettingsKeybindings: return "settings.keybindings";
    case SyncCollection::kAdblockConfig: return "adblock.config";
    case SyncCollection::kBoostItem: return "boost.item";
    case SyncCollection::kEaselDocument: return "easel.document";
    case SyncCollection::kNoteDocument: return "note.document";
    case SyncCollection::kHistoryProfile: return "history.profile";
    case SyncCollection::kExtensionsProfile: return "extensions.profile";
    case SyncCollection::kCredentialsProfile: return "credentials.profile";
    case SyncCollection::kSitePermissionsProfile:
      return "sitePermissions.profile";
  }
  return "";
}

std::optional<SyncCollection> SyncCollectionFromString(std::string_view name) {
  for (SyncCollection c : AllSyncCollections()) {
    if (SyncCollectionToString(c) == name) {
      return c;
    }
  }
  return std::nullopt;
}

const std::vector<SyncCollection>& AllSyncCollections() {
  static const std::vector<SyncCollection> kAll = {
      SyncCollection::kWorkspaceMeta,
      SyncCollection::kWorkspaceProfile,
      SyncCollection::kWorkspaceSpace,
      SyncCollection::kWorkspaceToday,
      SyncCollection::kWorkspaceWindowLayout,
      SyncCollection::kArchiveProfile,
      SyncCollection::kSettingsPreferences,
      SyncCollection::kSettingsKeybindings,
      SyncCollection::kAdblockConfig,
      SyncCollection::kBoostItem,
      SyncCollection::kEaselDocument,
      SyncCollection::kNoteDocument,
      SyncCollection::kHistoryProfile,
      SyncCollection::kExtensionsProfile,
      SyncCollection::kCredentialsProfile,
      SyncCollection::kSitePermissionsProfile,
  };
  return kAll;
}

std::optional<std::string> SyncCollectionSingletonId(
    SyncCollection collection) {
  switch (collection) {
    case SyncCollection::kWorkspaceMeta:
    case SyncCollection::kSettingsPreferences:
    case SyncCollection::kSettingsKeybindings:
    case SyncCollection::kAdblockConfig:
      return std::string("global");
    case SyncCollection::kWorkspaceWindowLayout:
      return std::string("default");
    default:
      return std::nullopt;
  }
}

bool SyncCollectionCarriesAssets(SyncCollection collection) {
  return collection == SyncCollection::kEaselDocument ||
         collection == SyncCollection::kNoteDocument;
}

bool IsValidSyncRecordId(std::string_view record_id) {
  if (record_id.empty() || record_id.size() > kSyncMaxRecordIdLength) {
    return false;
  }
  for (char c : record_id) {
    bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
              (c >= 'a' && c <= 'z') || c == '.' || c == '_' || c == ':' ||
              c == '-';
    if (!ok) {
      return false;
    }
  }
  return true;
}

std::string_view SyncCategoryToString(SyncCategory category) {
  switch (category) {
    case SyncCategory::kWorkspace: return "workspace";
    case SyncCategory::kTodayTabs: return "todayTabs";
    case SyncCategory::kArchive: return "archive";
    case SyncCategory::kSettingsAndShortcuts: return "settingsAndShortcuts";
    case SyncCategory::kAdBlocking: return "adBlocking";
    case SyncCategory::kBoostsEaselsNotes: return "boostsEaselsNotes";
    case SyncCategory::kHistory: return "history";
    case SyncCategory::kExtensions: return "extensions";
    case SyncCategory::kCredentialsAndPermissions:
      return "credentialsAndPermissions";
  }
  return "workspace";
}

std::optional<SyncCategory> SyncCategoryFromString(std::string_view name) {
  static constexpr SyncCategory kCats[] = {
      SyncCategory::kWorkspace,
      SyncCategory::kTodayTabs,
      SyncCategory::kArchive,
      SyncCategory::kSettingsAndShortcuts,
      SyncCategory::kAdBlocking,
      SyncCategory::kBoostsEaselsNotes,
      SyncCategory::kHistory,
      SyncCategory::kExtensions,
      SyncCategory::kCredentialsAndPermissions,
  };
  for (SyncCategory c : kCats) {
    if (SyncCategoryToString(c) == name) {
      return c;
    }
  }
  return std::nullopt;
}

SyncCategory SyncCategoryForCollection(SyncCollection collection) {
  switch (collection) {
    case SyncCollection::kWorkspaceMeta:
    case SyncCollection::kWorkspaceProfile:
    case SyncCollection::kWorkspaceSpace:
    case SyncCollection::kWorkspaceWindowLayout:
      return SyncCategory::kWorkspace;
    case SyncCollection::kWorkspaceToday:
      return SyncCategory::kTodayTabs;
    case SyncCollection::kArchiveProfile:
      return SyncCategory::kArchive;
    case SyncCollection::kSettingsPreferences:
    case SyncCollection::kSettingsKeybindings:
      return SyncCategory::kSettingsAndShortcuts;
    case SyncCollection::kAdblockConfig:
      return SyncCategory::kAdBlocking;
    case SyncCollection::kBoostItem:
    case SyncCollection::kEaselDocument:
    case SyncCollection::kNoteDocument:
      return SyncCategory::kBoostsEaselsNotes;
    case SyncCollection::kHistoryProfile:
      return SyncCategory::kHistory;
    case SyncCollection::kExtensionsProfile:
      return SyncCategory::kExtensions;
    case SyncCollection::kCredentialsProfile:
    case SyncCollection::kSitePermissionsProfile:
      return SyncCategory::kCredentialsAndPermissions;
  }
  return SyncCategory::kWorkspace;
}

std::vector<SyncCollection> SyncCollectionsForCategory(SyncCategory category) {
  switch (category) {
    case SyncCategory::kWorkspace:
      return {SyncCollection::kWorkspaceMeta, SyncCollection::kWorkspaceProfile,
              SyncCollection::kWorkspaceSpace,
              SyncCollection::kWorkspaceWindowLayout};
    case SyncCategory::kTodayTabs:
      return {SyncCollection::kWorkspaceToday};
    case SyncCategory::kArchive:
      return {SyncCollection::kArchiveProfile};
    case SyncCategory::kSettingsAndShortcuts:
      return {SyncCollection::kSettingsPreferences,
              SyncCollection::kSettingsKeybindings};
    case SyncCategory::kAdBlocking:
      return {SyncCollection::kAdblockConfig};
    case SyncCategory::kBoostsEaselsNotes:
      return {SyncCollection::kBoostItem, SyncCollection::kEaselDocument,
              SyncCollection::kNoteDocument};
    case SyncCategory::kHistory:
      return {SyncCollection::kHistoryProfile};
    case SyncCategory::kExtensions:
      return {SyncCollection::kExtensionsProfile};
    case SyncCategory::kCredentialsAndPermissions:
      return {SyncCollection::kCredentialsProfile,
              SyncCollection::kSitePermissionsProfile};
  }
  return {};
}

bool SyncCategorySettings::IsEnabled(SyncCategory category) const {
  auto it = enabled.find(std::string(SyncCategoryToString(category)));
  return it == enabled.end() ? true : it->second;
}

bool SyncCategorySettings::IsEnabled(SyncCollection collection) const {
  return IsEnabled(SyncCategoryForCollection(collection));
}

void SyncCategorySettings::SetEnabled(SyncCategory category, bool is_on) {
  enabled[std::string(SyncCategoryToString(category))] = is_on;
}

std::set<SyncCollection> SyncCategorySettings::EnabledCollections() const {
  std::set<SyncCollection> out;
  for (SyncCollection c : AllSyncCollections()) {
    if (IsEnabled(c)) {
      out.insert(c);
    }
  }
  return out;
}

SyncCredentials::~SyncCredentials() {
  SyncCrypto::SecureZero(tokens.access_token);
  SyncCrypto::SecureZero(tokens.refresh_token);
  SyncCrypto::SecureZero(vault_key_base64);
}

// static
std::string SyncPersistedState::MirrorKey(SyncCollection collection,
                                          std::string_view record_id) {
  return std::string(SyncCollectionToString(collection)) + "|" +
         std::string(record_id);
}

// static
std::optional<std::pair<SyncCollection, std::string>>
SyncPersistedState::ParseMirrorKey(std::string_view key) {
  size_t bar = key.find('|');
  if (bar == std::string_view::npos) {
    return std::nullopt;
  }
  auto col = SyncCollectionFromString(key.substr(0, bar));
  if (!col) {
    return std::nullopt;
  }
  return std::make_pair(*col, std::string(key.substr(bar + 1)));
}

// --- 16 Collection Codecs ---

// static
std::string SyncCollectionCodecs::EncodeDeterministicJson(
    const base::DictValue& dict) {
  std::string out;
  base::JSONWriter::Write(dict, &out);
  return out;
}

// static
std::optional<base::DictValue> SyncCollectionCodecs::DecodeJsonDict(
    std::string_view json) {
  return base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
}

// static
std::optional<int> SyncCollectionCodecs::ProbeSchemaVersion(
    std::string_view json) {
  auto dict = DecodeJsonDict(json);
  if (!dict) return std::nullopt;
  return dict->FindInt("schemaVersion");
}

// static
std::vector<SyncedAssetRef> SyncCollectionCodecs::ProbeAssetRefs(
    std::string_view json) {
  std::vector<SyncedAssetRef> out;
  auto dict = DecodeJsonDict(json);
  if (!dict) return out;
  const auto* list = dict->FindList("assets");
  if (!list) return out;
  for (const auto& item : *list) {
    if (auto ref = DecodeAssetRef(item.GetIfDict());
        ref && SyncCrypto::IsValidBlobId(ref->blob_id)) {
      out.push_back(std::move(*ref));
    }
  }
  return out;
}

// 1. workspace.meta
// static
base::DictValue SyncCollectionCodecs::EncodeWorkspaceMeta(
    const SyncedWorkspaceMetaPayload& payload) {
  base::DictValue d;
  d.Set("schemaVersion", payload.schema_version);
  base::ListValue pids;
  for (const auto& p : payload.ordered_profile_ids) pids.Append(p);
  d.Set("orderedProfileIDs", std::move(pids));
  base::ListValue sids;
  for (const auto& s : payload.ordered_space_ids) sids.Append(s);
  d.Set("orderedSpaceIDs", std::move(sids));
  base::ListValue rules;
  for (const auto& r : payload.routing_rules) {
    base::DictValue rd;
    rd.Set("id", r.id);
    rd.Set("name", r.name);
    rd.Set("hostPattern", r.host_pattern);
    if (r.path_prefix) rd.Set("pathPrefix", *r.path_prefix);
    if (r.source_app_id) rd.Set("sourceAppID", *r.source_app_id);
    rd.Set("destination", EncodeRoutingDestination(r.destination));
    rd.Set("enabled", r.enabled);
    rules.Append(std::move(rd));
  }
  d.Set("routingRules", std::move(rules));
  d.Set("defaultDestination",
        EncodeRoutingDestination(payload.default_destination));
  return d;
}

// static
std::optional<SyncedWorkspaceMetaPayload>
SyncCollectionCodecs::DecodeWorkspaceMeta(const base::DictValue& dict) {
  SyncedWorkspaceMetaPayload out;
  out.schema_version = dict.FindInt("schemaVersion").value_or(1);
  if (const auto* pids = dict.FindList("orderedProfileIDs")) {
    for (const auto& v : *pids) {
      if (v.is_string()) out.ordered_profile_ids.push_back(v.GetString());
    }
  }
  if (const auto* sids = dict.FindList("orderedSpaceIDs")) {
    for (const auto& v : *sids) {
      if (v.is_string()) out.ordered_space_ids.push_back(v.GetString());
    }
  }
  if (const auto* rules = dict.FindList("routingRules")) {
    for (const auto& rv : *rules) {
      const auto* rd = rv.GetIfDict();
      if (!rd) continue;
      RoutingRule r;
      if (const auto* s = rd->FindString("id")) r.id = *s;
      if (const auto* s = rd->FindString("name")) r.name = *s;
      if (const auto* s = rd->FindString("hostPattern")) r.host_pattern = *s;
      if (const auto* s = rd->FindString("pathPrefix")) r.path_prefix = *s;
      if (const auto* s = rd->FindString("sourceAppID")) r.source_app_id = *s;
      r.destination = DecodeRoutingDestination(rd->FindDict("destination"));
      r.enabled = rd->FindBool("enabled").value_or(true);
      out.routing_rules.push_back(std::move(r));
    }
  }
  out.default_destination =
      DecodeRoutingDestination(dict.FindDict("defaultDestination"));
  return out;
}

// 2. workspace.profile
// static
base::DictValue SyncCollectionCodecs::EncodeProfile(const Profile& profile) {
  base::DictValue p;
  p.Set("id", profile.id);
  p.Set("name", profile.name);
  if (profile.icon) p.Set("icon", EncodeSpaceIcon(*profile.icon));
  base::ListValue favs;
  for (const auto& fav : profile.favorites) favs.Append(EncodeTab(fav));
  p.Set("favorites", std::move(favs));
  p.Set("dataDirectoryName", profile.data_directory_name);
  p.Set("favoritesEmptyStateDismissed",
        profile.favorites_empty_state_dismissed);

  base::DictValue st;
  st.Set("autoArchiveAfter",
         AutoArchiveToString(profile.settings.auto_archive_after));
  st.Set("littleOpenAutoArchiveAfter",
         AutoArchiveToString(profile.settings.little_open_auto_archive_after));
  st.Set("searchSuggestEnabled", profile.settings.search_suggest_enabled);
  st.Set("downloadDirectory", profile.settings.download_directory);
  st.Set("askWhereToSaveEachFile",
         profile.settings.ask_where_to_save_each_file);
  st.Set("searchEngineID", profile.settings.search_engine_id);
  st.Set("sleepMode", SleepModeToString(profile.settings.sleep_mode));
  st.Set("defaultDocumentApp", profile.settings.default_document_app);
  base::ListValue keep_alive;
  for (const auto& h : profile.settings.keep_alive_sites) keep_alive.Append(h);
  st.Set("keepAliveSites", std::move(keep_alive));
  base::ListValue engines;
  for (const auto& e : profile.settings.custom_search_engines) {
    base::DictValue ed;
    ed.Set("id", e.id);
    ed.Set("name", e.name);
    ed.Set("keyword", e.keyword);
    ed.Set("urlTemplate", e.url_template);
    engines.Append(std::move(ed));
  }
  st.Set("customSearchEngines", std::move(engines));
  p.Set("settings", std::move(st));

  base::DictValue wrapper;
  wrapper.Set("schemaVersion", 1);
  wrapper.Set("profile", std::move(p));
  return wrapper;
}

// static
std::optional<Profile> SyncCollectionCodecs::DecodeProfile(
    const base::DictValue& dict) {
  const base::DictValue* p = dict.FindDict("profile");
  if (!p) p = &dict;
  const std::string* id = p->FindString("id");
  if (!id || id->empty()) return std::nullopt;
  Profile out;
  out.id = *id;
  out.name = p->FindString("name") ? *p->FindString("name") : "Default";
  out.icon = DecodeSpaceIcon(p->FindDict("icon"));
  if (const auto* favs = p->FindList("favorites")) {
    for (const auto& v : *favs) {
      if (auto t = DecodeTab(v.GetIfDict())) {
        out.favorites.push_back(std::move(*t));
      }
    }
  }
  // Never trust dataDirectoryName from a remote Profile payload (prevents path
  // traversal and directory collisions); leave it empty so the local adapter
  // assigns a sanitized unique directory matching [A-Za-z0-9 _-]{1,64} with
  // "Default" reserved.
  out.data_directory_name.clear();
  out.favorites_empty_state_dismissed =
      p->FindBool("favoritesEmptyStateDismissed").value_or(false);
  if (const auto* st = p->FindDict("settings")) {
    if (const auto* s = st->FindString("autoArchiveAfter")) {
      out.settings.auto_archive_after = AutoArchiveFromString(*s);
    }
    if (const auto* s = st->FindString("littleOpenAutoArchiveAfter")) {
      out.settings.little_open_auto_archive_after = AutoArchiveFromString(*s);
    }
    out.settings.search_suggest_enabled =
        st->FindBool("searchSuggestEnabled").value_or(true);
    if (const auto* s = st->FindString("downloadDirectory")) {
      out.settings.download_directory = *s;
    }
    out.settings.ask_where_to_save_each_file =
        st->FindBool("askWhereToSaveEachFile").value_or(false);
    if (const auto* s = st->FindString("searchEngineID")) {
      out.settings.search_engine_id = *s;
    }
    if (const auto* s = st->FindString("sleepMode")) {
      out.settings.sleep_mode = SleepModeFromString(*s);
    }
    if (const auto* s = st->FindString("defaultDocumentApp")) {
      out.settings.default_document_app = *s;
    }
    if (const auto* ka = st->FindList("keepAliveSites")) {
      for (const auto& v : *ka) {
        if (v.is_string()) out.settings.keep_alive_sites.push_back(v.GetString());
      }
    }
    if (const auto* engs = st->FindList("customSearchEngines")) {
      for (const auto& ev : *engs) {
        const auto* ed = ev.GetIfDict();
        if (!ed) continue;
        CustomSearchEngine e;
        if (const auto* s = ed->FindString("id")) e.id = *s;
        if (const auto* s = ed->FindString("name")) e.name = *s;
        if (const auto* s = ed->FindString("keyword")) e.keyword = *s;
        if (const auto* s = ed->FindString("urlTemplate")) e.url_template = *s;
        out.settings.custom_search_engines.push_back(std::move(e));
      }
    }
  }
  return out;
}

// 3. workspace.space
// static
base::DictValue SyncCollectionCodecs::EncodeSpace(const Space& space) {
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("id", space.id);
  if (space.title) d.Set("title", *space.title);
  if (space.icon) d.Set("icon", EncodeSpaceIcon(*space.icon));
  d.Set("theme", EncodeSpaceTheme(space.theme));
  d.Set("profileID", space.profile_id);
  base::ListValue pinned;
  for (const auto& n : space.pinned) pinned.Append(EncodeNode(n));
  d.Set("pinned", std::move(pinned));
  d.Set("isPinnedCollapsed", space.is_pinned_collapsed);
  return d;
}

// static
std::optional<Space> SyncCollectionCodecs::DecodeSpace(
    const base::DictValue& dict) {
  const std::string* id = dict.FindString("id");
  const std::string* pid = dict.FindString("profileID");
  if (!id || id->empty() || !pid) return std::nullopt;
  Space s;
  s.id = *id;
  if (const auto* t = dict.FindString("title")) s.title = *t;
  s.icon = DecodeSpaceIcon(dict.FindDict("icon"));
  s.theme = DecodeSpaceTheme(dict.FindDict("theme"));
  s.profile_id = *pid;
  if (const auto* pinned = dict.FindList("pinned")) {
    for (const auto& v : *pinned) {
      if (auto n = DecodeNode(v.GetIfDict())) {
        s.pinned.push_back(std::move(*n));
      }
    }
  }
  s.is_pinned_collapsed = dict.FindBool("isPinnedCollapsed").value_or(false);
  return s;
}

// 4. workspace.today
// static
base::DictValue SyncCollectionCodecs::EncodeTodayTabs(
    const SpaceID& space_id,
    const std::vector<SidebarNode>& today) {
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("spaceID", space_id);
  base::ListValue list;
  for (const auto& n : today) list.Append(EncodeNode(n));
  d.Set("today", std::move(list));
  return d;
}

// static
std::optional<std::vector<SidebarNode>> SyncCollectionCodecs::DecodeTodayTabs(
    const base::DictValue& dict,
    SpaceID* out_space_id) {
  const std::string* sid = dict.FindString("spaceID");
  if (sid && out_space_id) *out_space_id = *sid;
  const auto* list = dict.FindList("today");
  if (!list) return std::nullopt;
  std::vector<SidebarNode> out;
  for (const auto& v : *list) {
    if (auto n = DecodeNode(v.GetIfDict())) {
      out.push_back(std::move(*n));
    }
  }
  return out;
}

// 5. workspace.windowLayout
// static
base::DictValue SyncCollectionCodecs::EncodeWindowLayout(
    const SyncedWindowLayoutPayload& layout) {
  base::DictValue d;
  d.Set("schemaVersion", layout.schema_version);
  d.Set("sidebarWidth", std::round(layout.sidebar_width));
  d.Set("sidebarMode",
        layout.sidebar_mode == SidebarMode::kHidden ? "hidden" : "anchored");
  d.Set("showsToolbar", layout.shows_toolbar);
  return d;
}

// static
std::optional<SyncedWindowLayoutPayload>
SyncCollectionCodecs::DecodeWindowLayout(const base::DictValue& dict) {
  SyncedWindowLayoutPayload out;
  out.schema_version = dict.FindInt("schemaVersion").value_or(1);
  double w = dict.FindDouble("sidebarWidth").value_or(228.0);
  if (std::isfinite(w)) {
    out.sidebar_width = std::clamp(w, 164.0, 600.0);
  }
  if (const auto* m = dict.FindString("sidebarMode"); m && *m == "hidden") {
    out.sidebar_mode = SidebarMode::kHidden;
  }
  out.shows_toolbar = dict.FindBool("showsToolbar").value_or(true);
  return out;
}

// 6. archive.profile
// static
base::DictValue SyncCollectionCodecs::EncodeArchiveProfile(
    const ProfileID& profile_id,
    std::vector<ArchivedTabRecord> records) {
  std::sort(records.begin(), records.end(),
            [](const ArchivedTabRecord& a, const ArchivedTabRecord& b) {
              return a.archived_at > b.archived_at;
            });
  if (records.size() > kSyncMaxArchiveRecordsPerProfile) {
    records.resize(kSyncMaxArchiveRecordsPerProfile);
  }
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("profileID", profile_id);
  base::ListValue list;
  for (const auto& r : records) {
    base::DictValue rd;
    rd.Set("id", r.id);
    rd.Set("url", r.url);
    rd.Set("title", r.title);
    if (r.space_id) rd.Set("spaceID", *r.space_id);
    if (r.profile_id) rd.Set("profileID", *r.profile_id);
    rd.Set("archivedAt", r.archived_at);
    rd.Set("reason", r.reason);
    rd.Set("originalLocation", r.original_location);
    rd.Set("kind", r.kind);
    rd.Set("payloadJSON", r.payload_json);
    list.Append(std::move(rd));
  }
  d.Set("records", std::move(list));
  return d;
}

// static
std::optional<std::vector<ArchivedTabRecord>>
SyncCollectionCodecs::DecodeArchiveProfile(const base::DictValue& dict,
                                           ProfileID* out_profile_id) {
  if (const auto* pid = dict.FindString("profileID"); pid && out_profile_id) {
    *out_profile_id = *pid;
  }
  const auto* list = dict.FindList("records");
  if (!list) return std::nullopt;
  std::vector<ArchivedTabRecord> out;
  for (const auto& v : *list) {
    const auto* rd = v.GetIfDict();
    if (!rd) continue;
    ArchivedTabRecord r;
    if (const auto* s = rd->FindString("id")) r.id = *s;
    if (const auto* s = rd->FindString("url")) r.url = *s;
    if (const auto* s = rd->FindString("title")) r.title = *s;
    if (const auto* s = rd->FindString("spaceID")) r.space_id = *s;
    if (const auto* s = rd->FindString("profileID")) r.profile_id = *s;
    r.archived_at = rd->FindDouble("archivedAt").value_or(0.0);
    if (const auto* s = rd->FindString("reason")) r.reason = *s;
    if (const auto* s = rd->FindString("originalLocation"))
      r.original_location = *s;
    if (const auto* s = rd->FindString("kind")) r.kind = *s;
    if (const auto* s = rd->FindString("payloadJSON")) r.payload_json = *s;
    out.push_back(std::move(r));
  }
  return out;
}

// 7. settings.preferences
// static
bool SyncCollectionCodecs::IsPortablePreferenceKey(std::string_view key) {
  static constexpr std::string_view kExcludedPrefixes[] = {
      "open.firstRun.", "open.updates.",    "open.debug.",
      "open.developer.", "open.automation.", "open.import.",
      "open.settings.", "open.library.",    "open.onboarding.",
      "open.appIcon.",  "open.sync.",
  };
  for (auto prefix : kExcludedPrefixes) {
    if (base::StartsWith(key, prefix)) return false;
  }
  if (base::StartsWith(key, "open.favorites.")) return true;

  static const std::set<std::string_view> kPortableKeys = {
      "open.general.previewsEnabled",
      "open.general.previewsFolders",
      "open.general.previewsPages",
      "open.general.previewsCalendar",
      "open.general.previewsRecents",
      "open.general.previewsGmail",
      "open.general.previewsOnHover",
      "open.general.previewsDelaySeconds",
      "open.general.warnBeforeQuitting",
      "open.links.littleOpenHotkeyEnabled",
      "open.links.openPeekShiftClick",
      "open.links.openPeekOtherSites",
      "open.links.externalInLittleOpen",
      "open.links.optionCommandClickLittleOpen",
      "open.shortcuts.defaultPriority",
      "open.shortcuts.switchToNinthEnabled",
      "open.shortcuts.includeFavoritesInTabNumbering",
      "open.advanced.tabSleepMode",
      "open.advanced.playSoundEffects",
      "open.advanced.hapticOnTabReorder",
      "open.advanced.restoreWindowsOnLaunch",
      "open.advanced.showFullURLWithToolbar",
      "open.advanced.enableBoosts",
      "open.advanced.allowWindowDraggingFromWebTop",
      "open.advanced.enableSharedQuotes",
      "open.advanced.enablePictureInPictureOnLeave",
      "open.advanced.allowSitesThemeData",
      "open.web.colorScheme",
      "open.sidebar.showSpaceHeaderOnSingleUnnamedSpace",
      "open.translate.enabled",
      "open.translate.neverTranslateHosts",
      "open.pip.keepOnTop",
      "open.pip.autoDisabledHosts",
      "open.capture.dragToCaptureEnabled",
      "open.capture.portraitHidesWatermark",
      "open.capture.portraitColorPercentage",
      "open.capture.portraitBackground",
      "open.easel.useAlignmentGuides",
      "open.profiles.confirmInterProfileMove",
      "open.liveFolders.githubAutoCreate",
  };
  return kPortableKeys.contains(key);
}

// static
base::DictValue SyncCollectionCodecs::EncodePreferences(
    const std::map<std::string, base::Value>& prefs) {
  base::DictValue values;
  for (const auto& [k, v] : prefs) {
    if (!IsPortablePreferenceKey(k)) continue;
    base::DictValue tagged;
    if (v.is_bool()) {
      tagged.Set("type", "bool");
      tagged.Set("value", v.GetBool());
    } else if (v.is_int()) {
      tagged.Set("type", "int");
      tagged.Set("value", v.GetInt());
    } else if (v.is_double()) {
      if (!std::isfinite(v.GetDouble())) continue;
      tagged.Set("type", "double");
      tagged.Set("value", v.GetDouble());
    } else if (v.is_string()) {
      tagged.Set("type", "string");
      tagged.Set("value", v.GetString());
    } else if (v.is_list()) {
      tagged.Set("type", "stringArray");
      tagged.Set("value", v.GetList().Clone());
    } else {
      continue;
    }
    values.Set(k, std::move(tagged));
  }
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("values", std::move(values));
  return d;
}

// static
std::optional<std::map<std::string, base::Value>>
SyncCollectionCodecs::DecodePreferences(const base::DictValue& dict) {
  const auto* values = dict.FindDict("values");
  if (!values) return std::nullopt;
  std::map<std::string, base::Value> out;
  for (const auto [k, v] : *values) {
    if (!IsPortablePreferenceKey(k)) continue;
    const auto* td = v.GetIfDict();
    if (!td) continue;
    const auto* type = td->FindString("type");
    const auto* raw = td->Find("value");
    if (!type || !raw) continue;
    if (*type == "bool" && raw->is_bool()) {
      out.emplace(k, base::Value(raw->GetBool()));
    } else if (*type == "int" && raw->is_int()) {
      out.emplace(k, base::Value(raw->GetInt()));
    } else if (*type == "double" && (raw->is_double() || raw->is_int())) {
      out.emplace(k, base::Value(raw->GetDouble()));
    } else if (*type == "string" && raw->is_string()) {
      out.emplace(k, base::Value(raw->GetString()));
    } else if (*type == "stringArray" && raw->is_list()) {
      out.emplace(k, base::Value(raw->GetList().Clone()));
    }
  }
  return out;
}

// 8. settings.keybindings
// static
base::DictValue SyncCollectionCodecs::EncodeKeybindings(
    const base::DictValue& bindings) {
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("store", bindings.Clone());
  return d;
}

// static
std::optional<base::DictValue> SyncCollectionCodecs::DecodeKeybindings(
    const base::DictValue& dict) {
  const auto* store = dict.FindDict("store");
  if (!store) return std::nullopt;
  return store->Clone();
}

// 9. adblock.config
// static
base::DictValue SyncCollectionCodecs::EncodeAdBlockConfig(
    const SyncedAdBlockConfigPayload& config) {
  base::DictValue d;
  d.Set("schemaVersion", config.schema_version);
  d.Set("globalEnabled", config.global_enabled);
  base::DictValue profiles;
  for (const auto& [pid, prof] : config.profiles) {
    base::DictValue pd;
    auto lists = prof.enabled_list_ids;
    std::sort(lists.begin(), lists.end());
    base::ListValue lval;
    for (const auto& id : lists) lval.Append(id);
    pd.Set("enabledListIDs", std::move(lval));

    auto excl = prof.excluded_domains;
    std::sort(excl.begin(), excl.end());
    base::ListValue eval;
    for (const auto& dom : excl) eval.Append(dom);
    pd.Set("excludedDomains", std::move(eval));

    profiles.Set(pid, std::move(pd));
  }
  d.Set("profiles", std::move(profiles));
  return d;
}

// static
std::optional<SyncedAdBlockConfigPayload>
SyncCollectionCodecs::DecodeAdBlockConfig(const base::DictValue& dict) {
  SyncedAdBlockConfigPayload out;
  out.schema_version = dict.FindInt("schemaVersion").value_or(1);
  out.global_enabled = dict.FindBool("globalEnabled").value_or(true);
  if (const auto* profiles = dict.FindDict("profiles")) {
    for (const auto [pid, v] : *profiles) {
      const auto* pd = v.GetIfDict();
      if (!pd) continue;
      SyncedAdBlockProfilePayload prof;
      if (const auto* l = pd->FindList("enabledListIDs")) {
        for (const auto& item : *l) {
          if (item.is_string()) prof.enabled_list_ids.push_back(item.GetString());
        }
      }
      if (const auto* e = pd->FindList("excludedDomains")) {
        for (const auto& item : *e) {
          if (item.is_string()) prof.excluded_domains.push_back(item.GetString());
        }
      }
      out.profiles[pid] = std::move(prof);
    }
  }
  return out;
}

// 10. boost.item
// static
std::string SyncCollectionCodecs::BoostRecordId(const ProfileID& profile_id,
                                                const std::string& boost_id) {
  return profile_id + ":" + boost_id;
}

// static
base::DictValue SyncCollectionCodecs::EncodeBoostItem(
    const ProfileID& profile_id,
    const Boost& boost) {
  base::DictValue b;
  b.Set("id", boost.id);
  b.Set("name", boost.name);
  base::DictValue match;
  match.Set("domain", boost.host_pattern);
  b.Set("siteMatch", std::move(match));
  b.Set("isEnabled", boost.enabled);
  b.Set("css", boost.custom_css);
  b.Set("js", boost.custom_js);
  if (boost.color.enabled) {
    base::DictValue c;
    c.Set("hueRotateDegrees", boost.color.hue_degrees);
    c.Set("saturation", boost.color.saturation);
    c.Set("brightness", 1.0 + boost.color.lightness);
    c.Set("contrast", boost.color.contrast);
    c.Set("invert", boost.color.invert ? 1.0 : 0.0);
    b.Set("colorAdjustment", std::move(c));
  }
  if (boost.font_family) b.Set("fontFamily", *boost.font_family);
  b.Set("textZoom", boost.text_zoom);
  if (!boost.text_transform.empty()) b.Set("textTransform", boost.text_transform);
  base::ListValue zaps;
  for (const auto& z : boost.zapped_elements) {
    base::DictValue zd;
    zd.Set("id", z.id);
    zd.Set("selector", z.selector);
    zd.Set("label", z.label);
    zaps.Append(std::move(zd));
  }
  b.Set("zaps", std::move(zaps));
  b.Set("createdAt", boost.created_at);
  b.Set("updatedAt", boost.modified_at);

  base::DictValue wrapper;
  wrapper.Set("schemaVersion", 1);
  wrapper.Set("profileID", profile_id);
  wrapper.Set("boost", std::move(b));
  return wrapper;
}

// static
std::optional<Boost> SyncCollectionCodecs::DecodeBoostItem(
    const base::DictValue& dict,
    ProfileID* out_profile_id) {
  const auto* pid = dict.FindString("profileID");
  if (pid && out_profile_id) *out_profile_id = *pid;
  const auto* b = dict.FindDict("boost");
  if (!b) return std::nullopt;
  const auto* id = b->FindString("id");
  if (!id || id->empty()) return std::nullopt;
  Boost out;
  out.id = *id;
  if (pid) out.profile_id = *pid;
  if (const auto* s = b->FindString("name")) out.name = *s;
  if (const auto* sm = b->FindDict("siteMatch")) {
    if (const auto* dom = sm->FindString("domain")) out.host_pattern = *dom;
  }
  out.enabled = b->FindBool("isEnabled").value_or(true);
  if (const auto* s = b->FindString("css")) out.custom_css = *s;
  if (const auto* s = b->FindString("js")) out.custom_js = *s;
  if (const auto* c = b->FindDict("colorAdjustment")) {
    out.color.enabled = true;
    out.color.hue_degrees = c->FindDouble("hueRotateDegrees").value_or(0.0);
    out.color.saturation = c->FindDouble("saturation").value_or(1.0);
    out.color.lightness = c->FindDouble("brightness").value_or(1.0) - 1.0;
    out.color.contrast = c->FindDouble("contrast").value_or(1.0);
    out.color.invert = c->FindDouble("invert").value_or(0.0) >= 0.5;
  }
  if (const auto* s = b->FindString("fontFamily")) out.font_family = *s;
  out.text_zoom = b->FindDouble("textZoom").value_or(1.0);
  if (const auto* s = b->FindString("textTransform")) out.text_transform = *s;
  if (const auto* zaps = b->FindList("zaps")) {
    for (const auto& zv : *zaps) {
      const auto* zd = zv.GetIfDict();
      if (!zd) continue;
      ZappedElement z;
      if (const auto* s = zd->FindString("id")) z.id = *s;
      if (const auto* s = zd->FindString("selector")) z.selector = *s;
      if (const auto* s = zd->FindString("label")) z.label = *s;
      if (!z.selector.empty()) out.zapped_elements.push_back(std::move(z));
    }
  }
  out.created_at = b->FindDouble("createdAt").value_or(0.0);
  out.modified_at = b->FindDouble("updatedAt").value_or(0.0);
  return out;
}

// 11. easel.document
// static
base::DictValue SyncCollectionCodecs::EncodeEaselDocument(
    const EaselDocument& doc,
    std::vector<SyncedAssetRef> assets) {
  std::sort(assets.begin(), assets.end(),
            [](const SyncedAssetRef& a, const SyncedAssetRef& b) {
              return a.filename < b.filename;
            });
  base::DictValue ed;
  ed.Set("formatVersion", doc.format_version);
  ed.Set("id", doc.id);
  ed.Set("title", doc.title);
  ed.Set("canvasWidth", doc.canvas_width);
  ed.Set("canvasHeight", doc.canvas_height);
  ed.Set("palette", doc.palette);
  base::ListValue elems;
  for (const auto& el : doc.elements) {
    base::DictValue eld;
    eld.Set("id", el.id);
    eld.Set("type", el.type);
    eld.Set("x", el.x);
    eld.Set("y", el.y);
    eld.Set("width", el.width);
    eld.Set("height", el.height);
    eld.Set("content", el.content);
    eld.Set("fillColor", el.fill_color);
    eld.Set("strokeColor", el.stroke_color);
    eld.Set("strokeWidth", el.stroke_width);
    eld.Set("fontSize", el.font_size);
    eld.Set("zIndex", el.z_index);
    elems.Append(std::move(eld));
  }
  ed.Set("elements", std::move(elems));
  ed.Set("createdAt", doc.created_at);
  ed.Set("modifiedAt", doc.modified_at);

  base::ListValue alist;
  for (const auto& a : assets) alist.Append(EncodeAssetRef(a));

  base::DictValue wrapper;
  wrapper.Set("schemaVersion", 1);
  wrapper.Set("document", std::move(ed));
  wrapper.Set("assets", std::move(alist));
  return wrapper;
}

// static
std::optional<EaselDocument> SyncCollectionCodecs::DecodeEaselDocument(
    const base::DictValue& dict,
    std::vector<SyncedAssetRef>* out_assets) {
  const auto* ed = dict.FindDict("document");
  if (!ed) return std::nullopt;
  const auto* id = ed->FindString("id");
  if (!id || id->empty()) return std::nullopt;
  EaselDocument doc;
  doc.format_version = ed->FindInt("formatVersion").value_or(1);
  doc.id = *id;
  if (const auto* s = ed->FindString("title")) doc.title = *s;
  doc.canvas_width = ed->FindDouble("canvasWidth").value_or(1000.0);
  doc.canvas_height = ed->FindDouble("canvasHeight").value_or(1400.0);
  if (const auto* s = ed->FindString("palette")) doc.palette = *s;
  if (const auto* elems = ed->FindList("elements")) {
    for (const auto& v : *elems) {
      const auto* eld = v.GetIfDict();
      if (!eld) continue;
      EaselElement el;
      if (const auto* s = eld->FindString("id")) el.id = *s;
      if (const auto* s = eld->FindString("type")) el.type = *s;
      el.x = eld->FindDouble("x").value_or(0.0);
      el.y = eld->FindDouble("y").value_or(0.0);
      el.width = eld->FindDouble("width").value_or(200.0);
      el.height = eld->FindDouble("height").value_or(100.0);
      if (const auto* s = eld->FindString("content")) el.content = *s;
      if (const auto* s = eld->FindString("fillColor")) el.fill_color = *s;
      if (const auto* s = eld->FindString("strokeColor")) el.stroke_color = *s;
      el.stroke_width = eld->FindDouble("strokeWidth").value_or(2.0);
      el.font_size = eld->FindDouble("fontSize").value_or(16.0);
      el.z_index = eld->FindInt("zIndex").value_or(0);
      doc.elements.push_back(std::move(el));
    }
  }
  doc.created_at = ed->FindDouble("createdAt").value_or(0.0);
  doc.modified_at = ed->FindDouble("modifiedAt").value_or(0.0);
  if (out_assets) {
    out_assets->clear();
    if (const auto* alist = dict.FindList("assets")) {
      for (const auto& v : *alist) {
        if (auto ref = DecodeAssetRef(v.GetIfDict())) {
          out_assets->push_back(std::move(*ref));
        }
      }
    }
  }
  return doc;
}

// 12. note.document
// static
base::DictValue SyncCollectionCodecs::EncodeNoteDocument(
    const NoteDocument& doc,
    std::vector<SyncedAssetRef> assets) {
  std::sort(assets.begin(), assets.end(),
            [](const SyncedAssetRef& a, const SyncedAssetRef& b) {
              return a.filename < b.filename;
            });
  base::DictValue nd;
  nd.Set("formatVersion", doc.format_version);
  nd.Set("id", doc.id);
  nd.Set("title", doc.title);
  nd.Set("text", doc.text);
  base::ListValue fmts;
  for (const auto& f : doc.formats) {
    base::DictValue fd;
    fd.Set("type", f.type);
    fd.Set("location", f.location);
    fd.Set("length", f.length);
    if (f.url) fd.Set("url", *f.url);
    if (f.level) fd.Set("level", *f.level);
    fmts.Append(std::move(fd));
  }
  nd.Set("formats", std::move(fmts));
  nd.Set("createdAt", doc.created_at);
  nd.Set("modifiedAt", doc.modified_at);

  base::ListValue alist;
  for (const auto& a : assets) alist.Append(EncodeAssetRef(a));

  base::DictValue wrapper;
  wrapper.Set("schemaVersion", 1);
  wrapper.Set("document", std::move(nd));
  wrapper.Set("assets", std::move(alist));
  return wrapper;
}

// static
std::optional<NoteDocument> SyncCollectionCodecs::DecodeNoteDocument(
    const base::DictValue& dict,
    std::vector<SyncedAssetRef>* out_assets) {
  const auto* nd = dict.FindDict("document");
  if (!nd) return std::nullopt;
  const auto* id = nd->FindString("id");
  if (!id || id->empty()) return std::nullopt;
  NoteDocument doc;
  doc.format_version = nd->FindInt("formatVersion").value_or(1);
  doc.id = *id;
  if (const auto* s = nd->FindString("title")) doc.title = *s;
  if (const auto* s = nd->FindString("text")) doc.text = *s;
  if (const auto* fmts = nd->FindList("formats")) {
    for (const auto& v : *fmts) {
      const auto* fd = v.GetIfDict();
      if (!fd) continue;
      NoteFormatRange r;
      if (const auto* s = fd->FindString("type")) r.type = *s;
      r.location = fd->FindInt("location").value_or(0);
      r.length = fd->FindInt("length").value_or(0);
      if (const auto* s = fd->FindString("url")) r.url = *s;
      r.level = fd->FindInt("level");
      doc.formats.push_back(std::move(r));
    }
  }
  doc.created_at = nd->FindDouble("createdAt").value_or(0.0);
  doc.modified_at = nd->FindDouble("modifiedAt").value_or(0.0);
  if (out_assets) {
    out_assets->clear();
    if (const auto* alist = dict.FindList("assets")) {
      for (const auto& v : *alist) {
        if (auto ref = DecodeAssetRef(v.GetIfDict())) {
          out_assets->push_back(std::move(*ref));
        }
      }
    }
  }
  return doc;
}

// 13. history.profile
// static
base::DictValue SyncCollectionCodecs::EncodeHistoryProfile(
    const ProfileID& profile_id,
    std::vector<HistoryEntry> entries) {
  std::sort(entries.begin(), entries.end(),
            [](const HistoryEntry& a, const HistoryEntry& b) {
              if (a.last_visit != b.last_visit) return a.last_visit > b.last_visit;
              return a.url > b.url;
            });
  if (entries.size() > kSyncMaxHistoryEntriesPerProfile) {
    entries.resize(kSyncMaxHistoryEntriesPerProfile);
  }
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("profileID", profile_id);
  base::ListValue list;
  for (const auto& e : entries) {
    base::DictValue ed;
    ed.Set("url", e.url);
    ed.Set("title", e.title);
    ed.Set("lastVisitedAt", e.last_visit);
    ed.Set("visitCount", e.visit_count);
    ed.Set("typedCount", e.typed_count);
    list.Append(std::move(ed));
  }
  d.Set("entries", std::move(list));
  return d;
}

// static
std::optional<std::vector<HistoryEntry>>
SyncCollectionCodecs::DecodeHistoryProfile(const base::DictValue& dict,
                                           ProfileID* out_profile_id) {
  if (const auto* pid = dict.FindString("profileID"); pid && out_profile_id) {
    *out_profile_id = *pid;
  }
  const auto* list = dict.FindList("entries");
  if (!list) return std::nullopt;
  std::vector<HistoryEntry> out;
  for (const auto& v : *list) {
    const auto* ed = v.GetIfDict();
    if (!ed) continue;
    HistoryEntry e;
    if (const auto* s = ed->FindString("url")) e.url = *s;
    if (const auto* s = ed->FindString("title")) e.title = *s;
    e.last_visit = ed->FindDouble("lastVisitedAt").value_or(0.0);
    e.visit_count = ed->FindInt("visitCount").value_or(1);
    e.typed_count = ed->FindInt("typedCount").value_or(0);
    if (!e.url.empty()) out.push_back(std::move(e));
  }
  return out;
}

// 14. extensions.profile
// static
base::DictValue SyncCollectionCodecs::EncodeExtensionsProfile(
    const ProfileID& profile_id,
    std::vector<SyncedExtensionRecord> extensions) {
  std::sort(extensions.begin(), extensions.end(),
            [](const SyncedExtensionRecord& a, const SyncedExtensionRecord& b) {
              return a.extension_id < b.extension_id;
            });
  base::DictValue d;
  d.Set("schemaVersion", 1);
  d.Set("profileID", profile_id);
  base::ListValue list;
  for (const auto& ext : extensions) {
    base::DictValue ed;
    ed.Set("extensionID", ext.extension_id);
    ed.Set("name", ext.name);
    ed.Set("fromWebStore", ext.from_web_store);
    ed.Set("isEnabled", ext.is_enabled);
    ed.Set("isPinned", ext.is_pinned);
    ed.Set("pinnedIndex", ext.pinned_index);
    list.Append(std::move(ed));
  }
  d.Set("extensions", std::move(list));
  return d;
}

// static
std::optional<std::vector<SyncedExtensionRecord>>
SyncCollectionCodecs::DecodeExtensionsProfile(const base::DictValue& dict,
                                              ProfileID* out_profile_id) {
  if (const auto* pid = dict.FindString("profileID"); pid && out_profile_id) {
    *out_profile_id = *pid;
  }
  const auto* list = dict.FindList("extensions");
  if (!list) return std::nullopt;
  std::vector<SyncedExtensionRecord> out;
  for (const auto& v : *list) {
    const auto* ed = v.GetIfDict();
    if (!ed) continue;
    SyncedExtensionRecord r;
    if (const auto* s = ed->FindString("extensionID")) r.extension_id = *s;
    if (const auto* s = ed->FindString("name")) r.name = *s;
    r.from_web_store = ed->FindBool("fromWebStore").value_or(true);
    r.is_enabled = ed->FindBool("isEnabled").value_or(true);
    r.is_pinned = ed->FindBool("isPinned").value_or(false);
    r.pinned_index = ed->FindInt("pinnedIndex").value_or(0);
    if (!r.extension_id.empty()) out.push_back(std::move(r));
  }
  return out;
}

// 15. credentials.profile
// static
base::DictValue SyncCollectionCodecs::EncodeCredentialsProfile(
    const SyncedCredentialsProfilePayload& payload) {
  base::DictValue d;
  d.Set("schemaVersion", payload.schema_version);
  d.Set("profileID", payload.profile_id);
  d.Set("passwordSavingEnabled", payload.password_saving_enabled);
  d.Set("creditCardsSavingEnabled", payload.credit_cards_saving_enabled);
  d.Set("creditCardReauthenticationEnabled",
        payload.credit_card_reauth_enabled);
  d.Set("addressesSavingEnabled", payload.addresses_saving_enabled);

  base::ListValue logins;
  for (const auto& l : payload.logins) {
    base::DictValue ld;
    ld.Set("originURL", l.origin_url);
    if (l.action_url) ld.Set("actionURL", *l.action_url);
    ld.Set("signonRealm", l.signon_realm);
    ld.Set("username", l.username);
    ld.Set("password", l.password);
    ld.Set("usernameElement", l.username_element);
    ld.Set("passwordElement", l.password_element);
    ld.Set("scheme", l.scheme);
    ld.Set("isBlacklisted", l.is_blacklisted);
    ld.Set("timesUsed", l.times_used);
    ld.Set("dateCreated", l.date_created);
    if (l.date_last_used) ld.Set("dateLastUsed", *l.date_last_used);
    if (l.date_password_modified)
      ld.Set("datePasswordModified", *l.date_password_modified);
    if (l.note) ld.Set("note", *l.note);
    logins.Append(std::move(ld));
  }
  d.Set("logins", std::move(logins));

  base::ListValue addrs;
  for (const auto& a : payload.addresses) {
    base::DictValue ad;
    ad.Set("guid", a.guid);
    base::DictValue fields;
    for (const auto& [fk, fv] : a.fields) fields.Set(fk, fv);
    ad.Set("fields", std::move(fields));
    ad.Set("useCount", a.use_count);
    if (a.use_date) ad.Set("useDate", *a.use_date);
    if (a.date_modified) ad.Set("dateModified", *a.date_modified);
    if (a.language_code) ad.Set("languageCode", *a.language_code);
    addrs.Append(std::move(ad));
  }
  d.Set("addresses", std::move(addrs));

  base::ListValue cards;
  for (const auto& c : payload.cards) {
    base::DictValue cd;
    cd.Set("guid", c.guid);
    cd.Set("nameOnCard", c.name_on_card);
    cd.Set("expirationMonth", c.expiration_month);
    cd.Set("expirationYear", c.expiration_year);
    cd.Set("number", c.number);
    if (c.nickname) cd.Set("nickname", *c.nickname);
    cd.Set("useCount", c.use_count);
    if (c.use_date) cd.Set("useDate", *c.use_date);
    if (c.date_modified) cd.Set("dateModified", *c.date_modified);
    cards.Append(std::move(cd));
  }
  d.Set("cards", std::move(cards));
  return d;
}

// static
std::optional<SyncedCredentialsProfilePayload>
SyncCollectionCodecs::DecodeCredentialsProfile(const base::DictValue& dict) {
  const auto* pid = dict.FindString("profileID");
  if (!pid || pid->empty()) return std::nullopt;
  SyncedCredentialsProfilePayload out;
  out.schema_version = dict.FindInt("schemaVersion").value_or(1);
  out.profile_id = *pid;
  out.password_saving_enabled =
      dict.FindBool("passwordSavingEnabled").value_or(true);
  out.credit_cards_saving_enabled =
      dict.FindBool("creditCardsSavingEnabled").value_or(true);
  out.credit_card_reauth_enabled =
      dict.FindBool("creditCardReauthenticationEnabled").value_or(true);
  out.addresses_saving_enabled =
      dict.FindBool("addressesSavingEnabled").value_or(true);
  if (const auto* logins = dict.FindList("logins")) {
    for (const auto& lv : *logins) {
      const auto* ld = lv.GetIfDict();
      if (!ld) continue;
      SyncedLoginRecord l;
      if (const auto* s = ld->FindString("originURL")) l.origin_url = *s;
      if (const auto* s = ld->FindString("actionURL")) l.action_url = *s;
      if (const auto* s = ld->FindString("signonRealm")) l.signon_realm = *s;
      if (const auto* s = ld->FindString("username")) l.username = *s;
      if (const auto* s = ld->FindString("password")) l.password = *s;
      if (const auto* s = ld->FindString("usernameElement"))
        l.username_element = *s;
      if (const auto* s = ld->FindString("passwordElement"))
        l.password_element = *s;
      l.scheme = ld->FindInt("scheme").value_or(0);
      l.is_blacklisted = ld->FindBool("isBlacklisted").value_or(false);
      l.times_used = ld->FindInt("timesUsed").value_or(0);
      l.date_created = ld->FindDouble("dateCreated").value_or(0.0);
      l.date_last_used = ld->FindDouble("dateLastUsed");
      l.date_password_modified = ld->FindDouble("datePasswordModified");
      if (const auto* s = ld->FindString("note")) l.note = *s;
      out.logins.push_back(std::move(l));
    }
  }
  if (const auto* addrs = dict.FindList("addresses")) {
    for (const auto& av : *addrs) {
      const auto* ad = av.GetIfDict();
      if (!ad) continue;
      SyncedAddressRecord a;
      if (const auto* s = ad->FindString("guid")) a.guid = *s;
      if (const auto* f = ad->FindDict("fields")) {
        for (const auto [fk, fv] : *f) {
          if (fv.is_string()) a.fields[fk] = fv.GetString();
        }
      }
      a.use_count = ad->FindInt("useCount").value_or(0);
      a.use_date = ad->FindDouble("useDate");
      a.date_modified = ad->FindDouble("dateModified");
      if (const auto* s = ad->FindString("languageCode")) a.language_code = *s;
      out.addresses.push_back(std::move(a));
    }
  }
  if (const auto* cards = dict.FindList("cards")) {
    for (const auto& cv : *cards) {
      const auto* cd = cv.GetIfDict();
      if (!cd) continue;
      SyncedCardRecord c;
      if (const auto* s = cd->FindString("guid")) c.guid = *s;
      if (const auto* s = cd->FindString("nameOnCard")) c.name_on_card = *s;
      c.expiration_month = cd->FindInt("expirationMonth").value_or(0);
      c.expiration_year = cd->FindInt("expirationYear").value_or(0);
      if (const auto* s = cd->FindString("number")) c.number = *s;
      if (const auto* s = cd->FindString("nickname")) c.nickname = *s;
      c.use_count = cd->FindInt("useCount").value_or(0);
      c.use_date = cd->FindDouble("useDate");
      c.date_modified = cd->FindDouble("dateModified");
      out.cards.push_back(std::move(c));
    }
  }
  return out;
}

// 16. sitePermissions.profile
// static
base::DictValue SyncCollectionCodecs::EncodeSitePermissionsProfile(
    const SyncedSitePermissionsProfilePayload& payload) {
  base::DictValue d;
  d.Set("schemaVersion", payload.schema_version);
  d.Set("profileID", payload.profile_id);

  auto perms = payload.permissions;
  std::sort(perms.begin(), perms.end(),
            [](const SyncedPermissionDecision& a,
               const SyncedPermissionDecision& b) {
              return std::tie(a.origin, a.permission) <
                     std::tie(b.origin, b.permission);
            });
  base::ListValue plist;
  for (const auto& p : perms) {
    base::DictValue pd;
    pd.Set("origin", p.origin);
    pd.Set("permission", p.permission);
    pd.Set("decision", p.decision);
    if (p.updated_at) pd.Set("updatedAt", *p.updated_at);
    plist.Append(std::move(pd));
  }
  d.Set("permissions", std::move(plist));

  auto settings = payload.site_settings;
  std::sort(settings.begin(), settings.end(),
            [](const SyncedSiteSetting& a, const SyncedSiteSetting& b) {
              return std::tie(a.origin, a.setting) <
                     std::tie(b.origin, b.setting);
            });
  base::ListValue slist;
  for (const auto& s : settings) {
    base::DictValue sd;
    sd.Set("origin", s.origin);
    sd.Set("setting", s.setting);
    sd.Set("value", s.value);
    slist.Append(std::move(sd));
  }
  d.Set("siteSettings", std::move(slist));
  return d;
}

// static
std::optional<SyncedSitePermissionsProfilePayload>
SyncCollectionCodecs::DecodeSitePermissionsProfile(
    const base::DictValue& dict) {
  const auto* pid = dict.FindString("profileID");
  if (!pid || pid->empty()) return std::nullopt;
  SyncedSitePermissionsProfilePayload out;
  out.schema_version = dict.FindInt("schemaVersion").value_or(1);
  out.profile_id = *pid;
  if (const auto* plist = dict.FindList("permissions")) {
    for (const auto& pv : *plist) {
      const auto* pd = pv.GetIfDict();
      if (!pd) continue;
      SyncedPermissionDecision p;
      if (const auto* s = pd->FindString("origin")) p.origin = *s;
      if (const auto* s = pd->FindString("permission")) p.permission = *s;
      if (const auto* s = pd->FindString("decision")) p.decision = *s;
      p.updated_at = pd->FindDouble("updatedAt");
      out.permissions.push_back(std::move(p));
    }
  }
  if (const auto* slist = dict.FindList("siteSettings")) {
    for (const auto& sv : *slist) {
      const auto* sd = sv.GetIfDict();
      if (!sd) continue;
      SyncedSiteSetting s;
      if (const auto* v = sd->FindString("origin")) s.origin = *v;
      if (const auto* v = sd->FindString("setting")) s.setting = *v;
      if (const auto* v = sd->FindString("value")) s.value = *v;
      out.site_settings.push_back(std::move(s));
    }
  }
  return out;
}

// --- SyncEngine implementation ---

SyncEngine::SyncPassContext::SyncPassContext() = default;
SyncEngine::SyncPassContext::~SyncPassContext() = default;

SyncEngine::BlobDownloadResult::BlobDownloadResult() = default;
SyncEngine::BlobDownloadResult::BlobDownloadResult(
    BlobDownloadResult&&) noexcept = default;
SyncEngine::BlobDownloadResult& SyncEngine::BlobDownloadResult::operator=(
    BlobDownloadResult&&) noexcept = default;
SyncEngine::BlobDownloadResult::~BlobDownloadResult() = default;

SyncEngine::SyncEngine(base::FilePath data_root,
                       std::unique_ptr<SyncHttpTransport> http_transport,
                       std::unique_ptr<SecretStore> secret_store,
                       std::unique_ptr<SyncWebSocketClient> ws_client)
    : data_root_(std::move(data_root)),
      http_transport_(std::move(http_transport)),
      secret_store_(std::move(secret_store)),
      ws_client_(std::move(ws_client)) {
  if (!secret_store_) {
    secret_store_ = OpenPlatform::Get()->CreateSecretStore(data_root_, false);
  }
  snapshot_.uses_file_credential_store =
      secret_store_ && secret_store_->UsesFileBackend();
}

void SyncEngine::SetCredentialAccountKey(std::string account_key) {
  credential_account_key_ = std::move(account_key);
}

SyncEngine::SyncEngine(
    std::filesystem::path state_dir,
    BrowserModel* /*model*/,
    std::unique_ptr<SecretStore> secrets,
    scoped_refptr<network::SharedURLLoaderFactory> loader_factory)
    : SyncEngine(base::FilePath::FromUTF8Unsafe(state_dir.string()),
                 CreateSimpleURLLoaderSyncTransport(std::move(loader_factory)),
                 std::move(secrets),
                 nullptr) {}

SyncEngine::~SyncEngine() {
  StopWebSocket();
}

SyncStatusInfo SyncEngine::Status() const {
  SyncStatusInfo info;
  info.signed_in = snapshot_.is_signed_in;
  info.email = snapshot_.email.value_or("");
  info.server_url = snapshot_.server_url;
  switch (snapshot_.status) {
    case SyncStatusKind::kSignedOut: info.state = "signedOut"; break;
    case SyncStatusKind::kIdle: info.state = "idle"; break;
    case SyncStatusKind::kSyncing: info.state = "syncing"; break;
    case SyncStatusKind::kAwaitingInitialChoice:
      info.state = "awaitingInitialChoice";
      break;
    case SyncStatusKind::kError: info.state = "error"; break;
    case SyncStatusKind::kNeedsReauth: info.state = "needsReauth"; break;
  }
  if (snapshot_.last_sync_at_ms) {
    info.last_sync_at = static_cast<double>(*snapshot_.last_sync_at_ms) / 1000.0;
  }
  info.revision = snapshot_.last_pulled_revision;
  info.categories = snapshot_.categories.enabled;
  if (snapshot_.status == SyncStatusKind::kError ||
      snapshot_.status == SyncStatusKind::kNeedsReauth) {
    info.error_message = snapshot_.status_message;
  }
  return info;
}

void SyncEngine::ConfigureServer(std::string url,
                                 std::map<std::string, bool> categories,
                                 StatusCallback done) {
  if (!url.empty()) {
    ConfigureServerUrl(url);
  }
  for (const auto& [k, v] : categories) {
    if (auto cat = SyncCategoryFromString(k)) {
      SetCategoryEnabled(*cat, v);
    }
  }
  if (done) {
    std::move(done).Run(Status());
  }
}

void SyncEngine::Register(
    std::string email,
    std::string password,
    std::string url,
    base::OnceCallback<void(base::expected<std::string, std::string>)> done) {
  SignUp(url.empty() ? snapshot_.server_url : url, email, password, "",
         base::BindOnce(
             [](base::OnceCallback<void(base::expected<std::string, std::string>)>
                    cb,
                SyncResult r) {
               if (!cb) return;
               if (r.ok) {
                 std::move(cb).Run(base::ok(std::move(r.recovery_key)));
               } else {
                 std::move(cb).Run(base::unexpected(std::move(r.error_message)));
               }
             },
             std::move(done)));
}

void SyncEngine::Login(
    std::string email,
    std::string password,
    std::string url,
    base::OnceCallback<void(base::expected<bool, std::string>)> done) {
  SignIn(url.empty() ? snapshot_.server_url : url, email, password,
         std::nullopt,
         base::BindOnce(
             [](base::OnceCallback<void(base::expected<bool, std::string>)> cb,
                SyncResult r) {
               if (!cb) return;
               if (r.ok) {
                 std::move(cb).Run(
                     base::ok(r.needs_initial_choice.has_value()));
               } else {
                 std::move(cb).Run(base::unexpected(std::move(r.error_message)));
               }
             },
             std::move(done)));
}

void SyncEngine::Logout(StatusCallback done) {
  SignOut(base::BindOnce(
      [](base::WeakPtr<SyncEngine> self, StatusCallback cb) {
        if (cb) {
          std::move(cb).Run(self ? self->Status() : SyncStatusInfo{});
        }
      },
      weak_factory_.GetWeakPtr(), std::move(done)));
}

void SyncEngine::Recover(
    std::string email,
    std::string recovery_key,
    std::string new_password,
    std::string url,
    base::OnceCallback<void(base::expected<void, std::string>)> done) {
  RecoverAccount(
      url.empty() ? snapshot_.server_url : url, email, recovery_key,
      new_password, std::nullopt,
      base::BindOnce(
          [](base::OnceCallback<void(base::expected<void, std::string>)> cb,
             SyncResult r) {
            if (!cb) return;
            if (r.ok) {
              std::move(cb).Run(base::ok());
            } else {
              std::move(cb).Run(base::unexpected(std::move(r.error_message)));
            }
          },
          std::move(done)));
}

void SyncEngine::ListDevices(
    base::OnceCallback<void(std::vector<SyncDeviceInfo>)> done) {
  RefreshDevices(base::BindOnce(
      [](base::OnceCallback<void(std::vector<SyncDeviceInfo>)> cb,
         bool /*ok*/, std::vector<SyncDeviceInfo> devs, std::string /*err*/) {
        if (cb) std::move(cb).Run(std::move(devs));
      },
      std::move(done)));
}

// static
std::optional<std::string> SyncEngine::ValidateServerUrl(std::string_view raw) {
  std::string trimmed(base::TrimWhitespaceASCII(raw, base::TRIM_ALL));
  while (!trimmed.empty() && trimmed.back() == '/') {
    trimmed.pop_back();
  }
  GURL parsed(trimmed);
  if (!parsed.is_valid() || !parsed.SchemeIsHTTPOrHTTPS() ||
      parsed.host().empty() || parsed.has_query() || parsed.has_ref() ||
      parsed.has_username() || parsed.has_password()) {
    return std::nullopt;
  }
  std::string normalized = parsed.spec();
  while (!normalized.empty() && normalized.back() == '/') {
    normalized.pop_back();
  }
  return normalized;
}

base::FilePath SyncEngine::StateFilePath() const {
  return data_root_.AppendASCII("State").AppendASCII("sync-state.json");
}

base::FilePath SyncEngine::BackupsDirPath() const {
  return data_root_.AppendASCII("State").AppendASCII("SyncBackups");
}

std::string SyncEngine::CredentialAccountKey() const {
  if (!credential_account_key_.empty()) {
    return credential_account_key_;
  }
  std::string utf8 = data_root_.AsUTF8Unsafe();
  std::string digest = SyncCrypto::Sha256Hex(
      reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size());
  return std::string(kSecretAccountPrefix) + digest.substr(0, 16);
}

scoped_refptr<base::SequencedTaskRunner> SyncEngine::GetOrCreateIoTaskRunner()
    const {
  if (!io_task_runner_ && base::ThreadPoolInstance::Get()) {
    io_task_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
        {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  }
  return io_task_runner_;
}

// static
std::string SyncEngine::GenerateUuidLower() {
  return base::Uuid::GenerateRandomV4().AsLowercaseString();
}

// static
int64_t SyncEngine::NowEpochMs() {
  return base::Time::Now().InMillisecondsSinceUnixEpoch();
}

// static
std::pair<std::string, std::string> SyncEngine::ParseServerError(
    const SyncHttpResponse& resp) {
  if (resp.status_code == 0) {
    return {"TRANSPORT", resp.error_message.empty() ? "Could not reach server."
                                                    : resp.error_message};
  }
  std::string_view body_sv(reinterpret_cast<const char*>(resp.body.data()),
                           resp.body.size());
  if (auto dict = base::JSONReader::ReadDict(body_sv, base::JSON_PARSE_RFC)) {
    if (const auto* err = dict->FindDict("error")) {
      std::string code =
          err->FindString("code") ? *err->FindString("code") : "SERVER_ERROR";
      std::string msg = err->FindString("message") ? *err->FindString("message")
                                                   : code;
      return {std::move(code), std::move(msg)};
    }
  }
  return {"HTTP_" + base::NumberToString(resp.status_code),
          "Sync server returned HTTP " +
              base::NumberToString(resp.status_code)};
}

bool SyncEngine::SaveStateToDisk() const {
  if (!state_) return false;
  const SyncPersistedState& s = *state_;
  base::DictValue d;
  d.Set("schemaVersion", s.schema_version);
  d.Set("serverURL", s.server_url);
  if (s.account_id) d.Set("accountId", *s.account_id);
  if (s.email) d.Set("email", *s.email);
  if (s.display_name) d.Set("displayName", *s.display_name);
  d.Set("deviceId", s.device_id);
  d.Set("deviceName", s.device_name);
  d.Set("lastPulledRevision", s.last_pulled_revision);
  d.Set("lastResetRevision", s.last_reset_revision);
  if (s.last_sync_at_ms) d.Set("lastSyncAt", static_cast<double>(*s.last_sync_at_ms));

  base::DictValue cats;
  for (const auto& [k, v] : s.categories.enabled) cats.Set(k, v);
  base::DictValue cat_wrap;
  cat_wrap.Set("enabled", std::move(cats));
  d.Set("categories", std::move(cat_wrap));

  if (s.awaiting_initial_choice) {
    base::DictValue ac;
    ac.Set("serverRevision", s.awaiting_initial_choice->server_revision);
    ac.Set("resetRevision", s.awaiting_initial_choice->reset_revision);
    ac.Set("hasCloudData", s.awaiting_initial_choice->has_cloud_data);
    base::DictValue cc;
    for (const auto& [k, v] : s.awaiting_initial_choice->collection_counts) {
      cc.Set(k, v);
    }
    ac.Set("collectionCounts", std::move(cc));
    d.Set("awaitingInitialChoice", std::move(ac));
  }

  base::DictValue mirror;
  for (const auto& [k, m] : s.mirror) {
    base::DictValue md;
    md.Set("payloadHash", m.payload_hash);
    md.Set("clientUpdatedAt", static_cast<double>(m.client_updated_at_ms));
    md.Set("deleted", m.deleted);
    mirror.Set(k, std::move(md));
  }
  d.Set("mirror", std::move(mirror));

  base::ListValue blobs;
  for (const auto& id : s.uploaded_blob_ids) blobs.Append(id);
  d.Set("uploadedBlobIDs", std::move(blobs));

  base::ListValue backfill;
  for (SyncCategory c : s.pending_backfill_categories) {
    backfill.Append(SyncCategoryToString(c));
  }
  d.Set("pendingBackfillCategories", std::move(backfill));

  base::FilePath path = StateFilePath();
  std::string json = SyncCollectionCodecs::EncodeDeterministicJson(d);
  if (auto runner = GetOrCreateIoTaskRunner()) {
    runner->PostTask(
        FROM_HERE,
        base::BindOnce(&WriteStateAtomicOnIo, std::move(path), std::move(json)));
    return true;
  }
  if (!base::CreateDirectory(path.DirName())) return false;
  return base::ImportantFileWriter::WriteFileAtomically(path, json);
}

std::optional<SyncPersistedState> SyncEngine::LoadStateFromDisk() const {
  base::FilePath path = StateFilePath();
  std::string raw;
  if (!base::ReadFileToStringWithMaxSize(path, &raw, 16 * 1024 * 1024)) {
    return std::nullopt;
  }
  auto dict = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  if (!dict) return std::nullopt;
  SyncPersistedState s;
  s.schema_version = dict->FindInt("schemaVersion").value_or(1);
  if (const auto* u = dict->FindString("serverURL")) s.server_url = *u;
  if (const auto* v = dict->FindString("accountId")) s.account_id = *v;
  if (const auto* v = dict->FindString("email")) s.email = *v;
  if (const auto* v = dict->FindString("displayName")) s.display_name = *v;
  s.device_id = dict->FindString("deviceId") ? *dict->FindString("deviceId")
                                             : GenerateUuidLower();
  s.device_name = dict->FindString("deviceName")
                      ? *dict->FindString("deviceName")
                      : OpenPlatform::Get()->GetDeviceName();
  s.last_pulled_revision = dict->FindInt("lastPulledRevision").value_or(0);
  s.last_reset_revision = dict->FindInt("lastResetRevision").value_or(0);
  if (auto ts = dict->FindDouble("lastSyncAt")) {
    s.last_sync_at_ms = static_cast<int64_t>(*ts);
  }
  if (const auto* cw = dict->FindDict("categories")) {
    if (const auto* en = cw->FindDict("enabled")) {
      for (const auto [k, v] : *en) {
        if (v.is_bool()) s.categories.enabled[k] = v.GetBool();
      }
    }
  }
  if (const auto* ac = dict->FindDict("awaitingInitialChoice")) {
    SyncCloudSummary sum;
    sum.server_revision = ac->FindInt("serverRevision").value_or(0);
    sum.reset_revision = ac->FindInt("resetRevision").value_or(0);
    sum.has_cloud_data = ac->FindBool("hasCloudData").value_or(false);
    if (const auto* cc = ac->FindDict("collectionCounts")) {
      for (const auto [k, v] : *cc) {
        if (v.is_int()) sum.collection_counts[k] = v.GetInt();
      }
    }
    s.awaiting_initial_choice = std::move(sum);
  }
  if (const auto* mirror = dict->FindDict("mirror")) {
    for (const auto [k, v] : *mirror) {
      const auto* md = v.GetIfDict();
      if (!md) continue;
      SyncRecordMirror m;
      if (const auto* h = md->FindString("payloadHash")) m.payload_hash = *h;
      m.client_updated_at_ms =
          static_cast<int64_t>(md->FindDouble("clientUpdatedAt").value_or(0.0));
      m.deleted = md->FindBool("deleted").value_or(false);
      s.mirror[k] = std::move(m);
    }
  }
  if (const auto* blobs = dict->FindList("uploadedBlobIDs")) {
    for (const auto& v : *blobs) {
      if (v.is_string()) s.uploaded_blob_ids.insert(v.GetString());
    }
  }
  if (const auto* bf = dict->FindList("pendingBackfillCategories")) {
    for (const auto& v : *bf) {
      if (v.is_string()) {
        if (auto c = SyncCategoryFromString(v.GetString())) {
          s.pending_backfill_categories.push_back(*c);
        }
      }
    }
  }
  return s;
}

void SyncEngine::DeleteStateFromDisk() const {
  base::FilePath path = StateFilePath();
  if (auto runner = GetOrCreateIoTaskRunner()) {
    runner->PostTask(FROM_HERE,
                     base::BindOnce(&DeleteStateOnIo, std::move(path)));
    return;
  }
  base::DeleteFile(path);
}

bool SyncEngine::SaveCredentialsToStore(const SyncCredentials& creds) {
  if (!secret_store_) return false;
  base::DictValue d;
  d.Set("accessToken", creds.tokens.access_token);
  d.Set("refreshToken", creds.tokens.refresh_token);
  d.Set("accessTokenExpiresAt",
        static_cast<double>(creds.tokens.access_token_expires_at_ms));
  d.Set("vaultKeyBase64", creds.vault_key_base64);
  std::string json;
  json.reserve(creds.tokens.access_token.size() +
               creds.tokens.refresh_token.size() +
               creds.vault_key_base64.size() + 256);
  base::JSONWriter::Write(d, &json);
  WipeDictString(d, "accessToken");
  WipeDictString(d, "refreshToken");
  WipeDictString(d, "vaultKeyBase64");
  std::vector<uint8_t> bytes(json.begin(), json.end());
  SyncCrypto::SecureZero(json);
  bool ok = secret_store_->SaveSecret(kSecretServiceName,
                                      CredentialAccountKey(), bytes);
  SyncCrypto::SecureZero(bytes);
  return ok;
}

std::optional<SyncCredentials> SyncEngine::LoadCredentialsFromStore() {
  if (!secret_store_) return std::nullopt;
  auto bytes =
      secret_store_->LoadSecret(kSecretServiceName, CredentialAccountKey());
  if (!bytes) return std::nullopt;
  std::string_view sv(reinterpret_cast<const char*>(bytes->data()),
                      bytes->size());
  auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
  SyncCrypto::SecureZero(*bytes);
  if (!dict) return std::nullopt;
  const auto* at = dict->FindString("accessToken");
  const auto* rt = dict->FindString("refreshToken");
  const auto* vk = dict->FindString("vaultKeyBase64");
  std::optional<SyncCredentials> result;
  if (at && rt && vk) {
    SyncCredentials creds;
    creds.tokens.access_token = *at;
    creds.tokens.refresh_token = *rt;
    creds.tokens.access_token_expires_at_ms = static_cast<int64_t>(
        dict->FindDouble("accessTokenExpiresAt").value_or(0.0));
    creds.vault_key_base64 = *vk;
    result = std::move(creds);
  }
  WipeDictString(*dict, "accessToken");
  WipeDictString(*dict, "refreshToken");
  WipeDictString(*dict, "vaultKeyBase64");
  return result;
}

void SyncEngine::DeleteCredentialsFromStore() {
  if (secret_store_) {
    secret_store_->DeleteSecret(kSecretServiceName, CredentialAccountKey());
  }
}

void SyncEngine::PublishSnapshot() {
  SyncAccountSnapshot next;
  next.is_signed_in = is_signed_in();
  next.server_url = state_ ? state_->server_url : snapshot_.server_url;
  if (state_) {
    next.account_id = state_->account_id;
    next.email = state_->email;
    next.display_name = state_->display_name;
    next.device_id = state_->device_id;
    next.device_name = state_->device_name;
    next.categories = state_->categories;
    next.last_sync_at_ms = state_->last_sync_at_ms;
    next.last_pulled_revision = state_->last_pulled_revision;
    next.pending_extension_installs = state_->pending_extension_installs;
    next.pending_initial_choice = state_->awaiting_initial_choice;
  } else {
    next.email = last_reauth_email_;
    next.categories = snapshot_.categories;
  }
  next.status = status_;
  next.status_message = status_message_;
  next.devices = devices_;
  next.warnings = warnings_;
  next.uses_file_credential_store =
      secret_store_ && secret_store_->UsesFileBackend();
  next.is_busy = sync_in_flight_;
  snapshot_ = std::move(next);
  if (on_snapshot_changed_) {
    on_snapshot_changed_.Run(snapshot_);
  }
  if (status_info_observer_) {
    status_info_observer_.Run(Status());
  }
}

void SyncEngine::SetStatus(SyncStatusKind kind, std::string message) {
  status_ = kind;
  status_message_ = std::move(message);
  PublishSnapshot();
}

void SyncEngine::ClearLocalSession(SyncStatusKind new_status,
                                   std::string message) {
  ++session_generation_;
  push_debounce_timer_.Stop();
  push_burst_started_ms_ = 0;
  StopWebSocket();
  DeleteCredentialsFromStore();
  DeleteStateFromDisk();

  SyncCategorySettings preserved_cats =
      state_ ? state_->categories : snapshot_.categories;
  std::string preserved_url = state_ ? state_->server_url : snapshot_.server_url;

  state_.reset();
  credentials_.reset();
  vault_keys_.reset();
  devices_.clear();
  warnings_.clear();
  sync_in_flight_ = false;
  follow_up_sync_requested_ = false;
  snapshot_.categories = preserved_cats;
  snapshot_.server_url = preserved_url;

  SetStatus(new_status, std::move(message));
}

bool SyncEngine::ConfigureServerUrl(std::string_view server_url) {
  auto valid = ValidateServerUrl(server_url);
  if (!valid) return false;
  snapshot_.server_url = *valid;
  if (state_) {
    state_->server_url = *valid;
    SaveStateToDisk();
  }
  PublishSnapshot();
  return true;
}

void SyncEngine::StartIfSignedIn() {
  if (started_) return;
  started_ = true;
  if (!base::PathExists(StateFilePath())) {
    return;
  }
  auto loaded = LoadStateFromDisk();
  if (!loaded || !loaded->account_id || loaded->account_id->empty()) {
    return;
  }
  auto creds = LoadCredentialsFromStore();
  if (!creds) {
    last_reauth_email_ = loaded->email;
    state_ = std::move(*loaded);
    SetStatus(SyncStatusKind::kNeedsReauth,
              "Sign in to Open Sync again to keep syncing.");
    return;
  }
  auto raw_vk = base::Base64Decode(creds->vault_key_base64);
  std::optional<SyncVaultKeys> keys =
      raw_vk ? SyncVaultKeys::DeriveFromVaultKey(*raw_vk) : std::nullopt;
  if (raw_vk) SyncCrypto::SecureZero(*raw_vk);
  if (!keys) {
    last_reauth_email_ = loaded->email;
    state_ = std::move(*loaded);
    SetStatus(SyncStatusKind::kNeedsReauth,
              "Sign in to Open Sync again to keep syncing.");
    return;
  }
  state_ = std::move(*loaded);
  credentials_ = std::move(*creds);
  vault_keys_ = std::move(*keys);

  if (state_->awaiting_initial_choice) {
    SetStatus(SyncStatusKind::kAwaitingInitialChoice,
              "Choose how to sync this device.");
    return;
  }
  SetStatus(SyncStatusKind::kIdle, "Up to date");
  StartWebSocket();
  SyncNow();
}

void SyncEngine::SendRaw(
    const std::string& method,
    const std::string& full_url,
    std::string content_type,
    std::string accept_header,
    std::vector<uint8_t> body,
    size_t max_response_bytes,
    std::optional<std::string> bearer_token,
    base::OnceCallback<void(SyncHttpResponse)> callback) {
  if (!http_transport_) {
    SyncHttpResponse resp;
    resp.error_message = "No HTTP transport configured.";
    std::move(callback).Run(std::move(resp));
    return;
  }
  SyncHttpRequest req;
  req.method = method;
  req.url = full_url;
  if (!accept_header.empty()) {
    req.headers["Accept"] = std::move(accept_header);
  }
  if (state_ && !state_->device_id.empty()) {
    req.headers["X-Open-Device-Id"] = state_->device_id;
  }
  if (bearer_token) {
    req.headers["Authorization"] = "Bearer " + *bearer_token;
  }
  req.content_type = std::move(content_type);
  req.body = std::move(body);
  req.max_response_bytes = max_response_bytes;
  http_transport_->Send(std::move(req), std::move(callback));
}

void SyncEngine::SendJson(
    const std::string& method,
    const std::string& full_url,
    std::optional<base::DictValue> body,
    std::optional<std::string> bearer_token,
    base::OnceCallback<void(SyncHttpResponse)> callback) {
  std::vector<uint8_t> raw_body;
  std::string content_type;
  if (body) {
    std::string serialized;
    base::JSONWriter::Write(*body, &serialized);
    if (serialized.size() > kSyncMaxJsonRequestBytes) {
      SyncHttpResponse resp;
      resp.error_message = "Request payload exceeds 8 MiB limit.";
      std::move(callback).Run(std::move(resp));
      return;
    }
    content_type = "application/json";
    raw_body.assign(serialized.begin(), serialized.end());
  }
  SendRaw(method, full_url, std::move(content_type), "application/json",
          std::move(raw_body), kSyncMaxJsonResponseBytes,
          std::move(bearer_token), std::move(callback));
}

void SyncEngine::RefreshAccessToken(
    base::OnceCallback<void(bool ok)> callback) {
  if (!state_ || !credentials_) {
    std::move(callback).Run(false);
    return;
  }
  pending_refresh_callbacks_.push_back(std::move(callback));
  if (refresh_in_flight_) {
    return;
  }
  refresh_in_flight_ = true;
  uint64_t gen = session_generation_;

  base::DictValue req_body;
  req_body.Set("refreshToken", credentials_->tokens.refresh_token);
  req_body.Set("deviceId", state_->device_id);

  SendJson(
      "POST", state_->server_url + "/v1/auth/refresh", std::move(req_body),
      std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen,
             SyncHttpResponse resp) {
            if (!self) {
              SyncCrypto::SecureZero(resp.body);
              return;
            }
            self->refresh_in_flight_ = false;
            auto callbacks = std::move(self->pending_refresh_callbacks_);
            self->pending_refresh_callbacks_.clear();

            bool ok = false;
            if (self->session_generation_ == gen && self->credentials_ &&
                resp.status_code >= 200 && resp.status_code < 300) {
              std::string_view sv(
                  reinterpret_cast<const char*>(resp.body.data()),
                  resp.body.size());
              if (auto d = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC)) {
                const auto* at = d->FindString("accessToken");
                const auto* rt = d->FindString("refreshToken");
                if (at && rt) {
                  self->credentials_->tokens.access_token = *at;
                  self->credentials_->tokens.refresh_token = *rt;
                  self->credentials_->tokens.access_token_expires_at_ms =
                      static_cast<int64_t>(
                          d->FindDouble("accessTokenExpiresAt").value_or(0.0));
                  self->SaveCredentialsToStore(*self->credentials_);
                  ok = true;
                }
                WipeDictString(*d, "accessToken");
                WipeDictString(*d, "refreshToken");
              }
            } else if (self->session_generation_ == gen) {
              auto [code, msg] = ParseServerError(resp);
              if (resp.status_code == 401 || resp.status_code == 403 ||
                  code == "TOKEN_REUSED") {
                // Keep sync state (mirror/revision/categories) so re-auth can
                // resume cleanly, but clear credentials and stored secret.
                self->StopWebSocket();
                self->push_debounce_timer_.Stop();
                self->push_burst_started_ms_ = 0;
                self->credentials_.reset();
                self->DeleteCredentialsFromStore();
                self->last_reauth_email_ =
                    self->state_ ? self->state_->email : std::nullopt;
                self->SetStatus(SyncStatusKind::kNeedsReauth,
                                "Your session ended. Sign in again.");
              }
            }
            SyncCrypto::SecureZero(resp.body);
            for (auto& cb : callbacks) {
              std::move(cb).Run(ok);
            }
          },
          weak_factory_.GetWeakPtr(), gen));
}

void SyncEngine::SendAuthenticatedBinary(
    const std::string& method,
    const std::string& path,
    std::string content_type,
    std::string accept_header,
    std::vector<uint8_t> body,
    size_t max_response_bytes,
    base::OnceCallback<void(SyncHttpResponse)> callback) {
  if (!state_ || !credentials_) {
    SyncHttpResponse resp;
    resp.status_code = 401;
    resp.error_message = "Not signed in.";
    std::move(callback).Run(std::move(resp));
    return;
  }

  const int64_t now_ms = NowEpochMs();
  const int64_t exp_ms = credentials_->tokens.access_token_expires_at_ms;
  if (exp_ms > 0 && exp_ms - now_ms < 60000) {
    RefreshAccessToken(base::BindOnce(
        [](base::WeakPtr<SyncEngine> self, std::string method, std::string path,
           std::string content_type, std::string accept_header,
           std::vector<uint8_t> body, size_t max_response_bytes,
           base::OnceCallback<void(SyncHttpResponse)> cb, bool refreshed) {
          if (!self || !refreshed || !self->state_ || !self->credentials_) {
            SyncHttpResponse resp;
            resp.status_code = 401;
            resp.error_message = "Session expired.";
            std::move(cb).Run(std::move(resp));
            return;
          }
          self->SendRaw(method, self->state_->server_url + path,
                        std::move(content_type), std::move(accept_header),
                        std::move(body), max_response_bytes,
                        self->credentials_->tokens.access_token, std::move(cb));
        },
        weak_factory_.GetWeakPtr(), method, path, std::move(content_type),
        std::move(accept_header), std::move(body), max_response_bytes,
        std::move(callback)));
    return;
  }

  std::vector<uint8_t> retry_body = body;
  std::string full_url = state_->server_url + path;
  uint64_t gen = session_generation_;

  SendRaw(
      method, full_url, content_type, accept_header, std::move(body),
      max_response_bytes, credentials_->tokens.access_token,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen, std::string method,
             std::string path, std::string content_type,
             std::string accept_header, std::vector<uint8_t> retry_body,
             size_t max_response_bytes,
             base::OnceCallback<void(SyncHttpResponse)> cb,
             SyncHttpResponse resp) {
            if (!self || self->session_generation_ != gen) {
              std::move(cb).Run(std::move(resp));
              return;
            }
            if (resp.status_code == 401) {
              auto [code, msg] = ParseServerError(resp);
              if (code != "INVALID_CREDENTIALS") {
                self->RefreshAccessToken(base::BindOnce(
                    [](base::WeakPtr<SyncEngine> s, std::string m,
                       std::string p, std::string ct, std::string ah,
                       std::vector<uint8_t> rb, size_t max_bytes,
                       base::OnceCallback<void(SyncHttpResponse)> inner_cb,
                       bool refreshed) {
                      if (!s || !refreshed || !s->state_ || !s->credentials_) {
                        SyncHttpResponse fail;
                        fail.status_code = 401;
                        fail.error_message = "Session expired.";
                        std::move(inner_cb).Run(std::move(fail));
                        return;
                      }
                      s->SendRaw(m, s->state_->server_url + p, std::move(ct),
                                 std::move(ah), std::move(rb), max_bytes,
                                 s->credentials_->tokens.access_token,
                                 std::move(inner_cb));
                    },
                    self, method, path, std::move(content_type),
                    std::move(accept_header), std::move(retry_body),
                    max_response_bytes, std::move(cb)));
                return;
              }
            }
            std::move(cb).Run(std::move(resp));
          },
          weak_factory_.GetWeakPtr(), gen, method, path,
          std::move(content_type), std::move(accept_header),
          std::move(retry_body), max_response_bytes, std::move(callback)));
}

void SyncEngine::SendAuthenticatedJson(
    const std::string& method,
    const std::string& path_and_query,
    std::optional<base::DictValue> body,
    base::OnceCallback<void(SyncHttpResponse)> callback) {
  if (!state_ || !credentials_) {
    SyncHttpResponse resp;
    resp.error_message = "Not signed in.";
    std::move(callback).Run(std::move(resp));
    return;
  }

  const int64_t now_ms = NowEpochMs();
  const int64_t exp_ms = credentials_->tokens.access_token_expires_at_ms;
  if (exp_ms > 0 && exp_ms - now_ms < 60000) {
    auto body_copy =
        body ? std::make_optional(body->Clone()) : std::nullopt;
    RefreshAccessToken(base::BindOnce(
        [](base::WeakPtr<SyncEngine> self, std::string method,
           std::string path_and_query, std::optional<base::DictValue> body,
           base::OnceCallback<void(SyncHttpResponse)> cb, bool refreshed) {
          if (!self || !refreshed || !self->state_ || !self->credentials_) {
            SyncHttpResponse resp;
            resp.status_code = 401;
            resp.error_message = "Session expired.";
            std::move(cb).Run(std::move(resp));
            return;
          }
          self->SendJson(method, self->state_->server_url + path_and_query,
                         std::move(body),
                         self->credentials_->tokens.access_token,
                         std::move(cb));
        },
        weak_factory_.GetWeakPtr(), method, path_and_query,
        std::move(body_copy), std::move(callback)));
    return;
  }

  auto retry_body = body ? std::make_optional(body->Clone()) : std::nullopt;
  std::string full_url = state_->server_url + path_and_query;
  uint64_t gen = session_generation_;

  SendJson(
      method, full_url, std::move(body), credentials_->tokens.access_token,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen, std::string method,
             std::string path_and_query,
             std::optional<base::DictValue> retry_body,
             base::OnceCallback<void(SyncHttpResponse)> cb,
             SyncHttpResponse resp) {
            if (!self || self->session_generation_ != gen) {
              std::move(cb).Run(std::move(resp));
              return;
            }
            if (resp.status_code == 401) {
              auto [code, msg] = ParseServerError(resp);
              if (code != "INVALID_CREDENTIALS") {
                self->RefreshAccessToken(base::BindOnce(
                    [](base::WeakPtr<SyncEngine> s, std::string m,
                       std::string pq, std::optional<base::DictValue> rb,
                       base::OnceCallback<void(SyncHttpResponse)> inner_cb,
                       bool refreshed) {
                      if (!s || !refreshed || !s->state_ || !s->credentials_) {
                        SyncHttpResponse fail;
                        fail.status_code = 401;
                        fail.error_message = "Session expired.";
                        std::move(inner_cb).Run(std::move(fail));
                        return;
                      }
                      s->SendJson(m, s->state_->server_url + pq, std::move(rb),
                                  s->credentials_->tokens.access_token,
                                  std::move(inner_cb));
                    },
                    self, method, path_and_query, std::move(retry_body),
                    std::move(cb)));
                return;
              }
            }
            std::move(cb).Run(std::move(resp));
          },
          weak_factory_.GetWeakPtr(), gen, method, path_and_query,
          std::move(retry_body), std::move(callback)));
}

void SyncEngine::SignUp(const std::string& server_url,
                        const std::string& email,
                        const std::string& password,
                        const std::string& display_name,
                        ResultCallback callback) {
  auto valid_url = ValidateServerUrl(server_url);
  if (!valid_url) {
    std::move(callback).Run(
        {false, "INVALID_SERVER_URL", "Invalid sync server URL."});
    return;
  }
  std::string normalized = SyncCrypto::NormalizeEmail(email);
  if (!SyncCrypto::IsValidNormalizedEmail(normalized)) {
    std::move(callback).Run({false, "INVALID_EMAIL", "Enter a valid email."});
    return;
  }
  if (password.size() < kSyncMinPasswordLength) {
    std::move(callback).Run(
        {false, "WEAK_PASSWORD", "Password must be at least 8 characters."});
    return;
  }

  if (is_signed_in() || state_.has_value()) {
    ClearLocalSession(SyncStatusKind::kSignedOut);
  }
  SetStatus(SyncStatusKind::kSyncing, "Creating your account...");

  uint64_t gen = session_generation_;
  std::string trimmed_name = TruncateUtf8Bytes(
      base::TrimWhitespaceASCII(display_name, base::TRIM_ALL),
      kSyncMaxDisplayNameLength);

  auto derive_task = base::BindOnce(
      [](std::string normalized_email, std::string pw) -> SignUpDerivedMaterial {
        SignUpDerivedMaterial mat;
        mat.kdf = SyncKdfParams::Generate();
        mat.vault_key = SyncCrypto::RandomBytes(kSyncKeyBytes);
        mat.recovery = SyncCrypto::GenerateRecoveryKey();
        if (mat.kdf && mat.vault_key && mat.recovery) {
          mat.pw_keys =
              SyncCrypto::DerivePasswordKeys(normalized_email, pw, *mat.kdf);
          mat.rec_keys =
              SyncCrypto::DeriveRecoveryKeys(mat.recovery->raw_bytes);
        }
        SyncCrypto::SecureZero(pw);
        return mat;
      },
      normalized, password);

  auto on_derived = base::BindOnce(
      [](base::WeakPtr<SyncEngine> self, uint64_t gen, std::string server_url,
         std::string normalized, std::string trimmed_name, ResultCallback cb,
         SignUpDerivedMaterial mat) {
        if (!self) {
          return;
        }
        if (self->session_generation_ != gen) {
          std::move(cb).Run({false, "CANCELLED", "Account creation cancelled."});
          return;
        }
        if (!mat.kdf || !mat.vault_key || !mat.recovery || !mat.pw_keys ||
            !mat.rec_keys) {
          self->SetStatus(SyncStatusKind::kSignedOut);
          std::move(cb).Run({false, "CRYPTO", "Key derivation failed."});
          return;
        }
        auto wrapped_pw = SyncCrypto::WrapVaultKey(
            *mat.vault_key, mat.pw_keys->password_wrap_key,
            SyncVaultWrapKind::kPassword, normalized);
        auto wrapped_rec = SyncCrypto::WrapVaultKey(
            *mat.vault_key, mat.rec_keys->recovery_wrap_key,
            SyncVaultWrapKind::kRecovery, normalized);
        if (!wrapped_pw || !wrapped_rec) {
          self->SetStatus(SyncStatusKind::kSignedOut);
          std::move(cb).Run({false, "CRYPTO", "Vault key wrapping failed."});
          return;
        }

        std::string device_id = GenerateUuidLower();
        std::string device_name = TruncateUtf8Bytes(
            OpenPlatform::Get()->GetDeviceName(), kSyncMaxDeviceNameLength);

        base::DictValue kdf_dict;
        kdf_dict.Set("algorithm", mat.kdf->algorithm);
        kdf_dict.Set("iterations", mat.kdf->iterations);
        kdf_dict.Set("saltBase64", mat.kdf->salt_base64);

        base::DictValue body;
        body.Set("email", normalized);
        body.Set("displayName", trimmed_name);
        body.Set("kdfParams", std::move(kdf_dict));
        body.Set("authVerifier", base::Base64Encode(mat.pw_keys->auth_verifier));
        body.Set("recoveryAuthVerifier",
                 base::Base64Encode(mat.rec_keys->recovery_auth_verifier));
        body.Set("wrappedVaultKeyByPassword", base::Base64Encode(*wrapped_pw));
        body.Set("wrappedVaultKeyByRecovery", base::Base64Encode(*wrapped_rec));
        body.Set("deviceId", device_id);
        body.Set("deviceName", device_name);
        body.Set("platform", OpenPlatform::Get()->GetSyncPlatformName());

        std::string vk_b64 = base::Base64Encode(*mat.vault_key);
        std::string recovery_formatted = mat.recovery->formatted;

        self->SendJson(
            "POST", server_url + "/v1/auth/register", std::move(body),
            std::nullopt,
            base::BindOnce(
                [](base::WeakPtr<SyncEngine> s, uint64_t expected_gen,
                   std::string url, std::string mail, std::string dev_id,
                   std::string dev_name, std::string vk_b64,
                   std::string recovery_formatted, ResultCallback done_cb,
                   SyncHttpResponse resp) {
                  if (!s) {
                    SyncCrypto::SecureZero(vk_b64);
                    SyncCrypto::SecureZero(recovery_formatted);
                    return;
                  }
                  if (s->session_generation_ != expected_gen) {
                    SyncCrypto::SecureZero(vk_b64);
                    SyncCrypto::SecureZero(recovery_formatted);
                    std::move(done_cb).Run(
                        {false, "CANCELLED", "Account creation cancelled."});
                    return;
                  }
                  if (resp.status_code < 200 || resp.status_code >= 300) {
                    SyncCrypto::SecureZero(vk_b64);
                    SyncCrypto::SecureZero(recovery_formatted);
                    auto [code, msg] = ParseServerError(resp);
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(done_cb).Run({false, code, msg});
                    return;
                  }
                  std::string_view sv(
                      reinterpret_cast<const char*>(resp.body.data()),
                      resp.body.size());
                  auto dict =
                      base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
                  if (!dict || !dict->FindString("accountId") ||
                      !dict->FindString("accessToken") ||
                      !dict->FindString("refreshToken")) {
                    SyncCrypto::SecureZero(vk_b64);
                    SyncCrypto::SecureZero(recovery_formatted);
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(done_cb).Run(
                        {false, "DECODING", "Malformed register response."});
                    return;
                  }
                  auto raw_vk = base::Base64Decode(vk_b64);
                  auto keys = raw_vk ? SyncVaultKeys::DeriveFromVaultKey(*raw_vk)
                                     : std::nullopt;
                  if (raw_vk) SyncCrypto::SecureZero(*raw_vk);
                  if (!keys) {
                    SyncCrypto::SecureZero(vk_b64);
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(done_cb).Run(
                        {false, "CRYPTO", "Failed deriving vault subkeys."});
                    return;
                  }

                  SyncCredentials creds;
                  creds.tokens.access_token = *dict->FindString("accessToken");
                  creds.tokens.refresh_token =
                      *dict->FindString("refreshToken");
                  creds.tokens.access_token_expires_at_ms =
                      static_cast<int64_t>(
                          dict->FindDouble("accessTokenExpiresAt")
                              .value_or(0.0));
                  creds.vault_key_base64 = std::move(vk_b64);
                  WipeDictString(*dict, "accessToken");
                  WipeDictString(*dict, "refreshToken");
                  s->SaveCredentialsToStore(creds);

                  SyncPersistedState st;
                  st.server_url = url;
                  st.account_id = *dict->FindString("accountId");
                  st.email = dict->FindString("email")
                                 ? *dict->FindString("email")
                                 : mail;
                  if (const auto* dn = dict->FindString("displayName");
                      dn && !dn->empty()) {
                    st.display_name = *dn;
                  }
                  st.device_id = dev_id;
                  st.device_name = dev_name;
                  st.last_reset_revision =
                      dict->FindInt("resetRevision").value_or(0);
                  st.categories = s->snapshot_.categories;

                  ++s->session_generation_;
                  s->state_ = std::move(st);
                  s->credentials_ = std::move(creds);
                  s->vault_keys_ = std::move(*keys);
                  s->SaveStateToDisk();
                  s->SetStatus(SyncStatusKind::kIdle, "Up to date");
                  s->StartWebSocket();
                  s->SyncNow();

                  SyncResult res;
                  res.ok = true;
                  res.recovery_key = std::move(recovery_formatted);
                  std::move(done_cb).Run(std::move(res));
                },
                self, gen, server_url, normalized, device_id, device_name,
                std::move(vk_b64), std::move(recovery_formatted),
                std::move(cb)));
      },
      weak_factory_.GetWeakPtr(), gen, *valid_url, normalized,
      std::move(trimmed_name), std::move(callback));

  if (base::ThreadPoolInstance::Get()) {
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
        std::move(derive_task), std::move(on_derived));
  } else {
    std::move(on_derived).Run(std::move(derive_task).Run());
  }
}

void SyncEngine::SignIn(const std::string& server_url,
                        const std::string& email,
                        const std::string& password,
                        std::optional<FirstSyncStrategy> initial_strategy,
                        ResultCallback callback) {
  auto valid_url = ValidateServerUrl(server_url);
  if (!valid_url) {
    std::move(callback).Run(
        {false, "INVALID_SERVER_URL", "Invalid sync server URL."});
    return;
  }
  std::string normalized = SyncCrypto::NormalizeEmail(email);
  if (!SyncCrypto::IsValidNormalizedEmail(normalized) || password.empty()) {
    std::move(callback).Run(
        {false, "INVALID_CREDENTIALS", "The email or password is incorrect."});
    return;
  }
  if (is_signed_in() || state_.has_value()) {
    ClearLocalSession(SyncStatusKind::kSignedOut);
  }
  SetStatus(SyncStatusKind::kSyncing, "Signing in...");

  uint64_t gen = session_generation_;
  base::DictValue kdf_req;
  kdf_req.Set("email", normalized);
  SendJson(
      "POST", *valid_url + "/v1/auth/kdf-params", std::move(kdf_req),
      std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen,
             std::string server_url, std::string email, std::string password,
             std::optional<FirstSyncStrategy> initial_strategy,
             ResultCallback cb, SyncHttpResponse resp) {
            if (!self) {
              SyncCrypto::SecureZero(password);
              return;
            }
            if (self->session_generation_ != gen) {
              SyncCrypto::SecureZero(password);
              std::move(cb).Run({false, "CANCELLED", "Sign-in cancelled."});
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              SyncCrypto::SecureZero(password);
              auto [code, msg] = ParseServerError(resp);
              self->SetStatus(SyncStatusKind::kSignedOut);
              std::move(cb).Run({false, code, msg});
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            const auto* kp = dict ? dict->FindDict("kdfParams") : nullptr;
            SyncKdfParams params;
            if (!kp || !kp->FindString("algorithm") ||
                !kp->FindInt("iterations") || !kp->FindString("saltBase64")) {
              SyncCrypto::SecureZero(password);
              self->SetStatus(SyncStatusKind::kSignedOut);
              std::move(cb).Run(
                  {false, "DECODING", "Malformed kdfParams response."});
              return;
            }
            params.algorithm = *kp->FindString("algorithm");
            params.iterations = *kp->FindInt("iterations");
            params.salt_base64 = *kp->FindString("saltBase64");

            auto derive_task = base::BindOnce(
                [](std::string mail, std::string pw,
                   SyncKdfParams kdf_params)
                    -> std::optional<SyncDerivedPasswordKeys> {
                  auto derived =
                      SyncCrypto::DerivePasswordKeys(mail, pw, kdf_params);
                  SyncCrypto::SecureZero(pw);
                  return derived;
                },
                email, std::move(password), std::move(params));

            auto on_derived = base::BindOnce(
                [](base::WeakPtr<SyncEngine> s, uint64_t expected_gen,
                   std::string server_url, std::string email,
                   std::optional<FirstSyncStrategy> initial_strategy,
                   ResultCallback cb,
                   std::optional<SyncDerivedPasswordKeys> derived) {
                  if (!s) {
                    return;
                  }
                  if (s->session_generation_ != expected_gen) {
                    std::move(cb).Run(
                        {false, "CANCELLED", "Sign-in cancelled."});
                    return;
                  }
                  if (!derived) {
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(cb).Run(
                        {false, "CRYPTO", "Password key derivation failed."});
                    return;
                  }

                  std::string device_id = GenerateUuidLower();
                  std::string device_name = TruncateUtf8Bytes(
                      OpenPlatform::Get()->GetDeviceName(),
                      kSyncMaxDeviceNameLength);
                  base::DictValue login_body;
                  login_body.Set("email", email);
                  login_body.Set("authVerifier",
                                 base::Base64Encode(derived->auth_verifier));
                  login_body.Set("deviceId", device_id);
                  login_body.Set("deviceName", device_name);
                  login_body.Set("platform",
                                 OpenPlatform::Get()->GetSyncPlatformName());

                  std::vector<uint8_t> wrap_key =
                      std::move(derived->password_wrap_key);
                  s->SendJson(
                      "POST", server_url + "/v1/auth/login",
                      std::move(login_body), std::nullopt,
                      base::BindOnce(
                          [](base::WeakPtr<SyncEngine> eng,
                             uint64_t expected_gen, std::string url,
                             std::string mail, std::string dev_id,
                             std::string dev_name,
                             std::vector<uint8_t> wrap_key,
                             std::optional<FirstSyncStrategy> strategy,
                             ResultCallback done_cb,
                             SyncHttpResponse login_resp) {
                            if (!eng) {
                              SyncCrypto::SecureZero(wrap_key);
                              return;
                            }
                            if (eng->session_generation_ != expected_gen) {
                              SyncCrypto::SecureZero(wrap_key);
                              std::move(done_cb).Run(
                                  {false, "CANCELLED", "Sign-in cancelled."});
                              return;
                            }
                            if (login_resp.status_code < 200 ||
                                login_resp.status_code >= 300) {
                              SyncCrypto::SecureZero(wrap_key);
                              auto [code, msg] = ParseServerError(login_resp);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run({false, code, msg});
                              return;
                            }
                            std::string_view lsv(
                                reinterpret_cast<const char*>(
                                    login_resp.body.data()),
                                login_resp.body.size());
                            auto ld = base::JSONReader::ReadDict(
                                lsv, base::JSON_PARSE_RFC);
                            if (!ld || !ld->FindString("accountId") ||
                                !ld->FindString("accessToken") ||
                                !ld->FindString("refreshToken") ||
                                !ld->FindString("wrappedVaultKeyByPassword")) {
                              SyncCrypto::SecureZero(wrap_key);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run(
                                  {false, "DECODING",
                                   "Malformed login response."});
                              return;
                            }
                            auto wrapped = base::Base64Decode(
                                *ld->FindString("wrappedVaultKeyByPassword"));
                            auto vk =
                                wrapped ? SyncCrypto::UnwrapVaultKey(
                                              *wrapped, wrap_key,
                                              SyncVaultWrapKind::kPassword,
                                              mail)
                                        : std::nullopt;
                            SyncCrypto::SecureZero(wrap_key);
                            if (!vk) {
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run(
                                  {false, "INVALID_CREDENTIALS",
                                   "Could not decrypt vault key."});
                              return;
                            }
                            auto keys = SyncVaultKeys::DeriveFromVaultKey(*vk);
                            std::string vk_b64 = base::Base64Encode(*vk);
                            SyncCrypto::SecureZero(*vk);
                            if (!keys) {
                              SyncCrypto::SecureZero(vk_b64);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run(
                                  {false, "CRYPTO",
                                   "Vault key derivation failed."});
                              return;
                            }

                            SyncCloudSummary summary;
                            summary.server_revision =
                                ld->FindInt("serverRevision").value_or(0);
                            summary.reset_revision =
                                ld->FindInt("resetRevision").value_or(0);
                            summary.has_cloud_data =
                                ld->FindBool("hasCloudData").value_or(false);
                            if (const auto* cc =
                                    ld->FindDict("collectionCounts")) {
                              for (const auto [k, v] : *cc) {
                                if (v.is_int())
                                  summary.collection_counts[k] = v.GetInt();
                              }
                            }

                            SyncCredentials creds;
                            creds.tokens.access_token =
                                *ld->FindString("accessToken");
                            creds.tokens.refresh_token =
                                *ld->FindString("refreshToken");
                            creds.tokens.access_token_expires_at_ms =
                                static_cast<int64_t>(
                                    ld->FindDouble("accessTokenExpiresAt")
                                        .value_or(0.0));
                            creds.vault_key_base64 = std::move(vk_b64);
                            WipeDictString(*ld, "accessToken");
                            WipeDictString(*ld, "refreshToken");
                            eng->SaveCredentialsToStore(creds);

                            SyncPersistedState st;
                            st.server_url = url;
                            st.account_id = *ld->FindString("accountId");
                            st.email = ld->FindString("email")
                                           ? *ld->FindString("email")
                                           : mail;
                            if (const auto* dn = ld->FindString("displayName");
                                dn && !dn->empty()) {
                              st.display_name = *dn;
                            }
                            st.device_id = dev_id;
                            st.device_name = dev_name;
                            st.last_reset_revision = summary.reset_revision;
                            st.categories = eng->snapshot_.categories;
                            if (summary.has_cloud_data) {
                              st.awaiting_initial_choice = summary;
                            }

                            ++eng->session_generation_;
                            eng->state_ = std::move(st);
                            eng->credentials_ = std::move(creds);
                            eng->vault_keys_ = std::move(*keys);
                            eng->SaveStateToDisk();

                            if (!summary.has_cloud_data) {
                              eng->SetStatus(SyncStatusKind::kIdle,
                                             "Up to date");
                              eng->StartWebSocket();
                              eng->SyncNow();
                              std::move(done_cb).Run({true});
                            } else if (strategy) {
                              eng->CompleteInitialSync(*strategy,
                                                       std::move(done_cb));
                            } else {
                              eng->SetStatus(
                                  SyncStatusKind::kAwaitingInitialChoice,
                                  "Choose how to sync this device.");
                              SyncResult res;
                              res.ok = true;
                              res.needs_initial_choice = summary;
                              std::move(done_cb).Run(std::move(res));
                            }
                          },
                          s, expected_gen, server_url, email, device_id,
                          device_name, std::move(wrap_key), initial_strategy,
                          std::move(cb)));
                },
                self, gen, server_url, email, initial_strategy, std::move(cb));

            if (base::ThreadPoolInstance::Get()) {
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
                  std::move(derive_task), std::move(on_derived));
            } else {
              std::move(on_derived).Run(std::move(derive_task).Run());
            }
          },
          weak_factory_.GetWeakPtr(), gen, *valid_url, normalized, password,
          initial_strategy, std::move(callback)));
}

void SyncEngine::RecoverAccount(
    const std::string& server_url,
    const std::string& email,
    const std::string& recovery_key,
    const std::string& new_password,
    std::optional<FirstSyncStrategy> initial_strategy,
    ResultCallback callback) {
  auto valid_url = ValidateServerUrl(server_url);
  if (!valid_url) {
    std::move(callback).Run(
        {false, "INVALID_SERVER_URL", "Invalid sync server URL."});
    return;
  }
  std::string normalized = SyncCrypto::NormalizeEmail(email);
  if (!SyncCrypto::IsValidNormalizedEmail(normalized)) {
    std::move(callback).Run({false, "INVALID_EMAIL", "Enter a valid email."});
    return;
  }
  if (new_password.size() < kSyncMinPasswordLength) {
    std::move(callback).Run(
        {false, "WEAK_PASSWORD", "Password must be at least 8 characters."});
    return;
  }
  auto rec_bytes = SyncCrypto::ParseRecoveryKey(recovery_key);
  if (!rec_bytes) {
    std::move(callback).Run(
        {false, "INVALID_RECOVERY_KEY", "Invalid recovery key."});
    return;
  }
  auto old_rec_keys = SyncCrypto::DeriveRecoveryKeys(*rec_bytes);
  SyncCrypto::SecureZero(*rec_bytes);
  if (!old_rec_keys) {
    std::move(callback).Run(
        {false, "INVALID_RECOVERY_KEY", "Invalid recovery key."});
    return;
  }
  if (is_signed_in() || state_.has_value()) {
    ClearLocalSession(SyncStatusKind::kSignedOut);
  }
  SetStatus(SyncStatusKind::kSyncing, "Recovering your account...");

  uint64_t gen = session_generation_;
  base::DictValue chal_body;
  chal_body.Set("email", normalized);
  chal_body.Set("recoveryAuthVerifier",
                base::Base64Encode(old_rec_keys->recovery_auth_verifier));
  std::vector<uint8_t> old_wrap_key =
      std::move(old_rec_keys->recovery_wrap_key);

  SendJson(
      "POST", *valid_url + "/v1/auth/recovery-challenge", std::move(chal_body),
      std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen,
             std::string server_url, std::string email,
             std::string new_password, std::vector<uint8_t> old_wrap_key,
             std::optional<FirstSyncStrategy> strategy, ResultCallback cb,
             SyncHttpResponse resp) {
            if (!self) {
              SyncCrypto::SecureZero(new_password);
              SyncCrypto::SecureZero(old_wrap_key);
              return;
            }
            if (self->session_generation_ != gen) {
              SyncCrypto::SecureZero(new_password);
              SyncCrypto::SecureZero(old_wrap_key);
              std::move(cb).Run({false, "CANCELLED", "Recovery cancelled."});
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              SyncCrypto::SecureZero(new_password);
              SyncCrypto::SecureZero(old_wrap_key);
              auto [code, msg] = ParseServerError(resp);
              self->SetStatus(SyncStatusKind::kSignedOut);
              std::move(cb).Run({false, code, msg});
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            if (!dict || !dict->FindString("accountId") ||
                !dict->FindString("wrappedVaultKeyByRecovery") ||
                !dict->FindString("recoveryTicket")) {
              SyncCrypto::SecureZero(new_password);
              SyncCrypto::SecureZero(old_wrap_key);
              self->SetStatus(SyncStatusKind::kSignedOut);
              std::move(cb).Run(
                  {false, "DECODING", "Malformed recovery challenge."});
              return;
            }

            auto wrapped = base::Base64Decode(
                *dict->FindString("wrappedVaultKeyByRecovery"));
            auto vault_key = wrapped ? SyncCrypto::UnwrapVaultKey(
                                           *wrapped, old_wrap_key,
                                           SyncVaultWrapKind::kRecovery, email)
                                     : std::nullopt;
            SyncCrypto::SecureZero(old_wrap_key);
            if (!vault_key) {
              SyncCrypto::SecureZero(new_password);
              self->SetStatus(SyncStatusKind::kSignedOut);
              std::move(cb).Run(
                  {false, "INVALID_RECOVERY_KEY", "Recovery key failed."});
              return;
            }

            std::string recovery_ticket = *dict->FindString("recoveryTicket");
            auto derive_task = base::BindOnce(
                [](std::string mail, std::string pw) -> RecoverDerivedMaterial {
                  RecoverDerivedMaterial mat;
                  mat.new_kdf = SyncKdfParams::Generate();
                  mat.new_rec = SyncCrypto::GenerateRecoveryKey();
                  if (mat.new_kdf) {
                    mat.new_pw_keys =
                        SyncCrypto::DerivePasswordKeys(mail, pw, *mat.new_kdf);
                  }
                  SyncCrypto::SecureZero(pw);
                  if (mat.new_rec) {
                    mat.new_rec_keys =
                        SyncCrypto::DeriveRecoveryKeys(mat.new_rec->raw_bytes);
                  }
                  return mat;
                },
                email, std::move(new_password));

            auto on_derived = base::BindOnce(
                [](base::WeakPtr<SyncEngine> s, uint64_t expected_gen,
                   std::string server_url, std::string email,
                   std::string recovery_ticket, std::vector<uint8_t> vault_key,
                   std::optional<FirstSyncStrategy> strategy, ResultCallback cb,
                   RecoverDerivedMaterial mat) {
                  if (!s) {
                    SyncCrypto::SecureZero(vault_key);
                    return;
                  }
                  if (s->session_generation_ != expected_gen) {
                    SyncCrypto::SecureZero(vault_key);
                    std::move(cb).Run(
                        {false, "CANCELLED", "Recovery cancelled."});
                    return;
                  }
                  if (!mat.new_kdf || !mat.new_rec || !mat.new_pw_keys ||
                      !mat.new_rec_keys) {
                    SyncCrypto::SecureZero(vault_key);
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(cb).Run(
                        {false, "CRYPTO", "Recovery re-wrap failed."});
                    return;
                  }
                  auto new_wrapped_pw = SyncCrypto::WrapVaultKey(
                      vault_key, mat.new_pw_keys->password_wrap_key,
                      SyncVaultWrapKind::kPassword, email);
                  auto new_wrapped_rec = SyncCrypto::WrapVaultKey(
                      vault_key, mat.new_rec_keys->recovery_wrap_key,
                      SyncVaultWrapKind::kRecovery, email);
                  std::string vk_b64 = base::Base64Encode(vault_key);
                  SyncCrypto::SecureZero(vault_key);
                  if (!new_wrapped_pw || !new_wrapped_rec) {
                    SyncCrypto::SecureZero(vk_b64);
                    s->SetStatus(SyncStatusKind::kSignedOut);
                    std::move(cb).Run(
                        {false, "CRYPTO", "Vault wrapping failed."});
                    return;
                  }

                  std::string device_id = GenerateUuidLower();
                  std::string device_name = TruncateUtf8Bytes(
                      OpenPlatform::Get()->GetDeviceName(),
                      kSyncMaxDeviceNameLength);
                  base::DictValue kdf_d;
                  kdf_d.Set("algorithm", mat.new_kdf->algorithm);
                  kdf_d.Set("iterations", mat.new_kdf->iterations);
                  kdf_d.Set("saltBase64", mat.new_kdf->salt_base64);

                  base::DictValue rec_body;
                  rec_body.Set("email", email);
                  rec_body.Set("recoveryTicket", recovery_ticket);
                  rec_body.Set("newKdfParams", std::move(kdf_d));
                  rec_body.Set(
                      "newAuthVerifier",
                      base::Base64Encode(mat.new_pw_keys->auth_verifier));
                  rec_body.Set("newRecoveryAuthVerifier",
                               base::Base64Encode(
                                   mat.new_rec_keys->recovery_auth_verifier));
                  rec_body.Set("newWrappedVaultKeyByPassword",
                               base::Base64Encode(*new_wrapped_pw));
                  rec_body.Set("newWrappedVaultKeyByRecovery",
                               base::Base64Encode(*new_wrapped_rec));
                  rec_body.Set("deviceId", device_id);
                  rec_body.Set("deviceName", device_name);
                  rec_body.Set("platform",
                               OpenPlatform::Get()->GetSyncPlatformName());

                  std::string new_rec_formatted = mat.new_rec->formatted;
                  s->SendJson(
                      "POST", server_url + "/v1/auth/recover",
                      std::move(rec_body), std::nullopt,
                      base::BindOnce(
                          [](base::WeakPtr<SyncEngine> eng,
                             uint64_t expected_gen, std::string url,
                             std::string mail, std::string dev_id,
                             std::string dev_name, std::string vk_b64,
                             std::string new_rec_fmt,
                             std::optional<FirstSyncStrategy> strat,
                             ResultCallback done_cb, SyncHttpResponse r) {
                            if (!eng) {
                              SyncCrypto::SecureZero(vk_b64);
                              SyncCrypto::SecureZero(new_rec_fmt);
                              return;
                            }
                            if (eng->session_generation_ != expected_gen) {
                              SyncCrypto::SecureZero(vk_b64);
                              SyncCrypto::SecureZero(new_rec_fmt);
                              std::move(done_cb).Run(
                                  {false, "CANCELLED", "Recovery cancelled."});
                              return;
                            }
                            if (r.status_code < 200 || r.status_code >= 300) {
                              SyncCrypto::SecureZero(vk_b64);
                              SyncCrypto::SecureZero(new_rec_fmt);
                              auto [code, msg] = ParseServerError(r);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run({false, code, msg});
                              return;
                            }
                            std::string_view rsv(
                                reinterpret_cast<const char*>(r.body.data()),
                                r.body.size());
                            auto rd = base::JSONReader::ReadDict(
                                rsv, base::JSON_PARSE_RFC);
                            if (!rd || !rd->FindString("accountId") ||
                                !rd->FindString("accessToken") ||
                                !rd->FindString("refreshToken")) {
                              SyncCrypto::SecureZero(vk_b64);
                              SyncCrypto::SecureZero(new_rec_fmt);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run(
                                  {false, "DECODING",
                                   "Malformed recover response."});
                              return;
                            }
                            auto raw_vk = base::Base64Decode(vk_b64);
                            auto keys =
                                raw_vk ? SyncVaultKeys::DeriveFromVaultKey(
                                             *raw_vk)
                                       : std::nullopt;
                            if (raw_vk) SyncCrypto::SecureZero(*raw_vk);
                            if (!keys) {
                              SyncCrypto::SecureZero(vk_b64);
                              SyncCrypto::SecureZero(new_rec_fmt);
                              eng->SetStatus(SyncStatusKind::kSignedOut);
                              std::move(done_cb).Run(
                                  {false, "CRYPTO",
                                   "Vault key derivation failed."});
                              return;
                            }

                            SyncCloudSummary summary;
                            summary.server_revision =
                                rd->FindInt("serverRevision").value_or(0);
                            summary.reset_revision =
                                rd->FindInt("resetRevision").value_or(0);
                            summary.has_cloud_data =
                                rd->FindBool("hasCloudData").value_or(false);
                            if (const auto* cc =
                                    rd->FindDict("collectionCounts")) {
                              for (const auto [k, v] : *cc) {
                                if (v.is_int())
                                  summary.collection_counts[k] = v.GetInt();
                              }
                            }

                            SyncCredentials creds;
                            creds.tokens.access_token =
                                *rd->FindString("accessToken");
                            creds.tokens.refresh_token =
                                *rd->FindString("refreshToken");
                            creds.tokens.access_token_expires_at_ms =
                                static_cast<int64_t>(
                                    rd->FindDouble("accessTokenExpiresAt")
                                        .value_or(0.0));
                            creds.vault_key_base64 = std::move(vk_b64);
                            WipeDictString(*rd, "accessToken");
                            WipeDictString(*rd, "refreshToken");
                            eng->SaveCredentialsToStore(creds);

                            SyncPersistedState st;
                            st.server_url = url;
                            st.account_id = *rd->FindString("accountId");
                            st.email = mail;
                            st.device_id = dev_id;
                            st.device_name = dev_name;
                            st.last_reset_revision = summary.reset_revision;
                            st.categories = eng->snapshot_.categories;
                            if (summary.has_cloud_data) {
                              st.awaiting_initial_choice = summary;
                            }

                            ++eng->session_generation_;
                            eng->state_ = std::move(st);
                            eng->credentials_ = std::move(creds);
                            eng->vault_keys_ = std::move(*keys);
                            eng->SaveStateToDisk();

                            SyncResult res;
                            res.ok = true;
                            res.recovery_key = std::move(new_rec_fmt);
                            if (!summary.has_cloud_data) {
                              eng->SetStatus(SyncStatusKind::kIdle,
                                             "Up to date");
                              eng->StartWebSocket();
                              eng->SyncNow();
                              std::move(done_cb).Run(std::move(res));
                            } else if (strat) {
                              eng->CompleteInitialSync(
                                  *strat,
                                  base::BindOnce(
                                      [](std::string rk,
                                         ResultCallback final_cb,
                                         SyncResult init_res) {
                                        init_res.recovery_key = std::move(rk);
                                        std::move(final_cb).Run(
                                            std::move(init_res));
                                      },
                                      res.recovery_key, std::move(done_cb)));
                            } else {
                              eng->SetStatus(
                                  SyncStatusKind::kAwaitingInitialChoice,
                                  "Choose how to sync this device.");
                              res.needs_initial_choice = summary;
                              std::move(done_cb).Run(std::move(res));
                            }
                          },
                          s, expected_gen, server_url, email, device_id,
                          device_name, std::move(vk_b64),
                          std::move(new_rec_formatted), strategy,
                          std::move(cb)));
                },
                self, gen, server_url, email, std::move(recovery_ticket),
                std::move(*vault_key), strategy, std::move(cb));

            if (base::ThreadPoolInstance::Get()) {
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
                  std::move(derive_task), std::move(on_derived));
            } else {
              std::move(on_derived).Run(std::move(derive_task).Run());
            }
          },
          weak_factory_.GetWeakPtr(), gen, *valid_url, normalized, new_password,
          std::move(old_wrap_key), initial_strategy, std::move(callback)));
}

void SyncEngine::CompleteInitialSync(FirstSyncStrategy strategy,
                                     ResultCallback callback) {
  if (!is_signed_in()) {
    std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    return;
  }
  pending_sync_callbacks_.push_back(std::move(callback));
  if (sync_in_flight_) {
    follow_up_sync_requested_ = true;
    return;
  }
  sync_in_flight_ = true;
  PublishSnapshot();
  StartSyncPass(/*round=*/0, strategy);
}

void SyncEngine::ChangePassword(const std::string& current_password,
                                const std::string& new_password,
                                bool revoke_other_sessions,
                                ResultCallback callback) {
  if (!is_signed_in() || !state_->email || !credentials_) {
    std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    return;
  }
  if (new_password.size() < kSyncMinPasswordLength) {
    std::move(callback).Run(
        {false, "WEAK_PASSWORD", "Password must be at least 8 characters."});
    return;
  }
  uint64_t gen = session_generation_;
  std::string email = *state_->email;
  base::DictValue kdf_req;
  kdf_req.Set("email", email);
  SendJson(
      "POST", state_->server_url + "/v1/auth/kdf-params", std::move(kdf_req),
      std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen, std::string email,
             std::string cur_pw, std::string new_pw, bool revoke_others,
             ResultCallback cb, SyncHttpResponse resp) {
            if (!self) {
              SyncCrypto::SecureZero(cur_pw);
              SyncCrypto::SecureZero(new_pw);
              return;
            }
            if (self->session_generation_ != gen || !self->credentials_) {
              SyncCrypto::SecureZero(cur_pw);
              SyncCrypto::SecureZero(new_pw);
              std::move(cb).Run(
                  {false, "CANCELLED", "Password change cancelled."});
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              SyncCrypto::SecureZero(cur_pw);
              SyncCrypto::SecureZero(new_pw);
              auto [c, m] = ParseServerError(resp);
              std::move(cb).Run({false, c, m});
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            const auto* kp = dict ? dict->FindDict("kdfParams") : nullptr;
            SyncKdfParams cur_kdf;
            if (!kp || !kp->FindString("algorithm") ||
                !kp->FindInt("iterations") || !kp->FindString("saltBase64")) {
              SyncCrypto::SecureZero(cur_pw);
              SyncCrypto::SecureZero(new_pw);
              std::move(cb).Run({false, "DECODING", "Malformed kdfParams."});
              return;
            }
            cur_kdf.algorithm = *kp->FindString("algorithm");
            cur_kdf.iterations = *kp->FindInt("iterations");
            cur_kdf.salt_base64 = *kp->FindString("saltBase64");

            auto new_kdf = SyncKdfParams::Generate();
            if (!new_kdf) {
              SyncCrypto::SecureZero(cur_pw);
              SyncCrypto::SecureZero(new_pw);
              std::move(cb).Run({false, "CRYPTO", "KDF generation failed."});
              return;
            }

            auto derive_task = base::BindOnce(
                [](std::string mail, std::string cpw, SyncKdfParams ckdf,
                   std::string npw,
                   SyncKdfParams nkdf) -> ChangePasswordDerivedKeys {
                  ChangePasswordDerivedKeys out;
                  out.current_keys =
                      SyncCrypto::DerivePasswordKeys(mail, cpw, ckdf);
                  out.new_keys = SyncCrypto::DerivePasswordKeys(mail, npw, nkdf);
                  SyncCrypto::SecureZero(cpw);
                  SyncCrypto::SecureZero(npw);
                  return out;
                },
                email, std::move(cur_pw), std::move(cur_kdf), std::move(new_pw),
                *new_kdf);

            auto on_derived = base::BindOnce(
                [](base::WeakPtr<SyncEngine> s, uint64_t expected_gen,
                   std::string email, SyncKdfParams new_kdf, bool revoke_others,
                   ResultCallback cb, ChangePasswordDerivedKeys derived) {
                  if (!s) {
                    return;
                  }
                  if (s->session_generation_ != expected_gen ||
                      !s->credentials_) {
                    std::move(cb).Run(
                        {false, "CANCELLED", "Password change cancelled."});
                    return;
                  }
                  auto vk =
                      base::Base64Decode(s->credentials_->vault_key_base64);
                  auto wrapped =
                      (vk && derived.new_keys)
                          ? SyncCrypto::WrapVaultKey(
                                *vk, derived.new_keys->password_wrap_key,
                                SyncVaultWrapKind::kPassword, email)
                          : std::nullopt;
                  if (vk) SyncCrypto::SecureZero(*vk);
                  if (!derived.current_keys || !derived.new_keys || !wrapped) {
                    std::move(cb).Run(
                        {false, "CRYPTO", "Key derivation failed."});
                    return;
                  }

                  base::DictValue nk;
                  nk.Set("algorithm", new_kdf.algorithm);
                  nk.Set("iterations", new_kdf.iterations);
                  nk.Set("saltBase64", new_kdf.salt_base64);

                  base::DictValue body;
                  body.Set("currentAuthVerifier",
                           base::Base64Encode(
                               derived.current_keys->auth_verifier));
                  body.Set("newKdfParams", std::move(nk));
                  body.Set(
                      "newAuthVerifier",
                      base::Base64Encode(derived.new_keys->auth_verifier));
                  body.Set("newWrappedVaultKeyByPassword",
                           base::Base64Encode(*wrapped));
                  body.Set("revokeOtherSessions", revoke_others);

                  s->SendAuthenticatedJson(
                      "POST", "/v1/auth/change-password", std::move(body),
                      base::BindOnce(
                          [](ResultCallback done, SyncHttpResponse r) {
                            if (r.status_code >= 200 && r.status_code < 300) {
                              std::move(done).Run({true});
                            } else {
                              auto [c, m] = ParseServerError(r);
                              std::move(done).Run({false, c, m});
                            }
                          },
                          std::move(cb)));
                },
                self, gen, email, std::move(*new_kdf), revoke_others,
                std::move(cb));

            if (base::ThreadPoolInstance::Get()) {
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
                  std::move(derive_task), std::move(on_derived));
            } else {
              std::move(on_derived).Run(std::move(derive_task).Run());
            }
          },
          weak_factory_.GetWeakPtr(), gen, email, current_password,
          new_password, revoke_other_sessions, std::move(callback)));
}

void SyncEngine::UpdateDisplayName(const std::string& display_name,
                                   ResultCallback callback) {
  if (!is_signed_in()) {
    std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    return;
  }
  std::string trimmed = TruncateUtf8Bytes(
      base::TrimWhitespaceASCII(display_name, base::TRIM_ALL),
      kSyncMaxDisplayNameLength);
  base::DictValue body;
  body.Set("displayName", trimmed);
  SendAuthenticatedJson(
      "PATCH", "/v1/account", std::move(body),
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, std::string name,
             ResultCallback cb, SyncHttpResponse resp) {
            if (!self) return;
            if (resp.status_code >= 200 && resp.status_code < 300) {
              if (self->state_) {
                self->state_->display_name = name;
                self->SaveStateToDisk();
              }
              self->PublishSnapshot();
              std::move(cb).Run({true});
            } else {
              auto [c, m] = ParseServerError(resp);
              std::move(cb).Run({false, c, m});
            }
          },
          weak_factory_.GetWeakPtr(), trimmed, std::move(callback)));
}

void SyncEngine::RefreshDevices(DevicesCallback callback) {
  if (!is_signed_in()) {
    std::move(callback).Run(false, {}, "Not signed in.");
    return;
  }
  SendAuthenticatedJson(
      "GET", "/v1/account", std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, DevicesCallback cb,
             SyncHttpResponse resp) {
            if (!self) return;
            if (resp.status_code < 200 || resp.status_code >= 300) {
              auto [c, m] = ParseServerError(resp);
              std::move(cb).Run(false, {}, m);
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            if (!dict) {
              std::move(cb).Run(false, {}, "Malformed account response.");
              return;
            }
            std::vector<SyncDeviceInfo> list;
            if (const auto* devs = dict->FindList("devices")) {
              for (const auto& dv : *devs) {
                const auto* dd = dv.GetIfDict();
                if (!dd) continue;
                SyncDeviceInfo info;
                if (const auto* s = dd->FindString("deviceId"))
                  info.device_id = *s;
                if (const auto* s = dd->FindString("deviceName"))
                  info.device_name = *s;
                if (const auto* s = dd->FindString("platform"))
                  info.platform = *s;
                if (auto ts = dd->FindDouble("lastSeenAt")) {
                  info.last_seen_at_ms = static_cast<int64_t>(*ts);
                }
                info.is_current = dd->FindBool("isCurrent").value_or(
                    self->state_ && info.device_id == self->state_->device_id);
                list.push_back(std::move(info));
              }
            }
            std::sort(list.begin(), list.end(),
                      [](const SyncDeviceInfo& a, const SyncDeviceInfo& b) {
                        if (a.is_current != b.is_current) return a.is_current;
                        return a.device_name < b.device_name;
                      });
            self->devices_ = list;
            self->PublishSnapshot();
            std::move(cb).Run(true, std::move(list), "");
          },
          weak_factory_.GetWeakPtr(), std::move(callback)));
}

void SyncEngine::RevokeDevice(const std::string& device_id,
                              ResultCallback callback) {
  if (!is_signed_in()) {
    std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    return;
  }
  if (state_ && device_id == state_->device_id) {
    SignOut(base::BindOnce(std::move(callback), SyncResult{true}));
    return;
  }
  SendAuthenticatedJson(
      "DELETE", "/v1/account/devices/" + device_id, std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, std::string target_id,
             ResultCallback cb, SyncHttpResponse resp) {
            if (!self) return;
            if (resp.status_code >= 200 && resp.status_code < 300) {
              std::erase_if(self->devices_, [&](const SyncDeviceInfo& d) {
                return d.device_id == target_id;
              });
              self->PublishSnapshot();
              std::move(cb).Run({true});
            } else {
              auto [c, m] = ParseServerError(resp);
              std::move(cb).Run({false, c, m});
            }
          },
          weak_factory_.GetWeakPtr(), device_id, std::move(callback)));
}

void SyncEngine::SignOut(base::OnceClosure callback) {
  if (is_signed_in()) {
    SendAuthenticatedJson("POST", "/v1/auth/logout", base::DictValue(),
                          base::BindOnce([](SyncHttpResponse) {}));
  }
  last_reauth_email_.reset();
  ClearLocalSession(SyncStatusKind::kSignedOut, "Signed out");
  if (callback) {
    std::move(callback).Run();
  }
}

void SyncEngine::DeleteAccount(const std::string& password,
                               ResultCallback callback) {
  if (!is_signed_in() || !state_->email) {
    std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    return;
  }
  uint64_t gen = session_generation_;
  std::string email = *state_->email;
  base::DictValue kdf_req;
  kdf_req.Set("email", email);
  SendJson(
      "POST", state_->server_url + "/v1/auth/kdf-params", std::move(kdf_req),
      std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen, std::string email,
             std::string password, ResultCallback cb, SyncHttpResponse resp) {
            if (!self) {
              SyncCrypto::SecureZero(password);
              return;
            }
            if (self->session_generation_ != gen) {
              SyncCrypto::SecureZero(password);
              std::move(cb).Run(
                  {false, "CANCELLED", "Account deletion cancelled."});
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              SyncCrypto::SecureZero(password);
              auto [c, m] = ParseServerError(resp);
              std::move(cb).Run({false, c, m});
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            const auto* kp = dict ? dict->FindDict("kdfParams") : nullptr;
            SyncKdfParams kdf;
            if (!kp || !kp->FindString("algorithm") ||
                !kp->FindInt("iterations") || !kp->FindString("saltBase64")) {
              SyncCrypto::SecureZero(password);
              std::move(cb).Run({false, "DECODING", "Malformed kdfParams."});
              return;
            }
            kdf.algorithm = *kp->FindString("algorithm");
            kdf.iterations = *kp->FindInt("iterations");
            kdf.salt_base64 = *kp->FindString("saltBase64");

            auto derive_task = base::BindOnce(
                [](std::string mail, std::string pw,
                   SyncKdfParams kdf_params)
                    -> std::optional<SyncDerivedPasswordKeys> {
                  auto keys =
                      SyncCrypto::DerivePasswordKeys(mail, pw, kdf_params);
                  SyncCrypto::SecureZero(pw);
                  return keys;
                },
                email, std::move(password), std::move(kdf));

            auto on_derived = base::BindOnce(
                [](base::WeakPtr<SyncEngine> s, uint64_t expected_gen,
                   ResultCallback cb,
                   std::optional<SyncDerivedPasswordKeys> keys) {
                  if (!s) {
                    return;
                  }
                  if (s->session_generation_ != expected_gen) {
                    std::move(cb).Run(
                        {false, "CANCELLED", "Account deletion cancelled."});
                    return;
                  }
                  if (!keys) {
                    std::move(cb).Run(
                        {false, "CRYPTO", "Key derivation failed."});
                    return;
                  }
                  base::DictValue body;
                  body.Set("authVerifier",
                           base::Base64Encode(keys->auth_verifier));
                  s->SendAuthenticatedJson(
                      "DELETE", "/v1/account", std::move(body),
                      base::BindOnce(
                          [](base::WeakPtr<SyncEngine> eng,
                             uint64_t expected_gen, ResultCallback done,
                             SyncHttpResponse r) {
                            if (!eng) return;
                            if (eng->session_generation_ != expected_gen) {
                              std::move(done).Run(
                                  {false, "CANCELLED",
                                   "Account deletion cancelled."});
                              return;
                            }
                            if (r.status_code >= 200 && r.status_code < 300) {
                              eng->ClearLocalSession(SyncStatusKind::kSignedOut,
                                                     "Signed out");
                              std::move(done).Run({true});
                            } else {
                              auto [c, m] = ParseServerError(r);
                              std::move(done).Run({false, c, m});
                            }
                          },
                          s, expected_gen, std::move(cb)));
                },
                self, gen, std::move(cb));

            if (base::ThreadPoolInstance::Get()) {
              base::ThreadPool::PostTaskAndReplyWithResult(
                  FROM_HERE,
                  {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
                  std::move(derive_task), std::move(on_derived));
            } else {
              std::move(on_derived).Run(std::move(derive_task).Run());
            }
          },
          weak_factory_.GetWeakPtr(), gen, email, password,
          std::move(callback)));
}

void SyncEngine::SyncNow(ResultCallback callback) {
  if (status_ == SyncStatusKind::kNeedsReauth) {
    if (callback) {
      std::move(callback).Run(
          {false, "NEEDS_REAUTH", "Your session ended. Sign in again."});
    }
    return;
  }
  if (!is_signed_in() || !credentials_) {
    if (callback) {
      std::move(callback).Run({false, "NOT_SIGNED_IN", "Not signed in."});
    }
    return;
  }
  if (state_->awaiting_initial_choice) {
    if (callback) {
      std::move(callback).Run(
          {false, "AWAITING_INITIAL_CHOICE",
           "Choose how to combine local and cloud data first."});
    }
    return;
  }
  if (callback) {
    pending_sync_callbacks_.push_back(std::move(callback));
  }
  if (sync_in_flight_) {
    follow_up_sync_requested_ = true;
    return;
  }
  sync_in_flight_ = true;
  PublishSnapshot();
  StartSyncPass(/*round=*/0, std::nullopt);
}

void SyncEngine::SchedulePush(std::string_view /*reason*/) {
  if (!is_signed_in() || is_applying_remote_ ||
      state_->awaiting_initial_choice ||
      status_ == SyncStatusKind::kNeedsReauth) {
    return;
  }
  int64_t now_ms = NowEpochMs();
  if (push_burst_started_ms_ == 0) {
    push_burst_started_ms_ = now_ms;
  }
  double elapsed_sec = static_cast<double>(now_ms - push_burst_started_ms_) /
                       1000.0;
  double delay_sec =
      std::max(0.0, std::min(kPushDebounceSec, kPushMaxCoalesceSec - elapsed_sec));
  push_debounce_timer_.Start(
      FROM_HERE, base::Seconds(delay_sec),
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self) {
            if (!self) return;
            self->push_burst_started_ms_ = 0;
            self->SyncNow();
          },
          weak_factory_.GetWeakPtr()));
}

void SyncEngine::SetCategoryEnabled(SyncCategory category, bool enabled) {
  if (!state_) {
    snapshot_.categories.SetEnabled(category, enabled);
    PublishSnapshot();
    return;
  }
  state_->categories.SetEnabled(category, enabled);
  auto& bf = state_->pending_backfill_categories;
  if (enabled) {
    if (std::find(bf.begin(), bf.end(), category) == bf.end()) {
      bf.push_back(category);
    }
  } else {
    std::erase(bf, category);
  }
  SaveStateToDisk();
  PublishSnapshot();
  if (enabled) {
    SyncNow();
  }
}

void SyncEngine::ResolvePendingExtensionInstalls(
    const std::vector<std::string>& extension_ids) {
  if (!state_) return;
  std::set<std::string> resolved(extension_ids.begin(), extension_ids.end());
  std::erase_if(state_->pending_extension_installs,
                [&](const SyncPendingExtension& ext) {
                  return resolved.contains(ext.extension_id);
                });
  SaveStateToDisk();
  PublishSnapshot();
}

void SyncEngine::StopAndFlush() {
  push_debounce_timer_.Stop();
  push_burst_started_ms_ = 0;
  StopWebSocket();
  if (state_) {
    SaveStateToDisk();
  }
}

// --- Sync pass execution ---

void SyncEngine::StartSyncPass(
    int round,
    std::optional<FirstSyncStrategy> initial_strategy) {
  if (!is_signed_in() || !credentials_ || !data_adapter_) {
    FinishSyncPass(false, "NO_DATA_ADAPTER", "Sync is not ready.");
    return;
  }

  if (initial_strategy == FirstSyncStrategy::kReplaceCloudWithLocal) {
    SetStatus(SyncStatusKind::kSyncing, "Replacing cloud data...");
    SyncLocalBundle local =
        data_adapter_->CollectLocalData(state_->categories, *vault_keys_);
    state_->mirror.clear();
    state_->pending_backfill_categories.clear();
    PushLocalDiff(
        local, SyncPushMode::kReplaceCloud, /*cursor_base=*/std::nullopt,
        base::BindOnce(
            [](base::WeakPtr<SyncEngine> self, PushDiffResult result) {
              if (!self) return;
              if (result.ok && self->state_) {
                self->state_->awaiting_initial_choice.reset();
                self->state_->last_sync_at_ms = NowEpochMs();
                self->SaveStateToDisk();
                self->StartWebSocket();
              }
              self->FinishSyncPass(result.ok, result.ok ? "" : "SYNC_ERROR",
                                   result.error);
            },
            weak_factory_.GetWeakPtr()));
    return;
  }

  auto ctx = std::make_shared<SyncPassContext>();
  ctx->round = round;
  ctx->generation = session_generation_;
  ctx->initial_strategy = initial_strategy;
  ctx->categories = state_->categories;
  ctx->enabled = state_->categories.EnabledCollections();

  if (!initial_strategy) {
    for (SyncCategory cat : state_->pending_backfill_categories) {
      if (ctx->categories.IsEnabled(cat)) {
        ctx->processed_backfill.push_back(cat);
        for (SyncCollection col : SyncCollectionsForCategory(cat)) {
          ctx->backfill_collections.insert(col);
        }
      }
    }
  }

  SetStatus(SyncStatusKind::kSyncing,
            initial_strategy.has_value() ? "Downloading your cloud data..."
                                         : "Checking for changes...");
  ctx->pull_state = std::make_shared<PullPassState>();
  ctx->pull_state->start_since =
      initial_strategy.has_value() ? 0 : state_->last_pulled_revision;
  ctx->pull_state->current_since = ctx->pull_state->start_since;
  ctx->pull_state->current_revision = ctx->pull_state->start_since;
  ctx->pull_state->reset_revision = state_->last_reset_revision;

  PullAllPages(ctx->pull_state,
               base::BindOnce(&SyncEngine::OnInitialPullCompleted,
                              weak_factory_.GetWeakPtr(), ctx));
}

void SyncEngine::PullAllPages(
    std::shared_ptr<PullPassState> pull_state,
    base::OnceCallback<void(bool ok, std::string error)> on_done) {
  if (!is_signed_in()) {
    std::move(on_done).Run(false, "Not signed in.");
    return;
  }
  if (++pull_state->pages > 10000) {
    std::move(on_done).Run(false, "Too many sync change pages.");
    return;
  }

  std::string query =
      "/v1/sync/changes?since=" +
      base::NumberToString(std::max(0, pull_state->current_since)) +
      "&limit=" + base::NumberToString(kSyncMaxChangesLimit);
  if (!pull_state->filter_collections.empty()) {
    query += "&collections=";
    for (size_t i = 0; i < pull_state->filter_collections.size(); ++i) {
      if (i > 0) query += ",";
      query += SyncCollectionToString(pull_state->filter_collections[i]);
    }
  }

  uint64_t gen = session_generation_;
  SendAuthenticatedJson(
      "GET", query, std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen,
             std::shared_ptr<PullPassState> ps,
             base::OnceCallback<void(bool, std::string)> done,
             SyncHttpResponse resp) {
            if (!self || self->session_generation_ != gen || !self->state_ ||
                !self->vault_keys_) {
              std::move(done).Run(false, "Sync cancelled.");
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              auto [code, msg] = ParseServerError(resp);
              std::move(done).Run(false, msg);
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            if (!dict) {
              std::move(done).Run(false, "Malformed changes response.");
              return;
            }

            bool full_resync =
                dict->FindBool("fullResyncRequired").value_or(false);
            if (full_resync && !ps->full_resync) {
              ps->full_resync = true;
              ps->by_key.clear();
              ps->order.clear();
            }

            std::string tombstone_hash = SyncCrypto::ComputePayloadHash(
                kSyncTombstonePayload, *self->vault_keys_);
            const std::string& account_id = *self->state_->account_id;

            if (const auto* recs = dict->FindList("records")) {
              for (const auto& rv : *recs) {
                const auto* rd = rv.GetIfDict();
                if (!rd) continue;
                const auto* col_str = rd->FindString("collection");
                const auto* rec_id = rd->FindString("recordId");
                const auto* ct_b64 = rd->FindString("ciphertext");
                if (!col_str || !rec_id || !ct_b64) continue;
                auto col = SyncCollectionFromString(*col_str);
                if (!col) continue;  // Forward-compat: skip unknown collections.
                bool deleted = rd->FindBool("deleted").value_or(false);
                int rev = rd->FindInt("revision").value_or(0);
                int64_t updated_ms = static_cast<int64_t>(
                    rd->FindDouble("clientUpdatedAt").value_or(0.0));

                auto combined = base::Base64Decode(*ct_b64);
                if (!combined) {
                  ps->warnings.push_back("Skipped damaged " + *col_str +
                                         " record.");
                  continue;
                }
                auto plain = SyncCrypto::OpenRecord(
                    *combined, *self->vault_keys_, account_id, *col_str,
                    *rec_id, deleted);
                if (!plain) {
                  ps->warnings.push_back("Failed to decrypt " + *col_str +
                                         " record.");
                  continue;
                }

                SyncRemoteRecord rec;
                rec.collection = *col;
                rec.record_id = *rec_id;
                rec.deleted = deleted;
                rec.client_updated_at_ms = updated_ms;
                rec.revision = rev;
                if (const auto* dev = rd->FindString("updatedByDeviceId")) {
                  rec.updated_by_device_id = *dev;
                }
                if (deleted) {
                  rec.payload_hash = tombstone_hash;
                } else {
                  std::string json(plain->begin(), plain->end());
                  rec.payload_hash =
                      SyncCrypto::ComputePayloadHash(json, *self->vault_keys_);
                  rec.payload_json = std::move(json);
                }

                std::string key =
                    SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
                auto it = ps->by_key.find(key);
                if (it != ps->by_key.end() && it->second.revision > rec.revision) {
                  continue;
                }
                if (it == ps->by_key.end()) {
                  ps->order.push_back(key);
                }
                ps->by_key[key] = std::move(rec);
              }
            }

            ps->current_revision =
                std::max(ps->current_revision,
                         dict->FindInt("currentRevision").value_or(0));
            ps->reset_revision =
                dict->FindInt("resetRevision").value_or(ps->reset_revision);
            bool has_more = dict->FindBool("hasMore").value_or(false);
            int next_since =
                dict->FindInt("nextSince").value_or(ps->current_since);
            if (has_more) {
              if (next_since <= ps->current_since && !full_resync) {
                std::move(done).Run(false, "Server change cursor did not advance.");
                return;
              }
              ps->current_since = next_since;
              self->PullAllPages(ps, std::move(done));
              return;
            }
            std::move(done).Run(true, "");
          },
          weak_factory_.GetWeakPtr(), gen, pull_state, std::move(on_done)));
}

void SyncEngine::OnInitialPullCompleted(std::shared_ptr<SyncPassContext> ctx,
                                        bool ok,
                                        std::string error) {
  if (!ok || !is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "SYNC_PULL_FAILED",
                   error.empty() ? "Sync cancelled." : error);
    return;
  }

  // If the server resetRevision advanced since last pull, re-pull from 0.
  if (!ctx->initial_strategy && !ctx->pull_state->full_resync &&
      ctx->pull_state->reset_revision > state_->last_reset_revision &&
      state_->last_pulled_revision > 0) {
    ctx->pull_state = std::make_shared<PullPassState>();
    ctx->pull_state->start_since = 0;
    ctx->pull_state->current_since = 0;
    ctx->pull_state->full_resync = true;
    PullAllPages(ctx->pull_state,
                 base::BindOnce(&SyncEngine::OnInitialPullCompleted,
                                weak_factory_.GetWeakPtr(), ctx));
    return;
  }

  ctx->full_reset = ctx->pull_state->full_resync;
  for (const auto& w : ctx->pull_state->warnings) {
    ctx->pass_warnings.push_back(w);
  }

  // P1-2: Category backfill — pull from revision 0 filtered to newly enabled
  // collections before deciding what to push or apply.
  if (!ctx->initial_strategy && !ctx->full_reset &&
      !ctx->backfill_collections.empty()) {
    auto backfill_state = std::make_shared<PullPassState>();
    backfill_state->start_since = 0;
    backfill_state->current_since = 0;
    backfill_state->current_revision = 0;
    backfill_state->reset_revision = state_->last_reset_revision;
    backfill_state->filter_collections.assign(
        ctx->backfill_collections.begin(), ctx->backfill_collections.end());
    PullAllPages(backfill_state,
                 base::BindOnce(&SyncEngine::OnBackfillPullCompleted,
                                weak_factory_.GetWeakPtr(), ctx,
                                backfill_state));
    return;
  }

  ContinueAfterPulls(std::move(ctx));
}

void SyncEngine::OnBackfillPullCompleted(
    std::shared_ptr<SyncPassContext> ctx,
    std::shared_ptr<PullPassState> backfill_state,
    bool ok,
    std::string error) {
  if (!ok || !is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "SYNC_PULL_FAILED",
                   error.empty() ? "Sync cancelled." : error);
    return;
  }

  for (const auto& w : backfill_state->warnings) {
    ctx->pass_warnings.push_back(w);
  }

  ctx->backfill_records.clear();
  for (const auto& key : backfill_state->order) {
    auto it = backfill_state->by_key.find(key);
    if (it == backfill_state->by_key.end()) continue;
    const SyncRemoteRecord& rec = it->second;
    ctx->backfill_records.push_back(rec);

    auto existing = ctx->pull_state->by_key.find(key);
    if (existing == ctx->pull_state->by_key.end()) {
      ctx->pull_state->order.push_back(key);
      ctx->pull_state->by_key[key] = rec;
    } else if (existing->second.revision < rec.revision) {
      existing->second = rec;
    }
  }

  ContinueAfterPulls(std::move(ctx));
}

void SyncEngine::ContinueAfterPulls(std::shared_ptr<SyncPassContext> ctx) {
  if (!is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "CANCELLED", "Sync cancelled.");
    return;
  }

  // P1-1: LWW push-before-pull order (matching macOS SyncEngine.swift:840-875).
  // Collect local dirty records BEFORE applying remote changes, push dirty
  // keys first (excluding backfill collections which merge cloud first), and
  // re-pull if the server reports conflicts.
  if (!ctx->initial_strategy && !ctx->full_reset) {
    SyncLocalBundle local =
        data_adapter_->CollectLocalData(ctx->categories, *vault_keys_);
    for (const auto& w : local.warnings) {
      ctx->pass_warnings.push_back(w);
    }
    ctx->dirty_before_apply = ComputeDirtyKeys(
        local, state_->mirror, ctx->enabled, *vault_keys_);
    ctx->pre_apply_local = std::move(local);

    SyncLocalBundle first = FilterLocalBundleExcluding(
        *ctx->pre_apply_local, ctx->backfill_collections);
    std::set<std::string> early_dirty = ComputeDirtyKeys(
        first, state_->mirror, ctx->enabled, *vault_keys_);
    if (!early_dirty.empty()) {
      SetStatus(SyncStatusKind::kSyncing, "Uploading changes...");
      PushLocalDiff(first, SyncPushMode::kDelta,
                    /*cursor_base=*/ctx->pull_state->current_revision,
                    base::BindOnce(&SyncEngine::OnEarlyPushCompleted,
                                   weak_factory_.GetWeakPtr(), ctx));
      return;
    }
  }

  PrepareApplyRemote(std::move(ctx));
}

void SyncEngine::OnEarlyPushCompleted(std::shared_ptr<SyncPassContext> ctx,
                                      PushDiffResult result) {
  if (!result.ok || !is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "SYNC_PUSH_FAILED",
                   result.error.empty() ? "Sync cancelled." : result.error);
    return;
  }

  std::set<std::string> still_dirty = ComputeDirtyKeys(
      *ctx->pre_apply_local, state_->mirror, ctx->enabled, *vault_keys_);
  ctx->pushed_first.clear();
  for (const auto& key : ctx->dirty_before_apply) {
    if (!still_dirty.contains(key)) {
      ctx->pushed_first.insert(key);
    }
  }
  ctx->dirty_before_apply = std::move(still_dirty);
  ctx->cursor_after_push = result.clean_cursor;

  if (result.had_conflicts) {
    // Server holds strictly newer copies for some records; re-pull them.
    SetStatus(SyncStatusKind::kSyncing, "Checking for changes...");
    ctx->cursor_after_push.reset();
    auto repull = std::make_shared<PullPassState>();
    repull->start_since = state_->last_pulled_revision;
    repull->current_since = repull->start_since;
    repull->current_revision = repull->start_since;
    repull->reset_revision = state_->last_reset_revision;
    PullAllPages(repull,
                 base::BindOnce(&SyncEngine::OnConflictRepullCompleted,
                                weak_factory_.GetWeakPtr(), ctx, repull));
    return;
  }

  PrepareApplyRemote(std::move(ctx));
}

void SyncEngine::OnConflictRepullCompleted(
    std::shared_ptr<SyncPassContext> ctx,
    std::shared_ptr<PullPassState> repull_state,
    bool ok,
    std::string error) {
  if (!ok || !is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "SYNC_PULL_FAILED",
                   error.empty() ? "Sync cancelled." : error);
    return;
  }

  if (!repull_state->full_resync &&
      repull_state->reset_revision > state_->last_reset_revision &&
      state_->last_pulled_revision > 0) {
    auto full_repull = std::make_shared<PullPassState>();
    full_repull->start_since = 0;
    full_repull->current_since = 0;
    full_repull->full_resync = true;
    PullAllPages(full_repull,
                 base::BindOnce(&SyncEngine::OnConflictRepullCompleted,
                                weak_factory_.GetWeakPtr(), ctx, full_repull));
    return;
  }

  for (const auto& w : repull_state->warnings) {
    ctx->pass_warnings.push_back(w);
  }
  ctx->pull_state = std::move(repull_state);
  ctx->full_reset = ctx->pull_state->full_resync;

  if (!ctx->full_reset) {
    for (const auto& rec : ctx->backfill_records) {
      std::string key =
          SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
      auto existing = ctx->pull_state->by_key.find(key);
      if (existing == ctx->pull_state->by_key.end()) {
        ctx->pull_state->order.push_back(key);
        ctx->pull_state->by_key[key] = rec;
      } else if (existing->second.revision < rec.revision) {
        existing->second = rec;
      }
    }
  } else {
    ctx->pre_apply_local.reset();
    ctx->dirty_before_apply.clear();
    ctx->pushed_first.clear();
  }

  PrepareApplyRemote(std::move(ctx));
}

void SyncEngine::PrepareApplyRemote(std::shared_ptr<SyncPassContext> ctx) {
  if (!is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(false, "CANCELLED", "Sync cancelled.");
    return;
  }

  const bool replace_local =
      (ctx->initial_strategy == FirstSyncStrategy::kReplaceLocalWithCloud) ||
      ctx->full_reset;
  const bool is_initial_snapshot =
      ctx->initial_strategy == FirstSyncStrategy::kReplaceLocalWithCloud ||
      ctx->initial_strategy == FirstSyncStrategy::kMergeLocalAndCloud;

  if (is_initial_snapshot) {
    state_->mirror.clear();
  } else if (ctx->full_reset) {
    std::erase_if(state_->mirror, [&](const auto& pair) {
      auto parsed = SyncPersistedState::ParseMirrorKey(pair.first);
      return !parsed || ctx->enabled.contains(parsed->first);
    });
  }

  ctx->remote.clear();
  ctx->changed.clear();
  for (const auto& key : ctx->pull_state->order) {
    auto it = ctx->pull_state->by_key.find(key);
    if (it == ctx->pull_state->by_key.end()) continue;
    const auto& rec = it->second;
    if (!ctx->enabled.contains(rec.collection)) continue;
    // Skip keys that won the early LWW push.
    if (ctx->pushed_first.contains(key)) continue;

    ctx->remote.push_back(rec);
    if (replace_local || is_initial_snapshot) {
      if (!rec.deleted) {
        ctx->changed.push_back(rec);
      }
    } else {
      auto mit = state_->mirror.find(key);
      if (mit == state_->mirror.end() && rec.deleted) continue;
      if (mit != state_->mirror.end() &&
          mit->second.payload_hash == rec.payload_hash &&
          mit->second.deleted == rec.deleted) {
        continue;
      }
      ctx->changed.push_back(rec);
    }
  }

  if (!ctx->changed.empty()) {
    DownloadBlobsForRecords(
        ctx->changed, ctx->generation,
        base::BindOnce(&SyncEngine::ApplyAndFinishPass,
                       weak_factory_.GetWeakPtr(), ctx));
    return;
  }

  ApplyAndFinishPass(std::move(ctx), BlobDownloadResult{});
}

struct SyncEngine::BlobDownloadState {
  uint64_t generation = 0;
  std::vector<SyncRemoteRecord> records;
  std::vector<SyncedAssetRef> queue;
  size_t index = 0;
  size_t total_bytes = 0;
  BlobDownloadResult result;
  base::OnceCallback<void(BlobDownloadResult)> on_done;
};

void SyncEngine::DownloadBlobsForRecords(
    const std::vector<SyncRemoteRecord>& records,
    uint64_t generation,
    base::OnceCallback<void(BlobDownloadResult)> on_done) {
  auto st = std::make_shared<BlobDownloadState>();
  st->generation = generation;
  st->records = records;
  st->on_done = std::move(on_done);

  std::set<std::string> planned_ids;
  size_t planned_bytes = 0;
  bool any_planned_record = false;

  for (const auto& rec : records) {
    if (!SyncCollectionCarriesAssets(rec.collection) || rec.deleted ||
        !rec.payload_json) {
      continue;
    }
    auto refs = SyncCollectionCodecs::ProbeAssetRefs(*rec.payload_json);
    std::vector<SyncedAssetRef> fresh;
    std::set<std::string> fresh_ids;
    size_t fresh_bytes = 0;
    for (const auto& ref : refs) {
      if (!SyncCrypto::IsValidBlobId(ref.blob_id)) continue;
      if (planned_ids.contains(ref.blob_id) ||
          !fresh_ids.insert(ref.blob_id).second) {
        continue;
      }
      fresh.push_back(ref);
      fresh_bytes += static_cast<size_t>(std::max<int64_t>(0, ref.byte_length)) +
                     kSyncNonceBytes + kSyncGcmTagBytes;
    }
    if (fresh.empty()) continue;
    if (any_planned_record &&
        (planned_ids.size() + fresh.size() > kSyncMaxBlobsPerPass ||
         planned_bytes + fresh_bytes > kSyncMaxTotalBlobBytesPerPass)) {
      st->result.had_cap_skips = true;
      continue;
    }
    any_planned_record = true;
    for (auto& ref : fresh) {
      planned_ids.insert(ref.blob_id);
      st->queue.push_back(std::move(ref));
    }
    planned_bytes += fresh_bytes;
  }

  if (!st->queue.empty()) {
    SetStatus(SyncStatusKind::kSyncing, "Downloading attachments...");
  }
  DownloadNextBlob(std::move(st));
}

void SyncEngine::DownloadNextBlob(std::shared_ptr<BlobDownloadState> s) {
  if (!is_signed_in() || session_generation_ != s->generation || !state_ ||
      !vault_keys_) {
    s->result.ok = false;
    s->result.error = "Sync cancelled.";
    std::move(s->on_done).Run(std::move(s->result));
    return;
  }

  if (s->index >= s->queue.size() ||
      (s->index > 0 && s->total_bytes >= kSyncMaxTotalBlobBytesPerPass)) {
    if (s->index < s->queue.size()) {
      s->result.had_cap_skips = true;
    }
    for (const auto& rec : s->records) {
      if (!SyncCollectionCarriesAssets(rec.collection) || rec.deleted ||
          !rec.payload_json) {
        continue;
      }
      auto refs = SyncCollectionCodecs::ProbeAssetRefs(*rec.payload_json);
      for (const auto& ref : refs) {
        if (!SyncCrypto::IsValidBlobId(ref.blob_id)) continue;
        if (!s->result.blobs.contains(ref.blob_id)) {
          s->result.deferred_keys.insert(
              SyncPersistedState::MirrorKey(rec.collection, rec.record_id));
          break;
        }
      }
    }
    std::move(s->on_done).Run(std::move(s->result));
    return;
  }

  const SyncedAssetRef ref = s->queue[s->index];
  SendAuthenticatedBinary(
      "GET", "/v1/blobs/" + ref.blob_id, /*content_type=*/"",
      /*accept_header=*/"application/octet-stream", /*body=*/{},
      kSyncMaxBlobBytes,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self,
             std::shared_ptr<BlobDownloadState> state, SyncedAssetRef asset,
             SyncHttpResponse resp) {
            if (!self || self->session_generation_ != state->generation ||
                !self->state_ || !self->vault_keys_) {
              state->result.ok = false;
              state->result.error = "Sync cancelled.";
              std::move(state->on_done).Run(std::move(state->result));
              return;
            }
            if (resp.status_code == 401 || resp.status_code == 403) {
              auto [code, msg] = ParseServerError(resp);
              state->result.ok = false;
              state->result.error = msg;
              std::move(state->on_done).Run(std::move(state->result));
              return;
            }
            if (resp.status_code >= 200 && resp.status_code < 300) {
              state->total_bytes += resp.body.size();
              auto plain = SyncCrypto::OpenBlob(
                  resp.body, *self->vault_keys_, *self->state_->account_id,
                  asset.blob_id);
              bool verified =
                  plain.has_value() &&
                  SyncCrypto::ComputeBlobId(plain->data(), plain->size(),
                                            *self->vault_keys_) ==
                      asset.blob_id &&
                  (asset.sha256.empty() ||
                   SyncCrypto::Sha256Hex(plain->data(), plain->size()) ==
                       asset.sha256);
              if (verified) {
                state->result.blobs[asset.blob_id] = std::move(*plain);
              } else {
                state->result.warnings.push_back(
                    "Skipped " + asset.filename +
                    ": the attachment failed verification.");
              }
            } else {
              auto [code, msg] = ParseServerError(resp);
              state->result.warnings.push_back(
                  "Could not download " + asset.filename + ": " + msg);
            }
            ++state->index;
            self->DownloadNextBlob(std::move(state));
          },
          weak_factory_.GetWeakPtr(), std::move(s), ref));
}

void SyncEngine::ApplyAndFinishPass(std::shared_ptr<SyncPassContext> ctx,
                                    BlobDownloadResult blob_result) {
  if (!blob_result.ok || !is_signed_in() || !data_adapter_ ||
      session_generation_ != ctx->generation) {
    FinishSyncPass(
        false, "SYNC_BLOB_FAILED",
        blob_result.error.empty() ? "Sync cancelled." : blob_result.error);
    return;
  }

  for (const auto& w : blob_result.warnings) {
    ctx->pass_warnings.push_back(w);
  }

  // Defer records whose referenced blobs failed or were skipped by pass cap.
  if (!blob_result.deferred_keys.empty()) {
    std::erase_if(ctx->changed, [&](const SyncRemoteRecord& rec) {
      return blob_result.deferred_keys.contains(
          SyncPersistedState::MirrorKey(rec.collection, rec.record_id));
    });
  }

  const bool replace_local =
      (ctx->initial_strategy == FirstSyncStrategy::kReplaceLocalWithCloud) ||
      ctx->full_reset;

  std::set<std::string> echo_candidates;
  if (!ctx->changed.empty() || replace_local) {
    SetStatus(SyncStatusKind::kSyncing, "Applying changes...");
    if (replace_local) {
      base::FilePath backup_dir =
          BackupsDirPath().AppendASCII(base::NumberToString(NowEpochMs()));
      base::CreateDirectory(backup_dir);
      data_adapter_->PrepareLocalBackup(backup_dir);
      // Prune older backups, keeping kMaxBackups newest.
      std::vector<base::FilePath> folders;
      base::FileEnumerator enumerator(BackupsDirPath(), false,
                                      base::FileEnumerator::DIRECTORIES);
      for (base::FilePath p = enumerator.Next(); !p.empty();
           p = enumerator.Next()) {
        folders.push_back(p);
      }
      std::sort(folders.begin(), folders.end());
      while (folders.size() > static_cast<size_t>(kMaxBackups)) {
        base::DeletePathRecursively(folders.front());
        folders.erase(folders.begin());
      }
    }

    SyncRemoteBundle bundle;
    bundle.records = ctx->changed;
    bundle.blobs = std::move(blob_result.blobs);
    bundle.is_full_snapshot = replace_local || ctx->initial_strategy.has_value();

    for (const auto& [blob_id, _] : bundle.blobs) {
      state_->uploaded_blob_ids.insert(blob_id);
    }

    is_applying_remote_ = true;
    SyncApplyOutcome outcome = data_adapter_->ApplyRemoteData(
        bundle,
        replace_local ? SyncApplyMode::kReplaceLocal
                      : SyncApplyMode::kMergeOrDelta,
        ctx->categories);
    is_applying_remote_ = false;

    for (const auto& w : outcome.warnings) {
      ctx->pass_warnings.push_back(w);
    }
    for (const auto& ext : outcome.pending_extension_installs) {
      bool exists = std::any_of(
          state_->pending_extension_installs.begin(),
          state_->pending_extension_installs.end(),
          [&](const SyncPendingExtension& existing) {
            return existing.profile_id == ext.profile_id &&
                   existing.extension_id == ext.extension_id;
          });
      if (!exists) {
        state_->pending_extension_installs.push_back(ext);
      }
    }
    for (const auto& rec : ctx->changed) {
      std::string key =
          SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
      state_->mirror[key] = SyncRecordMirror{
          rec.payload_hash, rec.client_updated_at_ms, rec.deleted};
      if (!rec.deleted && !ctx->dirty_before_apply.contains(key)) {
        echo_candidates.insert(key);
      }
    }
  }

  // Record tombstones the server sent for records this device never had.
  for (const auto& rec : ctx->remote) {
    if (!rec.deleted) continue;
    std::string key =
        SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
    if (blob_result.deferred_keys.contains(key)) continue;
    if (!state_->mirror.contains(key)) {
      state_->mirror[key] = SyncRecordMirror{
          rec.payload_hash, rec.client_updated_at_ms, /*deleted=*/true};
    }
  }

  state_->last_pulled_revision =
      std::max({state_->last_pulled_revision, ctx->pull_state->current_revision,
                ctx->cursor_after_push.value_or(0)});
  state_->last_reset_revision =
      std::max(state_->last_reset_revision, ctx->pull_state->reset_revision);

  // P1-2: Clear ONLY the backfill categories that were processed in this pass.
  if (ctx->initial_strategy.has_value()) {
    state_->pending_backfill_categories.clear();
  } else if (!ctx->processed_backfill.empty()) {
    std::set<SyncCategory> done_cats(ctx->processed_backfill.begin(),
                                     ctx->processed_backfill.end());
    std::erase_if(state_->pending_backfill_categories,
                  [&](SyncCategory cat) { return done_cats.contains(cat); });
  }

  // P1-3: Re-queue deferred asset records' categories for backfill retry.
  if (!blob_result.deferred_keys.empty()) {
    for (const auto& key : blob_result.deferred_keys) {
      if (auto parsed = SyncPersistedState::ParseMirrorKey(key)) {
        SyncCategory cat = SyncCategoryForCollection(parsed->first);
        auto& bf = state_->pending_backfill_categories;
        if (std::find(bf.begin(), bf.end(), cat) == bf.end()) {
          bf.push_back(cat);
        }
      }
    }
    if (blob_result.had_cap_skips) {
      follow_up_sync_requested_ = true;
    }
    ctx->pass_warnings.push_back(
        "Some attachments are still downloading; their Easels and Notes "
        "follow in the next sync pass.");
  }

  for (const auto& w : ctx->pass_warnings) {
    warnings_.push_back(w);
  }
  SaveStateToDisk();

  // If nothing arrived and the early push covered every collection, we are done.
  if (!ctx->initial_strategy && ctx->changed.empty() &&
      ctx->pre_apply_local.has_value() && ctx->backfill_collections.empty()) {
    state_->last_sync_at_ms = NowEpochMs();
    SaveStateToDisk();
    FinishSyncPass(true, "", "");
    return;
  }

  // Collect local state to suppress echoes and push remaining local edits.
  SyncLocalBundle local =
      (ctx->changed.empty() && ctx->pre_apply_local.has_value())
          ? std::move(*ctx->pre_apply_local)
          : data_adapter_->CollectLocalData(ctx->categories, *vault_keys_);

  // Echo suppression: align mirror hashes with re-serialized local form.
  std::map<std::string, std::string> local_hashes;
  for (const auto& rec : local.records) {
    std::string key =
        SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
    local_hashes[key] =
        SyncCrypto::ComputePayloadHash(rec.payload_json, *vault_keys_);
  }
  for (const auto& key : echo_candidates) {
    auto it = state_->mirror.find(key);
    if (it == state_->mirror.end()) continue;
    auto hit = local_hashes.find(key);
    if (hit != local_hashes.end()) {
      it->second.payload_hash = hit->second;
      it->second.deleted = false;
    } else if (!it->second.deleted) {
      state_->mirror.erase(it);
    }
  }

  if (ctx->initial_strategy == FirstSyncStrategy::kReplaceLocalWithCloud) {
    state_->awaiting_initial_choice.reset();
    state_->last_sync_at_ms = NowEpochMs();
    SaveStateToDisk();
    StartWebSocket();
    FinishSyncPass(true, "", "");
    return;
  }

  SetStatus(SyncStatusKind::kSyncing, "Uploading changes...");
  PushLocalDiff(
      local, SyncPushMode::kDelta, /*cursor_base=*/std::nullopt,
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, int round,
             std::optional<FirstSyncStrategy> strategy, PushDiffResult result) {
            if (!self) return;
            if (!result.ok) {
              self->FinishSyncPass(false, "SYNC_PUSH_FAILED", result.error);
              return;
            }
            if (result.had_conflicts && round < 2) {
              if (strategy && self->state_) {
                self->state_->awaiting_initial_choice.reset();
                self->SaveStateToDisk();
              }
              // Server had newer LWW records; run another round to pull & converge.
              self->StartSyncPass(round + 1, std::nullopt);
              return;
            }
            if (self->state_) {
              if (strategy) {
                self->state_->awaiting_initial_choice.reset();
              }
              self->state_->last_sync_at_ms = NowEpochMs();
              self->SaveStateToDisk();
              if (strategy) {
                self->StartWebSocket();
              }
            }
            self->FinishSyncPass(true, "", "");
          },
          weak_factory_.GetWeakPtr(), ctx->round, ctx->initial_strategy));
}

void SyncEngine::PushLocalDiff(
    const SyncLocalBundle& local,
    SyncPushMode mode,
    std::optional<int> cursor_base,
    base::OnceCallback<void(PushDiffResult)> on_done) {
  if (!is_signed_in() || !credentials_) {
    PushDiffResult res;
    res.ok = false;
    res.error = "Not signed in.";
    std::move(on_done).Run(std::move(res));
    return;
  }

  const auto enabled = state_->categories.EnabledCollections();
  const int64_t now_ms = NowEpochMs();
  const std::string& account_id = *state_->account_id;

  std::map<std::string, std::pair<SyncLocalRecord, std::string>> local_by_key;
  for (const auto& rec : local.records) {
    if (!enabled.contains(rec.collection) ||
        !IsValidSyncRecordId(rec.record_id)) {
      continue;
    }
    std::string key =
        SyncPersistedState::MirrorKey(rec.collection, rec.record_id);
    std::string hash =
        SyncCrypto::ComputePayloadHash(rec.payload_json, *vault_keys_);
    local_by_key[key] = std::make_pair(rec, std::move(hash));
  }

  std::vector<PendingPushMutation> mutations;
  std::set<std::string> needed_blobs;
  for (const auto& [key, pair] : local_by_key) {
    const auto& [rec, hash] = pair;
    const SyncRecordMirror* known = nullptr;
    if (mode != SyncPushMode::kReplaceCloud) {
      auto it = state_->mirror.find(key);
      if (it != state_->mirror.end()) known = &it->second;
    }
    if (known && !known->deleted && known->payload_hash == hash) {
      continue;
    }
    int64_t ts = std::max(now_ms, (known ? known->client_updated_at_ms : 0) + 1);
    std::vector<uint8_t> plain(rec.payload_json.begin(), rec.payload_json.end());
    auto sealed = SyncCrypto::SealRecord(
        plain, *vault_keys_, account_id, SyncCollectionToString(rec.collection),
        rec.record_id, /*deleted=*/false);
    if (!sealed || sealed->size() > kSyncMaxRecordCiphertextBytes) {
      warnings_.push_back("Skipped oversized record " + key);
      continue;
    }
    if (SyncCollectionCarriesAssets(rec.collection)) {
      for (const auto& ref :
           SyncCollectionCodecs::ProbeAssetRefs(rec.payload_json)) {
        if (SyncCrypto::IsValidBlobId(ref.blob_id)) {
          needed_blobs.insert(ref.blob_id);
        }
      }
    }
    PendingPushMutation m;
    m.key = key;
    m.collection = rec.collection;
    m.record_id = rec.record_id;
    m.deleted = false;
    m.payload_json = rec.payload_json;
    m.payload_hash = hash;
    m.client_updated_at_ms = ts;
    m.ciphertext_base64 = base::Base64Encode(*sealed);
    mutations.push_back(std::move(m));
  }

  if (mode == SyncPushMode::kDelta) {
    std::string tombstone_hash =
        SyncCrypto::ComputePayloadHash(kSyncTombstonePayload, *vault_keys_);
    std::vector<uint8_t> tomb_bytes(
        kSyncTombstonePayload,
        kSyncTombstonePayload + std::char_traits<char>::length(
                                    kSyncTombstonePayload));
    for (const auto& [key, known] : state_->mirror) {
      if (known.deleted || local_by_key.contains(key)) continue;
      auto parsed = SyncPersistedState::ParseMirrorKey(key);
      if (!parsed || !enabled.contains(parsed->first) ||
          !local.complete_collections.contains(parsed->first)) {
        continue;
      }
      int64_t ts = std::max(now_ms, known.client_updated_at_ms + 1);
      auto sealed = SyncCrypto::SealRecord(
          tomb_bytes, *vault_keys_, account_id,
          SyncCollectionToString(parsed->first), parsed->second,
          /*deleted=*/true);
      if (!sealed) continue;
      PendingPushMutation m;
      m.key = key;
      m.collection = parsed->first;
      m.record_id = parsed->second;
      m.deleted = true;
      m.payload_json = kSyncTombstonePayload;
      m.payload_hash = tombstone_hash;
      m.client_updated_at_ms = ts;
      m.ciphertext_base64 = base::Base64Encode(*sealed);
      mutations.push_back(std::move(m));
    }
  }

  auto batches =
      std::make_shared<std::vector<std::vector<PendingPushMutation>>>();
  std::vector<PendingPushMutation> current_batch;
  size_t batch_bytes = 0;
  for (auto& m : mutations) {
    size_t sz = m.ciphertext_base64.size() + 512;
    if (!current_batch.empty() &&
        (current_batch.size() >= kSyncPushBatchSize ||
         batch_bytes + sz > kSyncPushBatchBase64Bytes)) {
      batches->push_back(std::move(current_batch));
      current_batch.clear();
      batch_bytes = 0;
    }
    batch_bytes += sz;
    current_batch.push_back(std::move(m));
  }
  if (!current_batch.empty()) {
    batches->push_back(std::move(current_batch));
  }
  if (batches->empty() && mode == SyncPushMode::kReplaceCloud) {
    batches->emplace_back();
  }
  if (batches->empty()) {
    PushDiffResult nothing;
    nothing.ok = true;
    nothing.current_revision = state_->last_pulled_revision;
    nothing.reset_revision = state_->last_reset_revision;
    nothing.clean_cursor = cursor_base.value_or(state_->last_pulled_revision);
    std::move(on_done).Run(std::move(nothing));
    return;
  }

  // P1-3: Queue unuploaded blobs referenced by dirty asset-carrying records.
  auto blob_queue = std::make_shared<std::vector<SyncLocalBlob>>();
  if (!needed_blobs.empty()) {
    std::set<std::string> known_blobs =
        (mode == SyncPushMode::kReplaceCloud) ? std::set<std::string>()
                                              : state_->uploaded_blob_ids;
    std::set<std::string> queued_ids;
    for (const auto& blob : local.blobs) {
      if (needed_blobs.contains(blob.blob_id) &&
          !known_blobs.contains(blob.blob_id) &&
          queued_ids.insert(blob.blob_id).second) {
        blob_queue->push_back(blob);
      }
    }
    for (const auto& id : needed_blobs) {
      if (!known_blobs.contains(id) && !queued_ids.contains(id)) {
        warnings_.push_back(
            "An Easel or Note references a missing attachment (" +
            id.substr(0, 8) + ").");
      }
    }
  }

  UploadBlobsAndPushBatches(std::move(blob_queue), /*blob_index=*/0,
                            session_generation_, std::move(batches), mode,
                            cursor_base, std::move(on_done));
}

void SyncEngine::UploadBlobsAndPushBatches(
    std::shared_ptr<std::vector<SyncLocalBlob>> blob_queue,
    size_t blob_index,
    uint64_t generation,
    std::shared_ptr<std::vector<std::vector<PendingPushMutation>>> batches,
    SyncPushMode mode,
    std::optional<int> cursor_base,
    base::OnceCallback<void(PushDiffResult)> on_done) {
  if (!is_signed_in() || !credentials_ || !state_ || !vault_keys_ ||
      session_generation_ != generation) {
    PushDiffResult res;
    res.ok = false;
    res.error = "Sync cancelled.";
    std::move(on_done).Run(std::move(res));
    return;
  }

  while (blob_index < blob_queue->size()) {
    const SyncLocalBlob& blob = (*blob_queue)[blob_index];
    if (!SyncCrypto::IsValidBlobId(blob.blob_id) ||
        blob.data.size() + kSyncNonceBytes + kSyncGcmTagBytes >
            kSyncMaxBlobBytes) {
      warnings_.push_back("Skipped an attachment larger than 20 MB.");
      ++blob_index;
      continue;
    }
    auto sealed = SyncCrypto::SealBlob(blob.data, *vault_keys_,
                                       *state_->account_id, blob.blob_id);
    if (!sealed || sealed->size() > kSyncMaxBlobBytes) {
      warnings_.push_back("Skipped an attachment that failed encryption.");
      ++blob_index;
      continue;
    }

    SetStatus(SyncStatusKind::kSyncing, "Uploading attachments...");
    std::string blob_id = blob.blob_id;
    SendAuthenticatedBinary(
        "PUT", "/v1/blobs/" + blob_id,
        /*content_type=*/"application/octet-stream",
        /*accept_header=*/"application/json", std::move(*sealed),
        kSyncMaxJsonResponseBytes,
        base::BindOnce(
            [](base::WeakPtr<SyncEngine> self,
               std::shared_ptr<std::vector<SyncLocalBlob>> queue,
               size_t next_index, uint64_t gen, std::string uploaded_id,
               std::shared_ptr<std::vector<std::vector<PendingPushMutation>>>
                   mut_batches,
               SyncPushMode push_mode, std::optional<int> cb_cursor,
               base::OnceCallback<void(PushDiffResult)> done,
               SyncHttpResponse resp) {
              if (!self || self->session_generation_ != gen || !self->state_) {
                PushDiffResult fail;
                fail.ok = false;
                fail.error = "Sync cancelled.";
                std::move(done).Run(std::move(fail));
                return;
              }
              if (resp.status_code == 401 || resp.status_code == 403) {
                auto [code, msg] = ParseServerError(resp);
                PushDiffResult fail;
                fail.ok = false;
                fail.error = msg;
                std::move(done).Run(std::move(fail));
                return;
              }
              if (resp.status_code >= 200 && resp.status_code < 300) {
                self->state_->uploaded_blob_ids.insert(uploaded_id);
                self->SaveStateToDisk();
              } else {
                auto [code, msg] = ParseServerError(resp);
                self->warnings_.push_back("Could not upload attachment (" +
                                          uploaded_id.substr(0, 8) +
                                          "): " + msg);
              }
              self->UploadBlobsAndPushBatches(
                  std::move(queue), next_index, gen, std::move(mut_batches),
                  push_mode, cb_cursor, std::move(done));
            },
            weak_factory_.GetWeakPtr(), std::move(blob_queue), blob_index + 1,
            generation, std::move(blob_id), std::move(batches), mode,
            cursor_base, std::move(on_done)));
    return;
  }

  std::optional<int> initial_chain =
      cursor_base.value_or(state_->last_pulled_revision);
  PushMutationBatches(std::move(batches), /*batch_index=*/0, mode, cursor_base,
                      initial_chain, /*any_conflicts=*/false,
                      state_->last_pulled_revision, state_->last_reset_revision,
                      /*total_accepted=*/0, std::move(on_done));
}

void SyncEngine::PushMutationBatches(
    std::shared_ptr<std::vector<std::vector<PendingPushMutation>>> batches,
    size_t batch_index,
    SyncPushMode mode,
    std::optional<int> cursor_base,
    std::optional<int> chain_cursor,
    bool any_conflicts,
    int last_revision,
    int last_reset_revision,
    int total_accepted,
    base::OnceCallback<void(PushDiffResult)> on_done) {
  if (!is_signed_in() || !credentials_) {
    PushDiffResult res;
    res.ok = false;
    res.had_conflicts = any_conflicts;
    res.error = "Not signed in.";
    std::move(on_done).Run(std::move(res));
    return;
  }
  if (batch_index >= batches->size()) {
    PushDiffResult res;
    res.ok = true;
    res.had_conflicts = any_conflicts;
    res.current_revision = last_revision;
    res.reset_revision = last_reset_revision;
    res.accepted_count = total_accepted;
    res.clean_cursor = chain_cursor;
    std::move(on_done).Run(std::move(res));
    return;
  }

  const auto& batch = (*batches)[batch_index];
  base::ListValue wire_muts;
  for (const auto& m : batch) {
    base::DictValue md;
    md.Set("collection", SyncCollectionToString(m.collection));
    md.Set("recordId", m.record_id);
    md.Set("deleted", m.deleted);
    md.Set("clientUpdatedAt", static_cast<double>(m.client_updated_at_ms));
    md.Set("ciphertext", m.ciphertext_base64);
    wire_muts.Append(std::move(md));
  }

  base::DictValue body;
  body.Set("deviceId", state_->device_id);
  body.Set("mode",
           mode == SyncPushMode::kReplaceCloud ? "replaceCloud" : "delta");
  body.Set("baseRevision", state_->last_pulled_revision);
  body.Set("mutations", std::move(wire_muts));

  uint64_t gen = session_generation_;
  int known_reset = state_->last_reset_revision;
  SendAuthenticatedJson(
      "POST", "/v1/sync/push", std::move(body),
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self, uint64_t gen,
             std::shared_ptr<std::vector<std::vector<PendingPushMutation>>>
                 batches,
             size_t idx, SyncPushMode used_mode, std::optional<int> cursor_base,
             std::optional<int> chain_cursor, int known_reset,
             bool prev_conflicts, int total_accepted,
             base::OnceCallback<void(PushDiffResult)> done,
             SyncHttpResponse resp) {
            if (!self || self->session_generation_ != gen || !self->state_) {
              PushDiffResult fail;
              fail.ok = false;
              fail.had_conflicts = prev_conflicts;
              fail.error = "Sync cancelled.";
              std::move(done).Run(std::move(fail));
              return;
            }
            if (resp.status_code < 200 || resp.status_code >= 300) {
              auto [c, m] = ParseServerError(resp);
              PushDiffResult fail;
              fail.ok = false;
              fail.had_conflicts = prev_conflicts;
              fail.error = m;
              std::move(done).Run(std::move(fail));
              return;
            }
            std::string_view sv(
                reinterpret_cast<const char*>(resp.body.data()),
                resp.body.size());
            auto dict = base::JSONReader::ReadDict(sv, base::JSON_PARSE_RFC);
            if (!dict) {
              PushDiffResult fail;
              fail.ok = false;
              fail.had_conflicts = prev_conflicts;
              fail.error = "Malformed push response.";
              std::move(done).Run(std::move(fail));
              return;
            }

            std::set<std::string> conflicted_keys;
            if (const auto* conflicts = dict->FindList("conflicts")) {
              for (const auto& cv : *conflicts) {
                const auto* cd = cv.GetIfDict();
                if (!cd) continue;
                const auto* col = cd->FindString("collection");
                const auto* rid = cd->FindString("recordId");
                if (col && rid) {
                  conflicted_keys.insert(*col + "|" + *rid);
                }
              }
            }

            bool has_conflicts = prev_conflicts || !conflicted_keys.empty();
            int cur_rev = dict->FindInt("currentRevision")
                              .value_or(self->state_->last_pulled_revision);
            int reset_rev = dict->FindInt("resetRevision")
                                .value_or(self->state_->last_reset_revision);
            int accepted = dict->FindInt("acceptedCount").value_or(0);

            const bool was_replace = (used_mode == SyncPushMode::kReplaceCloud);
            std::optional<int> start =
                was_replace
                    ? std::optional<int>(reset_rev)
                    : (reset_rev == known_reset ? chain_cursor : std::nullopt);
            std::optional<int> next_chain;
            if (start && conflicted_keys.empty() && cur_rev >= *start &&
                cur_rev <= *start + accepted) {
              next_chain = cur_rev;
            }

            for (const auto& m : (*batches)[idx]) {
              if (!conflicted_keys.contains(m.key)) {
                self->state_->mirror[m.key] = SyncRecordMirror{
                    m.payload_hash, m.client_updated_at_ms, m.deleted};
              }
            }
            if (!cursor_base.has_value()) {
              if (was_replace) {
                self->state_->last_reset_revision = reset_rev;
                self->state_->last_pulled_revision =
                    next_chain.value_or(reset_rev);
              } else if (next_chain.has_value()) {
                self->state_->last_pulled_revision =
                    std::max(self->state_->last_pulled_revision, *next_chain);
              }
            }
            self->SaveStateToDisk();

            // Multi-batch replaceCloud uses replaceCloud once, then delta.
            self->PushMutationBatches(
                batches, idx + 1, SyncPushMode::kDelta, cursor_base, next_chain,
                has_conflicts, cur_rev, reset_rev, total_accepted + accepted,
                std::move(done));
          },
          weak_factory_.GetWeakPtr(), gen, batches, batch_index, mode,
          cursor_base, chain_cursor, known_reset, any_conflicts, total_accepted,
          std::move(on_done)));
}

void SyncEngine::FinishSyncPass(bool ok,
                                const std::string& error_code,
                                const std::string& error_message) {
  sync_in_flight_ = false;
  if (ok) {
    SetStatus(SyncStatusKind::kIdle, "Up to date");
  } else if (status_ != SyncStatusKind::kNeedsReauth) {
    SetStatus(SyncStatusKind::kError, error_message);
  }

  auto callbacks = std::move(pending_sync_callbacks_);
  pending_sync_callbacks_.clear();
  for (auto& cb : callbacks) {
    if (cb) {
      std::move(cb).Run({ok, error_code, error_message});
    }
  }

  if (follow_up_sync_requested_ && is_signed_in() && credentials_ &&
      status_ != SyncStatusKind::kNeedsReauth &&
      !state_->awaiting_initial_choice) {
    follow_up_sync_requested_ = false;
    SyncNow();
  }
}

// --- WebSocket wakeup listener (§4.6) ---

void SyncEngine::StartWebSocket() {
  if (!ws_client_ || !is_signed_in() || state_->awaiting_initial_choice ||
      !credentials_) {
    return;
  }
  ws_reconnect_timer_.Stop();
  std::string ws_url = MakeWsUrlFromHttp(state_->server_url);
  ws_client_->Connect(ws_url, credentials_->tokens.access_token,
                      state_->device_id, this);
  ws_ping_timer_.Start(FROM_HERE, base::Seconds(kWsPingIntervalSec), this,
                       &SyncEngine::SendWebSocketPing);
}

void SyncEngine::StopWebSocket() {
  ws_reconnect_timer_.Stop();
  ws_ping_timer_.Stop();
  if (ws_client_) {
    ws_client_->Disconnect();
  }
}

void SyncEngine::SendWebSocketPing() {
  if (ws_client_) {
    ws_client_->SendText(R"({"type":"ping"})");
  }
}

void SyncEngine::HandleWebSocketTextFrame(std::string_view json_text) {
  if (json_text.size() > 65536) return;
  auto dict = base::JSONReader::ReadDict(json_text, base::JSON_PARSE_RFC);
  if (!dict) return;
  const auto* type = dict->FindString("type");
  if (!type) return;
  if (*type == "connected") {
    OnWsConnected(dict->FindInt("serverRevision").value_or(0),
                  dict->FindInt("resetRevision").value_or(0));
  } else if (*type == "sync_available") {
    const auto* src = dict->FindString("sourceDeviceId");
    OnWsSyncAvailable(dict->FindInt("revision").value_or(0),
                      dict->FindInt("resetRevision").value_or(0),
                      src ? *src : "");
  }
}

void SyncEngine::OnWsConnected(int server_revision, int reset_revision) {
  ws_backoff_seconds_ = kWsMinBackoffSec;
  if (!is_signed_in() || state_->awaiting_initial_choice) return;
  if (server_revision > state_->last_pulled_revision ||
      reset_revision > state_->last_reset_revision) {
    SyncNow();
  }
}

void SyncEngine::OnWsSyncAvailable(int revision,
                                   int reset_revision,
                                   const std::string& source_device_id) {
  ws_backoff_seconds_ = kWsMinBackoffSec;
  if (!is_signed_in() || state_->awaiting_initial_choice) return;
  if (!source_device_id.empty() &&
      base::EqualsCaseInsensitiveASCII(source_device_id, state_->device_id)) {
    return;
  }
  if (revision > state_->last_pulled_revision ||
      reset_revision > state_->last_reset_revision) {
    SyncNow();
  }
}

void SyncEngine::OnWsSessionRevoked() {
  last_reauth_email_ = state_ ? state_->email : std::nullopt;
  ClearLocalSession(SyncStatusKind::kNeedsReauth,
                    "This device was signed out of Open Sync. Sign in again.");
}

void SyncEngine::OnWsDisconnected(int close_code,
                                  const std::string& reason,
                                  int http_status) {
  ws_ping_timer_.Stop();
  if (!is_signed_in()) return;
  if (close_code == kSyncWsSessionRevokedCloseCode ||
      reason == "session_revoked") {
    OnWsSessionRevoked();
    return;
  }
  ScheduleWebSocketReconnect(/*force_refresh=*/http_status == 401);
}

void SyncEngine::ScheduleWebSocketReconnect(bool force_refresh) {
  if (!is_signed_in()) return;
  ws_force_refresh_next_ = force_refresh;
  double delay = ws_backoff_seconds_;
  ws_backoff_seconds_ = std::min(ws_backoff_seconds_ * 2.0, kWsMaxBackoffSec);
  ws_reconnect_timer_.Start(
      FROM_HERE, base::Seconds(delay),
      base::BindOnce(
          [](base::WeakPtr<SyncEngine> self) {
            if (!self || !self->is_signed_in()) return;
            if (self->ws_force_refresh_next_) {
              self->ws_force_refresh_next_ = false;
              self->RefreshAccessToken(base::BindOnce(
                  [](base::WeakPtr<SyncEngine> s, bool ok) {
                    if (s && ok) s->StartWebSocket();
                  },
                  self));
            } else {
              self->StartWebSocket();
            }
          },
          weak_factory_.GetWeakPtr()));
}

}  // namespace open_unified
