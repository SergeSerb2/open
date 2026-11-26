// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// OpenLiveDataService (core/livedata — compiled inside open_unified_core):
//   1. Calendar Meeting State & Join Meeting (Cmd+Ctrl+J):
//      - Parses iCal (.ics) feeds, ingests live Google/Outlook/Notion Calendar
//        tab metadata, and provides a macOS EventKit-ready CalendarEventProvider
//        hook interface.
//      - Detects video-call links (Google Meet, Zoom, Teams, Webex, Whereby,
//        FaceTime, Slack Huddle, Around) and computes countdown labels
//        ("in 5m", "Now", "3m ago") feeding sidebar favorite subtitles and
//        CommandId::kJoinMeeting.
//   2. Live Folders Engine (GitHub PRs / RSS 2.0 & Atom Feeds):
//      - Periodic background refresher respecting power sleep & network state
//        via network::SimpleURLLoader + URLLoaderFactory*.
//      - Tracks per-folder unread counts and notifies Observer::OnLiveFolderUpdated.
//   3. Live Hover Preview Metadata Cache & Favorite Unread Badges:
//      - Caches per-tab/favorite preview snapshots (upcoming calendar events,
//        unread mail snippets/counts, GitHub PR status items) and parses
//        page-title unread counts ("(3) Home / X", "Inbox (12) - Gmail").
//
// GN layering rule: core/livedata/* MUST NEVER include browser/ or ui/ headers.

#ifndef OPEN_UNIFIED_CORE_LIVEDATA_OPEN_LIVEDATA_SERVICE_H_
#define OPEN_UNIFIED_CORE_LIVEDATA_OPEN_LIVEDATA_SERVICE_H_

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "base/timer/timer.h"
#include "open_unified/core/model/open_types.h"

namespace network {
class SimpleURLLoader;
namespace mojom {
class URLLoaderFactory;
}  // namespace mojom
}  // namespace network

namespace open_unified {

// ===========================================================================
// Calendar & Join Meeting Types
// ===========================================================================

enum class MeetingService {
  kGoogleMeet,
  kZoom,
  kTeams,
  kWebex,
  kWhereby,
  kFaceTime,
  kSlackHuddle,
  kAround,
  kOther,
};

struct DetectedMeetingLink {
  MeetingService service = MeetingService::kOther;
  std::string url;
  std::string service_name;

  bool operator==(const DetectedMeetingLink&) const = default;
};

struct CalendarMeeting {
  CalendarMeeting();
  CalendarMeeting(const CalendarMeeting&);
  CalendarMeeting(CalendarMeeting&&) noexcept;
  CalendarMeeting& operator=(const CalendarMeeting&);
  CalendarMeeting& operator=(CalendarMeeting&&) noexcept;
  ~CalendarMeeting();

  std::string id;
  std::string title;
  TimestampSec starts_at = 0.0;
  TimestampSec ends_at = 0.0;
  bool is_all_day = false;
  bool is_declined = false;
  bool is_canceled = false;
  std::string calendar_title;
  std::string location;
  std::string notes;
  std::string join_url;
  MeetingService service = MeetingService::kOther;
  // Populated by NextUpcomingMeeting / UpcomingMeetings: "in 5m", "Now", "3m ago".
  std::string countdown_label;
};

enum class CalendarAccessState {
  kNotDetermined,
  kGranted,
  kDenied,
  kRestricted,
};

// Platform calendar provider hook (e.g., macOS EventKit adapter implemented
// outside core/livedata without introducing AppKit/EventKit deps here).
class CalendarEventProvider {
 public:
  using AccessCallback = base::OnceCallback<void(CalendarAccessState)>;
  using EventsCallback = base::OnceCallback<void(std::vector<CalendarMeeting>)>;

  virtual ~CalendarEventProvider() = default;

