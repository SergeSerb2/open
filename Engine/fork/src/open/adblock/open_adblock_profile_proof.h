// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_PROFILE_PROOF_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_PROFILE_PROOF_H_
#include "base/files/file_path.h"
#include "base/functional/callback.h"
namespace open_engine {
void RunOpenAdBlockProfileProof(base::FilePath root,
                               base::OnceCallback<void(bool)> done);
}
#endif
