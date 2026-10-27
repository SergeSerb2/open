// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_

#include "base/files/file_path.h"
#include "base/functional/callback.h"

namespace open_engine {

class OpenAdBlockService;

// The --open-adblock-selftest mode (docs/plans/adblock-fork.md §13.1): loads
// |adblock_root| into |service|, prints "OpenAdBlockSelftest:" lines to
// stderr (status, a few checks, the cosmetic query cost), then runs |done|
// with the verdict. A regression gate for the engine, kept behind the switch.
void RunOpenAdBlockSelftest(OpenAdBlockService* service,
                            base::FilePath adblock_root,
                            base::OnceCallback<void(bool)> done);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_SELFTEST_H_