  virtual CalendarAccessState GetAccessState() const = 0;
  virtual void RequestAccess(AccessCallback callback) = 0;
  virtual void FetchEvents(TimestampSec start,
                           TimestampSec end,
                           EventsCallback callback) = 0;
};

// ===========================================================================
// Live Folder Types
// ===========================================================================

struct LiveFolderItem {
  LiveFolderItem();
  LiveFolderItem(const LiveFolderItem&);
  LiveFolderItem(LiveFolderItem&&) noexcept;
  LiveFolderItem& operator=(const LiveFolderItem&);
  LiveFolderItem& operator=(LiveFolderItem&&) noexcept;
  ~LiveFolderItem();

  std::string id;
  std::string title;
  std::string url;
  std::string subtitle;
  std::string status_badge;
  TimestampSec updated_at = 0.0;
  bool unread = false;
};

struct LiveFolderState {
  LiveFolderState();
  LiveFolderState(const LiveFolderState&);
  LiveFolderState(LiveFolderState&&) noexcept;
  LiveFolderState& operator=(const LiveFolderState&);
  LiveFolderState& operator=(LiveFolderState&&) noexcept;
  ~LiveFolderState();

  ItemID folder_id;
  LiveFolderConfig config;
  std::vector<LiveFolderItem> items;
  int unread_count = 0;
  TimestampSec last_refreshed_at = 0.0;
  std::string last_error;
  bool refreshing = false;
};

// ===========================================================================
// Hover Preview & Favorite Badge Cache Types
// ===========================================================================

enum class HoverPreviewKind {
  kNone,
  kCalendar,
  kMail,
  kGitHubPrs,
  kRecents,
};

struct MailPreviewItem {
  MailPreviewItem();
  MailPreviewItem(const MailPreviewItem&);
  MailPreviewItem(MailPreviewItem&&) noexcept;
  MailPreviewItem& operator=(const MailPreviewItem&);
  MailPreviewItem& operator=(MailPreviewItem&&) noexcept;
  ~MailPreviewItem();

  std::string subject;
  std::string sender;
  std::string snippet;
  std::string url;
  TimestampSec received_at = 0.0;
};

struct HoverPreviewSnapshot {
  HoverPreviewSnapshot();
  HoverPreviewSnapshot(const HoverPreviewSnapshot&);
  HoverPreviewSnapshot(HoverPreviewSnapshot&&) noexcept;
  HoverPreviewSnapshot& operator=(const HoverPreviewSnapshot&);
  HoverPreviewSnapshot& operator=(HoverPreviewSnapshot&&) noexcept;
  ~HoverPreviewSnapshot();

  ItemID tab_id;
  HoverPreviewKind kind = HoverPreviewKind::kNone;
  std::string header_title;
  int unread_count = 0;
  std::string badge_text;
  std::string subtitle_text;
  std::vector<CalendarMeeting> calendar_events;
  std::vector<MailPreviewItem> mail_items;
  std::vector<LiveFolderItem> live_items;
  TimestampSec updated_at = 0.0;
};

// ===========================================================================
// OpenLiveDataService
// ===========================================================================

class OpenLiveDataService {
 public:
  // Arc's built-in limits (OpenLiveData/Calendar.swift, LiveCalendar.swift,
  // LiveFolders.swift).
  static constexpr double kJoinableAfterStartSec = 10.0 * 60.0;
  static constexpr double kCountdownLeadSec = 60.0 * 60.0;
  static constexpr double kMinLiveFolderRefreshSec = 10.0;
  static constexpr size_t kMaxLiveFolderItems = 50;

  class Observer : public base::CheckedObserver {
   public:
    virtual void OnUpcomingMeetingChanged(
        const std::optional<CalendarMeeting>& meeting) {}
    virtual void OnFavoriteSubtitleChanged(const ItemID& tab_id,
                                           const std::string& subtitle) {}
    virtual void OnFavoriteBadgeChanged(const ItemID& tab_id,
                                        const std::string& badge_text) {}
    virtual void OnLiveFolderUpdated(const ItemID& folder_id,
                                     const std::vector<LiveFolderItem>& items,
                                     int unread_count) {}
    virtual void OnHoverPreviewUpdated(const ItemID& tab_id,
                                       const HoverPreviewSnapshot& snapshot) {}
  };

