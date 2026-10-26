// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

//! CXX bridge over the vendored Brave `adblock` crate (MPL-2.0), the only
//! Rust Open writes by hand (docs/plans/adblock-fork.md §5). C++ sees one
//! opaque engine, flat structs, one enum, strings and string vectors.
//!
//! Chromium builds Rust with `-Cpanic=abort`, so a panic here ends the
//! browser process, and `catch_unwind` cannot help. Crate calls that return
//! a `Result` can still panic on hostile input: guard every known case
//! before the call (a DAT of 4 bytes or less, review 98-3) and fuzz the rest
//! (docs/followups.md). This file indexes nothing it has not checked.
//!
//! Nothing here builds CSS text (§8.3): cosmetic results are sanitized
//! selector and declaration vectors, and the renderer makes one rule per
//! selector.

use std::collections::{BTreeSet, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;

/// Bumped on any change to `ParseOptions`, permissions, crate or regex
/// features, or bridge semantics: a cached DAT from another format is never
/// loaded (§5.5, review 100-1(a)).
const SHIM_VERSION: u32 = 2;
/// The adblock crate's features (third_party/rust/adblock/v0_8/BUILD.gn).
const CRATE_FEATURES: &str = "embedded-domain-resolver,full-regex-handling,resource-assembler";
/// The regex crate's features (the adblock-v0_8 crate patch, review 97-1).
const REGEX_FEATURES: &str =
    "perf-backtrack,perf-cache,perf-dfa,perf-inline,perf-onepass,std,unicode";

/// D-17: the longest URL spec (without the fragment) a check matches whole.
const MATCH_CAP: usize = 8192;
/// §8.3: the longest selector that crosses the bridge.
const MAX_SELECTOR: usize = 2048;
/// §8.3: selector text per frame payload.
const PAYLOAD_CAP: usize = 256 * 1024;

#[cxx::bridge(namespace = "open_adblock")]
mod ffi {
    /// The request's resource type, mapped to the crate's vocabulary inside
    /// the shim (no free-form string crosses the bridge; review 98-6).
    enum OpenRequestType {
        Document,
        Subdocument,
        Script,
        Image,
        Stylesheet,
        Font,
        Media,
        Object,
        Xmlhttprequest,
        Ping,
        Websocket,
        CspReport,
        Other,
    }

    /// The result of one network check.
    struct OpenBlockerResult {
        /// A blocking rule matched (after exceptions).
        matched: bool,
        /// An `$important` rule matched (the crate already applied precedence).
        important: bool,
        /// A `$redirect` rule matched.
        has_redirect: bool,
        /// The crate's `data:<mime>;base64,…` resource for a `$redirect`, for
        /// every request type; C++ decides whether to serve it (§7.4).
        redirect_data_url: String,
        /// The URL after `$removeparam`, or empty (always empty when
        /// `truncated`).
        rewritten_url: String,
        /// CSP directives to add (document and subdocument only), or empty.
        csp_directives: String,
        /// The URL was longer than the match cap and only its first part was
        /// matched (§7.7).
        truncated: bool,
    }

    /// A `##selector:style(declarations)` rule.
    struct OpenStyleRule {
        selector: String,
        /// Sanitized declarations, `; `-separated, each with `!important`.
        declarations: String,
    }

    /// A `:remove-attr()` or `:remove-class()` rule.
    struct OpenRemoveRule {
        selector: String,
        names: Vec<String>,
    }

    /// The cosmetic filters for one page, as sanitized vectors (§8.3). Sorted,
    /// except `hide_selectors` (sorted only when the payload cap applies).
    struct OpenCosmeticResources {
        /// Selectors to hide (`display: none !important`).
        hide_selectors: Vec<String>,
        style_rules: Vec<OpenStyleRule>,
        /// Selectors of elements to remove from the DOM (`:remove()`).
        remove_selectors: Vec<String>,
        remove_attrs: Vec<OpenRemoveRule>,
        remove_classes: Vec<OpenRemoveRule>,
        /// The crate's scriptlet code (main world), or empty.
        scriptlets: String,
        /// Generic `#@#` exceptions; the renderer echoes them back with its
        /// class and ID reports.
        exceptions: Vec<String>,
        /// `$generichide`: the renderer must not report class and ID tokens.
        generichide: bool,
        /// Selectors dropped for a procedural operator (v1 runs none).
        dropped_procedural: u32,
        /// Selectors and declarations dropped as unsafe or over a cap.
        dropped_unsafe: u32,
    }

    /// What a text build produced (§5.5).
    struct OpenBuildReport {
        /// A DAT of this build restores the same engine. False when a list
        /// has `$removeparam` or `:remove*()` rules, which a v0 DAT drops.
        lossless: bool,
        /// The dropped kinds found: `removeparam`, `remove`, `remove-attr`,
        /// `remove-class`.
        lossy_kinds: Vec<String>,
        resources_loaded: u32,
        /// Empty, `json` (the resources file did not parse) or `empty` (it
        /// had no resources).
        resources_error: String,
    }

    /// Facts about an engine.
    struct OpenEngineInfo {
        /// Bytes of the last serialization (0 before the first one).
        serialized_size: u64,
        /// Lists consumed by the last text build.
        list_count: u32,
    }

    extern "Rust" {
        type OpenAdblockEngine;

        /// `adblock=…;shim=…;features=…;regex=…;dat=v0`: what a cached DAT
        /// must have been made with (the receipt binds it).
        fn open_adblock_engine_format() -> String;
        fn open_adblock_create_empty() -> Box<OpenAdblockEngine>;
        fn open_adblock_build(list_texts: &[String], resources_json: &str)
            -> Box<OpenAdblockEngine>;
        fn open_adblock_build_report(engine: &OpenAdblockEngine) -> OpenBuildReport;
        fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8>;
        fn open_adblock_deserialize(
            engine: &mut OpenAdblockEngine,
            dat: &[u8],
            resources_json: &str,
        ) -> bool;
        fn open_adblock_check(
            engine: &OpenAdblockEngine,
            url: &str,
            source_url: &str,
            request_type: OpenRequestType,
        ) -> OpenBlockerResult;
        fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources;
        fn open_adblock_hidden_selectors(
            engine: &OpenAdblockEngine,
            classes: &[String],
            ids: &[String],
            exceptions: &[String],
        ) -> Vec<String>;
        fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo;
    }
}

use ffi::{
    OpenBlockerResult, OpenBuildReport, OpenCosmeticResources, OpenEngineInfo, OpenRemoveRule,
    OpenRequestType, OpenStyleRule,
};

/// One Profile's engine. Shared by every check of the Profile under a read
/// lock on the C++ side, so it must be `Send + Sync` (R-1).
pub struct OpenAdblockEngine {
    inner: Engine,
    list_count: u32,
    serialized_size: AtomicU64,
    report: BuildReport,
}

#[derive(Clone, Default)]
struct BuildReport {
    lossy_kinds: BTreeSet<&'static str>,
    resources_loaded: u32,
    resources_error: &'static str,
}

impl OpenAdblockEngine {
    fn new(inner: Engine, list_count: u32, report: BuildReport) -> Box<Self> {
        Box::new(Self { inner, list_count, serialized_size: AtomicU64::new(0), report })
    }
}

pub fn open_adblock_engine_format() -> String {
    format!(
        "adblock=0.8.11;shim={SHIM_VERSION};features={CRATE_FEATURES};regex={REGEX_FEATURES};dat=v0"
    )
}

pub fn open_adblock_create_empty() -> Box<OpenAdblockEngine> {
    OpenAdblockEngine::new(Engine::new(true), 0, BuildReport::default())
}

/// Parses the crate's own serialized `Vec<Resource>` and applies it. The
/// crate's assembler would read uBlock Origin's files from paths, and it
/// panics on malformed input (`resource_assembler.rs`), so adblock-fork Step
/// 7 produces this JSON form instead (R-2).
fn apply_resources(engine: &mut Engine, resources_json: &str, report: &mut BuildReport) {
    if resources_json.is_empty() {
        return;
    }
    match serde_json::from_str::<Vec<Resource>>(resources_json) {
        Ok(resources) if !resources.is_empty() => {
            report.resources_loaded = u32::try_from(resources.len()).unwrap_or(u32::MAX);
            engine.use_resources(resources);
        }
        Ok(_) => report.resources_error = "empty",
        Err(_) => report.resources_error = "json",
    }
}

/// The rule kinds a v0 DAT drops (F-31), found by a conservative scan: a
/// false positive only costs a text build at the next launch.
fn lossy_kinds(list_texts: &[String]) -> BTreeSet<&'static str> {
    let mut kinds = BTreeSet::new();
    for text in list_texts {
        for line in text.lines() {
            let line = line.trim_start();
            if line.starts_with('!') || line.starts_with('[') {
                continue;
            }
            if line.contains("removeparam") {
                kinds.insert("removeparam");
            }
            if line.contains(":remove(") {
                kinds.insert("remove");
            }
            if line.contains(":remove-attr(") {
                kinds.insert("remove-attr");
            }
            if line.contains(":remove-class(") {
                kinds.insert("remove-class");
            }
        }
    }
    kinds
}

