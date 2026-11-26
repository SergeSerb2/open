// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/core/livedata/open_livedata_service.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/strings/escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/values.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr base::TimeDelta kBackgroundPollInterval = base::Seconds(30);
constexpr base::TimeDelta kCalendarCountdownInterval = base::Seconds(15);
constexpr double kCalendarFetchIntervalSec = 360.0;
constexpr size_t kMaxFeedDownloadBytes = 2 * 1024 * 1024;
constexpr base::TimeDelta kFeedFetchTimeout = base::Seconds(15);
constexpr size_t kMeetingScanLimit = 16384;

constexpr net::NetworkTrafficAnnotationTag kLiveDataTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("open_livedata_service", R"(
        semantics {
          sender: "Open LiveData Service"
          description:
            "Fetches user-configured Live Folders (GitHub PRs, RSS/Atom "
            "feeds) and iCalendar (.ics) feeds for sidebar previews and "
            "meeting countdowns."
          trigger:
            "User creates a Live Folder or configures an iCal feed URL."
          data:
            "Public or token-authenticated feed requests to user-selected URLs."
          destination: OTHER
          destination_other: "User-configured feed or GitHub endpoint"
          internal {
            contacts {
              email: "engineering@openbrowser.dev"
            }
          }
          user_data {
            type: ACCESS_TOKEN
          }
          last_reviewed: "2026-11-26"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Controlled by Live Folder and Calendar Preview settings."
          policy_exception_justification:
            "Only fetches endpoints explicitly added by the user."
        })");

std::string ServiceDisplayName(MeetingService service) {
  switch (service) {
    case MeetingService::kGoogleMeet:
      return "Google Meet";
    case MeetingService::kZoom:
      return "Zoom";
    case MeetingService::kTeams:
      return "Teams";
    case MeetingService::kWebex:
      return "Webex";
    case MeetingService::kWhereby:
      return "Whereby";
    case MeetingService::kFaceTime:
      return "FaceTime";
    case MeetingService::kSlackHuddle:
      return "Huddle";
    case MeetingService::kAround:
      return "Around";
    case MeetingService::kOther:
      return "Meeting";
  }
  return "Meeting";
}

bool IsBadgeEligibleUrl(std::string_view raw_url) {
  GURL url(raw_url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  std::string host = base::ToLowerASCII(url.host());
  if (host.starts_with("www.")) {
    host.erase(0, 4);
  }
  return host == "mail.google.com" || host == "web.whatsapp.com" ||
         host == "twitter.com" || host == "x.com" ||
         host == "mobile.twitter.com" || host == "mobile.x.com" ||
         host == "app.slack.com" || host.ends_with(".slack.com") ||
         host == "outlook.live.com" || host == "outlook.office.com" ||
         host == "outlook.office365.com";
}

// Parses RFC 3339 / ISO-8601 or RFC 2822 timestamp string to Unix epoch seconds.
TimestampSec ParseTimestampString(std::string_view text) {
  std::string trimmed(base::TrimWhitespaceASCII(text, base::TRIM_ALL));
  if (trimmed.empty()) {
    return 0.0;
  }
  base::Time parsed;
  if (base::Time::FromUTCString(trimmed.c_str(), &parsed) ||
      base::Time::FromString(trimmed.c_str(), &parsed)) {
    return parsed.InSecondsFSinceUnixEpoch();
  }
  return 0.0;
}

// Parses an iCal date/datetime value: YYYYMMDD or YYYYMMDDTHHMMSS[Z].
std::optional<TimestampSec> ParseIcsDateTime(std::string_view value,
                                             bool* out_all_day) {
  std::string s(base::TrimWhitespaceASCII(value, base::TRIM_ALL));
  if (s.size() < 8) {
    return std::nullopt;
  }
  base::Time::Exploded ex = {};
  if (!base::StringToInt(s.substr(0, 4), &ex.year) ||
      !base::StringToInt(s.substr(4, 2), &ex.month) ||
      !base::StringToInt(s.substr(6, 2), &ex.day_of_month)) {
    return std::nullopt;
  }

  if (s.size() == 8) {
    if (out_all_day) {
      *out_all_day = true;
    }
    base::Time t;
    if (base::Time::FromLocalExploded(ex, &t)) {
      return t.InSecondsFSinceUnixEpoch();
    }
    return std::nullopt;
  }

  if (s.size() < 15 || (s[8] != 'T' && s[8] != 't')) {
    return std::nullopt;
  }
  if (!base::StringToInt(s.substr(9, 2), &ex.hour) ||
      !base::StringToInt(s.substr(11, 2), &ex.minute) ||
      !base::StringToInt(s.substr(13, 2), &ex.second)) {
    return std::nullopt;
  }
  if (out_all_day) {
    *out_all_day = false;
  }

  const bool is_utc = s.back() == 'Z' || s.back() == 'z';
  base::Time t;
  const bool ok = is_utc ? base::Time::FromUTCExploded(ex, &t)
                         : base::Time::FromLocalExploded(ex, &t);
  if (!ok) {
    return std::nullopt;
  }
  return t.InSecondsFSinceUnixEpoch();
}

// Parses an RFC 5545 DURATION string such as PT30M, PT1H15M, P1D.
double ParseIcsDurationSec(std::string_view dur) {
  if (dur.empty()) {
    return 0.0;
  }
  size_t i = 0;
  if (dur[i] == '+' || dur[i] == '-') {
    ++i;
  }
  if (i >= dur.size() || (dur[i] != 'P' && dur[i] != 'p')) {
    return 0.0;
  }
  ++i;
  double total = 0.0;
  bool in_time = false;
  while (i < dur.size()) {
    if (dur[i] == 'T' || dur[i] == 't') {
      in_time = true;
      ++i;
      continue;
    }
    size_t start = i;
    while (i < dur.size() && std::isdigit(static_cast<unsigned char>(dur[i]))) {
      ++i;
    }
    if (start == i || i >= dur.size()) {
      break;
    }
    int num = 0;
    base::StringToInt(dur.substr(start, i - start), &num);
    const char unit = static_cast<char>(std::toupper(
        static_cast<unsigned char>(dur[i++])));
    if (unit == 'W') {
      total += num * 7.0 * 86400.0;
    } else if (unit == 'D') {
      total += num * 86400.0;
    } else if (unit == 'H') {
      total += num * 3600.0;
    } else if (unit == 'M' && in_time) {
      total += num * 60.0;
    } else if (unit == 'S') {
      total += num;
    }
  }
  return total;
}

std::string UnescapeIcsText(std::string_view input) {
  std::string out;
  out.reserve(input.size());
  for (size_t i = 0; i < input.size(); ++i) {
    if (input[i] == '\\' && i + 1 < input.size()) {
      const char next = input[++i];
      if (next == 'n' || next == 'N') {
        out.push_back('\n');
      } else {
        out.push_back(next);
      }
    } else {
      out.push_back(input[i]);
    }
  }
  return out;
}

// --- Lightweight XML Helpers for RSS 2.0 / Atom / Gmail Atom ---------------

std::string DecodeXmlEntities(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] != '&') {
      out.push_back(text[i]);
      continue;
    }
    const size_t semi = text.find(';', i + 1);
    if (semi == std::string_view::npos || semi - i > 12) {
      out.push_back('&');
      continue;
    }
    const std::string_view ent = text.substr(i + 1, semi - i - 1);
    if (ent == "amp") {
      out.push_back('&');
    } else if (ent == "lt") {
      out.push_back('<');
    } else if (ent == "gt") {
      out.push_back('>');
    } else if (ent == "quot") {
      out.push_back('"');
    } else if (ent == "apos" || ent == "#39") {
      out.push_back('\'');
    } else if (ent.starts_with('#')) {
      int code = 0;
      const bool ok =
          ent.size() > 2 && (ent[1] == 'x' || ent[1] == 'X')
              ? base::HexStringToInt(ent.substr(2), &code)
              : base::StringToInt(ent.substr(1), &code);
      if (ok && code > 0 && code < 128) {
        out.push_back(static_cast<char>(code));
      } else {
        out.push_back(' ');
      }
    } else {
      out.append(text.substr(i, semi - i + 1));
    }
    i = semi;
  }
  return out;
}

