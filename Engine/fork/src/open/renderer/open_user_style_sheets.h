// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_RENDERER_OPEN_USER_STYLE_SHEETS_H_
#define OPEN_RENDERER_OPEN_USER_STYLE_SHEETS_H_

namespace blink {
class WebLocalFrame;
}

namespace open_engine {

// User-origin style sheets per browser (PB1 11:05, 2026-11-12; Arc's theme
// variables). Called by CefRenderFrameObserver::DidCommitProvisionalLoad (CEF
// patch 0601) for a main frame: inserts the browser's sheets into the new
// document with user origin, so the page sees their effect but no <style>
// node and no document.styleSheets entry. Renderer main thread.
void ApplyUserStyleSheetsAtCommit(blink::WebLocalFrame* frame, int browser_id);

}  // namespace open_engine

#endif  // OPEN_RENDERER_OPEN_USER_STYLE_SHEETS_H_
