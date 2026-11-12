import Foundation

/// Open's own scriptlet library: a clean-room implementation of the commonly used filter-list
/// scriptlets, written from their documented behavior (names and arguments are list syntax;
/// no third-party scriptlet code is bundled — uBO's are GPL-3.0, docs/plans/adblock-fork.md §8.5).
/// Unknown scriptlet names are skipped by the parser.
public enum AdBlockScriptlets {
    /// Filter-list name or alias → Open's implementation name.
    static let aliases: [String: String] = [
        "set-constant": "set-constant", "set": "set-constant",
        "abort-on-property-read": "abort-on-property-read", "aopr": "abort-on-property-read",
        "abort-on-property-write": "abort-on-property-write", "aopw": "abort-on-property-write",
        "abort-current-script": "abort-current-script", "acs": "abort-current-script",
        "abort-current-inline-script": "abort-current-script", "acis": "abort-current-script",
        "no-settimeout-if": "no-setTimeout-if", "nostif": "no-setTimeout-if", "prevent-settimeout": "no-setTimeout-if",
        "no-setinterval-if": "no-setInterval-if", "nosiif": "no-setInterval-if", "prevent-setinterval": "no-setInterval-if",
        "addeventlistener-defuser": "addEventListener-defuser", "aeld": "addEventListener-defuser",
        "prevent-addeventlistener": "addEventListener-defuser",
        "remove-attr": "remove-attr", "ra": "remove-attr",
        "remove-class": "remove-class", "rc": "remove-class",
        "json-prune": "json-prune",
        "prevent-fetch": "prevent-fetch", "no-fetch-if": "prevent-fetch",
        "prevent-xhr": "prevent-xhr", "no-xhr-if": "prevent-xhr",
        "noeval": "noeval",
    ]