std::string StripCdataAndTrim(std::string_view raw) {
  std::string_view s = base::TrimWhitespaceASCII(raw, base::TRIM_ALL);
  constexpr std::string_view kCdataStart = "<![CDATA[";
  constexpr std::string_view kCdataEnd = "]]>";
  if (s.starts_with(kCdataStart) && s.ends_with(kCdataEnd) &&
      s.size() >= kCdataStart.size() + kCdataEnd.size()) {
    s = s.substr(kCdataStart.size(),
                 s.size() - kCdataStart.size() - kCdataEnd.size());
    return std::string(base::TrimWhitespaceASCII(s, base::TRIM_ALL));
  }
  return DecodeXmlEntities(s);
}

// Extracts the inner text of the first <tag ...>...</tag> inside |block|.
std::string ExtractXmlTagText(std::string_view block, std::string_view tag) {
  const std::string open_prefix = "<" + std::string(tag);
  const std::string close_tag = "</" + std::string(tag) + ">";

  size_t pos = 0;
  while (pos < block.size()) {
    const size_t open = block.find(open_prefix, pos);
    if (open == std::string_view::npos) {
      return std::string();
    }
    const size_t after = open + open_prefix.size();
    if (after < block.size() && block[after] != '>' &&
        !std::isspace(static_cast<unsigned char>(block[after]))) {
      pos = after;
      continue;
    }
    const size_t gt = block.find('>', after);
    if (gt == std::string_view::npos) {
      return std::string();
    }
    if (gt > after && block[gt - 1] == '/') {
      pos = gt + 1;
      continue;
    }
    const size_t close = block.find(close_tag, gt + 1);
    if (close == std::string_view::npos) {
      return std::string();
    }
    return StripCdataAndTrim(block.substr(gt + 1, close - gt - 1));
  }
  return std::string();
}

// Extracts href="..." from an Atom <link ...> tag inside |block|.
std::string ExtractAtomLinkHref(std::string_view block) {
  size_t pos = 0;
  std::string fallback;
  while (pos < block.size()) {
    const size_t open = block.find("<link", pos);
    if (open == std::string_view::npos) {
      break;
    }
    const size_t after = open + 5;
    if (after < block.size() && block[after] != '>' &&
        !std::isspace(static_cast<unsigned char>(block[after]))) {
      pos = after;
      continue;
    }
    const size_t gt = block.find('>', after);
    if (gt == std::string_view::npos) {
      break;
    }
    const std::string_view attrs = block.substr(after, gt - after);
    pos = gt + 1;

    const size_t href_pos = attrs.find("href=");
    if (href_pos == std::string_view::npos || href_pos + 6 >= attrs.size()) {
      continue;
    }
    const char quote = attrs[href_pos + 5];
    if (quote != '"' && quote != '\'') {
      continue;
    }
    const size_t end_q = attrs.find(quote, href_pos + 6);
    if (end_q == std::string_view::npos) {
      continue;
    }
    std::string href = DecodeXmlEntities(
        attrs.substr(href_pos + 6, end_q - (href_pos + 6)));
    if (attrs.find("rel=\"alternate\"") != std::string_view::npos ||
        attrs.find("rel='alternate'") != std::string_view::npos) {
      return href;
    }
    if (fallback.empty()) {
      fallback = std::move(href);
    }
  }
  return fallback;
}

std::vector<std::string_view> SplitXmlBlocks(std::string_view xml,
                                             std::string_view tag) {
  std::vector<std::string_view> blocks;
  const std::string open_prefix = "<" + std::string(tag);
  const std::string close_tag = "</" + std::string(tag) + ">";
  size_t pos = 0;
  while (pos < xml.size() && blocks.size() < 200) {
    const size_t open = xml.find(open_prefix, pos);
    if (open == std::string_view::npos) {
      break;
    }
    const size_t after = open + open_prefix.size();
    if (after < xml.size() && xml[after] != '>' &&
        !std::isspace(static_cast<unsigned char>(xml[after]))) {
      pos = after;
      continue;
    }
    const size_t gt = xml.find('>', after);
    if (gt == std::string_view::npos) {
      break;
    }
    const size_t close = xml.find(close_tag, gt + 1);
    if (close == std::string_view::npos) {
      break;
    }
    blocks.push_back(xml.substr(gt + 1, close - gt - 1));
    pos = close + close_tag.size();
  }
  return blocks;
}

std::string RepoNameFromApiUrl(std::string_view api_url) {
  // e.g. "https://api.github.com/repos/owner/repo" -> "owner/repo"
  constexpr std::string_view kMarker = "/repos/";
  const size_t idx = api_url.find(kMarker);
  if (idx != std::string_view::npos) {
    return std::string(api_url.substr(idx + kMarker.size()));
  }
  return std::string();
}

std::string BuildLiveFolderFetchUrl(const LiveFolderConfig& config) {
  const std::string provider = base::ToLowerASCII(config.provider);
  if (provider == "github_prs" || provider == "github") {
    if (config.query.starts_with("http://") ||
        config.query.starts_with("https://")) {
      return config.query;
    }
    const std::string q =
        config.query.empty() ? "is:pr is:open sort:updated-desc" : config.query;
    return "https://api.github.com/search/issues?per_page=50&q=" +
           base::EscapeQueryParamValue(q, /*use_plus=*/true);
  }
  // RSS / Atom feed URL directly in config.query.
  return config.query;
}

}  // namespace

// ===========================================================================
// Struct Boilerplate
// ===========================================================================

CalendarMeeting::CalendarMeeting() = default;
CalendarMeeting::CalendarMeeting(const CalendarMeeting&) = default;
CalendarMeeting::CalendarMeeting(CalendarMeeting&&) noexcept = default;
CalendarMeeting& CalendarMeeting::operator=(const CalendarMeeting&) = default;
CalendarMeeting& CalendarMeeting::operator=(CalendarMeeting&&) noexcept =
    default;
CalendarMeeting::~CalendarMeeting() = default;

LiveFolderItem::LiveFolderItem() = default;
LiveFolderItem::LiveFolderItem(const LiveFolderItem&) = default;
LiveFolderItem::LiveFolderItem(LiveFolderItem&&) noexcept = default;
LiveFolderItem& LiveFolderItem::operator=(const LiveFolderItem&) = default;
LiveFolderItem& LiveFolderItem::operator=(LiveFolderItem&&) noexcept = default;
LiveFolderItem::~LiveFolderItem() = default;

