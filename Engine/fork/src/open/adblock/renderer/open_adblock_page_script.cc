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
  let workTimer = 0;
  let tokenCharacters = 0;
  let collecting = true;
  let head = null;
  let tail = null;
  // Retain the walker and the class/ID position when one task yields.
  let active = null;
  let scanningInitial = true;
  const stopCollecting = () => {
    collecting = false;
    observer.disconnect();
    clearTimeout(workTimer);
    workTimer = 0;
    head = tail = active = null;
  };
  const add = (token, seen, pending) => {
    if (!collecting) return;
    if (!token || token.length > 2048 || seen.has(token)) return;
    // Bound document-lifetime sets and queues, including tokens that match
    // no filter. These caps are separate from the 64 inserted-sheet limit.
    if (seenClasses.size + seenIds.size >= 65536 ||
        tokenCharacters + token.length > 4 * 1024 * 1024) {
      stopCollecting();
      return;
    }
    seen.add(token);
    pending.push(token);
    tokenCharacters += token.length;
  };
  // This is a task budget, not a document limit. Exhaustion only yields.
  const spend = budget => {
    if (!budget.steps) return false;
    --budget.steps;
    return true;
  };
  const scan = (element, subtree, initial = false) => ({
    element, classIndex: 0, phase: 0, initial,
    walker: subtree ? document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT) : null
  });
  const collectElement = (state, budget) => {
    if (!state.phase) {
      if (!spend(budget)) return false;
      state.phase = 1;
    }
    while (state.classIndex < state.element.classList.length) {
      if (!spend(budget)) return false;
      add(state.element.classList[state.classIndex++], seenClasses, classes);
      if (!collecting) return false;
    }
    if (!spend(budget)) return false;
    add(state.element.id, seenIds, ids);
    return collecting;
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
      stopCollecting();
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
  const drain = () => {
    workTimer = 0;
    const measureInitial = scanningInitial && typeof binding.trace === 'function';
    if (measureInitial) trace(7);
    const budget = {steps: 65536};
    while (collecting && budget.steps) {
      if (active) {
        if (!collectElement(active, budget)) break;
        const element = active.walker && active.walker.nextNode();
        if (element) {
          active.element = element;
          active.classIndex = active.phase = 0;
        } else {
          if (active.initial) {
            scanningInitial = false;
            trace(2, classes.length + ids.length);
          }
          active = null;
        }
        continue;
      }
      if (!head) break;
      if (head.recordIndex === head.records.length) {
        head = head.next;
        if (!head) tail = null;
        continue;
      }
      const record = head.records[head.recordIndex];
      if (!spend(budget)) break;
      if (record.type === 'attributes') {
        ++head.recordIndex;
        active = scan(record.target, false);
      } else if (head.nodeIndex < record.addedNodes.length) {
        const node = record.addedNodes[head.nodeIndex++];
        if (node.nodeType === Node.ELEMENT_NODE) active = scan(node, true);
      } else {
        ++head.recordIndex;
        head.nodeIndex = 0;
      }
    }
    schedule();
    if (collecting && (active || head)) {
      trace(6);
      workTimer = setTimeout(drain, 0);
    }
    if (measureInitial) trace(8, scanningInitial ? 0 : 1);
  };
  const observer = new MutationObserver(records => {
    if (!collecting) return;
    // Linked batches retain MutationRecord and addedNodes positions without
    // copying an unbounded subtree into another array.
    const batch = {records, recordIndex: 0, nodeIndex: 0, next: null};
    if (tail) tail.next = batch;
    else head = batch;
    tail = batch;
    if (!workTimer) workTimer = setTimeout(drain, 0);
  });
  // Native startup runs on the first idle task after DOMContentLoaded. Read
  // existing parser/inline-script elements once before watching mutations.
  active = scan(root, true, true);
  drain();
  // Observe before the first yielded task: parser/SPA changes during the
  // remaining initial scan must also be queued, even if the walker saw them.
  if (collecting) {
    observer.observe(root, {subtree: true, childList: true,
                            attributes: true, attributeFilter: ['class', 'id']});
  }
  schedule();
})())JS";
}

}  // namespace open_engine
