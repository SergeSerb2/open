// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
#ifndef OPEN_BROWSER_AUTOFILL_OPEN_PASSWORD_PROMPT_ROUTER_H_
#define OPEN_BROWSER_AUTOFILL_OPEN_PASSWORD_PROMPT_ROUTER_H_
namespace content { class WebContents; }
namespace open_engine {
class OpenPasswordPromptRouter {
 public:
  static bool Show(content::WebContents*, bool user_action);
  static bool Hide(content::WebContents*);
};
}  // namespace open_engine
#endif