LiveFolderState::LiveFolderState() = default;
LiveFolderState::LiveFolderState(const LiveFolderState&) = default;
LiveFolderState::LiveFolderState(LiveFolderState&&) noexcept = default;
LiveFolderState& LiveFolderState::operator=(const LiveFolderState&) = default;
LiveFolderState& LiveFolderState::operator=(LiveFolderState&&) noexcept =
    default;
LiveFolderState::~LiveFolderState() = default;

MailPreviewItem::MailPreviewItem() = default;
MailPreviewItem::MailPreviewItem(const MailPreviewItem&) = default;
MailPreviewItem::MailPreviewItem(MailPreviewItem&&) noexcept = default;
MailPreviewItem& MailPreviewItem::operator=(const MailPreviewItem&) = default;
MailPreviewItem& MailPreviewItem::operator=(MailPreviewItem&&) noexcept =
    default;
MailPreviewItem::~MailPreviewItem() = default;

HoverPreviewSnapshot::HoverPreviewSnapshot() = default;
HoverPreviewSnapshot::HoverPreviewSnapshot(const HoverPreviewSnapshot&) =
    default;
HoverPreviewSnapshot::HoverPreviewSnapshot(HoverPreviewSnapshot&&) noexcept =
    default;
HoverPreviewSnapshot& HoverPreviewSnapshot::operator=(
    const HoverPreviewSnapshot&) = default;
HoverPreviewSnapshot& HoverPreviewSnapshot::operator=(
    HoverPreviewSnapshot&&) noexcept = default;
HoverPreviewSnapshot::~HoverPreviewSnapshot() = default;

// ===========================================================================
// OpenLiveDataService
// ===========================================================================

OpenLiveDataService::OpenLiveDataService() = default;

OpenLiveDataService::~OpenLiveDataService() {
  Stop();
}

void OpenLiveDataService::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenLiveDataService::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

void OpenLiveDataService::SetURLLoaderFactory(
    network::mojom::URLLoaderFactory* factory) {
  if (!factory) {
    ics_loaders_.clear();
    for (auto& [id, entry] : live_folders_) {
      entry->loader.reset();
      entry->state.refreshing = false;
    }
  }
  url_loader_factory_ = factory;
}

void OpenLiveDataService::SetGitHubBearerToken(std::string token) {
  github_bearer_token_ = std::move(token);
}

void OpenLiveDataService::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  background_timer_.Start(
      FROM_HERE, kBackgroundPollInterval,
      base::BindRepeating(&OpenLiveDataService::OnBackgroundTick,
                          base::Unretained(this)));
  calendar_tick_timer_.Start(
      FROM_HERE, kCalendarCountdownInterval,
      base::BindRepeating(&OpenLiveDataService::OnCalendarTick,
                          base::Unretained(this)));
  OnBackgroundTick();
  OnCalendarTick();
}

void OpenLiveDataService::Stop() {
  started_ = false;
  background_timer_.Stop();
  calendar_tick_timer_.Stop();
  ics_loaders_.clear();
  for (auto& [id, entry] : live_folders_) {
    entry->loader.reset();
    entry->state.refreshing = false;
  }
}

void OpenLiveDataService::SetPowerSuspended(bool suspended) {
  power_suspended_ = suspended;
  if (!suspended && started_ && network_online_) {
    OnBackgroundTick();
    OnCalendarTick();
  }
}

void OpenLiveDataService::SetNetworkOnline(bool online) {
  network_online_ = online;
  if (online && started_ && !power_suspended_) {
    OnBackgroundTick();
  }
}

// ===========================================================================
// Calendar & Join Meeting
// ===========================================================================

void OpenLiveDataService::SetCalendarEventProvider(
    std::unique_ptr<CalendarEventProvider> provider) {
  calendar_provider_ = std::move(provider);
  if (started_) {
    RefreshCalendarNow();
  }
}

void OpenLiveDataService::SetIcsFeedUrls(std::vector<std::string> urls) {
  ics_feed_urls_ = std::move(urls);
  // Drop cached events for removed feeds.
  std::set<std::string> allowed(ics_feed_urls_.begin(), ics_feed_urls_.end());
  for (auto it = ics_events_by_url_.begin(); it != ics_events_by_url_.end();) {
    if (!allowed.contains(it->first)) {
      it = ics_events_by_url_.erase(it);
    } else {
      ++it;
    }
  }
  RebuildMergedCalendarEvents();
  if (started_) {
    RefreshIcsFeeds();
  }
}

void OpenLiveDataService::RefreshCalendarNow() {
  const TimestampSec now = NowSec();
  last_calendar_fetch_at_ = now;
  RefreshIcsFeeds();

  if (calendar_provider_ &&
      calendar_provider_->GetAccessState() == CalendarAccessState::kGranted) {
    const TimestampSec start = now - kJoinableAfterStartSec;
    const TimestampSec end = now + 24.0 * 3600.0;
    calendar_provider_->FetchEvents(
        start, end,
        base::BindOnce(&OpenLiveDataService::OnProviderEventsLoaded,
                       weak_factory_.GetWeakPtr()));
  }
}

void OpenLiveDataService::IngestCalendarTabMetadata(
    const ItemID& tab_id,
    const std::string& tab_url,
    const std::string& page_title,
    const std::vector<CalendarMeeting>& extracted_events) {
  if (IsCalendarFavoriteUrl(tab_url)) {
    calendar_favorite_tabs_.insert(tab_id);
  }

  std::vector<CalendarMeeting> normalized;
  normalized.reserve(extracted_events.size());
  for (CalendarMeeting ev : extracted_events) {
    if (ev.title.empty()) {
      ev.title = "Event";
    }
    if (ev.join_url.empty()) {
      if (auto detected =
              DetectMeetingLink(ev.join_url, ev.location, ev.notes)) {
        ev.join_url = detected->url;
        ev.service = detected->service;
      }
    } else if (auto classified = ClassifyMeetingUrl(ev.join_url)) {
      ev.service = classified->service;
    }
    normalized.push_back(std::move(ev));
  }

  // If the tab title itself carries a meeting URL or countdown notification,
  // capture a fallback live meeting entry when no structured events were passed.
  if (normalized.empty() && !page_title.empty()) {
    if (auto detected = DetectMeetingLink(tab_url, page_title, "")) {
      CalendarMeeting m;
      m.id = "tab:" + tab_id;
      m.title = page_title;
      const TimestampSec now = NowSec();
      m.starts_at = now;
      m.ends_at = now + 1800.0;
      m.join_url = detected->url;
      m.service = detected->service;
      normalized.push_back(std::move(m));
    }
  }

  tab_calendar_events_[tab_id] = std::move(normalized);
  RebuildMergedCalendarEvents();
  RefreshCalendarSubtitlesAndPreviews(NowSec());
}

void OpenLiveDataService::RegisterCalendarFavoriteTab(
    const ItemID& tab_id,
    const std::string& tab_url) {
  if (!IsCalendarFavoriteUrl(tab_url)) {
    return;
  }
  calendar_favorite_tabs_.insert(tab_id);
  RefreshCalendarSubtitlesAndPreviews(NowSec());
}

