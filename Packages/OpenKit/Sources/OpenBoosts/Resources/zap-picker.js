// Open's own picker implementation, written from the behavior spec, not Arc code.
(function () {
  "use strict";
  // Capture before page scripts can replace these in this injection world.
  // Production picker injection MUST use an ISOLATED WORLD; see docs/boosts.md.
  const applyNative = Reflect.apply;
  const uncurry = fn => (self, ...args) => applyNative(fn, self, args);
  const captureCollection = Native => {
    class Captured extends Native {}
    for (const key of Reflect.ownKeys(Native.prototype)) {
      if (key !== "constructor") Object.defineProperty(Captured.prototype, key, Object.getOwnPropertyDescriptor(Native.prototype, key));
    }
    return Captured;
  };
  const Map = captureCollection(window.Map), Set = captureCollection(window.Set), WeakMap = captureCollection(window.WeakMap);
  const MutationObserver = captureCollection(window.MutationObserver);
  const JSON = { parse: window.JSON.parse, stringify: window.JSON.stringify };
  const utf8 = new TextEncoder();
  const arrayFrom = Array.from.bind(Array), arrayIsArray = Array.isArray;
  const arrayMap = uncurry(Array.prototype.map), arrayFilter = uncurry(Array.prototype.filter);
  const arraySome = uncurry(Array.prototype.some), arrayEvery = uncurry(Array.prototype.every);
  const arrayFind = uncurry(Array.prototype.find), arrayFindIndex = uncurry(Array.prototype.findIndex);
  const arraySort = uncurry(Array.prototype.sort), arrayJoin = uncurry(Array.prototype.join);
  const arrayPush = uncurry(Array.prototype.push), arrayPop = uncurry(Array.prototype.pop), arraySplice = uncurry(Array.prototype.splice);
  const nativeSlice = uncurry(Array.prototype.slice), stringSlice = uncurry(String.prototype.slice);
  const nativeIncludes = uncurry(Array.prototype.includes), stringIncludes = uncurry(String.prototype.includes);
  const nativeIndexOf = uncurry(Array.prototype.indexOf), stringIndexOf = uncurry(String.prototype.indexOf);
  const arraySlice = (v, ...args) => (typeof v === "string" ? stringSlice : nativeSlice)(v, ...args);
  const arrayIncludes = (v, ...args) => (typeof v === "string" ? stringIncludes : nativeIncludes)(v, ...args);
  const arrayIndexOf = (v, ...args) => (typeof v === "string" ? stringIndexOf : nativeIndexOf)(v, ...args);
  const attachShadow = uncurry(Element.prototype.attachShadow), matchesSelector = uncurry(Element.prototype.matches);
  const elementQueryAll = uncurry(Element.prototype.querySelectorAll), documentQueryAll = uncurry(Document.prototype.querySelectorAll);
  const fragmentQueryAll = uncurry(DocumentFragment.prototype.querySelectorAll);
  const elementQuery = uncurry(Element.prototype.querySelector), documentQuery = uncurry(Document.prototype.querySelector);
  const fragmentQuery = uncurry(DocumentFragment.prototype.querySelector);
  const queryAll = (root, s) => (root.nodeType === 9 ? documentQueryAll : root.nodeType === 1 ? elementQueryAll : fragmentQueryAll)(root, s);
  const query = (root, s) => (root.nodeType === 9 ? documentQuery : root.nodeType === 1 ? elementQuery : fragmentQuery)(root, s);
  const getComputedStyle = window.getComputedStyle.bind(window);
  const bounds = uncurry(Element.prototype.getBoundingClientRect);
  const documentPoint = uncurry(Document.prototype.elementFromPoint), documentPoints = uncurry(Document.prototype.elementsFromPoint);
  const shadowPoint = uncurry(ShadowRoot.prototype.elementFromPoint), shadowPoints = uncurry(ShadowRoot.prototype.elementsFromPoint);
  const atPoint = (root, x, y) => (root.nodeType === 9 ? documentPoint : shadowPoint)(root, x, y);
  const atPoints = (root, x, y) => (root.nodeType === 9 ? documentPoints : shadowPoints)(root, x, y);
  const requestAnimationFrame = window.requestAnimationFrame.bind(window), cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
  const setTimeout = window.setTimeout.bind(window), clearTimeout = window.clearTimeout.bind(window);
  const cssEscape = window.CSS?.escape;
  if (window.__openZap?.version === 1) return;
  // Abstract transport is postMessage(type, payload); the engine must not double-wrap.
  const bridge = window.__open ||= { postMessage() {} };
  if (!bridge._handlers) {
    bridge._handlers = [];
    const prior = bridge.receive;
    bridge.receive = msg => {
      if (prior) applyNative(prior, bridge, [msg]);
      for (const h of bridge._handlers) { try { h(msg); } catch (e) { console.warn("[open-boosts]", e); } }
    };
  }
  // The engine may replace the fallback shim later while adopting its handlers.
  const sendToNative = (type, payload) => window.__open?.postMessage?.(type, payload);
  const post = (type, payload) => { try { sendToNative(type, { ...payload, boostID, sessionNonce }); } catch (_) {} };
  const escape = s => cssEscape ? cssEscape(s) : s.replace(/[^a-zA-Z0-9_-]/g, c => "\\" + c);
  const own = e => !!e && /^(open-zap-|open-boosts-)/.test(e.id || "");
  const rect = e => { const r = bounds(e); return { x: r.x, y: r.y, width: r.width, height: r.height }; };
  let active = false, boostID = null, sessionNonce = null, host = null, overlay = null, highlight, chip, bar, relatedButton, popup, band;
  let hovered = null, lastMove = null, frame = 0, flashTimer = 0, graceTimer = 0;
  let pendingList = null;
  // Spec values explicitly marked as guesses live in one named constant each.
  const IDLE_INSTRUCTION_COLOR = "#777777";
  const HOVER_TINT = "rgba(255,214,10,0.35)";
  const REVEAL_CHIP_LAYOUT = "display:flex;gap:8px;align-items:center;overflow:auto";
  const REVEAL_CHIP_LABEL = entry => entry.label || entry.selector;
  let mode = "zap", revealing = null;
  let session = [], lastPick = null, multi = [], previewStyles = new Map();
  const knownZaps = new Map();
  const queriedRoots = new Set();

  function elementAt(x, y) {
    let e = atPoint(document, x, y);
    // The host is hit only over its interactive controls. Never pick through it.
    if (own(e)) return null;
    // Closed trees retarget to their host. Open trees allow a root-scoped hit test.
    while (e?.shadowRoot) {
      const inner = atPoint(e.shadowRoot, x, y);
      if (!inner || inner === e) break;
      e = inner;
    }
    return own(e) || e?.closest("[data-open-zap-ignore]") ? null : e;
  }
  function hash(e) {
    const index = e.parentElement ? arrayIndexOf([...e.parentElement.children], e) : 0;
    return `${e.tagName}#${e.id || ""}.${arrayJoin([...e.classList], ".")}@${index}`;
  }
  function hoveredAt(x, y) { const e = elementAt(x, y); return e ? { rect: rect(e), hash: hash(e) } : null; }
  const semanticTags = new Set("a article aside blockquote button details dialog dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main nav pre section p svg picture video iframe object".split(" "));
  const words = "data inline grid meta avatar card col item info line text title header footer button link icon image logo menu nav search social tag time video audio widget wrapper content container main section article aside page post sidebar site author category date entry excerpt featured gallery navigation next pagination permalink previous".split(" ");
  const rare = "jz jx jq jv jw zj zx zq zk zv zw xj xz xq xk xv xw qj qz qx qk qv qw kz kx kq kv kw vj vz vx vq vk vw wj wx wq".split(" ");
  let nextElementID = 1;
  const elementIDs = new WeakMap();
  function gibberish(s) {
    return (s.match(/[0-9]/g) || []).length > 2 || (/[A-Z]$/.test(s) && s !== s.toUpperCase()) ||
      arraySome(s.split(/[aeiouAEIOU\-_ ]/), run => run.length > 4) || arraySome(rare, pair => arrayIncludes(s.toLowerCase(), pair));
  }
  function semantic(s) { return !gibberish(s) && arraySome(words, w => arrayIncludes(s.toLowerCase(), w)); }
  function identifierScore(s) { return gibberish(s) ? -1 : semantic(s) ? 1 : -0.5; }
  const quote = s => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\n\r\f]/g, c => "\\" + c.charCodeAt(0).toString(16) + " ");
  function terms(e, cache) {
    if (!elementIDs.has(e)) elementIDs.set(e, nextElementID++);
    const id = elementIDs.get(e);
    if (cache.has(id)) return cache.get(id);
    const result = [], add = (term, score) => arrayPush(result, { term, score });
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
    const tag = e.tagName.toLowerCase(); add(tag, arrayIncludes(tag, "-") ? 1 : semanticTags.has(tag) ? 0.5 : -0.1);
    if (e.parentElement) {
      const children = [...e.parentElement.children], i = arrayIndexOf(children, e);
      if (i === 0) add(":first-child", -0.1);
      if (i === children.length - 1) add(":last-child", -0.1);
      add(`:nth-child(${i + 1})`, -0.1);
    }
    cache.set(id, result); return result;
  }
  function generateCandidates(e) {
    const scope = e.getRootNode(), termCache = new Map(), matchCache = new Map(), all = new Map();
    const survivors = new Map();
    const remember = list => { for (const c of list) survivors.set(c.selector, c); return list; };
    const count = (selector, baseNodes) => {
      if (matchCache.has(selector)) return matchCache.get(selector).length;
      let nodes = [];
      // Ancestor/:has expansions only narrow an existing selector. Filter its
      // cached nodes instead of querying the entire document for every trial.
      try { nodes = baseNodes ? arrayFilter(baseNodes, node => matchesSelector(node, selector)) : [...queryAll(scope, selector)]; } catch (_) {}
      // Every candidate must select the picked element, never its descendants alone.
      if (!arrayIncludes(nodes, e) || arraySome(nodes, own)) nodes = [];
      matchCache.set(selector, nodes); return nodes.length;
    };
    const make = (selector, semanticness, baseNodes) => {
      const matches = count(selector, baseNodes);
      if (!matches || matches > 100) return null;
      const c = { selector, matches, semanticness, nodes: matchCache.get(selector) };
      if (!all.has(selector) || all.get(selector).semanticness < semanticness) all.set(selector, c);
      return c;
    };
    const bySemantic = (a,b) => b.semanticness - a.semanticness || a.selector.length - b.selector.length;
    function prune(candidates, cap) {
      const unique = new Map();
      for (const c of candidates) if (c && (!unique.has(c.selector) || unique.get(c.selector).semanticness < c.semanticness)) unique.set(c.selector, c);
      return arraySlice(arraySort([...unique.values()], bySemantic), 0, cap);
    }
    let beam = remember(prune(arrayMap(terms(e, termCache), t => make(t.term, t.score)), 90));
    for (let parent = e.parentElement, depth = 1; parent && depth <= 8; parent = parent.parentElement, depth++) {
      const expanded = [];
      for (const c of beam) for (const t of terms(parent, termCache)) {
        arrayPush(expanded, make(`${t.term} ${c.selector}`, c.semanticness + t.score, c.nodes));
        if (depth === 1) arrayPush(expanded, make(`${t.term} > ${c.selector}`, c.semanticness + t.score - 0.1, c.nodes));
      }
      beam = prune(expanded, 90);
      remember(prune(beam, 12));
      if (parent.tagName === "BODY" || parent.tagName === "HTML") break;
    }
    // The shadow host is outside the selector scope; never put its term in a root-local selector.
    const descendants = [];
    for (const child of e.children) {
      arrayPush(descendants, { node: child, prefix: "" });
      for (const grandchild of child.children) arrayPush(descendants, { node: grandchild, prefix: child.tagName.toLowerCase() + " " });
      if (descendants.length >= 32) break;
    }
    remember(beam);
    let phase2 = prune([...survivors.values()], 12);
    for (let step = 0; step < 3 && descendants.length; step++) {
      const expanded = [];
      for (const c of phase2) for (const d of arraySlice(descendants, 0, 32)) for (const t of arrayFilter(terms(d.node, termCache), t => t.score >= 0.5)) {
        const condition = `${d.prefix}${t.term}`;
        if (arrayIncludes(c.selector, `:has(${condition})`) || arrayIncludes(c.selector, `:has(> ${condition})`)) continue;
        arrayPush(expanded, make(`${c.selector}:has(${condition})`, c.semanticness + t.score, c.nodes));
        if (!d.prefix) arrayPush(expanded, make(`${c.selector}:has(> ${condition})`, c.semanticness + t.score - 0.1, c.nodes));
      }
      phase2 = remember(prune(expanded, 12));
    }
    const fingerprints = new Map();
    const fingerprint = node => {
      if (!fingerprints.has(node)) {
        const s = getComputedStyle(node);
        fingerprints.set(node, arrayJoin([s.fontFamily, s.fontSize, s.color, s.backgroundColor, s.textDecoration, s.fontWeight], "|"));
      }
      return fingerprints.get(node);
    };
    const ranked = arraySort(arrayMap([...survivors.values()], c => {
      const nodes = c.matches > 1 ? c.nodes : [];
      const uniform = nodes.length > 1 && arrayEvery(nodes, n => fingerprint(n) === fingerprint(nodes[0]));
      return { ...c, rankingScore: c.semanticness + (uniform ? 20 : 0) };
    }), (a,b) => b.rankingScore - a.rankingScore || a.selector.length - b.selector.length);
    // Allowed diversity rule: max five of each match count, then fill in a second pass.
    const taken = [], counts = new Map();
    for (const c of ranked) {
      if ((counts.get(c.matches) || 0) >= 5) continue;
      arrayPush(taken, c); counts.set(c.matches, (counts.get(c.matches) || 0) + 1);
      if (taken.length === 15) break;
    }
    if (taken.length < 15) for (const c of ranked) if (!arrayIncludes(taken, c)) { arrayPush(taken, c); if (taken.length === 15) break; }
    // A stable unique ID is the canonical precise pick (A7/A10); scoring still
    // chooses the other candidates and the related-element alternatives.
    let preferred = e.id && !gibberish(e.id) ? all.get("#" + escape(e.id)) : null;
    if (preferred?.matches !== 1) {
      for (let hook = e, depth = 0; hook && depth <= 8; hook = hook.parentElement, depth++) {
        if (!hook.hasAttribute("data-testid")) continue;
        const exact = `[data-testid="${quote(hook.getAttribute("data-testid"))}"]`;
        preferred = arraySort(arrayFilter([...all.values()], c => c.matches === 1 && arrayIncludes(c.selector, exact)), (a,b) => a.selector.length - b.selector.length)[0];
        if (preferred) break;
      }
    }
    if (preferred?.matches === 1) {
      const existing = arrayFindIndex(taken, c => c.selector === preferred.selector);
      if (existing >= 0) arraySplice(taken, existing, 1);
      arraySplice(taken, 0, 0, preferred); arraySplice(taken, 15);
    }
    return arraySort(taken, (a,b) => a.matches - b.matches);
  }
  function candidatesAt(x, y) { const e = elementAt(x, y); return e ? arrayMap(generateCandidates(e), ({ selector, matches }) => ({ selector, matches })) : []; }
  let rootCache = null, rootObserver = null;
  function invalidateRoots() { rootCache = null; }
  function roots() {
    if (rootObserver?.takeRecords().length) invalidateRoots();
    if (rootCache) return rootCache;
    const all = new Set([document, ...queriedRoots]);
    const walk = root => { for (const e of queryAll(root, "*")) if (!own(e) && e.shadowRoot) { all.add(e.shadowRoot); walk(e.shadowRoot); } };
    walk(document);
    rootCache = arrayFilter([...all], r => r === document || r.host?.isConnected);
    if (rootObserver) for (const root of rootCache) rootObserver.observe(root, { childList: true, subtree: true });
    return rootCache;
  }
  function nodesForSelector(selector) {
    const nodes = [];
    for (const root of roots()) { try { arrayPush(nodes, ...queryAll(root, selector)); } catch (_) {} }
    return arrayFilter([...new Set(nodes)], e => !own(e));
  }
  function rectsForSelector(selector) {
    invalidateRoots();
    return arrayFilter(arrayMap(arraySlice(nodesForSelector(selector), 0, 100), rect), r => r.width > 0 && r.height > 0);
  }

  function ensureOverlay() {
    if (host) { if (!host.isConnected) document.documentElement.appendChild(host); return; }
    host = document.createElement("div"); host.id = "open-zap-overlay-host";
    host.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647";
    overlay = attachShadow(host, { mode: "closed" });
    overlay.innerHTML = `<style>
      :host { all:initial; } [hidden] { display:none !important; }
      .content-frame { z-index:4;position:fixed;inset:0;box-sizing:border-box;border:3px solid #3139FF;pointer-events:none; }
      .hl,.hl-multi { z-index:0;position:fixed;pointer-events:none;box-sizing:border-box;background:${HOVER_TINT}; }
      .tag { z-index:1;position:fixed;pointer-events:none;font:11px monospace;background:white;color:#333;padding:2px 6px;max-width:460px; }
      .bar { z-index:2;position:fixed;bottom:0;left:0;right:0;height:56px;background:#FBFBFD;color:${IDLE_INSTRUCTION_COLOR};font:13px system-ui;pointer-events:auto;display:flex;align-items:center;justify-content:center; }
      .instruction .accent { color:#3139FF; } .bar.popup-open .instruction,.bar.popup-open .accent { color:#DBDFFF; }
      button { border:0;cursor:pointer;font:13px system-ui;box-sizing:border-box; } button:focus-visible { outline:2px solid #3139FF;outline-offset:2px; }
      .done { position:absolute;right:10px;top:10px;width:59px;height:38px;border-radius:8px;background:#EDEEFF;color:#3139FF;font-weight:500; }
      .undo { position:absolute;left:10px;background:transparent;color:#555; }
      .reveals { ${REVEAL_CHIP_LAYOUT};max-width:55%;margin-right:70px; } .reveal { border-radius:8px;background:#EDEEFF;padding:8px;color:#333;white-space:nowrap; }
      .popup { z-index:3;position:fixed;width:428px;max-width:calc(100vw - 12px);height:90px;border-radius:12px;background:white;box-shadow:0 4px 20px #0003;pointer-events:auto;overflow:hidden;color:#333; }
      .actions { display:flex;gap:6px;padding:8px; } .actions button { height:38px;border-radius:7px;color:white;padding:0 10px;white-space:nowrap; }
      .this { background:#FF453A; } .related { background:#FF9500;flex:1; } .cancel { background:#999; } .select { background:#3139FF;flex:1; }
      .band { background:#F0F0F2;padding:8px;font:11px monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis; }
    </style><div class="content-frame"></div><div class="hl" hidden></div><div class="tag" hidden></div>
    <div class="bar"><button class="undo">Undo</button><span class="instruction">Click elements on the page to <span class="accent">Zap</span> them</span><div class="reveals" hidden></div><button class="done">Done</button></div>
    <div class="popup" hidden><div class="actions"><button class="this">Zap this</button><button class="related">Zap all related elements</button><button class="select" hidden>Use Selector</button><button class="cancel">Cancel</button></div><div class="band"></div></div>`;
    highlight = query(overlay, ".hl"); chip = query(overlay, ".tag"); bar = query(overlay, ".bar");
    popup = query(overlay, ".popup"); band = query(overlay, ".band"); relatedButton = query(overlay, ".related");
    query(overlay, ".undo").addEventListener("click", undo);
    query(overlay, ".done").addEventListener("click", () => exitWithReason("done"));
    query(overlay, ".this").addEventListener("click", commitPick);
    query(overlay, ".cancel").addEventListener("click", closePopup);
    query(overlay, ".select").addEventListener("click", () => {
      if (mode !== "select" || !lastPick) return;
      post("picker:selected", { selector: lastPick.entry.selector, matches: lastPick.chosen.matches });
      closePopup();
    });
    relatedButton.addEventListener("mouseenter", showRelated);
    relatedButton.addEventListener("mouseleave", () => { clearMulti(); updateBand(); });
    relatedButton.addEventListener("click", commitRelated);
    document.documentElement.appendChild(host);
  }
  function position(box, r) { Object.assign(box.style, { left: r.x + "px", top: r.y + "px", width: r.width + "px", height: r.height + "px" }); }
  function drawHover() {
    frame = 0;
    if (lastMove) {
      const event = lastMove; lastMove = null;
      hovered = own(event.target) || event.target?.closest?.("[data-open-zap-ignore]") ? null : elementAt(event.clientX, event.clientY);
    }
    if (!active || !popup?.hidden || !hovered?.isConnected) { if (highlight) { highlight.hidden = true; chip.hidden = true; } return; }
    const r = rect(hovered); position(highlight, r); highlight.hidden = false; chip.hidden = false;
    // Full selector generation is click-only; hover uses one cheap best-term preview.
    const cls = arrayFind([...hovered.classList], c => !gibberish(c));
    const term = semantic(hovered.id) ? "#" + hovered.id : cls ? "." + cls : hovered.tagName.toLowerCase();
    chip.textContent = hovered.tagName.toLowerCase() + " " + arraySlice(term, 0, 60);
    chip.style.left = Math.max(0, r.x) + "px"; chip.style.top = Math.max(0, r.y - 22) + "px";
  }
  function move(event) {
    // Events can arrive faster than display refresh; hit-test only the last one.
    lastMove = event;
    if (!frame) frame = requestAnimationFrame(drawHover);
  }
  function reposition() { if (!frame) frame = requestAnimationFrame(drawHover); }
  function clearMulti() { for (const box of multi) box.remove(); multi = []; }
  function showRelated() {
    clearMulti();
    if (!lastPick?.wide) return;
    band.textContent = `${lastPick.wide.matches} ${lastPick.wide.selector}`;
    // Preview every visible match before the one direct related commit.
    const nodes = queryAll(lastPick.entry.root, lastPick.wide.selector);
    for (const r of arrayFilter(arrayMap(arraySlice([...nodes], 0, 100), rect), r => r.width > 0 && r.height > 0)) {
      const box = document.createElement("div"); box.className = "hl-multi"; position(box, r); overlay.appendChild(box); arrayPush(multi, box);
    }
  }
  function refreshPreview(render = true) {
    for (const style of previewStyles.values()) style.remove(); previewStyles.clear();
    for (const entry of session) {
      if (entry.root !== document && !entry.root.host?.isConnected) continue;
      try { queryAll(entry.root, entry.selector); } catch (_) { continue; }
      let style = previewStyles.get(entry.root);
      if (!style) {
        style = document.createElement("style");
        if (entry.root === document) style.id = "open-zap-preview-style";
        else style.setAttribute("data-open-zap-preview", "");
        (entry.root === document ? document.documentElement : entry.root).appendChild(style);
        previewStyles.set(entry.root, style);
      }
      style.textContent += `${entry.selector} { display: ${revealing === entry.selector ? "revert" : "none"} !important; }\n`;
    }
    if (revealing && !arraySome(session, z => z.selector === revealing)) {
      for (const root of roots()) {
        let style = previewStyles.get(root);
        if (!style) { style = document.createElement("style"); (root === document ? document.documentElement : root).appendChild(style); previewStyles.set(root, style); }
        style.textContent += `${revealing} { display: revert !important; }`;
      }
    }
    if (render) renderReveals();
  }
  function removePreview() {
    clearTimeout(graceTimer); graceTimer = 0;
    window.removeEventListener("open-boosts-applied", removePreview);
    for (const style of previewStyles.values()) style.remove(); previewStyles.clear();
  }
  function label(e, selector) { return e.tagName.toLowerCase() + (selector.startsWith("#") ? "#" + e.id : ""); }
  function click(event) {
    if (arrayIncludes(event.composedPath(), host) || arraySome(event.composedPath(), n => n.hasAttribute?.("data-open-zap-ignore"))) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const target = event.composedPath()[0];
    const e = target instanceof Element && !own(target) ? target : elementAt(event.clientX, event.clientY);
    if (!e) return noCandidate();
    invalidateRoots();
    let list = generateCandidates(e);
    const root = e.getRootNode();
    if (!list.length || !arrayIncludes(list[0].nodes, e)) list = generateCandidates(e);
    if (!list.length || !arrayIncludes(list[0].nodes, e)) return noCandidate();
    queriedRoots.add(root);
    const chosen = list[0];
    const wide = arrayFind(list, c => c.matches > 1 && arrayEvery(c.nodes, n => n.tagName === e.tagName && n.parentElement === e.parentElement));
    const entry = { boostID, selector: chosen.selector, label: label(e, chosen.selector), root };
    lastPick = { entry, chosen, wide };
    relatedButton.hidden = mode === "select";
    relatedButton.disabled = !wide || wide.selector === chosen.selector;
    query(overlay, ".this").hidden = mode === "select";
    query(overlay, ".select").hidden = mode !== "select";
    updateBand(); popup.hidden = false; bar.classList.add("popup-open");
    popup.style.left = Math.max(6, Math.min(event.clientX, window.innerWidth - 434)) + "px";
    popup.style.top = Math.max(6, Math.min(event.clientY + 12, window.innerHeight - 152)) + "px";
    hovered = null; lastMove = null; drawHover();
  }
  function updateBand() { if (lastPick) band.textContent = `${lastPick.chosen.matches} ${lastPick.entry.selector}`; }
  function closePopup() { popup.hidden = true; lastPick = null; bar.classList.remove("popup-open"); clearMulti(); }
  function commitPick() {
    if (mode !== "zap" || !lastPick) return;
    const { entry, chosen } = lastPick;
    if (arraySome(session, z => z.selector === entry.selector)) { closePopup(); return; }
    arrayPush(session, entry); knownZaps.set(entry.boostID + "\0" + entry.selector, entry);
    refreshPreview();
    closePopup();
    post("zap:committed", { selector: entry.selector, label: entry.label, matches: chosen.matches, inShadowRoot: entry.root instanceof ShadowRoot });
  }
  function renderReveals() {
    if (!overlay) return;
    const list = query(overlay, ".reveals"); list.replaceChildren();
    const entries = [...knownZaps.values()];
    list.hidden = !entries.length || mode === "select";
    query(overlay, ".instruction").hidden = entries.length > 0 && mode === "zap";
    if (list.hidden) return;
    const title = document.createElement("span"); title.textContent = "Click to reveal"; list.appendChild(title);
    for (const entry of entries) {
      const button = document.createElement("button"); button.className = "reveal"; button.textContent = REVEAL_CHIP_LABEL(entry);
      button.addEventListener("mouseenter", () => { revealing = entry.selector; refreshPreviewStylesOnly(); });
      button.addEventListener("mouseleave", () => { revealing = null; refreshPreviewStylesOnly(); });
      button.addEventListener("click", () => { revealing = null; post("zap:revealRequested", { selector: entry.selector }); });
      list.appendChild(button);
    }
  }
  // Hover changes only styles; rebuilding the hovered chip would drop mouseleave.
  function refreshPreviewStylesOnly() {
    refreshPreview(false);
  }
  function noCandidate() {
    highlight.style.borderColor = "red";
    clearTimeout(flashTimer); flashTimer = setTimeout(() => { highlight.style.borderColor = "#3139FF"; }, 200);
    post("picker:error", { kind: "no-candidate" });
  }
  function commitRelated() {
    if (mode !== "zap" || !lastPick?.wide) return;
    const { entry, wide } = lastPick;
    lastPick.chosen = wide; entry.selector = wide.selector;
    commitPick();
  }
  function undo() {
    if (!active || mode === "select") return false;
    const entry = arrayPop(session); if (!entry) return false;
    knownZaps.delete(entry.boostID + "\0" + entry.selector); lastPick = null; closePopup();
    refreshPreview(); clearMulti();
    post("zap:removed", { boostID: entry.boostID, selector: entry.selector, via: "undo" }); return true;
  }
  function keydown(e) {
    if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); exitWithReason("esc"); }
    else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); e.stopImmediatePropagation(); undo(); }
  }
  function pagehide() { exitWithReason("navigation"); }
  function postListResults(selectors, listID) {
    const type = "zap:list-result";
    let entries = [];
    const payload = complete => ({ entries, ...(listID ? { listID, complete } : {}), boostID, sessionNonce });
    const fits = () => utf8.encode(type).length + utf8.encode(JSON.stringify(payload(false))).length <= 65536;
    for (const [selector, label] of selectors) {
      const count = nodesForSelector(selector).length;
      const entry = { selector, label, matchCount: count, truncated: count > 100 };
      arrayPush(entries, entry);
      if (!fits()) {
        arrayPop(entries);
        if (entries.length) post(type, payload(false));
        entries = [entry];
        // Native's selector/label limits make a single entry fit. A malformed
        // legacy caller may omit counts, but never ends an active picker.
        if (!fits()) entries = [];
      }
    }
    if (entries.length) post(type, payload(false));
    entries = [];
    // Native publishes a snapshot only after this end marker and a complete
    // set of stored selectors. No prefix of a counts reply becomes authoritative.
    if (listID || !selectors.size) post(type, payload(true));
  }
  function listZaps(p) {
    let selectors;
    if (typeof p.listID === "string") {
      if (p.listID.length > 64 || typeof p.reset !== "boolean" || typeof p.complete !== "boolean" || !arrayIsArray(p.selectors)) return;
      if (p.reset) pendingList = { id: p.listID, selectors: new Map() };
      if (pendingList?.id !== p.listID) return;
      selectors = pendingList.selectors;
      for (const s of p.selectors) {
        if (typeof s !== "string" || (selectors.size >= 1024 && !selectors.has(s))) { pendingList = null; return; }
        selectors.set(s, typeof p.labels?.[s] === "string" ? p.labels[s] : "");
      }
      if (!p.complete) return;
      pendingList = null;
      // The completed native snapshot is the authority, including deletions.
      session = arrayFilter(session, z => selectors.has(z.selector));
      for (const [key, entry] of knownZaps) if (!selectors.has(entry.selector)) knownZaps.delete(key);
    } else {
      // Keep the package harness's single-message transport compatible.
      selectors = new Map(arrayMap(arrayFilter([...knownZaps.values()], z => z.boostID === p.boostID), z => [z.selector, z.label]));
      for (const s of p.selectors || []) if (typeof s === "string" && !selectors.has(s)) selectors.set(s, typeof p.labels?.[s] === "string" ? p.labels[s] : "");
    }
    invalidateRoots();
    if (mode === "zap") for (const [selector, label] of selectors) {
      const entry = knownZaps.get(boostID + "\0" + selector) || { boostID, selector };
      entry.label = label; knownZaps.set(boostID + "\0" + selector, entry);
    }
    renderReveals(); postListResults(selectors, p.listID);
  }
  function enter(options) {
    if (active) { if (options?.boostID !== boostID) post("picker:error", { kind: "already-active" }); return; }
    // Only a native-issued capability can yield messages accepted by native.
    // Main-world callers can invent a nonce, but the coordinator rejects it.
    if (typeof options?.boostID !== "string" || typeof options.sessionNonce !== "string" || options.sessionNonce.length < 16) return;
    if (options.mode !== undefined && options.mode !== "zap" && options.mode !== "select") return;
    removePreview(); session = []; knownZaps.clear(); lastPick = null; pendingList = null;
    boostID = options.boostID; sessionNonce = options.sessionNonce; mode = options.mode === "select" ? "select" : "zap"; revealing = null; active = true;
    invalidateRoots(); rootObserver = new MutationObserver(invalidateRoots);
    rootObserver.observe(document, { childList: true, subtree: true });
    ensureOverlay(); host.hidden = false; closePopup(); renderReveals();
    query(overlay, ".undo").hidden = mode === "select";
    document.addEventListener("mousemove", move, true); document.addEventListener("click", click, true); document.addEventListener("keydown", keydown, true);
    window.addEventListener("scroll", reposition, true); window.addEventListener("resize", reposition);
    window.addEventListener("pagehide", pagehide);
    post("picker:ready", { boostID });
  }
  function exitWithReason(reason) {
    if (!active) return;
    active = false; rootObserver?.disconnect(); rootObserver = null; invalidateRoots(); pendingList = null;
    document.removeEventListener("mousemove", move, true); document.removeEventListener("click", click, true); document.removeEventListener("keydown", keydown, true);
    window.removeEventListener("scroll", reposition, true); window.removeEventListener("resize", reposition);
    window.removeEventListener("pagehide", pagehide);
    cancelAnimationFrame(frame); frame = 0; clearTimeout(flashTimer); clearMulti(); hovered = null; lastMove = null; host.hidden = true;
    if (previewStyles.size) { window.addEventListener("open-boosts-applied", removePreview, { once: true }); graceTimer = setTimeout(removePreview, 500); }
    post("picker:exited", { boostID, reason });
    sessionNonce = null; boostID = null;
  }
  window.__openZap = { version: 1, enter, exit: () => exitWithReason("done"), isActive: () => active, isObserving: () => rootObserver !== null, undo, candidatesAt, rectsForSelector, hoveredAt };
  arrayPush(bridge._handlers, msg => {
    if (msg?.v !== 1) { console.warn("[open-zap]", "unsupported bridge version"); return; }
    try {
      const p = msg.payload;
      if (msg.type === "zap:enter") { enter(p); return; }
      if (!active || p?.boostID !== boostID || p.sessionNonce !== sessionNonce) return;
      if (msg.type === "zap:exit") exitWithReason("bridge");
      else if (msg.type === "zap:undo") undo();
      else if (msg.type === "zap:remove" && mode === "zap") {
        revealing = null;
        session = arrayFilter(session, z => z.boostID !== p.boostID || z.selector !== p.selector); knownZaps.delete(p.boostID + "\0" + p.selector); refreshPreview();
        post("zap:removed", { boostID: p.boostID, selector: p.selector, via: "native" });
      } else if (msg.type === "zap:list") listZaps(p);
    } catch (e) { console.warn("[open-zap]", e); }
  });
})();