/// Builds an engine from the enabled lists (in the caller's order) and the
/// scriptlet and redirect resources. CPU-heavy: C++ calls it on a background
/// task runner only.
pub fn open_adblock_build(list_texts: &[String], resources_json: &str) -> Box<OpenAdblockEngine> {
    let mut set = FilterSet::new(false);
    for text in list_texts {
        set.add_filter_list(text, ParseOptions::default());
    }
    let mut engine = Engine::from_filter_set(set, true);
    let mut report = BuildReport { lossy_kinds: lossy_kinds(list_texts), ..Default::default() };
    apply_resources(&mut engine, resources_json, &mut report);
    OpenAdblockEngine::new(engine, u32::try_from(list_texts.len()).unwrap_or(u32::MAX), report)
}

pub fn open_adblock_build_report(engine: &OpenAdblockEngine) -> OpenBuildReport {
    OpenBuildReport {
        lossless: engine.report.lossy_kinds.is_empty(),
        lossy_kinds: engine.report.lossy_kinds.iter().map(|k| (*k).to_string()).collect(),
        resources_loaded: engine.report.resources_loaded,
        resources_error: engine.report.resources_error.to_string(),
    }
}

pub fn open_adblock_serialize(engine: &OpenAdblockEngine) -> Vec<u8> {
    match engine.inner.serialize_raw() {
        Ok(bytes) => {
            engine.serialized_size.store(bytes.len() as u64, Ordering::Relaxed);
            bytes
        }
        Err(_) => Vec::new(),
    }
}