void OpenLiveDataService::UnregisterFavoriteTab(const ItemID& tab_id) {
  calendar_favorite_tabs_.erase(tab_id);
  tab_calendar_events_.erase(tab_id);
  last_favorite_subtitles_.erase(tab_id);
  last_favorite_badges_.erase(tab_id);
  hover_previews_.erase(tab_id);
  RebuildMergedCalendarEvents();
}

std::optional<CalendarMeeting> OpenLiveDataService::NextUpcomingMeeting(
    TimestampSec now) const {
  if (now <= 0.0) {
    now = NowSec();
  }
  const CalendarMeeting* best = nullptr;
  double best_distance = 0.0;

  for (const CalendarMeeting& ev : merged_calendar_events_) {
    if (ev.is_all_day || ev.is_declined || ev.is_canceled) {
      continue;
    }
    if (ev.join_url.empty()) {
      continue;
    }
    if (ev.ends_at > 0.0 && ev.ends_at <= now) {
      continue;
    }
    if (ev.starts_at < now - kJoinableAfterStartSec) {
      continue;
    }
    const double distance = std::abs(ev.starts_at - now);
    if (!best || distance < best_distance ||
        (distance == best_distance && ev.starts_at < best->starts_at)) {
      best = &ev;
      best_distance = distance;
    }
  }

  if (!best) {
    return std::nullopt;
  }
  CalendarMeeting copy = *best;
  copy.countdown_label = FormatCountdownLabel(copy.starts_at, now);
  return copy;
}

std::vector<CalendarMeeting> OpenLiveDataService::UpcomingMeetings(
    TimestampSec now,
    size_t max_count) const {
  if (now <= 0.0) {
    now = NowSec();
  }
  std::vector<CalendarMeeting> out;
  for (const CalendarMeeting& ev : merged_calendar_events_) {
    if (ev.is_declined || ev.is_canceled) {
      continue;
    }
    if (!ev.is_all_day && ev.ends_at > 0.0 && ev.ends_at <= now) {
      continue;
    }
    if (!ev.is_all_day && ev.starts_at < now - kJoinableAfterStartSec) {
      continue;
    }
    CalendarMeeting copy = ev;
    if (!copy.is_all_day) {
      copy.countdown_label = FormatCountdownLabel(copy.starts_at, now);
    }
    out.push_back(std::move(copy));
  }
  std::sort(out.begin(), out.end(),
            [](const CalendarMeeting& a, const CalendarMeeting& b) {
              return a.starts_at < b.starts_at;
            });
  if (out.size() > max_count) {
    out.resize(max_count);
  }
  return out;
}

// static
std::optional<DetectedMeetingLink> OpenLiveDataService::ClassifyMeetingUrl(
    std::string_view raw_url) {
  GURL url(raw_url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return std::nullopt;
  }
  const std::string host = base::ToLowerASCII(url.host());
  const std::string path(url.path());
  const std::vector<std::string> parts = base::SplitString(
      path, "/", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);

  auto make_link = [&](MeetingService svc) -> DetectedMeetingLink {
    return {svc, url.spec(), ServiceDisplayName(svc)};
  };

  if (host == "meet.google.com") {
    if (!parts.empty() &&
        (parts[0].find('-') != std::string::npos || parts[0] == "lookup")) {
      return make_link(MeetingService::kGoogleMeet);
    }
    return std::nullopt;
  }
  if (host == "teams.live.com") {
    if (parts.size() >= 2 && parts[0] == "meet") {
      return make_link(MeetingService::kTeams);
    }
    return std::nullopt;
  }
  if (host == "teams.microsoft.com") {
    if (path.starts_with("/l/meetup-join/")) {
      return make_link(MeetingService::kTeams);
    }
    return std::nullopt;
  }
  if (host == "zoom.us" || host.ends_with(".zoom.us")) {
    if (parts.size() >= 2 &&
        (parts[0] == "j" || parts[0] == "my" || parts[0] == "w" ||
         parts[0] == "s" || parts[0] == "wc")) {
      return make_link(MeetingService::kZoom);
    }
    return std::nullopt;
  }
  if (host.ends_with(".webex.com")) {
    if (!parts.empty()) {
      const std::string first = base::ToLowerASCII(parts[0]);
      if (first == "meet" || first == "join" || first == "wbxmjs" ||
          first == "webappng") {
        return make_link(MeetingService::kWebex);
      }
    }
    return std::nullopt;
  }
  if (host == "whereby.com" || host.ends_with(".whereby.com")) {
    if (!parts.empty() && parts[0] != "information" && parts[0] != "user") {
      return make_link(MeetingService::kWhereby);
    }
    return std::nullopt;
  }
  if (host == "facetime.apple.com") {
    if (!parts.empty() && parts[0] == "join") {
      return make_link(MeetingService::kFaceTime);
    }
    return std::nullopt;
  }
  if (host == "app.slack.com") {
    if (parts.size() >= 2 && parts[0] == "huddle") {
      return make_link(MeetingService::kSlackHuddle);
    }
    return std::nullopt;
  }
  if (host == "around.co") {
    if (parts.size() >= 2 && parts[0] == "r") {
      return make_link(MeetingService::kAround);
    }
    return std::nullopt;
  }
  return std::nullopt;
}

// static
std::optional<DetectedMeetingLink> OpenLiveDataService::DetectMeetingLink(
    std::string_view url,
    std::string_view location,
    std::string_view notes) {
  if (!url.empty()) {
    if (auto direct = ClassifyMeetingUrl(url)) {
      return direct;
    }
  }

  auto scan_text = [](std::string_view text)
      -> std::optional<DetectedMeetingLink> {
    if (text.empty()) {
      return std::nullopt;
    }
    const std::string_view bounded =
        text.substr(0, std::min(text.size(), kMeetingScanLimit));
    size_t pos = 0;
    while (pos < bounded.size()) {
      const size_t https_pos = bounded.find("https://", pos);
      const size_t http_pos = bounded.find("http://", pos);
      const size_t start = std::min(https_pos, http_pos);
      if (start == std::string_view::npos) {
        break;
      }
      size_t end = start;
      while (end < bounded.size()) {
        const unsigned char c = static_cast<unsigned char>(bounded[end]);
        if (std::isspace(c) || c == '<' || c == '>' || c == '"' || c == '\'' ||
            c == ')' || c == ']') {
          break;
        }
        ++end;
      }
      // Trim trailing punctuation commonly attached to URLs in notes.
      while (end > start &&
             (bounded[end - 1] == '.' || bounded[end - 1] == ',' ||
              bounded[end - 1] == ';')) {
        --end;
      }
      if (auto link = ClassifyMeetingUrl(bounded.substr(start, end - start))) {
        return link;
      }
      pos = end;
    }
    return std::nullopt;
  };

  if (auto found = scan_text(location)) {
    return found;
  }
  return scan_text(notes);
}

// static
std::string OpenLiveDataService::FormatCountdownLabel(TimestampSec starts_at,
                                                      TimestampSec now) {
  const double until = starts_at - now;
  if (until > kCountdownLeadSec) {
    return std::string();
  }
  if (until > 0.0) {
    const int mins = std::max(1, static_cast<int>(std::ceil(until / 60.0)));
    return "in " + base::NumberToString(mins) + "m";
  }
  if (until > -60.0) {
    return "Now";
  }
  const int ago = std::max(1, static_cast<int>(std::floor((-until) / 60.0)));
  return base::NumberToString(ago) + "m ago";
}

