// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_COSMETICS_HOST_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_COSMETICS_HOST_H_

namespace service_manager {
class BinderRegistry;
}

namespace open_engine {

class OpenAdBlockService;

// Setup on UI only. Capture a refcounted matcher, never a Profile/service
// pointer; the registry dispatches the binder and receiver on its runner.
void ExposeAdBlockInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    OpenAdBlockService* service);

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_COSMETICS_HOST_H_