/// Loads a serialized engine into an empty one, then applies the resources
/// (a DAT never carries them, F-31). False on any error (version skew,
/// truncation); C++ then builds from text.
pub fn open_adblock_deserialize(
    engine: &mut OpenAdblockEngine,
    dat: &[u8],
    resources_json: &str,
) -> bool {
    // The crate reads the byte after its 4-byte magic without a length check
    // (data_format/mod.rs:90): a DAT of 4 bytes or less panics (review 98-3).
    if dat.len() <= 4 {
        return false;
    }
    match engine.inner.deserialize(dat) {
        Ok(()) => {
            engine.serialized_size.store(dat.len() as u64, Ordering::Relaxed);
            let mut report = BuildReport::default();
            apply_resources(&mut engine.inner, resources_json, &mut report);
            engine.report = report;
            true
        }
        Err(_) => {
            // A failed load may leave partial state: start from empty again.
            engine.inner = Engine::new(true);
            false
        }
    }
}

fn crate_request_type(request_type: OpenRequestType) -> &'static str {
    match request_type {
        OpenRequestType::Document => "document",
        OpenRequestType::Subdocument => "subdocument",
        OpenRequestType::Script => "script",
        OpenRequestType::Image => "image",
        OpenRequestType::Stylesheet => "stylesheet",
        OpenRequestType::Font => "font",
        OpenRequestType::Media => "media",
        OpenRequestType::Object => "object",
        OpenRequestType::Xmlhttprequest => "xmlhttprequest",
        OpenRequestType::Ping => "ping",
        OpenRequestType::Websocket => "websocket",
        OpenRequestType::CspReport => "csp_report",
        _ => "other",
    }
}