// static
bool OpenLiveDataService::IsCalendarFavoriteUrl(std::string_view raw_url) {
  GURL url(raw_url);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const std::string host = base::ToLowerASCII(url.host());
  if (host == "calendar.google.com" || host == "calendar.notion.so" ||
      host == "calendar.notion.com") {
    return true;
  }
  if (host == "outlook.live.com" || host == "outlook.office.com" ||
      host == "outlook.office365.com") {
    return base::ToLowerASCII(url.path()).starts_with("/calendar");
  }
  return false;
}

// static
std::vector<CalendarMeeting> OpenLiveDataService::ParseIcsFeed(
    std::string_view ics_text,
    TimestampSec window_start,
    TimestampSec window_end) {
  // Unfold RFC 5545 folded lines (CRLF/LF followed by space or tab).
  std::vector<std::string> lines;
  std::string current;
  for (size_t i = 0; i < ics_text.size(); ++i) {
    const char c = ics_text[i];
    if (c == '\r') {
      continue;
    }
    if (c == '\n') {
      if (i + 1 < ics_text.size() &&
          (ics_text[i + 1] == ' ' || ics_text[i + 1] == '\t')) {
        ++i;  // Continuation line.
        continue;
      }
      lines.push_back(std::move(current));
      current.clear();
      continue;
    }
    current.push_back(c);
  }
  if (!current.empty()) {
    lines.push_back(std::move(current));
  }

  std::vector<CalendarMeeting> events;
  bool in_event = false;
  CalendarMeeting ev;
  std::string raw_url;
  double duration_sec = 0.0;

  for (const std::string& line : lines) {
    if (line == "BEGIN:VEVENT") {
      in_event = true;
      ev = CalendarMeeting();
      raw_url.clear();
      duration_sec = 0.0;
      continue;
    }
    if (line == "END:VEVENT") {
      if (in_event && ev.starts_at > 0.0) {
        if (ev.ends_at <= 0.0) {
          ev.ends_at = ev.starts_at +
                       (duration_sec > 0.0 ? duration_sec : 3600.0);
        }
        if (ev.title.empty()) {
          ev.title = "Event";
        }
        if (ev.id.empty()) {
          ev.id = ev.title + "@" + base::NumberToString(
                                       static_cast<int64_t>(ev.starts_at));
        }
        if (auto link = DetectMeetingLink(raw_url, ev.location, ev.notes)) {
          ev.join_url = link->url;
          ev.service = link->service;
        }
        const bool in_window =
            (window_start <= 0.0 || ev.ends_at >= window_start) &&
            (window_end <= 0.0 || ev.starts_at <= window_end);
        if (in_window) {
          events.push_back(std::move(ev));
        }
      }
      in_event = false;
      continue;
    }
    if (!in_event) {
      continue;
    }

    const size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    const std::string_view key_and_params =
        std::string_view(line).substr(0, colon);
    const std::string_view value = std::string_view(line).substr(colon + 1);

    const size_t semi = key_and_params.find(';');
    const std::string prop = base::ToUpperASCII(
        semi == std::string_view::npos ? key_and_params
                                       : key_and_params.substr(0, semi));
    const std::string_view params =
        semi == std::string_view::npos ? std::string_view()
                                       : key_and_params.substr(semi + 1);

    if (prop == "UID") {
      ev.id = std::string(value);
    } else if (prop == "SUMMARY") {
      ev.title = UnescapeIcsText(value);
    } else if (prop == "DTSTART") {
      bool all_day = params.find("VALUE=DATE") != std::string_view::npos;
      if (auto ts = ParseIcsDateTime(value, &all_day)) {
        ev.starts_at = *ts;
        ev.is_all_day = ev.is_all_day || all_day;
      }
    } else if (prop == "DTEND") {
      bool all_day = false;
      if (auto ts = ParseIcsDateTime(value, &all_day)) {
        ev.ends_at = *ts;
      }
    } else if (prop == "DURATION") {
      duration_sec = ParseIcsDurationSec(value);
    } else if (prop == "LOCATION") {
      ev.location = UnescapeIcsText(value);
    } else if (prop == "DESCRIPTION") {
      ev.notes = UnescapeIcsText(value);
    } else if (prop == "URL" || prop == "X-GOOGLE-CONFERENCE") {
      if (raw_url.empty()) {
        raw_url = std::string(value);
      }
    } else if (prop == "STATUS") {
      if (base::ToUpperASCII(value) == "CANCELLED") {
        ev.is_canceled = true;
      }
    } else if (prop == "ATTENDEE") {
      if (base::ToUpperASCII(params).find("PARTSTAT=DECLINED") !=
          std::string::npos) {
        ev.is_declined = true;
      }
    }
  }

  return events;
}

// ===========================================================================
// Live Folders Engine
// ===========================================================================

void OpenLiveDataService::RegisterLiveFolder(const ItemID& folder_id,
                                             const LiveFolderConfig& config) {
  auto& slot = live_folders_[folder_id];
  if (!slot) {
    slot = std::make_unique<LiveFolderEntry>();
    slot->state.folder_id = folder_id;
  }
  slot->state.config = config;
  if (started_ && config.enabled) {
    RefreshLiveFolder(folder_id, /*force=*/false);
  }
}

void OpenLiveDataService::UnregisterLiveFolder(const ItemID& folder_id) {
  live_folders_.erase(folder_id);
}

bool OpenLiveDataService::RefreshLiveFolder(const ItemID& folder_id,
                                            bool force) {
  auto it = live_folders_.find(folder_id);
  if (it == live_folders_.end()) {
    return false;
  }
  LiveFolderEntry& entry = *it->second;
  if (!entry.state.config.enabled || entry.state.refreshing) {
    return false;
  }
  if (power_suspended_ || !network_online_ || !url_loader_factory_) {
    return false;
  }

  const TimestampSec now = NowSec();
  if (!force && entry.state.last_refreshed_at > 0.0 &&
      (now - entry.state.last_refreshed_at) < kMinLiveFolderRefreshSec) {
    return false;
  }

  const std::string fetch_url_str = BuildLiveFolderFetchUrl(entry.state.config);
  GURL fetch_url(fetch_url_str);
  if (!fetch_url.is_valid() || !fetch_url.SchemeIsHTTPOrHTTPS()) {
    entry.state.last_error = "Invalid Live Folder feed URL.";
    return false;
  }

  entry.state.refreshing = true;
  entry.state.last_error.clear();

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = fetch_url;
  request->method = "GET";
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;

  const std::string provider = base::ToLowerASCII(entry.state.config.provider);
  if (provider == "github_prs" || provider == "github") {
    request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                               "application/vnd.github+json");
    request->headers.SetHeader(net::HttpRequestHeaders::kUserAgent,
                               "OpenBrowser/1.0");
    if (!github_bearer_token_.empty()) {
      request->headers.SetHeader(net::HttpRequestHeaders::kAuthorization,
                                 "Bearer " + github_bearer_token_);
    }
  } else {
    request->headers.SetHeader(
        net::HttpRequestHeaders::kAccept,
        "application/atom+xml, application/rss+xml, application/xml, text/xml");
  }

  entry.loader = network::SimpleURLLoader::Create(std::move(request),
                                                  kLiveDataTrafficAnnotation);
  entry.loader->SetTimeoutDuration(kFeedFetchTimeout);
  entry.loader->DownloadToString(
      url_loader_factory_,
      base::BindOnce(&OpenLiveDataService::OnLiveFolderDownloaded,
                     weak_factory_.GetWeakPtr(), folder_id, provider),
      kMaxFeedDownloadBytes);
  return true;
}