  OpenLiveDataService();
  OpenLiveDataService(const OpenLiveDataService&) = delete;
  OpenLiveDataService& operator=(const OpenLiveDataService&) = delete;
  ~OpenLiveDataService();

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

  // Injects Chromium's URLLoaderFactory (not owned; pass nullptr before
  // Profile teardown).
  void SetURLLoaderFactory(network::mojom::URLLoaderFactory* factory);

  // Optional GitHub personal access token / session token for GitHub API
  // Live Folders (never logged or persisted by this service).
  void SetGitHubBearerToken(std::string token);

  // Lifecycle & power/network gating (pauses background polling on sleep or
  // offline state).
  void Start();
  void Stop();
  void SetPowerSuspended(bool suspended);
  void SetNetworkOnline(bool online);

  // --- Calendar & Join Meeting ---------------------------------------------

  void SetCalendarEventProvider(
      std::unique_ptr<CalendarEventProvider> provider);
  CalendarEventProvider* calendar_provider() const {
    return calendar_provider_.get();
  }

  // Configures one or more iCal (.ics) feed URLs (from preferences).
  void SetIcsFeedUrls(std::vector<std::string> urls);
  const std::vector<std::string>& ics_feed_urls() const {
    return ics_feed_urls_;
  }
  void RefreshCalendarNow();

  // Ingests calendar events or title/notification metadata extracted from a
  // Google Calendar, Outlook Calendar, or Notion Calendar Favorite tab.
  void IngestCalendarTabMetadata(
      const ItemID& tab_id,
      const std::string& tab_url,
      const std::string& page_title,
      const std::vector<CalendarMeeting>& extracted_events = {});
  void RegisterCalendarFavoriteTab(const ItemID& tab_id,
                                   const std::string& tab_url);
  void UnregisterFavoriteTab(const ItemID& tab_id);

  // Returns the next joinable meeting (within join window), with countdown_label
  // populated ("in 5m", "Now", "3m ago"), or nullopt if none.
  std::optional<CalendarMeeting> NextUpcomingMeeting(
      TimestampSec now = 0.0) const;

  // Returns upcoming events sorted by start time for calendar hover previews.
  std::vector<CalendarMeeting> UpcomingMeetings(TimestampSec now = 0.0,
                                                size_t max_count = 6) const;

  // Static calendar utilities.
  static std::optional<DetectedMeetingLink> ClassifyMeetingUrl(
      std::string_view url);
  static std::optional<DetectedMeetingLink> DetectMeetingLink(
      std::string_view url,
      std::string_view location,
      std::string_view notes);
  static std::string FormatCountdownLabel(TimestampSec starts_at,
                                          TimestampSec now);
  static bool IsCalendarFavoriteUrl(std::string_view url);
  static std::vector<CalendarMeeting> ParseIcsFeed(
      std::string_view ics_text,
      TimestampSec window_start = 0.0,
      TimestampSec window_end = 0.0);

  // --- Live Folders Engine -------------------------------------------------

  void RegisterLiveFolder(const ItemID& folder_id,
                          const LiveFolderConfig& config);
  void UnregisterLiveFolder(const ItemID& folder_id);
  bool RefreshLiveFolder(const ItemID& folder_id, bool force = false);
  void RefreshAllLiveFolders(bool force = false);

  std::optional<LiveFolderState> GetLiveFolderState(
      const ItemID& folder_id) const;
  int GetLiveFolderUnreadCount(const ItemID& folder_id) const;
  void MarkLiveFolderItemRead(const ItemID& folder_id,
                              const std::string& item_url);
  void MarkLiveFolderAllRead(const ItemID& folder_id);

