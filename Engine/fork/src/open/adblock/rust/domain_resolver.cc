// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/rust/domain_resolver.h"

#include <string>
#include <string_view>

#include "net/base/registry_controlled_domains/registry_controlled_domain.h"

namespace open_adblock {

size_t open_adblock_domain_start(rust::Str host) {
  const std::string_view input(host.data(), host.size());
  const std::string domain =
      net::registry_controlled_domains::GetDomainAndRegistry(
          input, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  // The crate needs offsets into its input. Canonicalization can change a
  // host, so accept a suffix only when its bytes still match exactly.
  if (domain.empty() || !input.ends_with(domain)) {
    return 0;
  }
  return input.size() - domain.size();
}

}  // namespace open_adblock
