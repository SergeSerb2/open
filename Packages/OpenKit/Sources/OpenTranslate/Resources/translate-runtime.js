// Open's page translation runtime (docs/plans/page-platform.md §4.7.4).
// Installed on demand, after the user asks to translate. The shell pulls batches with
// `__openTranslate.nextBatch()` (a promise that resolves when units are ready; no polling)
// and returns results with `__openTranslate.apply(batchID, results)`. `restore()` puts every
// text node and attribute back byte for byte and stops the observers.
//
// Limits (the page controls the DOM): at most MAX_UNITS units per start; a unit text of at most
// MAX_UNIT_CHARS UTF-16 units (a longer run falls back to its text nodes, a longer text node is
// skipped); a batch of at most MAX_BATCH_UNITS units and MAX_BATCH_CHARS characters, except a
// single unit that alone is longer. The shell checks the same limits again (TranslationBatch).
(() => {
  'use strict';
  if (window.__openTranslate) return 'present';

  const MAX_UNITS = 20000, MAX_UNIT_CHARS = 20000, MAX_BATCH_UNITS = 40, MAX_BATCH_CHARS = 4000;
  const MUTATION_DEBOUNCE_MS = 300;
  const SVG_NS = 'http://www.w3.org/2000/svg';
  // Never translated, and nothing inside them (§4.7.4).
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'KBD', 'SAMP', 'TEXTAREA', 'INPUT',
    'SELECT', 'OPTION', 'TEMPLATE', 'IFRAME', 'OBJECT', 'EMBED', 'CANVAS', 'VIDEO', 'AUDIO', 'MATH', 'HEAD']);
  // Inline elements whose text joins the sentence around them (numbered markers ⟦k⟧…⟦/k⟧).
  const INLINE = new Set(['A', 'ABBR', 'B', 'BDI', 'BDO', 'CITE', 'DATA', 'DFN', 'EM', 'I', 'LABEL', 'MARK',
    'Q', 'S', 'SMALL', 'SPAN', 'STRONG', 'SUB', 'SUP', 'TIME', 'U', 'VAR', 'FONT', 'BIG', 'TT', 'INS', 'DEL']);
  // Inline elements kept whole inside a sentence (a self-closing marker ⟦k/⟧). A button's own
  // text is a unit of its own.
  const OPAQUE_INLINE = new Set(['BR', 'WBR', 'IMG', 'BUTTON']);
  const ATTRIBUTES = ['placeholder', 'title', 'alt', 'aria-label'];
  const BUTTON_TYPES = new Set(['button', 'submit', 'reset']);

  let active = false, nextUnitID = 1, nextBatchID = 1, unitCount = 0;
  let pending = [];            // units waiting to come near the viewport
  let ready = [];              // units near the viewport
  let inflight = null;         // {id, units}: the batch the shell is translating
  let waiter = null;           // resolve of the pending nextBatch()
  let firstRound = false;      // the IntersectionObserver delivered its first callback
  let initialAck = false;      // the first batch (possibly empty) went out
  let applied = [];            // restore records, in apply order
  let unitized = new WeakSet();          // containers scanned in this start
  const unitsByAnchor = new Map();       // observed element -> its pending units
  const originalText = new WeakMap();    // Text -> original data
  const originalAttrs = new WeakMap();   // Element -> {name: original value or null}
  let io = null, mo = null, debounce = 0, addedRoots = new Set(), changedTexts = new Set();
  let selfWrite = false;

  const hasText = (s) => /\S/.test(s);
  const skipped = (el) => !el || SKIP.has(el.tagName) || el.namespaceURI === SVG_NS ||
    el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate')) ||
    el.isContentEditable === true;
  const inSkipped = (node) => {
    // Up to and including <html>: `<html translate="no">` opts the whole page out.
    for (let e = node.nodeType === 1 ? node : node.parentElement; e; e = e.parentElement) {
      if (skipped(e)) return true;
    }
    return false;
  };
  const opaque = (el) => OPAQUE_INLINE.has(el.tagName) || skipped(el);
  // An inline element holds only text and inline elements (no block inside), up to a small depth.
  function simpleInline(el, depth) {
    if (opaque(el)) return true;
    if (depth > 8) return false;
    for (const c of el.childNodes) {
      if (c.nodeType !== 1) continue;
      if (!(INLINE.has(c.tagName) || opaque(c)) || !simpleInline(c, depth + 1)) return false;
    }
    return true;
  }
  const isInlineChild = (n) => n.nodeType === 3 || (n.nodeType === 1 && (INLINE.has(n.tagName) || opaque(n)) && simpleInline(n, 0));

  // ---- Units -------------------------------------------------------------------------------
  function addUnit(unit, anchor) {
    if (unitCount >= MAX_UNITS) return false;
    unitCount += 1;
    unit.id = nextUnitID++;
    unit.anchor = anchor;
    let list = unitsByAnchor.get(anchor);
    if (!list) { list = []; unitsByAnchor.set(anchor, list); if (io) io.observe(anchor); }
    list.push(unit);
    pending.push(unit);
    return true;
  }

  function serialize(nodes, ctx, parentKey) {
    let s = '';
    for (const n of nodes) {
      if (n.nodeType === 3) { ctx.texts.push(n); s += n.data.replace(/\s+/g, ' '); continue; }
      if (n.nodeType !== 1) continue;
      const k = ctx.next++;
      ctx.parents[k] = parentKey;
      ctx.elements[k] = n;
      if (opaque(n)) { ctx.opaque[k] = true; s += '⟦' + k + '/⟧'; continue; }
      s += '⟦' + k + '⟧' + serialize(Array.from(n.childNodes), ctx, k) + '⟦/' + k + '⟧';
    }
    return s;
  }

  function addRun(container, nodes) {
    const ctx = { next: 1, texts: [], elements: {}, parents: {}, opaque: {} };
    const raw = serialize(nodes, ctx, 0);
    const text = raw.trim();
    if (!hasText(text.replace(/⟦\/?\d+\/?⟧/g, ''))) return;
    if (text.length > MAX_UNIT_CHARS || ctx.next === 1) {
      // Plain text, or a run too long for one unit: translate node by node.
      for (const t of ctx.texts) addNodeUnit(t);
      return;
    }
    addUnit({ kind: 'run', container, nodes, ctx, text, lead: /^\s/.test(raw), trail: /\s$/.test(raw) }, container);
  }

  function addNodeUnit(textNode) {
    const data = textNode.data;
    if (!hasText(data) || data.length > MAX_UNIT_CHARS || !textNode.parentElement) return;
    const lead = data.match(/^\s*/)[0], trail = data.match(/\s*$/)[0];
    addUnit({ kind: 'node', node: textNode, text: data.trim().replace(/\s+/g, ' '), lead, trail }, textNode.parentElement);
  }

  function addAttributeUnits(el) {
    if (el.closest('[translate="no"], .notranslate, [contenteditable=""], [contenteditable="true"]')) return;
    for (const name of ATTRIBUTES) {
      const v = el.getAttribute(name);
      if (v && hasText(v) && v.length <= MAX_UNIT_CHARS) addUnit({ kind: 'attr', element: el, name, text: v.trim() }, el);
    }
    if (el.tagName === 'INPUT' && BUTTON_TYPES.has((el.getAttribute('type') || '').toLowerCase())) {
      const v = el.getAttribute('value');
      if (v && hasText(v) && v.length <= MAX_UNIT_CHARS) addUnit({ kind: 'attr', element: el, name: 'value', text: v.trim() }, el);
    }
  }

  // Walks a block container: runs of inline content become units, blocks and buttons recurse.
  function scan(root) {
    if (root.nodeType !== 1 || inSkipped(root)) {
      if (root.nodeType === 1 && (root.tagName === 'INPUT' || root.tagName === 'TEXTAREA') && !unitized.has(root)) { unitized.add(root); addAttributeUnits(root); }
      return;
    }
    const stack = [root];
    while (stack.length) {
      const el = stack.pop();
      if (unitized.has(el)) continue;
      unitized.add(el);
      addAttributeUnits(el);
      let run = [];
      const children = [];
      for (const c of el.childNodes) {
        if (isInlineChild(c)) { run.push(c); if (c.nodeType === 1) children.push(c); continue; }
        if (run.length) { addRun(el, run); run = []; }
        if (c.nodeType === 1) children.push(c);
      }
      if (run.length) addRun(el, run);
      for (let i = children.length - 1; i >= 0; i--) {
        const c = children[i];
        if (skipped(c)) {
          if ((c.tagName === 'INPUT' || c.tagName === 'TEXTAREA') && !unitized.has(c)) { unitized.add(c); addAttributeUnits(c); }
          continue;
        }
        if (!isInlineChild(c) || c.tagName === 'BUTTON') { stack.push(c); continue; }
        // Inline elements inside a run: their attributes (img alt, span title) and buttons inside.
        addAttributeUnits(c);
        for (const d of c.querySelectorAll('*')) {
          if (d.tagName === 'BUTTON' && !inSkipped(d)) stack.push(d);
          else if (!inSkipped(d) || d.tagName === 'INPUT') addAttributeUnits(d);
        }
      }
    }
  }

  // ---- Batches -----------------------------------------------------------------------------
  const connected = (u) => u.kind === 'run' ? u.nodes.every((n) => n.isConnected && n.parentNode === u.container)
    : u.kind === 'node' ? u.node.isConnected : u.element.isConnected;
  // The unit still reads as it did when it was made: a result for text the page changed in the
  // meantime is dropped (the mutation observer queues the new text as its own unit).
  function unchanged(u) {
    if (u.kind === 'node') return u.node.data.trim().replace(/\s+/g, ' ') === u.text;
    if (u.kind === 'attr') return (u.element.getAttribute(u.name) || '').trim() === u.text;
    return serialize(u.nodes, { next: 1, texts: [], elements: {}, parents: {}, opaque: {} }, 0).trim() === u.text;
  }

  function takeBatch() {
    const units = [];
    let chars = 0;
    while (ready.length && units.length < MAX_BATCH_UNITS) {
      const u = ready[0];
      if (!connected(u)) { ready.shift(); continue; }
      if (units.length && chars + u.text.length > MAX_BATCH_CHARS) break;
      ready.shift(); units.push(u); chars += u.text.length;
    }
    if (!units.length) return null;
    inflight = { id: nextBatchID++, units };
    return { id: inflight.id, units: units.map((u) => ({ id: u.id, text: u.text })) };
  }

  function wake() {
    if (!waiter || inflight) return;
    let batch = takeBatch();
    if (batch) initialAck = true;
    else if (firstRound && !initialAck) {
      // Nothing near the viewport: tell the shell the first round is done (an empty batch).
      initialAck = true;
      batch = { id: nextBatchID++, units: [] };
    }
    if (!batch) return;
    const resolve = waiter; waiter = null; resolve(batch);
  }

  function promote(entries) {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const list = unitsByAnchor.get(e.target);
      unitsByAnchor.delete(e.target);
      if (io) io.unobserve(e.target);
      if (!list) continue;
      const moved = new Set(list);
      pending = pending.filter((u) => !moved.has(u));
      for (const u of list) ready.push(u);
    }
    firstRound = true;
    wake();
  }

  // ---- Applying ----------------------------------------------------------------------------
  function parseMarked(s) {
    const tokens = [];
    const re = /⟦(\/?)(\d+)(\/?)⟧/g;
    let last = 0, m;
    while ((m = re.exec(s))) {
      if (m.index > last) tokens.push({ t: 'text', v: s.slice(last, m.index) });
      tokens.push({ t: m[1] ? 'close' : m[3] ? 'self' : 'open', k: Number(m[2]) });
      last = re.lastIndex;
    }
    if (last < s.length) tokens.push({ t: 'text', v: s.slice(last) });
    return tokens;
  }

  // {level key: [text | element]} from the translated tokens; null when the markers do not match
  // the original structure (dropped, duplicated, or moved to another parent).
  function structure(tokens, ctx) {
    const levels = { 0: [] }, seen = new Set(), stack = [0];
    for (const tok of tokens) {
      const top = stack[stack.length - 1];
      if (tok.t === 'text') { levels[top].push(tok.v); continue; }
      const k = tok.k;
      if (!(k in ctx.elements)) return null;
      if (tok.t === 'self') {
        if (!ctx.opaque[k] || seen.has(k) || ctx.parents[k] !== top) return null;
        seen.add(k); levels[top].push(ctx.elements[k]); continue;
      }
      if (ctx.opaque[k]) return null;
      if (tok.t === 'open') {
        if (seen.has(k) || ctx.parents[k] !== top) return null;
        seen.add(k); levels[top].push(ctx.elements[k]); levels[k] = []; stack.push(k); continue;
      }
      if (top !== k) return null;
      stack.pop();
    }
    if (stack.length !== 1 || seen.size !== ctx.next - 1) return null;
    return levels;
  }

  function rememberText(t) { if (!originalText.has(t)) originalText.set(t, t.data); }

  function applyRun(u, translated) {
    const levels = structure(parseMarked(translated), u.ctx);
    if (!levels) return false;
    const top = levels[0];
    if (u.lead) { if (typeof top[0] === 'string') top[0] = ' ' + top[0].replace(/^\s+/, ''); else top.unshift(' '); }
    if (u.trail) { const i = top.length - 1; if (typeof top[i] === 'string') top[i] = top[i].replace(/\s+$/, '') + ' '; else top.push(' '); }
    for (const t of u.ctx.texts) rememberText(t);
    const record = { kind: 'run', container: u.container, original: u.nodes.slice(), children: [], inserted: [], created: new Set(), texts: u.ctx.texts.slice() };
    // Text segments reuse the original text nodes of their level, in order; extra segments get new nodes.
    const pools = new Map([[0, u.nodes.filter((n) => n.nodeType === 3)]]);
    for (const k in u.ctx.elements) if (!u.ctx.opaque[k]) pools.set(Number(k), Array.from(u.ctx.elements[k].childNodes).filter((n) => n.nodeType === 3));
    const build = (key, segments) => segments.map((seg) => {
      if (typeof seg !== 'string') return seg;
      const pool = pools.get(key);
      let node;
      if (pool && pool.length) node = pool.shift(); else { node = document.createTextNode(''); record.created.add(node); }
      node.data = seg;
      return node;
    });
    for (const key of Object.keys(levels).map(Number).sort((a, b) => a - b)) {
      if (key === 0) continue;
      const el = u.ctx.elements[key];
      const placed = build(key, levels[key]);
      record.children.push({ el, nodes: Array.from(el.childNodes), placed });
      el.replaceChildren(...placed);
    }
    const nodes = build(0, top);
    const ref = u.nodes[u.nodes.length - 1].nextSibling;
    for (const n of u.nodes) if (n.parentNode === u.container) u.container.removeChild(n);
    for (const n of nodes) u.container.insertBefore(n, ref && ref.parentNode === u.container ? ref : null);
    record.inserted = nodes;
    applied.push(record);
    return true;
  }

  function applyNode(u, translated) {
    rememberText(u.node);
    applied.push({ kind: 'node', node: u.node });
    u.node.data = u.lead + translated.trim() + u.trail;
    return true;
  }

  function applyAttr(u, translated) {
    let saved = originalAttrs.get(u.element);
    if (!saved) { saved = {}; originalAttrs.set(u.element, saved); }
    if (!(u.name in saved)) saved[u.name] = u.element.getAttribute(u.name);
    applied.push({ kind: 'attr', element: u.element, name: u.name });
    u.element.setAttribute(u.name, translated.trim());
    return true;
  }

  function apply(batchID, results) {
    if (!active || !inflight || inflight.id !== batchID || !Array.isArray(results) || results.length !== inflight.units.length) {
      return { stale: true, applied: 0, fallback: 0 };
    }
    const units = inflight.units;
    inflight = null;
    let done = 0, fallback = 0;
    selfWrite = true;
    try {
      units.forEach((u, i) => {
        const r = results[i];
        if (typeof r !== 'string' || r.length > 2 * MAX_UNIT_CHARS || !connected(u) || !unchanged(u)) return;
        if (u.kind === 'run') {
          if (applyRun(u, r)) { done += 1; return; }
          // The translator lost or moved a marker: translate this run's text nodes one by one (R-3).
          fallback += 1;
          const before = pending.length;
          for (const t of u.ctx.texts) addNodeUnit(t);
          const added = pending.splice(before);
          for (const a of added) {
            const list = unitsByAnchor.get(a.anchor);
            if (list) { const j = list.indexOf(a); if (j >= 0) list.splice(j, 1); if (!list.length) { unitsByAnchor.delete(a.anchor); if (io) io.unobserve(a.anchor); } }
            ready.push(a);
          }
        } else if (u.kind === 'node') { if (applyNode(u, r)) done += 1; } else if (applyAttr(u, r)) done += 1;
      });
    } finally {
      if (mo) mo.takeRecords();
      selfWrite = false;
    }
    wake();
    return { stale: false, applied: done, fallback };
  }

  // ---- Restore -----------------------------------------------------------------------------
  const sameNodes = (list, nodes) => list.length === nodes.length && nodes.every((n, i) => list[i] === n);

  function restoreAll() {
    selfWrite = true;
    try {
      for (let i = applied.length - 1; i >= 0; i--) {
        const r = applied[i];
        if (r.kind === 'attr') {
          const saved = originalAttrs.get(r.element);
          if (saved && r.name in saved) {
            if (saved[r.name] === null) r.element.removeAttribute(r.name); else r.element.setAttribute(r.name, saved[r.name]);
            delete saved[r.name];
          }
        } else if (r.kind === 'node') {
          if (originalText.has(r.node)) { r.node.data = originalText.get(r.node); originalText.delete(r.node); }
        } else {
          // Structure goes back only where it is still exactly what the run put there. Where the
          // page has since replaced or added children, the page owns that structure: only the
          // original text comes back, and nodes the page removed stay removed.
          for (let j = r.children.length - 1; j >= 0; j--) {
            const c = r.children[j];
            if (sameNodes(c.el.childNodes, c.placed)) c.el.replaceChildren(...c.nodes);
            else for (const n of c.placed) if (r.created.has(n) && n.parentNode === c.el) c.el.removeChild(n);
          }
          if (r.inserted.every((n) => n.parentNode === r.container)) {
            const ref = r.inserted.length ? r.inserted[r.inserted.length - 1].nextSibling : null;
            for (const n of r.inserted) r.container.removeChild(n);
            for (const n of r.original) r.container.insertBefore(n, ref);
          } else {
            for (const n of r.inserted) if (r.created.has(n) && n.parentNode === r.container) r.container.removeChild(n);
          }
          for (const t of r.texts) if (originalText.has(t)) { t.data = originalText.get(t); originalText.delete(t); }
        }
      }
    } finally {
      if (mo) mo.takeRecords();
      selfWrite = false;
    }
    applied = [];
  }

  // ---- Observers ---------------------------------------------------------------------------
  function onMutations(records) {
    if (selfWrite || !active) return;
    for (const r of records) {
      if (r.type === 'characterData') { if (r.target.nodeType === 3) changedTexts.add(r.target); continue; }
      for (const n of r.addedNodes) addedRoots.add(n);
    }
    if (!debounce && (addedRoots.size || changedTexts.size)) debounce = setTimeout(flushMutations, MUTATION_DEBOUNCE_MS);
  }

  function flushMutations() {
    debounce = 0;
    if (!active) return;
    const roots = Array.from(addedRoots), texts = Array.from(changedTexts);
    addedRoots = new Set(); changedTexts = new Set();
    for (const t of texts) {
      if (!t.isConnected || inSkipped(t)) continue;
      originalText.set(t, t.data);   // the page's own new text is the new original
      addNodeUnit(t);
    }
    for (const n of roots) {
      if (!n.isConnected || inSkipped(n)) continue;
      if (n.nodeType === 1 && !isInlineChild(n)) { scan(n); continue; }
      const parent = n.parentElement;
      if (!parent) continue;
      if (!unitized.has(parent)) { scan(parent); continue; }
      if (n.nodeType === 3) { addNodeUnit(n); continue; }
      if (n.nodeType !== 1) continue;
      addAttributeUnits(n);
      const walker = document.createTreeWalker(n, NodeFilter.SHOW_TEXT);
      for (let t = walker.nextNode(); t; t = walker.nextNode()) if (!inSkipped(t)) addNodeUnit(t);
    }
  }

  function stopObservers() {
    if (io) { io.disconnect(); io = null; }
    if (mo) { mo.disconnect(); mo = null; }
    if (debounce) { clearTimeout(debounce); debounce = 0; }
    addedRoots = new Set(); changedTexts = new Set();
  }

  // ---- API ---------------------------------------------------------------------------------
  const api = Object.freeze({
    start() {
      if (active) return { units: unitCount, already: true };
      active = true; unitCount = 0; firstRound = false; initialAck = false;
      pending = []; ready = []; inflight = null; unitsByAnchor.clear(); unitized = new WeakSet();
      io = new IntersectionObserver(promote, { rootMargin: '100% 0px' });
      mo = new MutationObserver(onMutations);
      if (document.body) {
        scan(document.body);
        mo.observe(document.body, { childList: true, subtree: true, characterData: true });
      }
      return { units: unitCount, already: false };
    },
    nextBatch() {
      if (!active) return Promise.resolve(null);
      if (inflight) {
        // The shell never applied the last batch (an error on its side): offer those units again.
        ready = inflight.units.concat(ready);
        inflight = null;
      }
      return new Promise((resolve) => {
        if (waiter) { const old = waiter; waiter = null; old(null); }
        waiter = resolve;
        wake();
      });
    },
    apply,
    restore() {
      const wasActive = active;
      active = false;
      stopObservers();
      if (waiter) { const w = waiter; waiter = null; w(null); }
      inflight = null; pending = []; ready = []; unitsByAnchor.clear();
      restoreAll();
      return wasActive;
    },
    state() {
      return { active, units: unitCount, pending: pending.length, ready: ready.length, inflight: inflight ? inflight.units.length : 0, applied: applied.length };
    },
  });

  Object.defineProperty(window, '__openTranslate', { value: api, configurable: false, enumerable: false, writable: false });
  return 'installed';
})()
