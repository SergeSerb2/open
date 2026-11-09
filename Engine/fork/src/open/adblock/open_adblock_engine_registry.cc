// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/open_adblock_engine_registry.h"

#include "base/no_destructor.h"

namespace open_engine {

// static
OpenAdBlockEngineRegistry& OpenAdBlockEngineRegistry::Get() {
  static base::NoDestructor<OpenAdBlockEngineRegistry> registry;
  return *registry;
}

OpenAdBlockEngineRegistry::OpenAdBlockEngineRegistry() {
  DETACH_FROM_SEQUENCE(sequence_checker_);
}

OpenAdBlockEngineRegistry::~OpenAdBlockEngineRegistry() = default;

std::shared_ptr<const EngineHolder> OpenAdBlockEngineRegistry::Find(
    const std::string& key) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto it = engines_.find(key);
  if (it == engines_.end()) {
    return nullptr;
  }
  std::shared_ptr<const EngineHolder> engine = it->second.lock();
  if (!engine) {
    engines_.erase(it);
  }
  return engine;
}

void OpenAdBlockEngineRegistry::Insert(
    const std::string& key,
    const std::shared_ptr<const EngineHolder>& engine) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  // Drop entries whose engine is gone, so the map stays small.
  std::erase_if(engines_, [](const auto& entry) { return entry.second.expired(); });
  engines_[key] = engine;
}

}  // namespace open_engine
