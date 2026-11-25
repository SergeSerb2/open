// Copyright 2026 The Open Authors. All rights reserved.
// Out-of-line special member definitions for complex data model types in
// open_types.h (Chromium Clang find-bad-constructs compliance).

#include "open_unified/core/model/open_types.h"

#include <utility>

namespace open_unified {

SpaceTheme::SpaceTheme() = default;
SpaceTheme::SpaceTheme(const SpaceTheme&) = default;
SpaceTheme::SpaceTheme(SpaceTheme&&) noexcept = default;
SpaceTheme& SpaceTheme::operator=(const SpaceTheme&) = default;
SpaceTheme& SpaceTheme::operator=(SpaceTheme&&) noexcept = default;
SpaceTheme::~SpaceTheme() = default;

SpaceIcon::SpaceIcon() = default;
SpaceIcon::SpaceIcon(SpaceIconKind kind, std::string value)
    : kind(kind), value(std::move(value)) {}
SpaceIcon::SpaceIcon(const SpaceIcon&) = default;
SpaceIcon::SpaceIcon(SpaceIcon&&) noexcept = default;
SpaceIcon& SpaceIcon::operator=(const SpaceIcon&) = default;
SpaceIcon& SpaceIcon::operator=(SpaceIcon&&) noexcept = default;
SpaceIcon::~SpaceIcon() = default;

LiveItemInfo::LiveItemInfo() = default;
LiveItemInfo::LiveItemInfo(const LiveItemInfo&) = default;
LiveItemInfo::LiveItemInfo(LiveItemInfo&&) noexcept = default;
LiveItemInfo& LiveItemInfo::operator=(const LiveItemInfo&) = default;
LiveItemInfo& LiveItemInfo::operator=(LiveItemInfo&&) noexcept = default;
LiveItemInfo::~LiveItemInfo() = default;

LiveFolderConfig::LiveFolderConfig() = default;
LiveFolderConfig::LiveFolderConfig(const LiveFolderConfig&) = default;
LiveFolderConfig::LiveFolderConfig(LiveFolderConfig&&) noexcept = default;
LiveFolderConfig& LiveFolderConfig::operator=(const LiveFolderConfig&) =
    default;
LiveFolderConfig& LiveFolderConfig::operator=(LiveFolderConfig&&) noexcept =
    default;
LiveFolderConfig::~LiveFolderConfig() = default;

TabLiveState::TabLiveState() = default;
TabLiveState::TabLiveState(const TabLiveState&) = default;
TabLiveState::TabLiveState(TabLiveState&&) noexcept = default;
TabLiveState& TabLiveState::operator=(const TabLiveState&) = default;
TabLiveState& TabLiveState::operator=(TabLiveState&&) noexcept = default;
TabLiveState::~TabLiveState() = default;

Tab::Tab() = default;
Tab::Tab(const Tab&) = default;
Tab::Tab(Tab&&) noexcept = default;
Tab& Tab::operator=(const Tab&) = default;
Tab& Tab::operator=(Tab&&) noexcept = default;
Tab::~Tab() = default;

Split::Split() = default;
Split::Split(const Split&) = default;
Split::Split(Split&&) noexcept = default;
Split& Split::operator=(const Split&) = default;
Split& Split::operator=(Split&&) noexcept = default;
Split::~Split() = default;

Folder::Folder() = default;
Folder::Folder(const Folder&) = default;
Folder::Folder(Folder&&) noexcept = default;
Folder& Folder::operator=(const Folder&) = default;
Folder& Folder::operator=(Folder&&) noexcept = default;
Folder::~Folder() = default;

SidebarNode::SidebarNode() : data(Tab{}) {}
SidebarNode::SidebarNode(Tab t) : data(std::move(t)) {}
SidebarNode::SidebarNode(Folder f) : data(std::move(f)) {}
SidebarNode::SidebarNode(Split s) : data(std::move(s)) {}
SidebarNode::SidebarNode(const SidebarNode&) = default;
SidebarNode::SidebarNode(SidebarNode&&) noexcept = default;
SidebarNode& SidebarNode::operator=(const SidebarNode&) = default;
SidebarNode& SidebarNode::operator=(SidebarNode&&) noexcept = default;
SidebarNode::~SidebarNode() = default;

CustomSearchEngine::CustomSearchEngine() = default;
CustomSearchEngine::CustomSearchEngine(const CustomSearchEngine&) = default;
CustomSearchEngine::CustomSearchEngine(CustomSearchEngine&&) noexcept = default;
CustomSearchEngine& CustomSearchEngine::operator=(const CustomSearchEngine&) =
    default;
CustomSearchEngine& CustomSearchEngine::operator=(
    CustomSearchEngine&&) noexcept = default;
CustomSearchEngine::~CustomSearchEngine() = default;

ProfileSettings::ProfileSettings() = default;
ProfileSettings::ProfileSettings(const ProfileSettings&) = default;
ProfileSettings::ProfileSettings(ProfileSettings&&) noexcept = default;
ProfileSettings& ProfileSettings::operator=(const ProfileSettings&) = default;
ProfileSettings& ProfileSettings::operator=(ProfileSettings&&) noexcept =
    default;
ProfileSettings::~ProfileSettings() = default;

Profile::Profile() = default;
Profile::Profile(const Profile&) = default;
Profile::Profile(Profile&&) noexcept = default;
Profile& Profile::operator=(const Profile&) = default;
Profile& Profile::operator=(Profile&&) noexcept = default;
Profile::~Profile() = default;

Space::Space() = default;
Space::Space(const Space&) = default;
Space::Space(Space&&) noexcept = default;
Space& Space::operator=(const Space&) = default;
Space& Space::operator=(Space&&) noexcept = default;
Space::~Space() = default;

BrowserWindowState::BrowserWindowState() = default;
BrowserWindowState::BrowserWindowState(const BrowserWindowState&) = default;
BrowserWindowState::BrowserWindowState(BrowserWindowState&&) noexcept = default;
BrowserWindowState& BrowserWindowState::operator=(const BrowserWindowState&) =
    default;
BrowserWindowState& BrowserWindowState::operator=(
    BrowserWindowState&&) noexcept = default;
BrowserWindowState::~BrowserWindowState() = default;

RoutingDestination::RoutingDestination() = default;
RoutingDestination::RoutingDestination(RoutingDestinationKind kind,
                                       std::optional<SpaceID> space_id,
                                       std::optional<ProfileID> profile_id)
    : kind(kind),
      space_id(std::move(space_id)),
      profile_id(std::move(profile_id)) {}
RoutingDestination::RoutingDestination(const RoutingDestination&) = default;
RoutingDestination::RoutingDestination(RoutingDestination&&) noexcept = default;
RoutingDestination& RoutingDestination::operator=(const RoutingDestination&) =
    default;
RoutingDestination& RoutingDestination::operator=(
    RoutingDestination&&) noexcept = default;
RoutingDestination::~RoutingDestination() = default;

RoutingRule::RoutingRule() = default;
RoutingRule::RoutingRule(const RoutingRule&) = default;
RoutingRule::RoutingRule(RoutingRule&&) noexcept = default;
RoutingRule& RoutingRule::operator=(const RoutingRule&) = default;
RoutingRule& RoutingRule::operator=(RoutingRule&&) noexcept = default;
RoutingRule::~RoutingRule() = default;

TreeChange::TreeChange() = default;
TreeChange::TreeChange(const TreeChange&) = default;
TreeChange::TreeChange(TreeChange&&) noexcept = default;
TreeChange& TreeChange::operator=(const TreeChange&) = default;
TreeChange& TreeChange::operator=(TreeChange&&) noexcept = default;
TreeChange::~TreeChange() = default;

ArchivedTabRecord::ArchivedTabRecord() = default;
ArchivedTabRecord::ArchivedTabRecord(const ArchivedTabRecord&) = default;
ArchivedTabRecord::ArchivedTabRecord(ArchivedTabRecord&&) noexcept = default;
ArchivedTabRecord& ArchivedTabRecord::operator=(const ArchivedTabRecord&) =
    default;
ArchivedTabRecord& ArchivedTabRecord::operator=(ArchivedTabRecord&&) noexcept =
    default;
ArchivedTabRecord::~ArchivedTabRecord() = default;

HistoryEntry::HistoryEntry() = default;
HistoryEntry::HistoryEntry(const HistoryEntry&) = default;
HistoryEntry::HistoryEntry(HistoryEntry&&) noexcept = default;
HistoryEntry& HistoryEntry::operator=(const HistoryEntry&) = default;
HistoryEntry& HistoryEntry::operator=(HistoryEntry&&) noexcept = default;
HistoryEntry::~HistoryEntry() = default;

DownloadRecord::DownloadRecord() = default;
DownloadRecord::DownloadRecord(const DownloadRecord&) = default;
DownloadRecord::DownloadRecord(DownloadRecord&&) noexcept = default;
DownloadRecord& DownloadRecord::operator=(const DownloadRecord&) = default;
DownloadRecord& DownloadRecord::operator=(DownloadRecord&&) noexcept = default;
DownloadRecord::~DownloadRecord() = default;

ZappedElement::ZappedElement() = default;
ZappedElement::ZappedElement(std::string id,
                             std::string selector,
                             std::string label)
    : id(std::move(id)),
      selector(std::move(selector)),
      label(std::move(label)) {}
ZappedElement::ZappedElement(const ZappedElement&) = default;
ZappedElement::ZappedElement(ZappedElement&&) noexcept = default;
ZappedElement& ZappedElement::operator=(const ZappedElement&) = default;
ZappedElement& ZappedElement::operator=(ZappedElement&&) noexcept = default;
ZappedElement::~ZappedElement() = default;

Boost::Boost() = default;
Boost::Boost(const Boost&) = default;
Boost::Boost(Boost&&) noexcept = default;
Boost& Boost::operator=(const Boost&) = default;
Boost& Boost::operator=(Boost&&) noexcept = default;
Boost::~Boost() = default;

NoteFormatRange::NoteFormatRange() = default;
NoteFormatRange::NoteFormatRange(const NoteFormatRange&) = default;
NoteFormatRange::NoteFormatRange(NoteFormatRange&&) noexcept = default;
NoteFormatRange& NoteFormatRange::operator=(const NoteFormatRange&) = default;
NoteFormatRange& NoteFormatRange::operator=(NoteFormatRange&&) noexcept =
    default;
NoteFormatRange::~NoteFormatRange() = default;

NoteDocument::NoteDocument() = default;
NoteDocument::NoteDocument(const NoteDocument&) = default;
NoteDocument::NoteDocument(NoteDocument&&) noexcept = default;
NoteDocument& NoteDocument::operator=(const NoteDocument&) = default;
NoteDocument& NoteDocument::operator=(NoteDocument&&) noexcept = default;
NoteDocument::~NoteDocument() = default;

EaselElement::EaselElement() = default;
EaselElement::EaselElement(const EaselElement&) = default;
EaselElement::EaselElement(EaselElement&&) noexcept = default;
EaselElement& EaselElement::operator=(const EaselElement&) = default;
EaselElement& EaselElement::operator=(EaselElement&&) noexcept = default;
EaselElement::~EaselElement() = default;

EaselDocument::EaselDocument() = default;
EaselDocument::EaselDocument(const EaselDocument&) = default;
EaselDocument::EaselDocument(EaselDocument&&) noexcept = default;
EaselDocument& EaselDocument::operator=(const EaselDocument&) = default;
EaselDocument& EaselDocument::operator=(EaselDocument&&) noexcept = default;
EaselDocument::~EaselDocument() = default;

}  // namespace open_unified