void OpenLiveDataService::RefreshAllLiveFolders(bool force) {
  for (const auto& [folder_id, entry] : live_folders_) {
    RefreshLiveFolder(folder_id, force);
  }
}

std::optional<LiveFolderState> OpenLiveDataService::GetLiveFolderState(
    const ItemID& folder_id) const {
  auto it = live_folders_.find(folder_id);
  if (it == live_folders_.end()) {
    return std::nullopt;
  }
  return it->second->state;
}

int OpenLiveDataService::GetLiveFolderUnreadCount(
    const ItemID& folder_id) const {
  auto it = live_folders_.find(folder_id);
  return it == live_folders_.end() ? 0 : it->second->state.unread_count;
}

void OpenLiveDataService::MarkLiveFolderItemRead(const ItemID& folder_id,
                                                 const std::string& item_url) {
  auto it = live_folders_.find(folder_id);
  if (it == live_folders_.end()) {
    return;
  }
  LiveFolderEntry& entry = *it->second;
  if (entry.unread_urls.erase(item_url) == 0) {
    return;
  }
  for (LiveFolderItem& item : entry.state.items) {
    if (item.url == item_url) {
      item.unread = false;
    }
  }
  entry.state.unread_count = static_cast<int>(entry.unread_urls.size());
  for (Observer& obs : observers_) {
    obs.OnLiveFolderUpdated(folder_id, entry.state.items,
                            entry.state.unread_count);
  }
}

void OpenLiveDataService::MarkLiveFolderAllRead(const ItemID& folder_id) {
  auto it = live_folders_.find(folder_id);
  if (it == live_folders_.end()) {
    return;
  }
  LiveFolderEntry& entry = *it->second;
  if (entry.unread_urls.empty()) {
    return;
  }
  entry.unread_urls.clear();
  for (LiveFolderItem& item : entry.state.items) {
    item.unread = false;
  }
  entry.state.unread_count = 0;
  for (Observer& obs : observers_) {
    obs.OnLiveFolderUpdated(folder_id, entry.state.items, 0);
  }
}

// static
std::vector<LiveFolderItem> OpenLiveDataService::ParseGitHubPullRequestsJson(
    std::string_view json_text) {
  std::vector<LiveFolderItem> items;
  auto parsed = base::JSONReader::Read(json_text, base::JSON_PARSE_RFC);
  if (!parsed) {
    return items;
  }

  const base::ListValue* list = nullptr;
  if (parsed->is_list()) {
    list = &parsed->GetList();
  } else if (parsed->is_dict()) {
    list = parsed->GetDict().FindList("items");
  }
  if (!list) {
    return items;
  }

  for (const base::Value& entry : *list) {
    if (items.size() >= kMaxLiveFolderItems) {
      break;
    }
    const base::DictValue* dict = entry.GetIfDict();
    if (!dict) {
      continue;
    }
    const std::string* html_url = dict->FindString("html_url");
    if (!html_url) {
      html_url = dict->FindString("url");
    }
    const std::string* title = dict->FindString("title");
    if (!html_url || !title || title->empty()) {
      continue;
    }
    GURL parsed_url(*html_url);
    if (!parsed_url.is_valid() || !parsed_url.SchemeIsHTTPOrHTTPS()) {
      continue;
    }

    LiveFolderItem item;
    item.url = parsed_url.spec();
    item.title = title->substr(0, 300);
    if (std::optional<int> num = dict->FindInt("number")) {
      item.id = "#" + base::NumberToString(*num);
    } else {
      item.id = item.url;
    }

    std::string repo;
    if (const std::string* repo_url = dict->FindString("repository_url")) {
      repo = RepoNameFromApiUrl(*repo_url);
    } else if (const base::DictValue* base_obj = dict->FindDict("base")) {
      if (const base::DictValue* repo_obj = base_obj->FindDict("repo")) {
        if (const std::string* full = repo_obj->FindString("full_name")) {
          repo = *full;
        }
      }
    }

    std::string author;
    if (const base::DictValue* user = dict->FindDict("user")) {
      if (const std::string* login = user->FindString("login")) {
        author = *login;
      }
    }

    if (!repo.empty() && !item.id.empty() && item.id[0] == '#') {
      item.subtitle = repo + " " + item.id;
    } else if (!repo.empty()) {
      item.subtitle = repo;
    }
    if (!author.empty()) {
      if (!item.subtitle.empty()) {
        item.subtitle += " \xC2\xB7 ";
      }
      item.subtitle += "@" + author;
    }

    const bool is_draft = dict->FindBool("draft").value_or(false);
    if (is_draft) {
      item.status_badge = "draft";
    } else if (const std::string* st = dict->FindString("state")) {
      item.status_badge = *st;
    } else {
      item.status_badge = "open";
    }

    if (const std::string* updated = dict->FindString("updated_at")) {
      item.updated_at = ParseTimestampString(*updated);
    }

    items.push_back(std::move(item));
  }
  return items;
}

// static
std::vector<LiveFolderItem> OpenLiveDataService::ParseFeedXml(
    std::string_view xml_text) {
  std::vector<LiveFolderItem> items;
  if (xml_text.empty()) {
    return items;
  }

  // Try RSS 2.0 <item> blocks first, then Atom <entry> blocks.
  const std::vector<std::string_view> rss_blocks =
      SplitXmlBlocks(xml_text, "item");
  if (!rss_blocks.empty()) {
    for (std::string_view block : rss_blocks) {
      if (items.size() >= kMaxLiveFolderItems) {
        break;
      }
      std::string link = ExtractXmlTagText(block, "link");
      std::string title = ExtractXmlTagText(block, "title");
      GURL parsed_url(link);
      if (!parsed_url.is_valid() || !parsed_url.SchemeIsHTTPOrHTTPS()) {
        continue;
      }
      LiveFolderItem item;
      item.url = parsed_url.spec();
      item.title = title.empty() ? item.url : title.substr(0, 300);
      item.id = ExtractXmlTagText(block, "guid");
      if (item.id.empty()) {
        item.id = item.url;
      }
      item.subtitle = ExtractXmlTagText(block, "dc:creator");
      if (item.subtitle.empty()) {
        item.subtitle = ExtractXmlTagText(block, "author");
      }
      item.status_badge = "rss";
      item.updated_at =
          ParseTimestampString(ExtractXmlTagText(block, "pubDate"));
      items.push_back(std::move(item));
    }
    return items;
  }

  const std::vector<std::string_view> atom_blocks =
      SplitXmlBlocks(xml_text, "entry");
  for (std::string_view block : atom_blocks) {
    if (items.size() >= kMaxLiveFolderItems) {
      break;
    }
    std::string link = ExtractAtomLinkHref(block);
    std::string title = ExtractXmlTagText(block, "title");
    GURL parsed_url(link);
    if (!parsed_url.is_valid() || !parsed_url.SchemeIsHTTPOrHTTPS()) {
      continue;
    }
    LiveFolderItem item;
    item.url = parsed_url.spec();
    item.title = title.empty() ? item.url : title.substr(0, 300);
    item.id = ExtractXmlTagText(block, "id");
    if (item.id.empty()) {
      item.id = item.url;
    }
    item.subtitle = ExtractXmlTagText(block, "name");
    item.status_badge = "atom";
    std::string ts = ExtractXmlTagText(block, "updated");
    if (ts.empty()) {
      ts = ExtractXmlTagText(block, "published");
    }
    item.updated_at = ParseTimestampString(ts);
    items.push_back(std::move(item));
  }
  return items;
}

