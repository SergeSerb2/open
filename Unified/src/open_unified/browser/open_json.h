// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// base::Value <-> open_types.h conversions shared by the open:// WebUI
// handlers and OpenAutomationServer. Keys are snake_case and match
// Unified/webui/src/shared/bridge.ts (the Preact frontend's typed contract).
// Every *FromValue() validates ranges and returns std::nullopt for input it
// cannot trust; WebUI payloads are renderer-controlled.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_JSON_H_
#define OPEN_UNIFIED_BROWSER_OPEN_JSON_H_

#include <optional>
#include <string>
#include <string_view>

#include "base/values.h"
#include "open_unified/core/model/open_types.h"

namespace open_unified::json {

// Enum <-> string (the strings bridge.ts uses).
std::string_view ThemeWheelName(ThemeWheel wheel);
std::string_view ThemeAppearanceName(ThemeAppearance appearance);
std::string_view ThemeTextureName(ThemeTexture texture);
std::string_view SpaceIconKindName(SpaceIconKind kind);
std::string_view AutoArchiveIntervalName(AutoArchiveInterval interval);
std::string_view SleepModeName(SleepMode mode);
std::string_view RoutingDestinationKindName(RoutingDestinationKind kind);
std::string_view SleepPhaseName(SleepPhase phase);
std::string_view NodeParentKindName(NodeParentKind kind);

std::optional<ThemeWheel> ParseThemeWheel(std::string_view value);
std::optional<ThemeAppearance> ParseThemeAppearance(std::string_view value);
std::optional<ThemeTexture> ParseThemeTexture(std::string_view value);
std::optional<SpaceIconKind> ParseSpaceIconKind(std::string_view value);
std::optional<AutoArchiveInterval> ParseAutoArchiveInterval(
    std::string_view value);
std::optional<SleepMode> ParseSleepMode(std::string_view value);
std::optional<RoutingDestinationKind> ParseRoutingDestinationKind(
    std::string_view value);

// Leaf types.
base::DictValue ColorToValue(const RGBAColor& color);
std::optional<RGBAColor> ColorFromValue(const base::Value* value);
base::DictValue SpaceIconToValue(const SpaceIcon& icon);
std::optional<SpaceIcon> SpaceIconFromValue(const base::Value* value);
base::DictValue SpaceStyleToValue(const SpaceStyle& style);
std::optional<SpaceStyle> SpaceStyleFromValue(const base::Value* value);
base::DictValue SpaceThemeToValue(const SpaceTheme& theme);

// Model types.
base::DictValue TabToValue(const Tab& tab);
base::DictValue TabLiveStateToValue(const TabLiveState& live);
base::DictValue SidebarNodeToValue(const SidebarNode& node);
base::DictValue ProfileSettingsToValue(const ProfileSettings& settings);
// Applies the keys present in |dict| onto |settings|; false on a bad value
// (|settings| is left unchanged then).
bool ApplyProfileSettings(const base::DictValue& dict,
                          ProfileSettings* settings);
base::DictValue RoutingDestinationToValue(const RoutingDestination& dest);
std::optional<RoutingDestination> RoutingDestinationFromValue(
    const base::Value* value);
base::DictValue RoutingRuleToValue(const RoutingRule& rule);
std::optional<RoutingRule> RoutingRuleFromValue(const base::Value* value);

// Library records.
base::DictValue HistoryEntryToValue(const HistoryEntry& entry,
                                      const ProfileID& profile_id);
base::DictValue ArchivedTabToValue(const ArchivedTabRecord& record,
                                     const std::string& space_title);
base::DictValue DownloadToValue(const DownloadRecord& record,
                                  const ProfileID& profile_id);

// Boosts.
base::DictValue BoostToValue(const Boost& boost);
std::optional<Boost> BoostFromValue(const base::Value* value);

// Documents.
base::DictValue NoteToValue(const NoteDocument& note);
std::optional<NoteDocument> NoteFromValue(const base::Value* value);
base::DictValue EaselToValue(const EaselDocument& easel);
std::optional<EaselDocument> EaselFromValue(const base::Value* value);

// Small readers with defaults for optional payload keys.
std::string GetString(const base::DictValue& dict,
                      std::string_view key,
                      std::string_view fallback = {});
std::optional<std::string> FindString(const base::DictValue& dict,
                                      std::string_view key);
bool GetBool(const base::DictValue& dict, std::string_view key,
             bool fallback);
double GetDouble(const base::DictValue& dict, std::string_view key,
                 double fallback);
int GetInt(const base::DictValue& dict, std::string_view key, int fallback);

}  // namespace open_unified::json

#endif  // OPEN_UNIFIED_BROWSER_OPEN_JSON_H_