/// §7.7: the URL without its fragment, cut to the match cap after the last
/// separator byte (any byte `^` matches) at or before the cap. True when cut.
fn match_input(url: &str) -> (&str, bool) {
    let url = url.split('#').next().unwrap_or("");
    if url.len() <= MATCH_CAP {
        return (url, false);
    }
    let bytes = url.as_bytes();
    let end = bytes
        .get(..MATCH_CAP)
        .unwrap_or(bytes)
        .iter()
        .rposition(|b| !(b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'%')))
        .map(|i| i + 1)
        .unwrap_or(0);
    // `end` follows an ASCII byte (or is 0), so it is a char boundary.
    (url.get(..end).unwrap_or(""), true)
}

/// One network check (R-4 to R-6). A URL the crate cannot parse is allowed.
pub fn open_adblock_check(
    engine: &OpenAdblockEngine,
    url: &str,
    source_url: &str,
    request_type: OpenRequestType,
) -> OpenBlockerResult {
    let (url, truncated) = match_input(url);
    let mut result = OpenBlockerResult {
        matched: false,
        important: false,
        has_redirect: false,
        redirect_data_url: String::new(),
        rewritten_url: String::new(),
        csp_directives: String::new(),
        truncated,
    };
    let type_name = crate_request_type(request_type);
    let Ok(request) = Request::new(url, source_url, type_name) else {
        return result;
    };
    let blocker = engine.inner.check_network_request(&request);
    result.matched = blocker.matched;
    result.important = blocker.important;
    if let Some(redirect) = blocker.redirect {
        result.has_redirect = true;
        // 0.8.11 returns a complete `data:` URL (F-32).
        if redirect.starts_with("data:") {
            result.redirect_data_url = redirect;
        }
    }
    if !truncated {
        result.rewritten_url = blocker.rewritten_url.unwrap_or_default();
    }
    if type_name == "document" || type_name == "subdocument" {
        result.csp_directives = engine.inner.get_csp_directives(&request).unwrap_or_default();
    }
    result
}

/// §8.3: uBO and AdGuard procedural operators. v1 runs none of them.
const PROCEDURAL: &[&str] = &[
    ":has-text(",
    ":-abp-",
    ":xpath(",
    ":upward(",
    ":matches-css",
    ":matches-attr(",
    ":matches-prop(",
    ":matches-media(",
    ":matches-path(",
    ":min-text-length(",
    ":watch-attr(",
    ":others(",
    ":nth-ancestor(",
    ":if(",
    ":if-not(",
    ":contains(",
    ":-ext-",
    ":remove(",
    ":style(",
];

pub(crate) enum Verdict {
    Keep,
    Procedural,
    Unsafe,
}

/// The bytes `check_selector` acts on; a selector without any is kept.
const SPECIAL: [bool; 256] = {
    let mut table = [false; 256];
    let bytes = b"{};<@/*\\\"'[]():\n\r\x0c\x00";
    let mut i = 0;
    while i < bytes.len() {
        table[bytes[i] as usize] = true;
        i += 1;
    }
    table
};

/// True when a procedural operator starts at one of the selector's colons
/// (every operator in `PROCEDURAL` begins with `:`).
fn has_procedural(bytes: &[u8]) -> bool {
    bytes.iter().enumerate().filter(|(_, b)| **b == b':').any(|(at, _)| {
        let rest = bytes.get(at..).unwrap_or(&[]);
        PROCEDURAL.iter().any(|op| {
            rest.get(..op.len()).is_some_and(|head| head.eq_ignore_ascii_case(op.as_bytes()))
        })
    })
}

