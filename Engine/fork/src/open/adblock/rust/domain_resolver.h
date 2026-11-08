// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_RUST_DOMAIN_RESOLVER_H_
#define OPEN_ADBLOCK_RUST_DOMAIN_RESOLVER_H_

#include <cstddef>

#include "third_party/rust/cxx/v1/cxx.h"

namespace open_adblock {
// Byte offset of eTLD+1 in |host|, or 0 when there is no registrable domain.
// Includes private registries, like the crate's original resolver.
size_t open_adblock_domain_start(rust::Str host);
}  // namespace open_adblock

#endif  // OPEN_ADBLOCK_RUST_DOMAIN_RESOLVER_H_
