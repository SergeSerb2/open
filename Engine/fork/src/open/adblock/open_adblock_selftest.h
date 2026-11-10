// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_

#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "open/adblock/open_adblock_types.h"

namespace open_engine {

class OpenAdBlockService;

// The --open-adblock-selftest mode (docs/plans/adblock-fork.md §13.1): loads
// |adblock_root| into |service|, prints "OpenAdBlockSelftest:" lines to
// stderr (status, a few checks, the cosmetic query cost), then runs |done|
// with the verdict. A regression gate for the engine, kept behind the switch.
void RunOpenAdBlockSelftest(OpenAdBlockService* service,
                            base::FilePath adblock_root,
                            base::OnceCallback<void(bool)> done);

// In-process allocation receipts, enabled only by the diagnostic switch.
void RecordOpenAdBlockMemoryPhase(const char* phase);

// Matcher-sequence shutdown receipt, after queued synthetic checks drain.
// Prints nothing when the non-official bench-load switch was not used.
void PrintOpenAdBlockBenchLoadCount();

// One line of |status| for harness logs: names, numbers and the error, never
// page data.
std::string AdBlockStatusText(const AdBlockStatus& status);

// The cefsimple smoke harness (§13.1): loads |adblock_root| into |service|
// and prints "OpenAdBlockSmoke: load result=<r> <status>" when it is done.
void LoadOpenAdBlockForSmoke(OpenAdBlockService* service,
                             base::FilePath adblock_root);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_