/// §8.3 selector rules: nothing that can open or close a rule, load a
/// resource or run script, nothing procedural, nothing unbalanced. One pass
/// over the bytes, no allocation: it runs on every selector of every page.
///
/// `{`, `}`, `;`, `<`, `@` and `/*` count outside quoted strings only:
/// inside a CSS string they are text, and only a newline can end the string
/// early, so newlines are refused everywhere. Real list selectors quote `;`
/// in attribute values (`div[style^="z-index: 999999999;"]`). A `\` escapes
/// the next character (Tailwind-style class names need it); inside quotes,
/// brackets do not count.
pub(crate) fn check_selector(selector: &str) -> Verdict {
    let bytes = selector.as_bytes();
    if bytes.is_empty() || bytes.len() > MAX_SELECTOR {
        return Verdict::Unsafe;
    }
    // Most selectors (`.ad-box`, `#ad_300`) have no byte the rules look at.
    if !bytes.iter().any(|b| SPECIAL[usize::from(*b)]) {
        return Verdict::Keep;
    }
    let mut unsafe_text = false;
    let mut colon = false;
    let mut stack = [0u8; 32];
    let mut depth = 0usize;
    let mut quote = 0u8;
    let mut escaped = false;
    let mut previous = 0u8;
    for &byte in bytes {
        if matches!(byte, b'\n' | b'\r' | 0x0c | 0) {
            unsafe_text = true;
        }
        if escaped {
            escaped = false;
            previous = 0;
            continue;
        }
        if byte == b'\\' {
            escaped = true;
            continue;
        }
        if quote != 0 {
            if byte == quote {
                quote = 0;
            }
            previous = 0;
            continue;
        }
        if matches!(byte, b'{' | b'}' | b';' | b'<' | b'@') || (previous == b'/' && byte == b'*') {
            unsafe_text = true;
        }
        previous = byte;
        match byte {
            b'"' | b'\'' => quote = byte,
            b'[' | b'(' => match stack.get_mut(depth) {
                Some(slot) => {
                    *slot = byte;
                    depth += 1;
                }
                None => unsafe_text = true,
            },
            b']' | b')' => {
                let open = if byte == b']' { b'[' } else { b'(' };
                if depth > 0 && stack.get(depth - 1) == Some(&open) {
                    depth -= 1;
                } else {
                    unsafe_text = true;
                }
            }
            b':' => colon = true,
            _ => {}
        }
    }
    if colon && has_procedural(bytes) {
        return Verdict::Procedural;
    }
    if unsafe_text || depth != 0 || quote != 0 || escaped {
        return Verdict::Unsafe;
    }
    Verdict::Keep
}

/// §8.3 `:style()` rules. None on unsafe text; else the declarations, each
/// with `!important`, joined by `; `.
fn sanitize_declarations(declarations: &[String]) -> Option<String> {
    const BAD: &[&str] = &[
        "url(", "image(", "image-set(", "cross-fade(", "element(", "attr(", "expression(", "\\",
        "/*", "{", "}", "@", "<", "\"", "'",
    ];
    let mut out: Vec<String> = Vec::new();
    for declaration in declarations {
        let lower = declaration.to_ascii_lowercase();
        if BAD.iter().any(|bad| lower.contains(bad)) {
            return None;
        }
        for part in declaration.split(';') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            if part.to_ascii_lowercase().ends_with("!important") {
                out.push(part.to_string());
            } else {
                out.push(format!("{part} !important"));
            }
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out.join("; "))
    }
}

/// Counts drops and the payload's selector bytes.
#[derive(Default)]
struct Sanitizer {
    procedural: u32,
    unsafe_: u32,
    bytes: usize,
}

impl Sanitizer {
    fn keep(&mut self, selector: &str) -> bool {
        match check_selector(selector) {
            Verdict::Procedural => {
                self.procedural = self.procedural.saturating_add(1);
                false
            }
            Verdict::Unsafe => {
                self.unsafe_ = self.unsafe_.saturating_add(1);
                false
            }
            Verdict::Keep if self.bytes.saturating_add(selector.len()) > PAYLOAD_CAP => {
                self.unsafe_ = self.unsafe_.saturating_add(1);
                false
            }
            Verdict::Keep => {
                self.bytes = self.bytes.saturating_add(selector.len());
                true
            }
        }
    }
}

