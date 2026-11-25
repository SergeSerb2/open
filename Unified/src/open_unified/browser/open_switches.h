// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_UNIFIED_BROWSER_OPEN_SWITCHES_H_
#define OPEN_UNIFIED_BROWSER_OPEN_SWITCHES_H_

namespace open_unified::switches {

// NDJSON automation over AF_UNIX (Linux, macOS, Windows 10 1803+). Only in
// builds with open_enable_automation = true (docs/automation.md).
inline constexpr char kAutomationSocket[] = "automation-socket";
// Loopback TCP fallback: 127.0.0.1:<port>. 0 picks a free port; the chosen
// port is written to <user data>/automation.port.
inline constexpr char kAutomationPort[] = "automation-port";

// Skips open://onboarding on a first run (e2e suites that test other flows).
inline constexpr char kSkipOnboarding[] = "open-skip-onboarding";

// Widevine component registration (hook 0008; off by default).
inline constexpr char kEnableWidevine[] = "open-enable-widevine";

// Overrides the directory of the ad-block lists root (current.json and
// generations, docs/plans/adblock-fork.md §9.2). Development and e2e only.
inline constexpr char kAdBlockDir[] = "open-adblock-dir";

// Base URL of a self-hosted Open Sync server for first-run configuration
// (e2e: a local SyncServer/ instance).
inline constexpr char kSyncServer[] = "open-sync-server";

// Environment fallbacks used by the e2e harness.
inline constexpr char kAutomationSocketEnv[] = "OPEN_AUTOMATION_SOCKET";
inline constexpr char kUserDataEnv[] = "OPEN_USER_DATA";

}  // namespace open_unified::switches

#endif  // OPEN_UNIFIED_BROWSER_OPEN_SWITCHES_H_
