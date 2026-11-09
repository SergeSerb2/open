// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_ENGINE_REGISTRY_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_ENGINE_REGISTRY_H_

#include <map>
#include <memory>
#include <string>

#include "base/no_destructor.h"
#include "base/sequence_checker.h"
#include "open/adblock/open_adblock_matcher.h"

namespace open_engine {

// Engines shared between Profiles (adblock-fork §6.6, D-16): engine key ->
// the live engine. The key is a content hash (engine format, each enabled
// list's ID and SHA-256 in manifest order, and the resources' SHA-256), so
// two Profiles with the same lists get one engine. The registry holds weak
// references only; an engine dies with its last matcher. Build runner only.
class OpenAdBlockEngineRegistry {
 public:
  static OpenAdBlockEngineRegistry& Get();

  OpenAdBlockEngineRegistry(const OpenAdBlockEngineRegistry&) = delete;
  OpenAdBlockEngineRegistry& operator=(const OpenAdBlockEngineRegistry&) =
      delete;

  // The live engine for |key|, or null.
  std::shared_ptr<const EngineHolder> Find(const std::string& key);
  void Insert(const std::string& key,
              const std::shared_ptr<const EngineHolder>& engine);

 private:
  friend class base::NoDestructor<OpenAdBlockEngineRegistry>;
  OpenAdBlockEngineRegistry();
  ~OpenAdBlockEngineRegistry();

  SEQUENCE_CHECKER(sequence_checker_);
  std::map<std::string, std::weak_ptr<const EngineHolder>> engines_;
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_ENGINE_REGISTRY_H_
