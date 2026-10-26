// Injection world: main. Arc timing evidence is a guess; see boosts-zap.md §1 BO-9.
(function () {
  "use strict";
  if (window.__openBoosts?.version === 1) return;
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
  const STYLE_ID = "open-boosts-style";
  let current = null, style = null, cssText = "", observer = null, frame = 0;
  let earlyObserver = null, earlyReady = null, pending = null;
  let historyHooks = [], attachHook = null, shadowCSS = "";
  let knownRoots = [];
  const rootStyles = new Map(), addedNodes = new Set();
  const badSelectors = new Set();
  const num = v => Number(v.toFixed(4)).toString();
  const clamp = (v, low, high, identity) => typeof v !== "number" || Number.isNaN(v) ? identity : Math.min(high, Math.max(low, v));

  function generatedCSS(plan) {
    let css = "";
    if (plan.colorAdjustment) {
      const c = plan.colorAdjustment;
      const h = Number.isFinite(c.hueRotateDegrees) ? ((c.hueRotateDegrees % 360) + 360) % 360 : 0;
      const s = clamp(c.saturation, 0, 3, 1), b = clamp(c.brightness, 0, 3, 1);
      const ct = clamp(c.contrast, 0, 3, 1), i = clamp(c.invert, 0, 1, 0);
      if ([h, s - 1, b - 1, ct - 1, i].some(v => Math.abs(v) > 1e-9)) {
        css += `html { filter: hue-rotate(${num(h)}deg) saturate(${num(s)}) brightness(${num(b)}) contrast(${num(ct)}) invert(${num(i)}); }\n`;
        // Open design decision: only full invert has an exact counter-invert.
        // Partial invert and the other recolor filters intentionally affect media.
        if (i >= 0.999) css += `img, video, picture, canvas { filter: invert(${num(i)}) hue-rotate(${num((h + 180) % 360)}deg); }\n`;
      }
    }
    if (typeof plan.fontFamily === "string" && plan.fontFamily.trim() && !/[;{}"\r\n]/.test(plan.fontFamily)) {
      css += `body, body *:not(script):not(style):not(code):not(pre):not(kbd):not(samp) { font-family: ${plan.fontFamily} !important; }\n`;
    }
    if (plan.textZoom != null) css += `html { zoom: ${num(clamp(plan.textZoom, 0.5, 2, 1))}; }\n`;
    if (["none", "uppercase", "lowercase", "capitalize"].includes(plan.textTransform)) {
      css += `body, body *:not(input):not(textarea):not([contenteditable]):not([contenteditable] *) { text-transform: ${plan.textTransform} !important; }\n`;
      // Reset inheritance too: excluding controls alone would still inherit body case.
      css += `input, textarea, [contenteditable], [contenteditable] * { text-transform: none !important; }\n`;
    }
    return css;
  }
  function zapRules(plan) {
    const selectors = new Set(), rules = [];
    for (const boost of plan.boosts) for (const s of boost.zaps || []) {
      if (typeof s !== "string" || !s.trim() || selectors.has(s)) continue;
      selectors.add(s);
      try {
        document.querySelector(s);
        rules.push(`${s} { display: none !important; }`);
      } catch (_) {
        if (!badSelectors.has(s)) { badSelectors.add(s); post("boost:error", { kind: "invalid-zap-selector", selector: s }); }
        selectors.delete(s);
      }
    }
    return { css: rules.join("\n"), count: selectors.size };
  }
  function reassert() {
    frame = 0;
    if (!current) return;
    for (const node of addedNodes) discover(node);
    addedNodes.clear();
    for (const [root, record] of rootStyles) {
      if (record.sheet && !root.adoptedStyleSheets.includes(record.sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, record.sheet];
      else if (record.style && !record.style.isConnected) root.appendChild(record.style);
    }
    if (current && !document.getElementById(STYLE_ID)) {
      style.textContent = cssText;
      document.documentElement.appendChild(style);
    }
  }
  function schedule() { if (current && !frame) frame = requestAnimationFrame(reassert); }
  function installGuards() {
    observer = new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes) if (node.nodeType === 1 && !ownHost(node)) addedNodes.add(node);
      schedule();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    for (const name of ["pushState", "replaceState"]) {
      const original = history[name];
      const wrapped = function (...args) { const value = original.apply(this, args); schedule(); return value; };
      history[name] = wrapped; historyHooks.push({ name, original, wrapped });
    }
    window.addEventListener("popstate", schedule); window.addEventListener("hashchange", schedule);
    // Zaps survive SPA DOM swaps as CSS rules; there is no per-element mutation work.
  }
  const ownHost = e => /^(open-zap-|open-boosts-)/.test(e.id || "");
  function register(root) {
    if (!current || ownHost(root.host) || rootStyles.has(root)) return;
    if (!knownRoots.some(ref => ref.deref() === root)) knownRoots.push(new WeakRef(root));
    const record = { sheet: null, style: null };
    try {
      if (!("adoptedStyleSheets" in root)) throw new Error("use style fallback");
      record.sheet = new CSSStyleSheet(); record.sheet.replaceSync(shadowCSS);
      root.adoptedStyleSheets = [...root.adoptedStyleSheets, record.sheet];
    } catch (_) {
      record.sheet = null; record.style = document.createElement("style");
      record.style.setAttribute("data-open-boosts", ""); record.style.textContent = shadowCSS;
      root.appendChild(record.style);
    }
    rootStyles.set(root, record);
    observer.observe(root, { childList: true, subtree: true });
    discover(root);
  }
  function discover(node) {
    if (!node || ownHost(node)) return;
    if (node.shadowRoot) register(node.shadowRoot);
    for (const e of node.querySelectorAll?.("*") || []) if (!ownHost(e) && e.shadowRoot) register(e.shadowRoot);
  }
  function installShadow() {
    const original = Element.prototype.attachShadow;
    const wrapped = function (options) { const root = original.call(this, options); register(root); return root; };
    Element.prototype.attachShadow = wrapped; attachHook = { original, wrapped };
    // Closed roots created before first apply cannot be enumerated. Same-origin
    // iframe content is the engine's per-frame injection job; never pierce it here.
    knownRoots = knownRoots.filter(ref => ref.deref()?.host.isConnected);
    for (const ref of knownRoots) register(ref.deref());
    discover(document.documentElement);
  }
  function cancelEarly() {
    earlyObserver?.disconnect(); earlyObserver = null;
    if (earlyReady) document.removeEventListener("DOMContentLoaded", earlyReady);
    earlyReady = null; pending = null;
  }
  function clear() {
    cancelEarly(); current = null;
    observer?.disconnect(); observer = null;
    for (const [root, record] of rootStyles) {
      if (record.sheet) root.adoptedStyleSheets = root.adoptedStyleSheets.filter(s => s !== record.sheet);
      record.style?.remove();
    }
    rootStyles.clear(); addedNodes.clear(); shadowCSS = "";
    knownRoots = knownRoots.filter(ref => ref.deref()?.host.isConnected);
    if (attachHook && Element.prototype.attachShadow === attachHook.wrapped) Element.prototype.attachShadow = attachHook.original;
    attachHook = null;
    if (frame) cancelAnimationFrame(frame); frame = 0;
    style?.remove(); style = null; cssText = "";
    for (const h of historyHooks) if (history[h.name] === h.wrapped) history[h.name] = h.original;
    historyHooks = [];
    window.removeEventListener("popstate", schedule); window.removeEventListener("hashchange", schedule);
    // Arbitrary prior user JS effects cannot be undone. Reload after editing Boost JS.
  }
  function apply(plan) {
    if (!plan || !Array.isArray(plan.boosts) || !plan.boosts.length) { clear(); window.dispatchEvent(new CustomEvent("open-boosts-applied")); return; }
    if (current?.planID === plan.planID) return;
    if (!document.documentElement) {
      pending = plan;
      if (!earlyObserver) {
        earlyReady = () => { if (document.documentElement && pending) { const p = pending; cancelEarly(); apply(p); } };
        earlyObserver = new MutationObserver(earlyReady); earlyObserver.observe(document, { childList: true });
        document.addEventListener("DOMContentLoaded", earlyReady, { once: true });
      }
      return;
    }
    clear();
    const zaps = zapRules(plan);
    cssText = generatedCSS(plan) + plan.boosts.map(b => b.css ? `/* open-boost:${b.boostID} */\n${b.css}\n` : "").join("") + zaps.css;
    if (!cssText.trim() && !(plan.js || "").trim()) return;
    current = { planID: plan.planID, boostIDs: plan.boosts.map(b => b.boostID), zapCount: zaps.count };
    style = document.createElement("style"); style.id = STYLE_ID; style.textContent = cssText;
    // Internal manifest lets a later-loaded picker list persisted selectors by boostID.
    style.dataset.openZaps = JSON.stringify(plan.boosts.map(b => ({ boostID: b.boostID, zaps: b.zaps || [] })));
    document.documentElement.appendChild(style);
    installGuards();
    // Root-scoped selectors use :host, since body is outside each shadow scope.
    shadowCSS = generatedCSS({ ...plan, colorAdjustment: null, textZoom: null }).replace(/(^|\n)body, body /g, "$1:host, :host ") + zaps.css;
    installShadow();
    // Script-element semantics preserve main-world top-level JS. No eval/Function or wrapping.
    // CSP can block this; the harness has no CSP. JS effects require reload to undo.
    if ((plan.js || "").trim()) {
      const script = document.createElement("script"); script.textContent = plan.js;
      document.documentElement.appendChild(script); script.remove();
    }
    post("boost:applied", { planID: plan.planID });
    window.dispatchEvent(new CustomEvent("open-boosts-applied"));
  }
  window.__openBoosts = {
    version: 1, apply, clear,
    state: () => ({ appliedPlanID: current?.planID ?? null, boostIDs: current ? [...current.boostIDs] : [], zapCount: current?.zapCount ?? 0 }),
  };
  bridge._handlers.push(msg => {
    if (msg?.v !== 1) { console.warn("[open-boosts]", "unsupported bridge version"); return; }
    try {
      if (msg.type === "boost:apply") apply(msg.payload);
      else if (msg.type === "boost:clear") clear();
    } catch (e) { console.warn("[open-boosts]", e); }
  });
})();