// ===========================================================================
// Hover Preview Cache & Favorite Unread Badges
// ===========================================================================

void OpenLiveDataService::UpdateTabTitleForBadge(const ItemID& tab_id,
                                                 const std::string& url,
                                                 const std::string& title) {
  if (!IsBadgeEligibleUrl(url)) {
    return;
  }
  const std::optional<int> count = ParseTitleUnreadCount(title);
  const std::string badge =
      count.has_value() ? FormatBadgeCount(*count) : std::string();

  auto& snapshot = hover_previews_[tab_id];
  snapshot.tab_id = tab_id;
  if (snapshot.kind == HoverPreviewKind::kNone) {
    snapshot.kind = HoverPreviewKind::kMail;
    snapshot.header_title = "Unread";
  }
  snapshot.unread_count = count.value_or(0);
  snapshot.badge_text = badge;
  snapshot.updated_at = NowSec();

  auto prev_it = last_favorite_badges_.find(tab_id);
  if (prev_it == last_favorite_badges_.end() || prev_it->second != badge) {
    last_favorite_badges_[tab_id] = badge;
    for (Observer& obs : observers_) {
      obs.OnFavoriteBadgeChanged(tab_id, badge);
    }
  }
  for (Observer& obs : observers_) {
    obs.OnHoverPreviewUpdated(tab_id, snapshot);
  }
}

void OpenLiveDataService::UpdateMailPreview(
    const ItemID& tab_id,
    int unread_count,
    std::vector<MailPreviewItem> items) {
  auto& snapshot = hover_previews_[tab_id];
  snapshot.tab_id = tab_id;
  snapshot.kind = HoverPreviewKind::kMail;
  snapshot.header_title = "Unread";
  snapshot.unread_count = std::max(0, unread_count);
  snapshot.badge_text =
      snapshot.unread_count > 0 ? FormatBadgeCount(snapshot.unread_count)
                                : std::string();
  snapshot.mail_items = std::move(items);
  snapshot.updated_at = NowSec();

  auto prev_it = last_favorite_badges_.find(tab_id);
  if (prev_it == last_favorite_badges_.end() ||
      prev_it->second != snapshot.badge_text) {
    last_favorite_badges_[tab_id] = snapshot.badge_text;
    for (Observer& obs : observers_) {
      obs.OnFavoriteBadgeChanged(tab_id, snapshot.badge_text);
    }
  }
  for (Observer& obs : observers_) {
    obs.OnHoverPreviewUpdated(tab_id, snapshot);
  }
}

void OpenLiveDataService::UpdateLiveItemsPreview(
    const ItemID& tab_id,
    std::string header_title,
    std::vector<LiveFolderItem> items) {
  auto& snapshot = hover_previews_[tab_id];
  snapshot.tab_id = tab_id;
  snapshot.kind = HoverPreviewKind::kGitHubPrs;
  snapshot.header_title = std::move(header_title);
  int unread = 0;
  for (const auto& item : items) {
    if (item.unread) {
      ++unread;
    }
  }
  snapshot.unread_count = unread;
  snapshot.badge_text = unread > 0 ? FormatBadgeCount(unread) : std::string();
  snapshot.live_items = std::move(items);
  snapshot.updated_at = NowSec();

  for (Observer& obs : observers_) {
    obs.OnHoverPreviewUpdated(tab_id, snapshot);
  }
}

std::optional<HoverPreviewSnapshot> OpenLiveDataService::GetHoverPreview(
    const ItemID& tab_id) const {
  auto it = hover_previews_.find(tab_id);
  if (it == hover_previews_.end()) {
    return std::nullopt;
  }
  return it->second;
}

void OpenLiveDataService::ClearTabPreview(const ItemID& tab_id) {
  hover_previews_.erase(tab_id);
}

// static
std::optional<int> OpenLiveDataService::ParseTitleUnreadCount(
    std::string_view title) {
  // Matches FavoriteBadgeCount.parse: "(3) Home / X", "Inbox (12) - Gmail".
  const size_t limit = std::min<size_t>(title.size(), 512);
  for (size_t i = 0; i < limit; ++i) {
    if (title[i] != '(') {
      continue;
    }
    if (i > 0 && !std::isspace(static_cast<unsigned char>(title[i - 1]))) {
      continue;
    }
    size_t j = i + 1;
    int value = 0;
    int digits = 0;
    while (j < limit && digits < 7 &&
           std::isdigit(static_cast<unsigned char>(title[j]))) {
      value = value * 10 + (title[j] - '0');
      ++digits;
      ++j;
    }
    if (digits > 0 && digits <= 6 && j < limit && title[j] == ')' &&
        (j + 1 == limit ||
         std::isspace(static_cast<unsigned char>(title[j + 1])))) {
      return value > 0 ? std::optional<int>(value) : std::nullopt;
    }
  }
  return std::nullopt;
}

// static
std::string OpenLiveDataService::FormatBadgeCount(int count) {
  if (count <= 0) {
    return std::string();
  }
  return count > 99 ? "99+" : base::NumberToString(count);
}

// static
std::vector<MailPreviewItem> OpenLiveDataService::ParseGmailAtomXml(
    std::string_view xml_text) {
  std::vector<MailPreviewItem> items;
  const std::vector<std::string_view> entries =
      SplitXmlBlocks(xml_text, "entry");
  for (std::string_view block : entries) {
    if (items.size() >= 20) {
      break;
    }
    std::string link = ExtractAtomLinkHref(block);
    GURL url(link);
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
      continue;
    }
    MailPreviewItem mail;
    mail.url = url.spec();
    mail.subject = ExtractXmlTagText(block, "title");
    if (mail.subject.empty()) {
      mail.subject = "(no subject)";
    }
    mail.sender = ExtractXmlTagText(block, "name");
    mail.snippet = ExtractXmlTagText(block, "summary");
    std::string ts = ExtractXmlTagText(block, "issued");
    if (ts.empty()) {
      ts = ExtractXmlTagText(block, "modified");
    }
    mail.received_at = ParseTimestampString(ts);
    items.push_back(std::move(mail));
  }
  return items;
}

// ===========================================================================
// Internal Timers & Download Callbacks
// ===========================================================================

void OpenLiveDataService::OnBackgroundTick() {
  if (power_suspended_ || !network_online_) {
    return;
  }
  const TimestampSec now = NowSec();

  // Refresh calendar sources on Arc's 360s interval.
  if (last_calendar_fetch_at_ <= 0.0 ||
      (now - last_calendar_fetch_at_) >= kCalendarFetchIntervalSec) {
    RefreshCalendarNow();
  }

  // Refresh due Live Folders respecting each folder's refresh_interval_sec.
  for (const auto& [folder_id, entry] : live_folders_) {
    if (!entry->state.config.enabled || entry->state.refreshing) {
      continue;
    }
    const double interval = std::max(
        kMinLiveFolderRefreshSec,
        static_cast<double>(entry->state.config.refresh_interval_sec));
    if (entry->state.last_refreshed_at <= 0.0 ||
        (now - entry->state.last_refreshed_at) >= interval) {
      RefreshLiveFolder(folder_id, /*force=*/false);
    }
  }
}

