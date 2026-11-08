// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open/adblock/renderer/open_adblock_page_script.h"

namespace open_engine {

std::string_view AdBlockClassIdObserverScript() {
  return R"JS((() => {
  'use strict';
  const binding = globalThis.__openAdBlock;
  const root = document.documentElement;
  if (!binding || !root) return;
  const seenClasses = new Set();
  const seenIds = new Set();
  const classes = [];
  const ids = [];
  let classOffset = 0;
  let idOffset = 0;
  let timer = 0;
  let tokenCharacters = 0;
  let collecting = true;
  const add = (token, seen, pending) => {
    if (!collecting) return;
    if (!token || token.length > 2048 || seen.has(token)) return;
    // Bound document-lifetime sets and queues, including tokens that match
    // no filter. These caps are separate from the 64 inserted-sheet limit.
    if (seenClasses.size + seenIds.size >= 65536 ||
        tokenCharacters + token.length > 4 * 1024 * 1024) {
      collecting = false;
      observer.disconnect();
      return;
    }
    seen.add(token);
    pending.push(token);
    tokenCharacters += token.length;
  };
  const collectElement = element => {
    for (const token of element.classList) {
      add(token, seenClasses, classes);
      if (!collecting) break;
    }
    add(element.id, seenIds, ids);
  };
  const collect = node => {
    if (!collecting || node.nodeType !== Node.ELEMENT_NODE) return;
    collectElement(node);
    // A TreeWalker avoids a second, unbounded array of matching DOM nodes.
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT);
    let element;
    while (collecting && (element = walker.nextNode())) {
      collectElement(element);
    }
  };
  const flush = () => {
    timer = 0;
    const nextClasses = classes.slice(classOffset, classOffset + 500);
    const nextIds = ids.slice(idOffset, idOffset + 500 - nextClasses.length);
    let result = 1;
    if (nextClasses.length + nextIds.length) {
      result = binding.report(nextClasses, nextIds);
      if (result > 0) {
        classOffset += nextClasses.length;
        idOffset += nextIds.length;
      }
    }
    if (result < 0) {
      observer.disconnect();
      classes.length = ids.length = 0;
      seenClasses.clear();
      seenIds.clear();
    } else if (classOffset < classes.length || idOffset < ids.length) {
      schedule();
    }
  };
  const schedule = () => {
    if (!timer &&
        (classOffset < classes.length || idOffset < ids.length)) {
      timer = setTimeout(flush, 100);
    }
  };
  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes') collectElement(record.target);
      else for (const node of record.addedNodes) collect(node);
    }
    schedule();
  });
  observer.observe(root, {subtree: true, childList: true,
                          attributes: true, attributeFilter: ['class', 'id']});
  collect(root);
  schedule();
})())JS";
}

}  // namespace open_engine
