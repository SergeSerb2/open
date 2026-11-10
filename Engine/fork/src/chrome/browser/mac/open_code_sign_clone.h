// Copyright 2026 The Open Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CHROME_BROWSER_MAC_OPEN_CODE_SIGN_CLONE_H_
#define CHROME_BROWSER_MAC_OPEN_CODE_SIGN_CLONE_H_

#include <optional>

#include "base/files/file_path.h"
#include "base/files/scoped_file.h"
#include "base/functional/function_ref.h"

namespace code_sign_clone_manager {

struct OpenCodeSignClone {
  base::FilePath bundle;
  // A shared lease prevents another browser from replacing an in-use clone.
  base::ScopedFD lease;
};

// Runs on the manager's blocking sequence. The caller must retain the lease
// until shutdown. Failure means use Chromium's original per-run clone, never
// disable cloning. `clone_app` is synchronous and must not retain arguments.
std::optional<OpenCodeSignClone> GetOpenCodeSignClone(
    const base::FilePath& source,
    const base::FilePath& executable_name,
    base::FunctionRef<bool(const base::FilePath&,
                           const base::FilePath&,
                           const base::FilePath&)> clone_app);

}  // namespace code_sign_clone_manager

#endif  // CHROME_BROWSER_MAC_OPEN_CODE_SIGN_CLONE_H_
