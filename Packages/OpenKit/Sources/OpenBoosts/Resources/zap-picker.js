// Open's own picker implementation, written from the behavior spec, not Arc code.
(function () {
  "use strict";
  if (window.__openZap?.version === 1) return;
  // Abstract transport is postMessage(type, payload); the engine must not double-wrap.
  const bridge = window.__open ||= { postMessage() {} };
  if (!bridge._handlers) {
    bridge._handlers = [];
    const prior = bridge.receive;
    bridge.receive = msg => {
      if (prior) prior.call(bridge, msg);
      for (const h of bridge._handlers) { try { h(msg); } catch (e) { console.warn("[open-boosts]", e); } }
    };
  }
  const post = (type, payload) => { try { window.__open?.postMessage?.(type, payload); } catch (_) {} };
  const escape = s => window.CSS?.escape ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, c => "\\" + c);
  const own = e => !!e && /^(open-zap-|open-boosts-)/.test(e.id || "");
  const rect = e => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; };
  let active = false, boostID = null, host = null, overlay = null, highlight, chip, bar, relatedButton;
  let hovered = null, lastPoint = null, frame = 0, flashTimer = 0, graceTimer = 0;
  let session = [], lastPick = null, multi = [], previewStyles = new Map();
  const knownZaps = new Map();
  const queriedRoots = new Set();

  function elementAt(x, y) {
    let e = document.elementFromPoint(x, y);
    if (own(e)) e = document.elementsFromPoint(x, y).find(n => !own(n)) || null;
    // Closed trees retarget to their host. Open trees allow a root-scoped hit test.
    while (e?.shadowRoot?.elementFromPoint) {
      const inner = e.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === e) break;
      e = inner;
    }
    return own(e) || e?.closest("[data-open-zap-ignore]") ? null : e;
  }
  function hash(e) {
    const index = e.parentElement ? [...e.parentElement.children].indexOf(e) : 0;
    return `${e.tagName}#${e.id || ""}.${[...e.classList].join(".")}@${index}`;
  }
  function hoveredAt(x, y) { const e = elementAt(x, y); return e ? { rect: rect(e), hash: hash(e) } : null; }
  const semanticTags = new Set("a article aside blockquote button details dialog dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main nav pre section p svg picture video iframe object".split(" "));
  const words = "data inline grid meta avatar card col item info line text title header footer button link icon image logo menu nav search social tag time video audio widget wrapper content container main section article aside page post sidebar site author category date entry excerpt featured gallery navigation next pagination permalink previous".split(" ");
  const rare = "jz jx jq jv jw zj zx zq zk zv zw xj xz xq xk xv xw qj qz qx qk qv qw kz kx kq kv kw vj vz vx vq vk vw wj wx wq".split(" ");
  let nextElementID = 1;
  function gibberish(s) {
    return (s.match(/[0-9]/g) || []).length > 2 || (/[A-Z]$/.test(s) && s !== s.toUpperCase()) ||
      s.split(/[aeiouAEIOU\-_ ]/).some(run => run.length > 4) || rare.some(pair => s.toLowerCase().includes(pair));
  }
  function semantic(s) { return !gibberish(s) && words.some(w => s.toLowerCase().includes(w)); }
  function identifierScore(s) { return gibberish(s) ? -1 : semantic(s) ? 1 : -0.5; }
  const quote = s => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\n\r\f]/g, c => "\\" + c.charCodeAt(0).toString(16) + " ");
  function terms(e, cache) {
    e.__open_id ||= nextElementID++;
    if (cache.has(e.__open_id)) return cache.get(e.__open_id);
    const result = [], add = (term, score) => result.push({ term, score });
    if (e.id) add("#" + escape(e.id), identifierScore(e.id));
    for (const cls of e.classList) add("." + escape(cls), identifierScore(cls));
    for (const attr of e.attributes) {
      if (attr.name === "id") continue;
      const name = escape(attr.name), value = quote(attr.value);
      let score = gibberish(attr.value) ? -1 : 0.3;
      if (attr.name === "data-testid") score = 1;
      else if (attr.name === "aria-label") score = 0.8;
      else if (attr.name === "role" || attr.name === "tabindex") score = 0.5;
      else if (attr.name === "href" && /^(A|AREA|LINK)$/.test(e.tagName)) score = 0.6;
      add(`[${name}]`, -0.1); add(`[${name}="${value}"]`, score);
      const first = attr.value.match(/^(.+?)([ \-/])/), last = attr.value.match(/([ \-/])([^ \-/]+)$/);
      if (first) add(`[${name}^="${quote(first[1] + first[2])}"]`, score);
      if (last) add(`[${name}$="${quote(last[1] + last[2])}"]`, score);
    }
    const tag = e.tagName.toLowerCase(); add(tag, tag.includes("-") ? 1 : semanticTags.has(tag) ? 0.5 : -0.1);
    if (e.parentElement) {
      const children = [...e.parentElement.children], i = children.indexOf(e);
      if (i === 0) add(":first-child", -0.1);
      if (i === children.length - 1) add(":last-child", -0.1);
      add(`:nth-child(${i + 1})`, -0.1);
    }
    cache.set(e.__open_id, result); return result;
  }
  function generateCandidates(e) {
    const scope = e.getRootNode(), termCache = new Map(), countCache = new Map(), all = new Map();
    const count = selector => {
      if (countCache.has(selector)) return countCache.get(selector);
      let nodes = [];
      try { nodes = [...scope.querySelectorAll(selector)]; } catch (_) {}
      // Every candidate must select the picked element, never its descendants alone.
      const n = nodes.includes(e) && !nodes.some(own) ? nodes.length : 0;
      countCache.set(selector, n); return n;
    };
    const make = (selector, semanticness) => {
      const matches = count(selector);
      if (!matches || matches > 100) return null;
      const c = { selector, matches, semanticness };
      if (!all.has(selector) || all.get(selector).semanticness < semanticness) all.set(selector, c);
      return c;
    };
    const bySemantic = (a,b) => b.semanticness - a.semanticness || a.selector.length - b.selector.length;
    function prune(candidates, cap) {
      const unique = new Map();
      for (const c of candidates) if (c && (!unique.has(c.selector) || unique.get(c.selector).semanticness < c.semanticness)) unique.set(c.selector, c);
      return [...unique.values()].sort(bySemantic).slice(0, cap);
    }
    let beam = prune(terms(e, termCache).map(t => make(t.term, t.score)), 90);
    for (let parent = e.parentElement, depth = 1; parent && depth <= 8; parent = parent.parentElement, depth++) {
      const expanded = [];
      for (const c of beam) for (const t of terms(parent, termCache)) {
        expanded.push(make(`${t.term} ${c.selector}`, c.semanticness + t.score));
        if (depth === 1) expanded.push(make(`${t.term} > ${c.selector}`, c.semanticness + t.score - 0.1));
      }
      beam = prune(expanded, 90);
      if (parent.tagName === "BODY" || parent.tagName === "HTML") break;
    }
    // The shadow host is outside the selector scope; never put its term in a root-local selector.
    const descendants = [];
    for (const child of e.children) {
      descendants.push({ node: child, prefix: "" });
      for (const grandchild of child.children) descendants.push({ node: grandchild, prefix: child.tagName.toLowerCase() + " " });
      if (descendants.length >= 32) break;
    }
    let phase2 = prune([...all.values()], 12);
    for (let step = 0; step < 3 && descendants.length; step++) {
      const expanded = [];
      for (const c of phase2) for (const d of descendants.slice(0, 32)) for (const t of terms(d.node, termCache).filter(t => t.score >= 0.5)) {
        const condition = `${d.prefix}${t.term}`;
        if (c.selector.includes(`:has(${condition})`) || c.selector.includes(`:has(> ${condition})`)) continue;
        expanded.push(make(`${c.selector}:has(${condition})`, c.semanticness + t.score));
        if (!d.prefix) expanded.push(make(`${c.selector}:has(> ${condition})`, c.semanticness + t.score - 0.1));
      }
      phase2 = prune(expanded, 12);
    }
    const fingerprints = new Map();
    const fingerprint = node => {
      if (!fingerprints.has(node)) {
        const s = getComputedStyle(node);
        fingerprints.set(node, [s.fontFamily, s.fontSize, s.color, s.backgroundColor, s.textDecoration, s.fontWeight].join("|"));
      }
      return fingerprints.get(node);
    };
    const ranked = [...all.values()].map(c => {
      const nodes = c.matches > 1 ? [...scope.querySelectorAll(c.selector)] : [];
      const uniform = nodes.length > 1 && nodes.every(n => fingerprint(n) === fingerprint(nodes[0]));
      return { ...c, rankingScore: c.semanticness + (uniform ? 20 : 0) };
    }).sort((a,b) => b.rankingScore - a.rankingScore || a.selector.length - b.selector.length);
    // Allowed diversity rule: max five of each match count, then fill in a second pass.
    const taken = [], counts = new Map();
    for (const c of ranked) {
      if ((counts.get(c.matches) || 0) >= 5) continue;
      taken.push(c); counts.set(c.matches, (counts.get(c.matches) || 0) + 1);
      if (taken.length === 15) break;
    }
    if (taken.length < 15) for (const c of ranked) if (!taken.includes(c)) { taken.push(c); if (taken.length === 15) break; }
    // A stable unique ID is the canonical precise pick (A7/A10); scoring still
    // chooses the other candidates and the related-element alternatives.
    let preferred = e.id && !gibberish(e.id) ? all.get("#" + escape(e.id)) : null;
    if (preferred?.matches !== 1) {
      for (let hook = e, depth = 0; hook && depth <= 8; hook = hook.parentElement, depth++) {
        if (!hook.hasAttribute("data-testid")) continue;
        const exact = `[data-testid="${quote(hook.getAttribute("data-testid"))}"]`;
        preferred = [...all.values()].filter(c => c.matches === 1 && c.selector.includes(exact)).sort((a,b) => a.selector.length - b.selector.length)[0];
        if (preferred) break;
      }
    }
    if (preferred?.matches === 1) {
      const existing = taken.findIndex(c => c.selector === preferred.selector);
      if (existing >= 0) taken.splice(existing, 1);
      taken.unshift(preferred); taken.splice(15);
    }
    return taken.sort((a,b) => a.matches - b.matches);
  }
  function candidatesAt(x, y) { const e = elementAt(x, y); return e ? generateCandidates(e).map(({ selector, matches }) => ({ selector, matches })) : []; }
  function roots() {
    const all = new Set([document, ...queriedRoots]);
    const walk = root => { for (const e of root.querySelectorAll("*")) if (!own(e) && e.shadowRoot) { all.add(e.shadowRoot); walk(e.shadowRoot); } };
    walk(document);
    return [...all].filter(r => r === document || r.host?.isConnected);
  }
  function nodesForSelector(selector) {
    const nodes = [];
    for (const root of roots()) { try { nodes.push(...root.querySelectorAll(selector)); } catch (_) {} }
    return [...new Set(nodes)].filter(e => !own(e));
  }
  function rectsForSelector(selector) { return nodesForSelector(selector).slice(0, 100).map(rect); }

  function ensureOverlay() {
    if (host) { if (!host.isConnected) document.documentElement.appendChild(host); return; }
    host = document.createElement("div"); host.id = "open-zap-overlay-host";
    host.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647";
    overlay = host.attachShadow({ mode: "closed" });
    overlay.innerHTML = `<style>
      .hl,.hl-multi { position:fixed;pointer-events:none;box-sizing:border-box;border:2px solid #4C8DFF;background:rgba(76,141,255,0.12);border-radius:2px; }
      .tag,.bar { position:fixed;font:11px system-ui;background:rgba(20,20,25,0.92);color:white;border-radius:4px;padding:2px 6px; }
      .tag { pointer-events:none;max-width:460px; } .bar { bottom:16px;left:50%;transform:translateX(-50%);pointer-events:auto;padding:10px;display:flex;gap:12px;align-items:center; }
      button { border:0;background:none;color:inherit;font:inherit;cursor:pointer;padding:4px; } button:focus { outline:1px solid #4C8DFF; }
    </style><div class="hl" hidden></div><div class="tag" hidden></div><div class="bar"><span class="count">Zap mode</span><button class="related" hidden></button><button class="undo">Undo</button><button class="done">Done</button></div>`;
    highlight = overlay.querySelector(".hl"); chip = overlay.querySelector(".tag"); bar = overlay.querySelector(".bar");
    relatedButton = overlay.querySelector(".related");
    overlay.querySelector(".undo").addEventListener("click", undo);
    overlay.querySelector(".done").addEventListener("click", () => exitWithReason("done"));
    relatedButton.addEventListener("mouseenter", showRelated);
    relatedButton.addEventListener("mouseleave", clearMulti);
    relatedButton.addEventListener("click", replaceRelated);
    document.documentElement.appendChild(host);
  }
  function position(box, r) { Object.assign(box.style, { left: r.x + "px", top: r.y + "px", width: r.width + "px", height: r.height + "px" }); }
  function drawHover() {
    frame = 0;
    if (!active || !hovered?.isConnected) { if (highlight) { highlight.hidden = true; chip.hidden = true; } return; }
    const r = rect(hovered); position(highlight, r); highlight.hidden = false; chip.hidden = false;
    // Full selector generation is click-only; hover uses one cheap best-term preview.
    const cls = [...hovered.classList].find(c => !gibberish(c));
    const term = semantic(hovered.id) ? "#" + hovered.id : cls ? "." + cls : hovered.tagName.toLowerCase();
    chip.textContent = hovered.tagName.toLowerCase() + " " + term.slice(0, 60);
    chip.style.left = Math.max(0, r.x) + "px"; chip.style.top = Math.max(0, r.y - 22) + "px";
  }
  function move(event) {
    lastPoint = { x: event.clientX, y: event.clientY };
    const composed = event.composedPath()[0];
    hovered = composed instanceof Element && !own(composed) && !composed.closest("[data-open-zap-ignore]") ? composed : elementAt(lastPoint.x, lastPoint.y);
    if (!frame) frame = requestAnimationFrame(drawHover);
  }
  function reposition() { if (!frame) frame = requestAnimationFrame(drawHover); }
  function clearMulti() { for (const box of multi) box.remove(); multi = []; }
  function showRelated() {
    clearMulti();
    if (!lastPick?.wide) return;
    for (const r of lastPick.rects) {
      const box = document.createElement("div"); box.className = "hl-multi"; position(box, r); overlay.appendChild(box); multi.push(box);
    }
  }
  function refreshPreview() {
    for (const style of previewStyles.values()) style.remove(); previewStyles.clear();
    for (const entry of session) {
      if (entry.root !== document && !entry.root.host?.isConnected) continue;
      try { entry.root.querySelectorAll(entry.selector); } catch (_) { continue; }
      let style = previewStyles.get(entry.root);
      if (!style) {
        style = document.createElement("style");
        if (entry.root === document) style.id = "open-zap-preview-style";
        else style.setAttribute("data-open-zap-preview", "");
        (entry.root === document ? document.documentElement : entry.root).appendChild(style);
        previewStyles.set(entry.root, style);
      }
      style.textContent += `${entry.selector} { display: none !important; }\n`;
    }
    if (overlay) overlay.querySelector(".count").textContent = `${session.length} zapped`;
  }
  function removePreview() {
    clearTimeout(graceTimer); graceTimer = 0;
    window.removeEventListener("open-boosts-applied", removePreview);
    for (const style of previewStyles.values()) style.remove(); previewStyles.clear();
  }
  function label(e, selector) { return e.tagName.toLowerCase() + (selector.startsWith("#") ? "#" + e.id : ""); }
  function click(event) {
    if (event.composedPath().includes(host) || event.composedPath().some(n => n.hasAttribute?.("data-open-zap-ignore"))) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const target = event.composedPath()[0];
    const e = target instanceof Element && !own(target) ? target : elementAt(event.clientX, event.clientY);
    if (!e) return noCandidate();
    let list = generateCandidates(e);
    const root = e.getRootNode();
    if (!list.length || ![...root.querySelectorAll(list[0].selector)].includes(e)) list = generateCandidates(e);
    if (!list.length || ![...root.querySelectorAll(list[0].selector)].includes(e)) return noCandidate();
    queriedRoots.add(root);
    const chosen = list[0];
    const wide = list.find(c => c.matches > 1 && [...root.querySelectorAll(c.selector)].every(n => n.tagName === e.tagName && n.parentElement === e.parentElement));
    const wideRects = wide ? [...root.querySelectorAll(wide.selector)].slice(0, 100).map(rect) : [];
    const entry = { boostID, selector: chosen.selector, label: label(e, chosen.selector), root };
    if (session.some(z => z.boostID === boostID && z.selector === entry.selector)) return;
    session.push(entry); knownZaps.set(entry.boostID + "\0" + entry.selector, entry);
    lastPick = { entry, wide, rects: wideRects };
    relatedButton.hidden = !wide || wide.selector === chosen.selector;
    relatedButton.textContent = wide ? `Zap all related (${wide.matches})` : "";
    refreshPreview();
    post("zap:committed", { boostID, selector: entry.selector, label: entry.label, matches: chosen.matches, inShadowRoot: root instanceof ShadowRoot });
    hovered = null; drawHover();
  }
  function noCandidate() {
    highlight.style.borderColor = "red";
    clearTimeout(flashTimer); flashTimer = setTimeout(() => { highlight.style.borderColor = "#4C8DFF"; }, 200);
    post("picker:error", { kind: "no-candidate" });
  }
  function replaceRelated() {
    if (!lastPick?.wide) return;
    const { entry, wide } = lastPick, oldSelector = entry.selector;
    knownZaps.delete(entry.boostID + "\0" + oldSelector); entry.selector = wide.selector; knownZaps.set(entry.boostID + "\0" + entry.selector, entry);
    refreshPreview(); clearMulti(); relatedButton.hidden = true;
    post("zap:replaced", { boostID: entry.boostID, oldSelector, newSelector: entry.selector, label: entry.label, matches: wide.matches });
  }
  function undo() {
    const entry = session.pop(); if (!entry) return false;
    knownZaps.delete(entry.boostID + "\0" + entry.selector); lastPick = null; if (relatedButton) relatedButton.hidden = true;
    refreshPreview(); clearMulti();
    post("zap:removed", { boostID: entry.boostID, selector: entry.selector, via: "undo" }); return true;
  }
  function keydown(e) {
    if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); exitWithReason("esc"); }
    else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); e.stopImmediatePropagation(); undo(); }
  }
  function enter(options) {
    if (active) { if (options.boostID !== boostID) post("picker:error", { kind: "already-active" }); return; }
    removePreview(); session = []; lastPick = null; boostID = options.boostID; active = true;
    ensureOverlay(); host.hidden = false; relatedButton.hidden = true;
    document.addEventListener("mousemove", move, true); document.addEventListener("click", click, true); document.addEventListener("keydown", keydown, true);
    window.addEventListener("scroll", reposition, true); window.addEventListener("resize", reposition);
    post("picker:ready", { boostID });
  }
  function exitWithReason(reason) {
    if (!active) return;
    active = false;
    document.removeEventListener("mousemove", move, true); document.removeEventListener("click", click, true); document.removeEventListener("keydown", keydown, true);
    window.removeEventListener("scroll", reposition, true); window.removeEventListener("resize", reposition);
    cancelAnimationFrame(frame); frame = 0; clearTimeout(flashTimer); clearMulti(); hovered = null; host.hidden = true;
    if (previewStyles.size) { window.addEventListener("open-boosts-applied", removePreview, { once: true }); graceTimer = setTimeout(removePreview, 500); }
    post("picker:exited", { boostID, reason });
  }
  window.__openZap = { version: 1, enter, exit: () => exitWithReason("done"), isActive: () => active, undo, candidatesAt, rectsForSelector, hoveredAt };
  bridge._handlers.push(msg => {
    if (msg?.v !== 1) { console.warn("[open-zap]", "unsupported bridge version"); return; }
    try {
      const p = msg.payload;
      if (msg.type === "zap:enter") enter(p);
      else if (msg.type === "zap:exit") exitWithReason("bridge");
      else if (msg.type === "zap:undo") undo();
      else if (msg.type === "zap:remove") {
        session = session.filter(z => z.boostID !== p.boostID || z.selector !== p.selector); knownZaps.delete(p.boostID + "\0" + p.selector); refreshPreview();
        post("zap:removed", { boostID: p.boostID, selector: p.selector, via: "native" });
      } else if (msg.type === "zap:list") {
        const selectors = new Map([...knownZaps.values()].filter(z => z.boostID === p.boostID).map(z => [z.selector, z.label]));
        for (const b of JSON.parse(document.getElementById("open-boosts-style")?.dataset.openZaps || "[]")) if (b.boostID === p.boostID) for (const s of b.zaps) if (!selectors.has(s)) selectors.set(s, "");
        post("zap:list-result", { boostID: p.boostID, entries: [...selectors].map(([selector, label]) => { const count = nodesForSelector(selector).length; return { selector, label, matchCount: count, truncated: count > 100 }; }) });
      }
    } catch (e) { console.warn("[open-zap]", e); }
  });
})();