void OpenLiveDataService::OnCalendarTick() {
  if (power_suspended_) {
    return;
  }
  RefreshCalendarSubtitlesAndPreviews(NowSec());
}

void OpenLiveDataService::RefreshIcsFeeds() {
  if (power_suspended_ || !network_online_ || !url_loader_factory_) {
    return;
  }
  for (const std::string& feed_url_str : ics_feed_urls_) {
    if (ics_loaders_.contains(feed_url_str)) {
      continue;
    }
    GURL url(feed_url_str);
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
      continue;
    }
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url;
    request->method = "GET";
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;

    auto loader = network::SimpleURLLoader::Create(std::move(request),
                                                   kLiveDataTrafficAnnotation);
    loader->SetTimeoutDuration(kFeedFetchTimeout);
    network::SimpleURLLoader* raw_loader = loader.get();
    ics_loaders_[feed_url_str] = std::move(loader);

    raw_loader->DownloadToString(
        url_loader_factory_,
        base::BindOnce(&OpenLiveDataService::OnIcsFeedDownloaded,
                       weak_factory_.GetWeakPtr(), feed_url_str),
        kMaxFeedDownloadBytes);
  }
}

void OpenLiveDataService::OnIcsFeedDownloaded(
    std::string feed_url,
    std::optional<std::string> body) {
  ics_loaders_.erase(feed_url);
  if (!body.has_value() || body->empty()) {
    return;
  }
  const TimestampSec now = NowSec();
  ics_events_by_url_[feed_url] = ParseIcsFeed(
      *body, now - kJoinableAfterStartSec, now + 48.0 * 3600.0);
  RebuildMergedCalendarEvents();
  RefreshCalendarSubtitlesAndPreviews(now);
}

void OpenLiveDataService::OnProviderEventsLoaded(
    std::vector<CalendarMeeting> events) {
  provider_calendar_events_ = std::move(events);
  RebuildMergedCalendarEvents();
  RefreshCalendarSubtitlesAndPreviews(NowSec());
}

void OpenLiveDataService::RebuildMergedCalendarEvents() {
  std::map<std::string, CalendarMeeting> dedup;
  auto merge_list = [&](const std::vector<CalendarMeeting>& list) {
    for (const CalendarMeeting& ev : list) {
      const std::string key =
          ev.id + "@" + base::NumberToString(static_cast<int64_t>(ev.starts_at));
      dedup[key] = ev;
    }
  };
  for (const auto& [url, list] : ics_events_by_url_) {
    merge_list(list);
  }
  for (const auto& [tab_id, list] : tab_calendar_events_) {
    merge_list(list);
  }
  merge_list(provider_calendar_events_);

  merged_calendar_events_.clear();
  merged_calendar_events_.reserve(dedup.size());
  for (auto& [k, ev] : dedup) {
    merged_calendar_events_.push_back(std::move(ev));
  }
  std::sort(merged_calendar_events_.begin(), merged_calendar_events_.end(),
            [](const CalendarMeeting& a, const CalendarMeeting& b) {
              return a.starts_at < b.starts_at;
            });
}

void OpenLiveDataService::RefreshCalendarSubtitlesAndPreviews(
    TimestampSec now) {
  const std::optional<CalendarMeeting> next = NextUpcomingMeeting(now);
  const std::string subtitle = next.has_value() ? next->countdown_label
                                                : std::string();
  const std::optional<std::string> key =
      next.has_value()
          ? std::optional<std::string>(next->id + "|" + next->countdown_label +
                                       "|" + next->join_url)
          : std::nullopt;
  if (key != last_announced_meeting_key_) {
    last_announced_meeting_key_ = key;
    for (Observer& obs : observers_) {
      obs.OnUpcomingMeetingChanged(next);
    }
  }

  const std::vector<CalendarMeeting> upcoming = UpcomingMeetings(now, 6);
  for (const ItemID& tab_id : calendar_favorite_tabs_) {
    auto prev_it = last_favorite_subtitles_.find(tab_id);
    if (prev_it == last_favorite_subtitles_.end() ||
        prev_it->second != subtitle) {
      last_favorite_subtitles_[tab_id] = subtitle;
      for (Observer& obs : observers_) {
        obs.OnFavoriteSubtitleChanged(tab_id, subtitle);
      }
    }

    auto& snapshot = hover_previews_[tab_id];
    snapshot.tab_id = tab_id;
    snapshot.kind = HoverPreviewKind::kCalendar;
    snapshot.header_title = "Upcoming";
    snapshot.subtitle_text = subtitle;
    snapshot.calendar_events = upcoming;
    snapshot.updated_at = now;
    for (Observer& obs : observers_) {
      obs.OnHoverPreviewUpdated(tab_id, snapshot);
    }
  }
}

void OpenLiveDataService::OnLiveFolderDownloaded(
    ItemID folder_id,
    std::string provider,
    std::optional<std::string> body) {
  auto it = live_folders_.find(folder_id);
  if (it == live_folders_.end()) {
    return;
  }
  LiveFolderEntry& entry = *it->second;
  entry.loader.reset();
  entry.state.refreshing = false;
  entry.state.last_refreshed_at = NowSec();

  if (!body.has_value() || body->empty()) {
    entry.state.last_error = "Could not fetch Live Folder feed.";
    return;
  }

  std::vector<LiveFolderItem> parsed;
  if (provider == "github_prs" || provider == "github") {
    parsed = ParseGitHubPullRequestsJson(*body);
  } else {
    parsed = ParseFeedXml(*body);
  }

  ApplyLiveFolderItems(entry, std::move(parsed));
}

void OpenLiveDataService::ApplyLiveFolderItems(
    LiveFolderEntry& entry,
    std::vector<LiveFolderItem> fresh_items) {
  std::set<std::string> active_urls;
  for (LiveFolderItem& item : fresh_items) {
    active_urls.insert(item.url);
    const bool is_new = !entry.seen_urls.contains(item.url);
    if (is_new) {
      entry.seen_urls.insert(item.url);
      if (entry.has_initial_fill) {
        entry.unread_urls.insert(item.url);
      }
    }
    item.unread = entry.unread_urls.contains(item.url);
  }

  // Drop unread markers for items that left the feed.
  for (auto it = entry.unread_urls.begin(); it != entry.unread_urls.end();) {
    if (!active_urls.contains(*it)) {
      it = entry.unread_urls.erase(it);
    } else {
      ++it;
    }
  }

  entry.has_initial_fill = true;
  entry.state.items = std::move(fresh_items);
  entry.state.unread_count = static_cast<int>(entry.unread_urls.size());
  entry.state.last_error.clear();

  for (Observer& obs : observers_) {
    obs.OnLiveFolderUpdated(entry.state.folder_id, entry.state.items,
                            entry.state.unread_count);
  }
}

// static
TimestampSec OpenLiveDataService::NowSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

}  // namespace open_unified