  // Static parsers (also usable directly on pre-fetched payloads).
  static std::vector<LiveFolderItem> ParseGitHubPullRequestsJson(
      std::string_view json_text);
  static std::vector<LiveFolderItem> ParseFeedXml(std::string_view xml_text);

  // --- Hover Preview Metadata Cache & Favorite Unread Badges ---------------

  // Parses unread count from a Favorite tab's title (Gmail, X/Twitter,
  // WhatsApp) and notifies OnFavoriteBadgeChanged / OnHoverPreviewUpdated.
  void UpdateTabTitleForBadge(const ItemID& tab_id,
                              const std::string& url,
                              const std::string& title);
  void UpdateMailPreview(const ItemID& tab_id,
                         int unread_count,
                         std::vector<MailPreviewItem> items);
  void UpdateLiveItemsPreview(const ItemID& tab_id,
                              std::string header_title,
                              std::vector<LiveFolderItem> items);
  std::optional<HoverPreviewSnapshot> GetHoverPreview(
      const ItemID& tab_id) const;
  void ClearTabPreview(const ItemID& tab_id);

  static std::optional<int> ParseTitleUnreadCount(std::string_view title);
  static std::string FormatBadgeCount(int count);
  static std::vector<MailPreviewItem> ParseGmailAtomXml(
      std::string_view xml_text);

 private:
  struct LiveFolderEntry {
    LiveFolderState state;
    std::set<std::string> seen_urls;
    std::set<std::string> unread_urls;
    bool has_initial_fill = false;
    std::unique_ptr<network::SimpleURLLoader> loader;
  };

  void OnBackgroundTick();
  void OnCalendarTick();
  void RefreshIcsFeeds();
  void OnIcsFeedDownloaded(std::string feed_url,
                           std::optional<std::string> body);
  void OnProviderEventsLoaded(std::vector<CalendarMeeting> events);
  void RebuildMergedCalendarEvents();
  void RefreshCalendarSubtitlesAndPreviews(TimestampSec now);

  void OnLiveFolderDownloaded(ItemID folder_id,
                              std::string provider,
                              std::optional<std::string> body);
  void ApplyLiveFolderItems(LiveFolderEntry& entry,
                            std::vector<LiveFolderItem> fresh_items);

  static TimestampSec NowSec();

  raw_ptr<network::mojom::URLLoaderFactory> url_loader_factory_ = nullptr;
  std::string github_bearer_token_;
  bool started_ = false;
  bool power_suspended_ = false;
  bool network_online_ = true;

  base::RepeatingTimer background_timer_;
  base::RepeatingTimer calendar_tick_timer_;

  // Calendar sources.
  std::unique_ptr<CalendarEventProvider> calendar_provider_;
  std::vector<std::string> ics_feed_urls_;
  std::map<std::string, std::unique_ptr<network::SimpleURLLoader>> ics_loaders_;
  std::map<std::string, std::vector<CalendarMeeting>> ics_events_by_url_;
  std::map<ItemID, std::vector<CalendarMeeting>> tab_calendar_events_;
  std::vector<CalendarMeeting> provider_calendar_events_;
  std::vector<CalendarMeeting> merged_calendar_events_;
  std::set<ItemID> calendar_favorite_tabs_;
  std::map<ItemID, std::string> last_favorite_subtitles_;
  std::map<ItemID, std::string> last_favorite_badges_;
  std::optional<std::string> last_announced_meeting_key_;
  TimestampSec last_calendar_fetch_at_ = 0.0;

  // Live folders.
  std::map<ItemID, std::unique_ptr<LiveFolderEntry>> live_folders_;

  // Hover preview cache.
  std::map<ItemID, HoverPreviewSnapshot> hover_previews_;

  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<OpenLiveDataService> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_LIVEDATA_OPEN_LIVEDATA_SERVICE_H_