/// The page's cosmetic filters as sanitized, sorted vectors (R-7, R-8,
/// §8.3). A URL the crate cannot parse gives empty resources.
pub fn open_adblock_cosmetic(engine: &OpenAdblockEngine, url: &str) -> OpenCosmeticResources {
    // The crate returns owned sets: move the strings, do not copy them.
    let adblock::cosmetic_filter_cache::UrlSpecificResources {
        hide_selectors,
        style_selectors,
        remove_selectors,
        remove_attrs,
        remove_classes,
        exceptions,
        injected_script,
        generichide,
    } = engine.inner.url_cosmetic_resources(url);
    let mut sanitizer = Sanitizer::default();

    // Hide selectors stay in the crate's order: sorting about 450 strings
    // costs some 30 µs per document, and each selector is its own rule. Only
    // a payload over the cap is sorted, so the cap drops the same ones.
    let mut hide_selectors: Vec<String> = hide_selectors.into_iter().collect();
    if hide_selectors.iter().map(String::len).sum::<usize>() > PAYLOAD_CAP {
        hide_selectors.sort_unstable();
    }
    hide_selectors.retain(|s| sanitizer.keep(s));

    let mut style_rules = Vec::new();
    let mut styles: Vec<(String, Vec<String>)> = style_selectors.into_iter().collect();
    styles.sort_unstable();
    // The crate lists a `:remove()` selector among the style selectors too.
    let mut remove_selectors: Vec<String> = remove_selectors
        .into_iter()
        .filter(|s| styles.binary_search_by(|(selector, _)| selector.cmp(s)).is_err())
        .collect();
    for (selector, declarations) in styles {
        if !sanitizer.keep(&selector) {
            continue;
        }
        match sanitize_declarations(&declarations) {
            Some(declarations) => style_rules.push(OpenStyleRule { selector, declarations }),
            None => sanitizer.unsafe_ = sanitizer.unsafe_.saturating_add(1),
        }
    }
    remove_selectors.sort_unstable();
    remove_selectors.retain(|s| sanitizer.keep(s));

    let mut remove_rules = |rules: std::collections::HashMap<String, Vec<String>>| {
        let mut sorted: Vec<(String, Vec<String>)> = rules.into_iter().collect();
        sorted.sort_unstable();
        sorted
            .into_iter()
            .filter(|(selector, _)| sanitizer.keep(selector))
            .map(|(selector, mut names)| {
                names.sort_unstable();
                OpenRemoveRule { selector, names }
            })
            .collect::<Vec<_>>()
    };
    let remove_attrs = remove_rules(remove_attrs);
    let remove_classes = remove_rules(remove_classes);

    let mut exceptions: Vec<String> = exceptions.into_iter().collect();
    exceptions.sort_unstable();

    OpenCosmeticResources {
        hide_selectors,
        style_rules,
        remove_selectors,
        remove_attrs,
        remove_classes,
        scriptlets: injected_script,
        exceptions,
        generichide,
        dropped_procedural: sanitizer.procedural,
        dropped_unsafe: sanitizer.unsafe_,
    }
}

/// Generic hide selectors for the class and ID tokens a page reported,
/// sanitized like the page's own (§8.3).
pub fn open_adblock_hidden_selectors(
    engine: &OpenAdblockEngine,
    classes: &[String],
    ids: &[String],
    exceptions: &[String],
) -> Vec<String> {
    let exceptions: HashSet<String> = exceptions.iter().cloned().collect();
    let mut selectors = engine.inner.hidden_class_id_selectors(classes, ids, &exceptions);
    selectors.sort();
    let mut sanitizer = Sanitizer::default();
    selectors.retain(|s| sanitizer.keep(s));
    selectors
}

pub fn open_adblock_info(engine: &OpenAdblockEngine) -> OpenEngineInfo {
    OpenEngineInfo {
        serialized_size: engine.serialized_size.load(Ordering::Relaxed),
        list_count: engine.list_count,
    }
}

/// R-1: the engine is shared across threads. If this stops compiling, a
/// crate feature that makes `Engine` thread-unsafe came back (adblock-fork
/// D-3): fix the features, not this assertion.
#[allow(dead_code)]
fn _assert_send_sync() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<OpenAdblockEngine>();
}
