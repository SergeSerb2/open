// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef OPEN_BROWSER_PROFILES_OPEN_PROFILE_CONTEXT_H_
#define OPEN_BROWSER_PROFILES_OPEN_PROFILE_CONTEXT_H_

class Profile;

namespace open_engine {
// Called before CEF detaches its native Profile pointer. Does not retain CEF.
void ProfileContextClosed(Profile* profile);
}  // namespace open_engine

#endif  // OPEN_BROWSER_PROFILES_OPEN_PROFILE_CONTEXT_H_
