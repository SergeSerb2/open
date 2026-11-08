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
  // Native installs this diagnostic callback only with verbose logging.
  // Stages and counts contain no page text or selector values.
  const trace = (stage, count = 0) => {
    if (binding && typeof binding.trace === 'function') binding.trace(stage, count);
  };
  trace(0, root ? 1 : 0);
  if (!binding || !root) return;
  trace(1);
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
  // Bound each initial scan or mutation batch, including nodes with no
  // tokens and repeated/invalid tokens that do not enter the lifetime sets.
  const spend = budget => {
    if (--budget.steps < 0) {
      collecting = false;
      observer.disconnect();
      return false;
    }
    return true;
  };
  const collectElement = (element, budget) => {
    if (!collecting || !spend(budget)) return;
    for (const token of element.classList) {
      if (!spend(budget)) break;
      add(token, seenClasses, classes);
      if (!collecting) break;
    }
    if (collecting && spend(budget)) add(element.id, seenIds, ids);
  };
  const collect = (node, budget) => {
    if (!collecting || node.nodeType !== Node.ELEMENT_NODE) return;
    collectElement(node, budget);
    // A TreeWalker avoids a second, unbounded array of matching DOM nodes.
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT);
    let element;
    while (collecting && (element = walker.nextNode())) {
      collectElement(element, budget);
    }
  };
  const flush = () => {
    timer = 0;
    const nextClasses = classes.slice(classOffset, classOffset + 500);
    const nextIds = ids.slice(idOffset, idOffset + 500 - nextClasses.length);
    trace(4, nextClasses.length + nextIds.length);
    let result = 1;
    if (nextClasses.length + nextIds.length) {
      result = binding.report(nextClasses, nextIds);
      trace(5, result > 0 ? 1 : 0);
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
      trace(3, classes.length - classOffset + ids.length - idOffset);
    }
  };
  const observer = new MutationObserver(records => {
    const budget = {steps: 65536};
    for (const record of records) {
      if (!collecting || !spend(budget)) break;
      if (record.type === 'attributes') collectElement(record.target, budget);
      else for (const node of record.addedNodes) {
        if (!collecting || !spend(budget)) break;
        collect(node, budget);
      }
    }
    schedule();
  });
  // The native entry runs one task after document-element creation. Read
  // existing parser/inline-script elements once before watching mutations.
  collect(root, {steps: 65536});
  trace(2, classes.length + ids.length);
  if (collecting) {
    observer.observe(root, {subtree: true, childList: true,
                            attributes: true, attributeFilter: ['class', 'id']});
  }
  schedule();
})())JS";
}

}  // namespace open_engine