    public static func canonical(_ name: String) -> String? {
        var n = name.lowercased()
        if n.hasSuffix(".js") { n.removeLast(3) }
        return aliases[n]
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Main-world source: the host gate, the exceptions, the library and the calls.
    static func source(calls: [(domains: AdBlockExtraRules.Domains, scriptlet: AdBlockExtraRules.Scriptlet)],
                       exceptions: [(domains: AdBlockExtraRules.Domains, key: String)]) -> String {
        var seen = Set<String>()
        let callJSON: [[String: Any]] = calls.compactMap { c in
            guard let name = canonical(c.scriptlet.name), seen.insert(c.scriptlet.key + "\u{2}\(c.domains)").inserted else { return nil }
            let key = ([name] + c.scriptlet.args).joined(separator: "\u{1}")
            return ["n": name, "a": c.scriptlet.args, "i": c.domains.include, "x": c.domains.exclude, "k": key]
        }
        let exJSON: [[String: Any]] = exceptions.map { e in
            // Exceptions name the scriptlet as the list wrote it; compare by canonical name.
            var key = e.key
            if !key.isEmpty {
                var parts = key.components(separatedBy: "\u{1}")
                if let name = canonical(parts[0]) { parts[0] = name }
                key = parts.joined(separator: "\u{1}")
            }
            return ["i": e.domains.include, "x": e.domains.exclude, "k": key]
        }
        return """
        (() => {
        'use strict';
        const host = location.hostname.toLowerCase().replace(/\\.$/, '');
        const hit = d => host === d || host.endsWith('.' + d);
        const applies = r => r.i.some(hit) && !r.x.some(hit);
        let all = false; const off = new Set();
        for (const e of \(json(exJSON))) if (applies(e)) { if (e.k === '') all = true; else off.add(e.k); }
        if (all) return;
        const calls = \(json(callJSON)).filter(c => applies(c) && !off.has(c.k));
        if (calls.length === 0) return;
        \(library)
        for (const c of calls) { try { L[c.n](...c.a); } catch (_) {} }
        })();
        """
    }

    /// Open-world source for the `:style()` rules of one domain.
    static func styleSource(_ rules: [(domains: AdBlockExtraRules.Domains, rule: AdBlockExtraRules.StyleRule)]) -> String {
        let r: [[String: Any]] = rules.map { ["i": $0.domains.include, "x": $0.domains.exclude, "c": $0.rule.css] }
        return """
        (() => {
        const host = location.hostname.toLowerCase().replace(/\\.$/, '');
        const hit = d => host === d || host.endsWith('.' + d);
        const css = \(json(r)).filter(r => r.i.some(hit) && !r.x.some(hit)).map(r => r.c).join('\\n');
        if (!css) return;
        try {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(css);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        } catch (_) {
          const style = document.createElement('style');
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        }
        })();
        """
    }

    /// The library. Every entry point refuses bad arguments silently; nothing logs.
    static let library = #"""
    const defineProperty = Object.defineProperty, getDescriptor = Object.getOwnPropertyDescriptor;
    const isObject = v => v !== null && (typeof v === 'object' || typeof v === 'function');
    // '' matches everything; '/re/flags' is a regular expression; anything else is a substring.
    // A leading '!' negates.
    const matcher = raw => {
      let s = String(raw ?? ''), negate = false;
      if (s.startsWith('!')) { negate = true; s = s.slice(1); }
      let test = () => true;
      const re = /^\/(.+)\/([dgimsuy]*)$/.exec(s);
      if (re) { try { const r = new RegExp(re[1], re[2].replace('g', '')); test = t => r.test(t); } catch (_) { test = () => false; } }
      else if (s !== '') test = t => String(t).includes(s);
      return negate ? t => !test(t) : test;
    };
    // Walks `a.b.c` from window. Missing or not-yet-assigned links get an accessor that resumes
    // the walk when the page assigns an object there.
    const walk = (chain, leaf) => {
      const parts = String(chain).split('.').filter(Boolean);
      if (parts.length === 0) return;
      const step = (owner, i) => {
        const key = parts[i];
        if (i === parts.length - 1) {
          const d = getDescriptor(owner, key);
          if (d && d.configurable === false) return;
          const current = d ? ('value' in d ? d.value : undefined) : undefined;
          try { defineProperty(owner, key, { configurable: true, enumerable: true, ...leaf(current) }); } catch (_) {}
          return;
        }
        let inner;
        try { inner = owner[key]; } catch (_) { return; }
        if (isObject(inner)) { step(inner, i + 1); return; }
        const d = getDescriptor(owner, key);
        if (d && d.configurable === false) return;
        try {
          defineProperty(owner, key, { configurable: true, enumerable: true,
            get() { return inner; },
            set(v) { inner = v; if (isObject(v)) step(v, i + 1); } });
        } catch (_) {}
      };
      step(window, 0);
    };
    const constant = raw => {
      const table = { 'undefined': undefined, 'false': false, 'true': true, 'null': null, '': '', 'emptyStr': '',
        'noopFunc': function () {}, 'trueFunc': function () { return true; }, 'falseFunc': function () { return false; },
        'emptyArr': [], 'emptyObj': {}, 'yes': 'yes', 'no': 'no' };
      if (Object.prototype.hasOwnProperty.call(table, raw)) return { ok: true, value: table[raw] };
      if (/^-?\d{1,5}$/.test(raw) && Math.abs(Number(raw)) <= 32767) return { ok: true, value: Number(raw) };
      return { ok: false };
    };
    const neuter = (owner, name, shouldBlock, blocked) => {
      const real = owner[name];
      if (typeof real !== 'function') return;
      owner[name] = new Proxy(real, { apply(target, self, args) {
        let block = false;
        try { block = shouldBlock(args); } catch (_) {}
        return block ? blocked(target, self, args) : Reflect.apply(target, self, args);
      } });
    };
    const timerFilter = (needle, delay) => {
      if ((needle ?? '') === '' && (delay ?? '') === '') return null;
      const text = matcher(needle);
      let d = String(delay ?? ''), negate = false;
      if (d.startsWith('!')) { negate = true; d = d.slice(1); }
      const wanted = d === '' ? null : Number(d);
      return args => {
        const fn = args[0], ms = Number(args[1] ?? 0);
        const delayHit = wanted === null || Number.isNaN(wanted) ? true : (negate ? ms !== wanted : ms === wanted);
        return text(typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn)) && delayHit;
      };
    };
    const onDOM = (run, behavior) => {
      const go = () => { try { run(); } catch (_) {} };
      go();
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go, { once: true });
      let queued = false;
      const observer = new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; go(); }); } });
      const start = () => observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      if (document.documentElement) start(); else document.addEventListener('readystatechange', start, { once: true });
      if (!String(behavior ?? '').includes('stay')) {
        window.addEventListener('load', () => setTimeout(() => observer.disconnect(), 10000), { once: true });
      }
    };
    const requestProps = raw => {
      const s = String(raw ?? '').trim();
      if (s === '') return null;
      const tests = [];
      for (const part of s.split(/\s+/)) {
        const m = /^(\w+):(.*)$/.exec(part);
        if (m) tests.push([m[1], matcher(m[2])]); else tests.push(['url', matcher(part)]);
      }
      return props => tests.every(([key, test]) => test(props[key] ?? ''));
    };
    const L = {
      'set-constant'(chain, raw) {
        const c = constant(String(raw ?? ''));
        if (!c.ok) return;
        walk(chain, () => ({ get() { return c.value; }, set() {} }));
      },
      'abort-on-property-read'(chain) {
        walk(chain, () => ({ get() { throw new ReferenceError(chain); }, set() {} }));
      },
      'abort-on-property-write'(chain) {
        walk(chain, current => { let v = current; return { get() { return v; }, set() { throw new ReferenceError(chain); } }; });
      },
      'abort-current-script'(chain, needle) {
        const test = matcher(needle), me = document.currentScript;
        const check = () => {
          const s = document.currentScript;
          if (!(s instanceof HTMLScriptElement) || s === me) return;
          if (test(s.src || s.textContent || '')) throw new ReferenceError(chain);
        };
        walk(chain, current => { let v = current; return { get() { check(); return v; }, set(n) { check(); v = n; } }; });
      },
      'no-setTimeout-if'(needle, delay) {
        const f = timerFilter(needle, delay);
        if (f) neuter(window, 'setTimeout', f, (t, self, args) => Reflect.apply(t, self, [function () {}, args[1]]));
      },
      'no-setInterval-if'(needle, delay) {
        const f = timerFilter(needle, delay);
        if (f) neuter(window, 'setInterval', f, (t, self, args) => Reflect.apply(t, self, [function () {}, args[1]]));
      },
      'addEventListener-defuser'(type, needle) {
        if ((type ?? '') === '' && (needle ?? '') === '') return;
        const typeTest = matcher(type), handlerTest = matcher(needle);
        neuter(EventTarget.prototype, 'addEventListener', args => {
          const h = args[1];
          const text = typeof h === 'function' ? Function.prototype.toString.call(h)
            : (isObject(h) && typeof h.handleEvent === 'function' ? Function.prototype.toString.call(h.handleEvent) : String(h));
          return typeTest(String(args[0])) && handlerTest(text);
        }, () => undefined);
      },
      'remove-attr'(attrs, selector, behavior) {
        const names = String(attrs ?? '').split('|').map(s => s.trim()).filter(Boolean);
        if (names.length === 0) return;
        const sel = String(selector ?? '').trim() || names.map(n => `[${CSS.escape(n)}]`).join(',');
        onDOM(() => { for (const el of document.querySelectorAll(sel)) for (const n of names) el.removeAttribute(n); }, behavior);
      },
      'remove-class'(classes, selector, behavior) {
        const names = String(classes ?? '').split('|').map(s => s.trim()).filter(Boolean);
        if (names.length === 0) return;
        const sel = String(selector ?? '').trim() || names.map(n => `.${CSS.escape(n)}`).join(',');
        onDOM(() => { for (const el of document.querySelectorAll(sel)) el.classList.remove(...names); }, behavior);
      },
      'json-prune'(prune, required) {
        const paths = String(prune ?? '').split(/\s+/).filter(Boolean).map(p => p.split('.'));
        const needs = String(required ?? '').split(/\s+/).filter(Boolean).map(p => p.split('.'));
        if (paths.length === 0) return;
        const visit = (node, path, i, act) => {
          if (!isObject(node)) return false;
          const key = path[i], last = i === path.length - 1;
          const keys = key === '[]' || key === '*' ? Object.keys(node) : [key];
          let found = false;
          for (const k of keys) {
            if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
            if (last) { found = true; if (act) delete node[k]; }
            else if (visit(node[k], path, i + 1, act)) found = true;
          }
          return found;
        };
        const prunes = obj => {
          if (!isObject(obj)) return obj;
          if (needs.length && !needs.every(p => visit(obj, p, 0, false))) return obj;
          for (const p of paths) visit(obj, p, 0, true);
          return obj;
        };
        const parse = JSON.parse;
        JSON.parse = new Proxy(parse, { apply(t, self, args) { return prunes(Reflect.apply(t, self, args)); } });
        if (typeof Response === 'function') {
          const json = Response.prototype.json;
          Response.prototype.json = new Proxy(json, { apply(t, self, args) { return Reflect.apply(t, self, args).then(prunes); } });
        }
      },
      'prevent-fetch'(props) {
        const test = requestProps(props);
        if (!test || typeof fetch !== 'function') return;
        neuter(window, 'fetch', args => {
          const input = args[0], init = args[1] || {};
          const url = input instanceof Request ? input.url : String(input);
          const method = (init.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
          return test({ url, method });
        }, () => Promise.resolve(new Response('', { status: 200, statusText: 'OK' })));
      },
      'prevent-xhr'(props) {
        const test = requestProps(props);
        if (!test) return;
        const blocked = new WeakSet(), proto = XMLHttpRequest.prototype;
        const open = proto.open;
        proto.open = new Proxy(open, { apply(t, self, args) {
          try { if (test({ method: String(args[0] ?? 'GET').toUpperCase(), url: String(args[1] ?? '') })) blocked.add(self); else blocked.delete(self); } catch (_) {}
          return Reflect.apply(t, self, args);
        } });
        const send = proto.send;
        proto.send = new Proxy(send, { apply(t, self, args) {
          if (!blocked.has(self)) return Reflect.apply(t, self, args);
          for (const [k, v] of [['readyState', 4], ['status', 200], ['statusText', 'OK'], ['response', ''], ['responseText', '']]) {
            try { defineProperty(self, k, { configurable: true, value: v }); } catch (_) {}
          }
          setTimeout(() => {
            for (const type of ['readystatechange', 'load', 'loadend']) { try { self.dispatchEvent(new Event(type)); } catch (_) {} }
          }, 1);
        } });
      },
      'noeval'() {
        window.eval = new Proxy(window.eval, { apply() { return undefined; } });
      },
    };
    """#
}
